// Exercise real UNIX/Wayland connection selection. Only compositor IPC replies
// are doubled; all sockets and wl_display instances are real and test-private.
#include "HyprlandAdapter.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QVector>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <functional>
#include <memory>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#include <wayland-client.h>

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

class Descriptor {
  public:
    explicit Descriptor(int fd = -1) : value(fd) {}
    ~Descriptor() { if (value >= 0) ::close(value); }
    Descriptor(const Descriptor &) = delete;
    Descriptor &operator=(const Descriptor &) = delete;
    int get() const { return value; }
  private:
    int value;
};

static sockaddr_un address(const QString &path) {
    const auto encoded = path.toLocal8Bit();
    sockaddr_un result{};
    result.sun_family = AF_UNIX;
    require(encoded.size() < static_cast<qsizetype>(sizeof result.sun_path), "test UNIX path too long");
    std::memcpy(result.sun_path, encoded.constData(), static_cast<size_t>(encoded.size()) + 1);
    return result;
}

class Listener {
  public:
    explicit Listener(QString path) : path(std::move(path)), fd(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) {
        require(fd.get() >= 0, "test listener socket failed");
        const auto endpoint = address(this->path);
        require(::bind(fd.get(), reinterpret_cast<const sockaddr *>(&endpoint), sizeof endpoint) == 0, "test listener bind failed");
        require(::listen(fd.get(), 8) == 0, "test listener listen failed");
    }
    ~Listener() { ::unlink(path.toLocal8Bit().constData()); }
    bool hasConnection() const {
        pollfd event{fd.get(), POLLIN, 0};
        const auto result = ::poll(&event, 1, 0);
        require(result >= 0, "test listener poll failed");
        return result > 0 && (event.revents & POLLIN);
    }
    const QString path;
    Descriptor fd;
};

static QString peerPath(int fd) {
    sockaddr_un peer{};
    socklen_t size = sizeof peer;
    require(::getpeername(fd, reinterpret_cast<sockaddr *>(&peer), &size) == 0, "connected display has no UNIX peer");
    require(peer.sun_family == AF_UNIX, "connected display is not UNIX");
    return QString::fromLocal8Bit(peer.sun_path);
}

