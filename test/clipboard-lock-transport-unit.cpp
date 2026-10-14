// Actual ClipboardBridge with a test-only libwayland protocol peer. No compositor/GPU.
#include "ClipboardBridge.hpp"
#include "wlr-data-control-server.h"
#include "wlr-data-control-client.h"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSocketNotifier>
#include <QTemporaryDir>
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <memory>
#include <poll.h>
#include <stdexcept>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <vector>
#include <unistd.h>
#include <wayland-server.h>

static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static bool closed(int fd) { errno = 0; return fcntl(fd, F_GETFD) < 0 && errno == EBADF; }
struct PipeIdentity {
    int fd = -1; dev_t device = 0; ino_t inode = 0;
    explicit PipeIdentity(int value = -1) : fd(value) {
        if (value < 0) return;
        struct stat st{};
        require(fstat(value, &st) == 0 && S_ISFIFO(st.st_mode), "protocol transfer is not a real pipe");
        device = st.st_dev; inode = st.st_ino;
    }
    bool matches(int value) const {
        struct stat st{};
        return value >= 0 && fstat(value, &st) == 0 && S_ISFIFO(st.st_mode) && st.st_dev == device && st.st_ino == inode;
    }
    QJsonObject json() const { return {{"fd", fd}, {"device", QString::number(device)}, {"inode", QString::number(inode)}}; }
};
static int bridgeEndpoint(ClipboardBridge &bridge, const PipeIdentity &pipe, QSocketNotifier::Type type) {
    for (auto *notifier : bridge.findChildren<QSocketNotifier *>()) {
        const int fd = static_cast<int>(notifier->socket());
        if (notifier->isEnabled() && notifier->type() == type && pipe.matches(fd)) {
            const auto mode = fcntl(fd, F_GETFL) & O_ACCMODE;
            require(mode == (type == QSocketNotifier::Read ? O_RDONLY : O_WRONLY), "production endpoint access mode mismatch");
            return fd;
        }
    }
    return -1;
}
static void waitUntil(const std::function<bool()> &condition, const char *message, int limit = 1500) {
    QElapsedTimer time; time.start();
    while (!condition() && time.elapsed() < limit) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
        usleep(500);
    }
    require(condition(), message);
}
static void settle(int duration = 50) {
    QElapsedTimer time; time.start();
    while (time.elapsed() < duration) { QCoreApplication::processEvents(QEventLoop::AllEvents, 5); usleep(500); }
}

class EnvironmentGuard {
  public:
    EnvironmentGuard() { for (const auto *key : {"XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "WAYLAND_SOCKET"}) values.push_back({key, qgetenv(key), qEnvironmentVariableIsSet(key)}); }
    ~EnvironmentGuard() { for (const auto &item : values) if (item.present) qputenv(item.key, item.value); else qunsetenv(item.key); }
  private:
    struct Value { const char *key; QByteArray value; bool present; }; std::vector<Value> values;
};
static int connectSocket(const QString &path) {
    const auto name = path.toLocal8Bit(); sockaddr_un address{}; address.sun_family = AF_UNIX;
    require(name.size() < static_cast<qsizetype>(sizeof address.sun_path), "decoy UNIX path too long");
    memcpy(address.sun_path, name.constData(), static_cast<size_t>(name.size()) + 1);
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0); require(fd >= 0, "decoy socket allocation failed");
    if (::connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof address) != 0) { ::close(fd); throw std::runtime_error("decoy connection failed"); }
    return fd;
}

class ProtocolPeer : public QObject {
  public:
    struct Seat { ProtocolPeer *owner; const char *name; wl_resource *device = nullptr, *selected = nullptr; };
    struct Source { ProtocolPeer *owner; wl_resource *resource; QStringList types; };
    struct Offer { ProtocolPeer *owner; wl_resource *resource; QByteArray payload; bool held; int receivedFd = -1; };
    class Feed : public QObject {
      public:
        Feed(int fd, QByteArray bytes) : fd(fd), bytes(std::move(bytes)), notifier(fd, QSocketNotifier::Write, this) {
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
            connect(&notifier, &QSocketNotifier::activated, this, [this] {
                while (offset < this->bytes.size()) {
                    const auto count = ::write(this->fd, this->bytes.constData() + offset, this->bytes.size() - offset);
                    if (count > 0) offset += count;
                    else if (count < 0 && errno == EINTR) continue;
                    else if (count < 0 && errno == EAGAIN) return;
                    else { finish(); return; }
                }
                finish();
            });
        }
        ~Feed() override { if (fd >= 0) ::close(fd); }
        void finish() { notifier.setEnabled(false); if (fd >= 0) ::close(fd); fd = -1; }
        int fd; QByteArray bytes; qsizetype offset = 0; QSocketNotifier notifier;
    };
    ProtocolPeer() : seats{{this, "human"}, {this, "agent"}} {
        require(runtime.isValid(), "private protocol runtime failed");
        qputenv("XDG_RUNTIME_DIR", runtime.path().toLocal8Bit());
        display = wl_display_create(); require(display, "libwayland server creation failed");
        clientCreated.owner = this;
        clientCreated.listener.notify = [](wl_listener *listener, void *) { ++reinterpret_cast<ClientCreated *>(listener)->owner->connections; };
        wl_display_add_client_created_listener(display, &clientCreated.listener);
        require(wl_display_add_socket(display, "clipboard-peer") == 0, "private Wayland socket creation failed");
        require(wl_global_create(display, &zwlr_data_control_manager_v1_interface, 2, this, bindManager), "data-control global creation failed");
        for (auto &seat : seats) require(wl_global_create(display, &wl_seat_interface, 5, &seat, bindSeat), "seat global creation failed");
        notifier = std::make_unique<QSocketNotifier>(wl_event_loop_get_fd(wl_display_get_event_loop(display)), QSocketNotifier::Read, this);
        connect(notifier.get(), &QSocketNotifier::activated, this, [this] {
            if (wl_event_loop_dispatch(wl_display_get_event_loop(display), 0) < 0) error = "server dispatch failed";
            wl_display_flush_clients(display);
        });
    }
    ~ProtocolPeer() override {
        notifier.reset();
        for (auto &offer : offers) if (offer->receivedFd >= 0) ::close(offer->receivedFd);
        feeds.clear();
        if (display) { wl_display_destroy_clients(display); wl_display_destroy(display); }
    }
    QString socketPath() const { return runtime.path() + "/clipboard-peer"; }
    Offer *selection(int index, const QByteArray &payload, bool held = false) {
        auto &seat = seats[index]; require(seat.device, "test seat data device not bound");
        auto *client = wl_resource_get_client(seat.device);
        auto *resource = wl_resource_create(client, &zwlr_data_control_offer_v1_interface, 1, 0);
        require(resource, "test offer creation failed");
        auto offer = std::make_unique<Offer>(Offer{this, resource, payload, held}); auto *raw = offer.get();
        static const struct zwlr_data_control_offer_v1_interface impl = {receiveOffer, destroyResource};
        wl_resource_set_implementation(resource, &impl, raw, [](wl_resource *r) {
            auto *offer = static_cast<Offer *>(wl_resource_get_user_data(r)); offer->resource = nullptr; ++offer->owner->destroyedOffers;
        });
        offers.push_back(std::move(offer));
        zwlr_data_control_device_v1_send_data_offer(seat.device, resource);
        zwlr_data_control_offer_v1_send_offer(resource, "text/plain;charset=utf-8");
        zwlr_data_control_device_v1_send_selection(seat.device, resource);
        wl_display_flush_clients(display);
        return raw;
    }
    int requestSource(int index, PipeIdentity *identity = nullptr) {
        auto *source = seats[index].selected; require(source, "published source not available");
        auto *data = static_cast<Source *>(wl_resource_get_user_data(source));
        require(data && data->types.contains("text/plain;charset=utf-8"), "production source did not offer the copied MIME type");
        require(std::any_of(data->types.begin(), data->types.end(), [](const QString &type) { return type.startsWith("application/x-cornice-clipboard-"); }), "published source lacks production loop-prevention marker");
        int pipes[2]; require(pipe2(pipes, O_CLOEXEC | O_NONBLOCK) == 0, "test source pipe allocation failed");
        require(fcntl(pipes[1], F_SETPIPE_SZ, 4096) >= 4096, "test pipe backpressure setup failed");
        if (identity) *identity = PipeIdentity(pipes[0]);
        zwlr_data_control_source_v1_send_send(source, "text/plain;charset=utf-8", pipes[1]);
        wl_display_flush_clients(display); ::close(pipes[1]);
        return pipes[0];
    }
    QTemporaryDir runtime{qEnvironmentVariable("TMPDIR") + "/clipboard-protocol-XXXXXX"};
    Seat seats[2]; QString error; int receives = 0, selections = 0, destroyedOffers = 0, connections = 0, managers = 0;
  private:
    static void destroyResource(wl_client *, wl_resource *resource) { wl_resource_destroy(resource); }
    static void bindSeat(wl_client *client, void *data, uint32_t version, uint32_t id) {
        auto *seat = static_cast<Seat *>(data);
        auto *resource = wl_resource_create(client, &wl_seat_interface, std::min(version, 5u), id);
        static const struct wl_seat_interface impl = {
            [](wl_client *, wl_resource *r, uint32_t) { wl_resource_post_error(r, 0, "test peer has no physical pointer"); },
            [](wl_client *, wl_resource *r, uint32_t) { wl_resource_post_error(r, 0, "test peer has no physical keyboard"); },
            [](wl_client *, wl_resource *r, uint32_t) { wl_resource_post_error(r, 0, "test peer has no physical touch"); },
            destroyResource};
        wl_resource_set_implementation(resource, &impl, seat, nullptr);
        wl_seat_send_capabilities(resource, 0); wl_seat_send_name(resource, seat->name);
    }
    static void bindManager(wl_client *client, void *data, uint32_t version, uint32_t id) {
        ++static_cast<ProtocolPeer *>(data)->managers;
        auto *resource = wl_resource_create(client, &zwlr_data_control_manager_v1_interface, std::min(version, 2u), id);
        static const struct zwlr_data_control_manager_v1_interface impl = {createSource, getDevice, destroyResource};
        wl_resource_set_implementation(resource, &impl, data, nullptr);
    }
    static void createSource(wl_client *client, wl_resource *manager, uint32_t id) {
        auto *peer = static_cast<ProtocolPeer *>(wl_resource_get_user_data(manager));
        auto *resource = wl_resource_create(client, &zwlr_data_control_source_v1_interface, 1, id);
        auto source = std::make_unique<Source>(Source{peer, resource, {}}); auto *raw = source.get();
        static const struct zwlr_data_control_source_v1_interface impl = {
            [](wl_client *, wl_resource *r, const char *mime) { static_cast<Source *>(wl_resource_get_user_data(r))->types.append(QString::fromUtf8(mime)); }, destroyResource};
        wl_resource_set_implementation(resource, &impl, raw, [](wl_resource *r) { static_cast<Source *>(wl_resource_get_user_data(r))->resource = nullptr; });
        peer->sources.push_back(std::move(source));
    }
    static void getDevice(wl_client *client, wl_resource *manager, uint32_t id, wl_resource *seatResource) {
        auto *seat = static_cast<Seat *>(wl_resource_get_user_data(seatResource));
        auto *resource = wl_resource_create(client, &zwlr_data_control_device_v1_interface, wl_resource_get_version(manager), id);
        static const struct zwlr_data_control_device_v1_interface impl = {
            [](wl_client *, wl_resource *r, wl_resource *source) {
                auto *seat = static_cast<Seat *>(wl_resource_get_user_data(r)); seat->selected = source; ++seat->owner->selections;
            }, destroyResource, [](wl_client *, wl_resource *, wl_resource *) {}};
        seat->device = resource;
        wl_resource_set_implementation(resource, &impl, seat, [](wl_resource *r) { static_cast<Seat *>(wl_resource_get_user_data(r))->device = nullptr; });
        zwlr_data_control_device_v1_send_selection(resource, nullptr);
    }
    static void receiveOffer(wl_client *, wl_resource *resource, const char *mime, int32_t fd) {
        auto *offer = static_cast<Offer *>(wl_resource_get_user_data(resource));
        ++offer->owner->receives;
        if (strcmp(mime, "text/plain;charset=utf-8")) { offer->owner->error = "unexpected receive MIME"; ::close(fd); return; }
        if (offer->held) offer->receivedFd = fd;
        else offer->owner->feeds.push_back(std::make_unique<Feed>(fd, offer->payload));
    }
    struct ClientCreated { wl_listener listener{}; ProtocolPeer *owner = nullptr; } clientCreated;
    wl_display *display = nullptr;
    std::unique_ptr<QSocketNotifier> notifier;
    std::vector<std::unique_ptr<Offer>> offers;
    std::vector<std::unique_ptr<Source>> sources;
    std::vector<std::unique_ptr<Feed>> feeds;
};

// Controlled real-compositor client. It advertises only synthetic test MIME;
// no server/seat/lock/provider is started here. The parent owns the sandbox.
class ControlledClient : public QObject {
  public:
    static constexpr const char *mime = "application/x-cornice-lock-transport-unit-v1";
    ControlledClient(QString displayName, QString seatName, QString role, QString file)
        : displayName(std::move(displayName)), seatName(std::move(seatName)), role(std::move(role)), file(std::move(file)) {
        require(this->role == "source" || this->role == "receiver", "client role must be source or receiver");
        require(!this->displayName.trimmed().isEmpty() && !this->seatName.isEmpty(), "client requires an explicit display and seat");
        if (this->role == "source") {
            QFile input(this->file); require(input.open(QIODevice::ReadOnly), "synthetic source file unavailable");
            require(input.size() <= 64 * 1024 * 1024, "synthetic payload exceeds 64 MiB"); payload = input.readAll();
        }
        const auto path = QDir::isAbsolutePath(this->displayName) ? this->displayName : QDir(qEnvironmentVariable("XDG_RUNTIME_DIR")).filePath(this->displayName);
        display = wl_display_connect_to_fd(connectSocket(path)); require(display, "explicit client display initialization failed");
        registry = wl_display_get_registry(display);
        static const wl_registry_listener globals = {
            [](void *data, wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
                auto *self = static_cast<ControlledClient *>(data);
                if (!strcmp(interface, "zwlr_data_control_manager_v1")) {
                    self->manager = static_cast<zwlr_data_control_manager_v1 *>(wl_registry_bind(registry, id, &zwlr_data_control_manager_v1_interface, std::min(version, 2u)));
                    self->bindTarget();
                } else if (!strcmp(interface, "wl_seat") && version >= 5) {
                    auto seat = std::make_unique<SeatBinding>(); seat->owner = self;
                    seat->proxy = static_cast<wl_seat *>(wl_registry_bind(registry, id, &wl_seat_interface, 5));
                    static const wl_seat_listener names = {
                        [](void *, wl_seat *, uint32_t) {},
                        [](void *data, wl_seat *, const char *name) {
                            auto *seat = static_cast<SeatBinding *>(data); seat->name = QString::fromUtf8(name); seat->owner->bindTarget();
                        }};
                    wl_seat_add_listener(seat->proxy, &names, seat.get()); self->seats.push_back(std::move(seat));
                }
            }, [](void *, wl_registry *, uint32_t) {}};
        wl_registry_add_listener(registry, &globals, this);
        displayRead = std::make_unique<QSocketNotifier>(wl_display_get_fd(display), QSocketNotifier::Read, this);
        displayWrite = std::make_unique<QSocketNotifier>(wl_display_get_fd(display), QSocketNotifier::Write, this);
        displayWrite->setEnabled(false);
        connect(displayRead.get(), &QSocketNotifier::activated, this, [this] { dispatch(); });
        connect(displayWrite.get(), &QSocketNotifier::activated, this, [this] { flush(); });
        fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
        input = std::make_unique<QSocketNotifier>(STDIN_FILENO, QSocketNotifier::Read, this);
        connect(input.get(), &QSocketNotifier::activated, this, [this] {
            char bytes[1024];
            while (true) {
                const auto count = ::read(STDIN_FILENO, bytes, sizeof bytes);
                if (count > 0) pendingCommands.append(bytes, count);
                else if (!count) { closeAll("stdin_eof"); QCoreApplication::quit(); return; }
                else if (errno == EINTR) continue;
                else if (errno == EAGAIN) break;
                else { fatal("stdin read failed"); return; }
            }
            while (pendingCommands.contains('\n')) {
                const auto end = pendingCommands.indexOf('\n'); const auto command = pendingCommands.left(end);
                pendingCommands.remove(0, end + 1); control(QString::fromUtf8(command));
            }
        });
        flush();
    }
    ~ControlledClient() override {
        input.reset(); displayRead.reset(); displayWrite.reset(); closeAll("client_cleanup");
        if (display) {
            if (selectionSync) wl_callback_destroy(selectionSync);
            if (source) zwlr_data_control_source_v1_destroy(source);
            if (device) zwlr_data_control_device_v1_destroy(device);
            for (auto &offer : offers) if (offer->proxy) zwlr_data_control_offer_v1_destroy(offer->proxy);
            for (auto &seat : seats) wl_seat_destroy(seat->proxy);
            if (manager) zwlr_data_control_manager_v1_destroy(manager);
            if (registry) wl_registry_destroy(registry);
            wl_display_flush(display); wl_display_disconnect(display);
        }
    }
  private:
    struct SeatBinding { ControlledClient *owner; wl_seat *proxy; QString name; };
    struct Offer { zwlr_data_control_offer_v1 *proxy; QStringList types; };
    struct Endpoint {
        int id, fd; QString direction; PipeIdentity pipe; qint64 offset = 0;
        Endpoint(int id, int fd, QString direction) : id(id), fd(fd), direction(std::move(direction)), pipe(fd) {}
        ~Endpoint() { if (fd >= 0) ::close(fd); }
    };
    void event(QJsonObject value) {
        value["pid"] = static_cast<qint64>(getpid()); value["role"] = role; value["seat"] = seatName; value["mime"] = QString::fromLatin1(mime);
        const auto bytes = QJsonDocument(value).toJson(QJsonDocument::Compact);
        std::printf("%s\n", bytes.constData()); std::fflush(stdout);
    }
    void fatal(const char *message) { event({{"event", "error"}, {"error", QString::fromUtf8(message)}}); QCoreApplication::exit(2); }
    void flush() {
        const auto result = wl_display_flush(display);
        if (result < 0 && errno != EAGAIN && errno != EINTR) { fatal("Wayland flush failed"); return; }
        if (displayWrite) displayWrite->setEnabled(result < 0);
    }
    void dispatch() {
        while (wl_display_prepare_read(display) != 0) if (wl_display_dispatch_pending(display) < 0) { fatal("Wayland pending dispatch failed"); return; }
        pollfd ready{wl_display_get_fd(display), POLLIN, 0};
        int result; do { result = poll(&ready, 1, 0); } while (result < 0 && errno == EINTR);
        if (result > 0 && (ready.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0) { fatal("Wayland read failed"); return; }
        } else {
            wl_display_cancel_read(display);
            if (result < 0 || (ready.revents & (POLLHUP | POLLERR | POLLNVAL))) { fatal("Wayland connection closed"); return; }
        }
        if (wl_display_dispatch_pending(display) < 0) { fatal("Wayland dispatch failed"); return; }
        flush();
    }
    void addEndpoint(int fd, const QString &direction) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        auto endpoint = std::make_unique<Endpoint>(++nextId, fd, direction);
        auto identity = endpoint->pipe.json(); identity["event"] = "endpoint"; identity["id"] = endpoint->id;
        identity["direction"] = direction; identity["access_mode"] = fcntl(fd, F_GETFL) & O_ACCMODE; identity["held"] = true;
        endpoints.push_back(std::move(endpoint)); event(identity);
    }
    void bindTarget() {
        if (!manager || device) return;
        for (auto &seat : seats) {
            if (seat->name != seatName) continue;
            device = zwlr_data_control_manager_v1_get_data_device(manager, seat->proxy);
            static const zwlr_data_control_device_v1_listener events = {
                [](void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *proxy) {
                    auto *self = static_cast<ControlledClient *>(data);
                    auto offer = std::make_unique<Offer>(Offer{proxy, {}});
                    static const zwlr_data_control_offer_v1_listener types = {
                        [](void *data, zwlr_data_control_offer_v1 *, const char *mime) { static_cast<Offer *>(data)->types.append(QString::fromUtf8(mime)); }};
                    zwlr_data_control_offer_v1_add_listener(proxy, &types, offer.get()); self->offers.push_back(std::move(offer));
                },
                [](void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *proxy) {
                    auto *self = static_cast<ControlledClient *>(data); Offer *offer = nullptr;
                    for (auto &candidate : self->offers) if (candidate->proxy == proxy) offer = candidate.get();
                    if (self->selected && self->selected != offer && self->selected->proxy) {
                        zwlr_data_control_offer_v1_destroy(self->selected->proxy); self->selected->proxy = nullptr;
                    }
                    self->selected = offer;
                    const auto desired = offer && offer->types.contains(QString::fromLatin1(mime));
                    self->event({{"event", "selection"}, {"desired_mime", desired}});
                    if (self->role != "receiver" || !desired) return;
                    int pipes[2]; if (pipe2(pipes, O_CLOEXEC | O_NONBLOCK) != 0) { self->fatal("receive pipe allocation failed"); return; }
                    fcntl(pipes[1], F_SETPIPE_SZ, 4096);
                    zwlr_data_control_offer_v1_receive(proxy, mime, pipes[1]); ::close(pipes[1]);
                    self->addEndpoint(pipes[0], "reader"); self->flush();
                },
                [](void *data, zwlr_data_control_device_v1 *) { static_cast<ControlledClient *>(data)->fatal("data-control device finished"); },
                [](void *, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *) {}};
            zwlr_data_control_device_v1_add_listener(device, &events, this);
            if (role == "source") {
                source = zwlr_data_control_manager_v1_create_data_source(manager);
                static const zwlr_data_control_source_v1_listener callbacks = {
                    [](void *data, zwlr_data_control_source_v1 *, const char *requested, int32_t fd) {
                        auto *self = static_cast<ControlledClient *>(data);
                        if (strcmp(requested, mime)) { ::close(fd); self->event({{"event", "rejected_mime"}, {"requested_mime", QString::fromUtf8(requested)}}); return; }
                        self->addEndpoint(fd, "writer");
                    },
                    [](void *data, zwlr_data_control_source_v1 *source) {
                        auto *self = static_cast<ControlledClient *>(data); zwlr_data_control_source_v1_destroy(source); self->source = nullptr;
                        // Hold independently transferred fds so source cancellation
                        // cannot mask whether the production reader was closed.
                        self->event({{"event", "source_cancelled"}, {"held_transfers_preserved", true}});
                    }};
                zwlr_data_control_source_v1_add_listener(source, &callbacks, this);
                zwlr_data_control_source_v1_offer(source, mime); zwlr_data_control_device_v1_set_selection(device, source);
                // Queue ordering proves the server processed set_selection, even
                // when policy rejected it. This is not selection acceptance.
                selectionSync = wl_display_sync(display);
                if (!selectionSync) { fatal("selection sync allocation failed"); return; }
                static const wl_callback_listener synced = {
                    [](void *data, wl_callback *callback, uint32_t serial) {
                        auto *self = static_cast<ControlledClient *>(data);
                        wl_callback_destroy(callback); self->selectionSync = nullptr;
                        self->event({{"event", "selection_ack"}, {"server_acknowledged", true},
                                     {"barrier", "wl_display_sync"}, {"serial", static_cast<qint64>(serial)},
                                     {"selection_acceptance", "not asserted"}});
                    }};
                wl_callback_add_listener(selectionSync, &synced, this);
            }
            event({{"event", "ready"}, {"display", displayName}, {"payload_bytes", payload.size()}, {"server_acknowledged", false}});
            flush(); return;
        }
    }
    void closeEndpoint(Endpoint &endpoint, const QString &reason) {
        if (endpoint.fd < 0) return;
        auto value = endpoint.pipe.json(); value["event"] = "closed"; value["id"] = endpoint.id;
        value["direction"] = endpoint.direction; value["reason"] = reason; value["offset"] = endpoint.offset;
        ::close(endpoint.fd); endpoint.fd = -1; value["fd_closed"] = true; event(value);
    }
    void closeAll(const QString &reason) { for (auto &endpoint : endpoints) closeEndpoint(*endpoint, reason); }
    void control(const QString &line) {
        const auto words = line.split(' ', Qt::SkipEmptyParts); if (words.isEmpty()) return;
        const auto command = words[0];
        if (command == "exit") { closeAll("command_exit"); QCoreApplication::quit(); return; }
        bool countOk = true, idOk = true;
        const qint64 amount = words.size() > 1 && command != "release" ? words[1].toLongLong(&countOk) : 1024 * 1024;
        const auto wantedId = command == "release" ? (words.size() > 1 ? words[1].toInt(&idOk) : 0) : (words.size() > 2 ? words[2].toInt(&idOk) : 0);
        if (!countOk || !idOk || amount < 0 || amount > 64 * 1024 * 1024) { event({{"event", "command_error"}, {"command", line}}); return; }
        for (auto &endpoint : endpoints) {
            if (wantedId && endpoint->id != wantedId) continue;
            if (command == "status") {
                auto value = endpoint->pipe.json(); value["event"] = "status"; value["id"] = endpoint->id; value["direction"] = endpoint->direction;
                value["fd_open"] = endpoint->fd >= 0 && fcntl(endpoint->fd, F_GETFD) >= 0; value["offset"] = endpoint->offset; event(value); continue;
            }
            if (endpoint->fd < 0) continue;
            if (command == "release") { closeEndpoint(*endpoint, "command_release"); continue; }
            if (command == "send" && endpoint->direction == "writer") {
                qint64 sent = 0;
                while (sent < amount && endpoint->offset < payload.size()) {
                    const auto count = ::write(endpoint->fd, payload.constData() + endpoint->offset, std::min(amount - sent, payload.size() - endpoint->offset));
                    if (count > 0) { sent += count; endpoint->offset += count; }
                    else if (count < 0 && errno == EINTR) continue;
                    else if (count < 0 && errno == EAGAIN) break;
                    else { const auto error = errno; event({{"event", "write_error"}, {"id", endpoint->id}, {"fd", endpoint->fd}, {"inode", QString::number(endpoint->pipe.inode)}, {"errno", error}}); closeEndpoint(*endpoint, "write_error"); break; }
                }
                event({{"event", "sent"}, {"id", endpoint->id}, {"bytes", sent}, {"offset", endpoint->offset}, {"payload_complete", endpoint->offset == payload.size()}});
            } else if (command == "read" && endpoint->direction == "reader") {
                QByteArray bytes; char chunk[16384];
                while (bytes.size() < amount) {
                    const auto count = ::read(endpoint->fd, chunk, std::min<qint64>(sizeof chunk, amount - bytes.size()));
                    if (count > 0) { bytes.append(chunk, count); endpoint->offset += count; }
                    else if (!count) { closeEndpoint(*endpoint, "peer_eof"); break; }
                    else if (errno == EINTR) continue;
                    else if (errno == EAGAIN) break;
                    else { event({{"event", "read_error"}, {"id", endpoint->id}, {"errno", errno}}); closeEndpoint(*endpoint, "read_error"); break; }
                }
                if (!bytes.isEmpty()) { QFile output(file); if (!output.open(QIODevice::WriteOnly | QIODevice::Append) || output.write(bytes) != bytes.size()) { fatal("synthetic receive output failed"); return; } }
                event({{"event", "read"}, {"id", endpoint->id}, {"bytes", bytes.size()}, {"offset", endpoint->offset}, {"sha256", QString::fromLatin1(QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex())}, {"data_base64", bytes.size() <= 256 ? QString::fromLatin1(bytes.toBase64()) : QString()}, {"fd_open", endpoint->fd >= 0}});
            }
        }
        if (command != "status" && command != "send" && command != "read" && command != "release") event({{"event", "command_error"}, {"command", line}});
    }
    QString displayName, seatName, role, file; QByteArray payload, pendingCommands;
    wl_display *display = nullptr; wl_registry *registry = nullptr; wl_callback *selectionSync = nullptr;
    zwlr_data_control_manager_v1 *manager = nullptr; zwlr_data_control_device_v1 *device = nullptr; zwlr_data_control_source_v1 *source = nullptr;
    std::unique_ptr<QSocketNotifier> displayRead, displayWrite, input;
    std::vector<std::unique_ptr<SeatBinding>> seats; std::vector<std::unique_ptr<Offer>> offers;
    std::vector<std::unique_ptr<Endpoint>> endpoints; Offer *selected = nullptr; int nextId = 0;
};