class Environment {
  public:
    explicit Environment(const QString &directory) {
        for (const auto *name : {"XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "WAYLAND_SOCKET"})
            saved.append({name, qgetenv(name), qEnvironmentVariableIsSet(name)});
        qputenv("XDG_RUNTIME_DIR", directory.toLocal8Bit());
        qputenv("WAYLAND_DISPLAY", "primary.sock");
        qunsetenv("WAYLAND_SOCKET");
    }
    ~Environment() {
        for (const auto &entry : saved)
            if (entry.present) qputenv(entry.name.constData(), entry.value);
            else qunsetenv(entry.name.constData());
    }
  private:
    struct Value { QByteArray name, value; bool present; };
    QVector<Value> saved;
};

struct Exchange { QByteArray request, reply; };
class CompositorIpc {
  public:
    CompositorIpc(const QString &directory, QVector<Exchange> exchanges, bool disappearAfterReply = false)
        : exchanges(std::move(exchanges)), disappearAfterReply(disappearAfterReply) {
        const auto parent = directory + "/hypr/unit";
        require(QDir().mkpath(parent), "test IPC directory creation failed");
        listener = std::make_unique<Listener>(parent + "/.socket.sock");
        worker = std::thread([this] { serve(); });
    }
    ~CompositorIpc() { stop = true; if (worker.joinable()) worker.join(); }
    void verify() {
        stop = true;
        if (worker.joinable()) worker.join();
        if (failure) std::rethrow_exception(failure);
        require(received == exchanges.size(), "unexpected compositor IPC request count");
    }
  private:
    void serve() {
        try {
            for (const auto &exchange : exchanges) {
                int ready = 0;
                while (!stop && ready == 0) {
                    pollfd event{listener->fd.get(), POLLIN, 0};
                    ready = ::poll(&event, 1, 20);
                    if (ready < 0 && errno == EINTR) ready = 0;
                    else require(ready >= 0, "test IPC accept poll failed");
                }
                if (stop && ready == 0) return;
                Descriptor connection(::accept4(listener->fd.get(), nullptr, nullptr, SOCK_CLOEXEC));
                require(connection.get() >= 0, "test IPC accept failed");
                QByteArray request;
                while (request.size() < exchange.request.size()) {
                    pollfd event{connection.get(), POLLIN, 0};
                    require(::poll(&event, 1, 1500) > 0, "test IPC request timed out");
                    char bytes[4096];
                    const auto count = ::read(connection.get(), bytes, sizeof bytes);
                    require(count > 0, "test IPC request closed early");
                    request.append(bytes, count);
                }
                require(request == exchange.request, "compositor IPC command or JSON mode mismatch");
                ++received;
                // Remove the real socket before responding, so the next query
                // deterministically sees an unavailable compositor endpoint.
                if (disappearAfterReply) listener.reset();
                qsizetype sent = 0;
                while (sent < exchange.reply.size()) {
                    const auto count = ::send(connection.get(), exchange.reply.constData() + sent,
                                              static_cast<size_t>(exchange.reply.size() - sent), MSG_NOSIGNAL);
                    if (count < 0 && errno == EINTR) continue;
                    require(count > 0, "test IPC response failed");
                    sent += count;
                }
            }
        } catch (...) { failure = std::current_exception(); }
    }
    const QVector<Exchange> exchanges;
    const bool disappearAfterReply;
    std::unique_ptr<Listener> listener;
    std::atomic<bool> stop = false;
    std::thread worker;
    qsizetype received = 0;
    std::exception_ptr failure;
};

using Display = std::unique_ptr<wl_display, decltype(&wl_display_disconnect)>;
static Display connect(const QString &instance = "unit") {
    auto *display = HyprlandAdapter(instance).connectManagementDisplay();
    require(display, "Wayland display connection returned null");
    return Display(display, &wl_display_disconnect);
}

static const QByteArray managementCapabilities = R"({"protocol":1,"features":["seat-input","management-display-v1"]})";
static QByteArray managementReply(const QString &name) {
    return QJsonDocument(QJsonObject{{"display", name}}).toJson(QJsonDocument::Compact);
}

class Fixture {
  public:
    Fixture() : environment(directory.path()), primary(directory.path() + "/primary.sock") {
        require(directory.isValid(), "test runtime directory creation failed");
    }
    QTemporaryDir directory;
    Environment environment;
    Listener primary;
};

static void mustFailWithoutFallback(Fixture &fixture) {
    bool threw = false;
    try { const auto display = connect(); }
    catch (const std::runtime_error &) { threw = true; }
    require(threw, "management failure did not throw");
    require(!fixture.primary.hasConnection(), "management failure silently fell back to the primary display");
}

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    int passed = 0, failed = 0;
    const auto run = [&](const QString &name, const std::function<void()> &test) {
        try { test(); ++passed; std::printf("PASS %s\n", name.toUtf8().constData()); }
        catch (const std::exception &error) { ++failed; std::fprintf(stderr, "FAIL %s: %s\n", name.toUtf8().constData(), error.what()); }
    };

    for (const auto &command : {QString("seat state main"), QString("seat lock-policy desktop2 continue"), QString("seat control desktop2 pause")}) {
        run("session lock is canonical across seat state/control/policy: " + command, [command] {
            Fixture fixture;
            const QByteArray reply = R"({"locked":true,"scopePolicy":"block","lockScope":"session"})";
            const auto wire = command.endsWith(" continue") ? QString("seat lock-policy desktop2 allow") : command;
            CompositorIpc ipc(fixture.directory.path(), {{"j/" + wire.toUtf8(), reply}});
            const auto state = QJsonDocument::fromJson(HyprlandAdapter("unit").command(command, true)).object();
            require(state["humanLocked"].toBool(), "session lock was lost in the adapter");
            require(state["lockScope"].toString() == "full", "session lock did not reach the full-lock clipboard gate");
            require(state["humanLockPolicy"].toString() == "pause", "block policy was not normalized");
            require(!state.contains("locked") && !state.contains("scopePolicy"), "wire aliases escaped the adapter");
            ipc.verify();
        });
    }
    for (const auto &command : {QString("seat list"), QString("seat")}) {
        run("seat lists normalize session/scoped locks and preserve canonical states: " + command, [command] {
            Fixture fixture;
            const QByteArray reply = R"([{"locked":true,"scopePolicy":"block","lockScope":"session"},{"locked":true,"scopePolicy":"allow","lockScope":"scoped"},{"humanLocked":true,"humanLockPolicy":"pause","lockScope":"full"},{"locked":false,"lockScope":"none"}])";
            CompositorIpc ipc(fixture.directory.path(), {{"j/" + command.toUtf8(), reply}});
            const auto states = QJsonDocument::fromJson(HyprlandAdapter("unit").command(command, true)).array();
            require(states.size() == 4, "seat list changed size");
            require(states[0].toObject()["lockScope"].toString() == "full", "list session lock was not normalized");
            require(states[1].toObject()["lockScope"].toString() == "human" && states[1].toObject()["humanLockPolicy"].toString() == "continue", "scoped continuation policy changed");
            require(states[2].toObject()["lockScope"].toString() == "full", "canonical full lock changed");
            require(!states[3].toObject()["humanLocked"].toBool() && states[3].toObject()["lockScope"].toString() == "none", "unlocked state changed");
            ipc.verify();
        });
    }

    run("no instance keeps the ordinary Wayland display", [] {
        Fixture fixture;
        const auto display = connect(QString());
        require(peerPath(wl_display_get_fd(display.get())) == fixture.primary.path, "no-instance connection selected another display");
    });
    for (const auto &reply : QVector<QByteArray>{"unknown request", R"({"features":[]})", R"({"protocol":1,"features":["seat-input","lock-scope-v1"]})"}) {
        run("explicit unsupported capabilities use the ordinary display: " + QString::fromUtf8(reply), [reply] {
            Fixture fixture;
            CompositorIpc ipc(fixture.directory.path(), {{"j/seat capabilities", reply}});
            const auto display = connect();
            require(peerPath(wl_display_get_fd(display.get())) == fixture.primary.path, "unsupported compositor selected another display");
            ipc.verify();
        });
    }
    for (const auto absolute : {false, true}) {
        run(absolute ? "management connection uses an absolute socket path" : "management connection uses the advertised runtime socket", [absolute] {
            Fixture fixture;
            Listener management(fixture.directory.path() + "/management.sock");
            CompositorIpc ipc(fixture.directory.path(), {{"j/seat capabilities", managementCapabilities},
                {"j/seat management-display", managementReply(absolute ? management.path : "management.sock")}});
            const auto display = connect();
            require(peerPath(wl_display_get_fd(display.get())) == management.path, "management connection selected the ordinary display");
            require(!fixture.primary.hasConnection(), "management connection also opened the primary display");
            ipc.verify();
        });
    }
    run("management connection ignores inherited WAYLAND_SOCKET and WAYLAND_DISPLAY", [] {
        Fixture fixture;
        Listener management(fixture.directory.path() + "/management.sock");
        Descriptor inherited(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0));
        require(inherited.get() >= 0, "inherited socket fixture creation failed");
        const auto endpoint = address(fixture.primary.path);
        require(::connect(inherited.get(), reinterpret_cast<const sockaddr *>(&endpoint), sizeof endpoint) == 0, "inherited socket fixture connection failed");
        qputenv("WAYLAND_SOCKET", QByteArray::number(inherited.get()));
        qputenv("WAYLAND_DISPLAY", "missing-ambient-display.sock");
        CompositorIpc ipc(fixture.directory.path(), {{"j/seat capabilities", managementCapabilities},
            {"j/seat management-display", managementReply("management.sock")}});
        const auto display = connect();
        require(peerPath(wl_display_get_fd(display.get())) == management.path, "inherited WAYLAND_SOCKET overrode the management connection");
        require(::fcntl(inherited.get(), F_GETFD) >= 0, "management connection consumed the inherited descriptor");
        require(qgetenv("WAYLAND_SOCKET") == QByteArray::number(inherited.get()), "management connection changed the inherited socket environment");
        require(qgetenv("WAYLAND_DISPLAY") == "missing-ambient-display.sock", "management connection changed the inherited display environment");
        ipc.verify();
    });
    for (const auto &reply : QVector<QByteArray>{"", "not json", "unknown request: connection lost", "[]", "{}", R"({"features":null})", R"({"features":"management-display-v1"})"}) {
        run("malformed capabilities fail without fallback: " + QString::fromUtf8(reply), [reply] {
            Fixture fixture;
            CompositorIpc ipc(fixture.directory.path(), {{"j/seat capabilities", reply}});
            mustFailWithoutFallback(fixture);
            ipc.verify();
        });
    }
    for (const auto &reply : QVector<QByteArray>{"", "not json", "[]", "{}", R"({"display":""})", R"({"display":"  "})", R"({"display":null})", R"({"display":123})", R"({"display":"bad\u0000name"})"}) {
        run("invalid management reply fails without fallback: " + QString::fromUtf8(reply), [reply] {
            Fixture fixture;
            CompositorIpc ipc(fixture.directory.path(), {{"j/seat capabilities", managementCapabilities}, {"j/seat management-display", reply}});
            mustFailWithoutFallback(fixture);
            ipc.verify();
        });
    }
    run("missing advertised management socket fails without fallback", [] {
        Fixture fixture;
        CompositorIpc ipc(fixture.directory.path(), {{"j/seat capabilities", managementCapabilities},
            {"j/seat management-display", managementReply("missing-management.sock")}});
        mustFailWithoutFallback(fixture);
        ipc.verify();
    });
    run("missing compositor IPC fails without fallback", [] {
        Fixture fixture;
        mustFailWithoutFallback(fixture);
    });
    run("compositor IPC disappears after capabilities and fails without fallback", [] {
        Fixture fixture;
        CompositorIpc ipc(fixture.directory.path(), {{"j/seat capabilities", managementCapabilities}}, true);
        mustFailWithoutFallback(fixture);
        ipc.verify();
    });
    std::printf("Management display unit: %d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