static QByteArray drain(int fd, bool *eof) {
    QByteArray result; char bytes[16384]; *eof = false;
    while (true) {
        const auto count = ::read(fd, bytes, sizeof bytes);
        if (count > 0) result.append(bytes, count);
        else if (!count) { *eof = true; break; }
        else if (errno == EINTR) continue;
        else { require(errno == EAGAIN, "peer read failed"); break; }
    }
    return result;
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); std::signal(SIGPIPE, SIG_IGN);
    if (argc > 1 && !strcmp(argv[1], "--client")) {
        try {
            require(argc == 6, "usage: --client DISPLAY SEAT source|receiver PAYLOAD_OR_OUTPUT_PATH");
            ControlledClient client(QString::fromLocal8Bit(argv[2]), QString::fromLocal8Bit(argv[3]), QString::fromLocal8Bit(argv[4]), QString::fromLocal8Bit(argv[5]));
            return app.exec();
        } catch (const std::exception &failure) { std::fprintf(stderr, "client error: %s\n", failure.what()); return 2; }
    }
    QJsonObject report{{"kind", "actual ClipboardBridge, real Qt and libwayland transport with test protocol peer"},
                       {"accepted", false}, {"graphical", false}, {"b18_compositor_exercised", false}, {"release_accepted", false}, {"pass", false}};
    const auto originalRuntime = qgetenv("XDG_RUNTIME_DIR");
    int writerPeer = -1, blockedPeer = -1, recoveryPeer = -1, decoyFd = -1;
    try {
        require(qEnvironmentVariable("CORNICE_TEST_DEVICE_FREE") == "1", "run through the device-free verifier");
        require(!QFile::exists("/dev/dri") && !QFile::exists("/dev/input"), "physical devices visible in transport fixture");
        for (const auto *key : {"DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DBUS_SESSION_BUS_ADDRESS", "HYPRLAND_INSTANCE_SIGNATURE"})
            require(!qEnvironmentVariableIsSet(key), "ambient desktop environment leaked into fixture");
        EnvironmentGuard environment;
        ProtocolPeer peer; ProtocolPeer decoy;
        decoyFd = connectSocket(decoy.socketPath());
        const auto inherited = QByteArray::number(decoyFd);
        qputenv("WAYLAND_SOCKET", inherited); qputenv("WAYLAND_DISPLAY", decoy.socketPath().toLocal8Bit());
        const auto inheritedRuntime = qgetenv("XDG_RUNTIME_DIR"), inheritedDisplay = qgetenv("WAYLAND_DISPLAY");
        ClipboardBridge bridge(peer.socketPath());
        const auto configure = [&](const QString &scope) { bridge.configure({"human", "agent"}, "human", "shared", 1024 * 1024, scope); };
        configure("none");
        waitUntil([&] {
            report["negotiation"] = QJsonObject{{"primary_connections", peer.connections}, {"primary_manager_bindings", peer.managers}, {"primary_devices", (peer.seats[0].device ? 1 : 0) + (peer.seats[1].device ? 1 : 0)}, {"decoy_connections", decoy.connections}, {"decoy_manager_bindings", decoy.managers}, {"decoy_devices", (decoy.seats[0].device ? 1 : 0) + (decoy.seats[1].device ? 1 : 0)}, {"decoy_fd_valid", fcntl(decoyFd, F_GETFD) >= 0}, {"inherited_wayland_socket_unchanged", qgetenv("WAYLAND_SOCKET") == inherited}};
            return peer.seats[0].device && peer.seats[1].device;
        }, "real registry/device negotiation timed out");
        settle();
        require(peer.connections == 1 && decoy.connections == 1 && decoy.managers == 0 && !decoy.seats[0].device && !decoy.seats[1].device, "named bridge connected or negotiated with the decoy protocol peer");
        require(fcntl(decoyFd, F_GETFD) >= 0 && qgetenv("WAYLAND_SOCKET") == inherited && qgetenv("WAYLAND_DISPLAY") == inheritedDisplay && qgetenv("XDG_RUNTIME_DIR") == inheritedRuntime, "bridge consumed the decoy fd or changed inherited environment");
        require(bridge.status()["connected"].toBool(), "production bridge did not negotiate data-control");
        const QByteArray original(256 * 1024, 'A');
        peer.selection(0, original);
        waitUntil([&] { return peer.selections == 2 && bridge.status()["transfers"].toInteger() == 1; }, "initial real copy did not publish to both seats");
        PipeIdentity writerPipe;
        writerPeer = peer.requestSource(1, &writerPipe);
        int writerFd = -1;
        waitUntil([&] {
            writerFd = bridgeEndpoint(bridge, writerPipe, QSocketNotifier::Write);
            int queued = 0; require(ioctl(writerPeer, FIONREAD, &queued) == 0, "source peer queue query failed");
            return writerFd >= 0 && queued > 0;
        }, "production source.send did not establish a backpressured writer");
        auto *held = peer.selection(0, {}, true);
        waitUntil([&] { return held->receivedFd >= 0; }, "production offer.receive was not issued");
        const PipeIdentity readerPipe(held->receivedFd);
        const auto readerFd = bridgeEndpoint(bridge, readerPipe, QSocketNotifier::Read);
        require(readerFd >= 0 && readerFd != writerFd, "exact production reader endpoint could not be identified");
        report["reader"] = QJsonObject{{"peer", readerPipe.json()}, {"production", PipeIdentity(readerFd).json()}};
        report["writer"] = QJsonObject{{"peer", writerPipe.json()}, {"production", PipeIdentity(writerFd).json()}};
        configure("full");
        const bool readerClosed = closed(readerFd), writerClosed = closed(writerFd);
        report["reader_fd_closed_immediately"] = readerClosed; report["writer_fd_closed_immediately"] = writerClosed;
        require(readerClosed, "full lock kept the exact production reader fd open");
        require(writerClosed, "full lock kept the exact production writer fd open");
        require(bridgeEndpoint(bridge, readerPipe, QSocketNotifier::Read) < 0 && bridgeEndpoint(bridge, writerPipe, QSocketNotifier::Write) < 0, "cancelled transfer notifier still active");
        errno = 0; const auto readerWrite = ::write(held->receivedFd, "R", 1);
        require(readerWrite < 0 && errno == EPIPE, "held peer can still write to the cancelled production reader");
        bool eof = false; const auto priorBytes = drain(writerPeer, &eof);
        require(eof && !priorBytes.isEmpty() && priorBytes.size() < original.size() && priorBytes == original.left(priorBytes.size()), "source pipe did not retain only its pre-lock prefix then close");
        report["writer_pre_lock_prefix_bytes"] = priorBytes.size(); report["reader_peer_write_errno"] = EPIPE;
        ::close(writerPeer); writerPeer = -1;
        const auto receives = peer.receives, selections = peer.selections, destroyed = peer.destroyedOffers;
        peer.selection(0, "blocked-copy");
        waitUntil([&] { return peer.destroyedOffers > destroyed; }, "locked selection event was not dispatched by production bridge");
        settle();
        require(peer.receives == receives && peer.selections == selections && bridge.status()["transfers"].toInteger() == 1, "full lock propagated a new offer");
        PipeIdentity blockedPipe; blockedPeer = peer.requestSource(1, &blockedPipe);
        waitUntil([&] { bool done = false; const auto data = drain(blockedPeer, &done); require(data.isEmpty(), "full lock leaked data from source.send"); return done; }, "locked source.send descriptor was not closed");
        require(bridgeEndpoint(bridge, blockedPipe, QSocketNotifier::Write) < 0, "full lock created a new production writer");
        report["locked_offer_receive_count_unchanged"] = true; report["locked_source_send_empty_and_closed"] = true;
        ::close(blockedPeer); blockedPeer = -1;
        configure("none"); settle();
        require(peer.receives == receives && peer.selections == selections, "unlock unexpectedly propagated the copy received while locked");
        const QByteArray fresh("fresh-copy-after-unlock"); peer.selection(0, fresh);
        waitUntil([&] { return peer.selections == selections + 2 && peer.receives == receives + 1 && bridge.status()["transfers"].toInteger() == 2; }, "fresh copy after unlock did not republish to both seats");
        PipeIdentity recoveryPipe; recoveryPeer = peer.requestSource(1, &recoveryPipe);
        QByteArray actual;
        waitUntil([&] { bool done = false; actual += drain(recoveryPeer, &done); return done; }, "fresh copied data did not complete source.send");
        require(actual == fresh && peer.error.isEmpty(), "fresh unlocked paste payload did not match");
        report["recovery_pipe"] = recoveryPipe.json(); report["recovery_payload"] = QString::fromUtf8(actual);
        report["receive_requests"] = peer.receives; report["publish_requests"] = peer.selections; report["completed_copies"] = bridge.status()["transfers"];
        require(decoy.managers == 0 && decoy.receives == 0 && decoy.selections == 0 && !decoy.seats[0].device && !decoy.seats[1].device, "clipboard target operations reached the decoy protocol peer");
        require(fcntl(decoyFd, F_GETFD) >= 0 && qgetenv("WAYLAND_SOCKET") == inherited && qgetenv("WAYLAND_DISPLAY") == inheritedDisplay && qgetenv("XDG_RUNTIME_DIR") == inheritedRuntime, "transfer changed inherited decoy descriptor/environment");
        report["decoy"] = QJsonObject{{"connected_fd", decoyFd}, {"fd_preserved", true}, {"connections", decoy.connections}, {"manager_bindings", decoy.managers}, {"receive_requests", decoy.receives}, {"selection_requests", decoy.selections}, {"inherited_environment_unchanged", true}};
        report["primary_connections"] = peer.connections;
        report["pass"] = true;
        std::puts("PASS: actual ClipboardBridge full lock closes identified reader/writer fds, blocks offer.receive/source.send, and restores fresh copies after unlock");
    } catch (const std::exception &failure) {
        report["failure"] = QString::fromUtf8(failure.what()); std::fprintf(stderr, "FAIL: %s\n", failure.what());
    }
    report["test_environment_restored"] = qgetenv("XDG_RUNTIME_DIR") == originalRuntime && !qEnvironmentVariableIsSet("WAYLAND_DISPLAY") && !qEnvironmentVariableIsSet("WAYLAND_SOCKET");
    if (report["pass"].toBool() && !report["test_environment_restored"].toBool()) {
        report["pass"] = false; report["failure"] = "test changed its caller environment";
    }
    for (const auto fd : {writerPeer, blockedPeer, recoveryPeer, decoyFd}) if (fd >= 0) ::close(fd);
    const auto json = QJsonDocument(report).toJson(QJsonDocument::Indented);
    if (argc == 2) { QFile file(QString::fromLocal8Bit(argv[1])); if (file.open(QIODevice::WriteOnly)) file.write(json); else return 2; }
    std::printf("%s", json.constData());
    return report["pass"].toBool() ? 0 : 1;
}
