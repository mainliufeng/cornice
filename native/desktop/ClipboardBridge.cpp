#include "HyprlandAdapter.hpp"
#include <exception>
#include "ClipboardBridge.hpp"
#include "wlr-data-control-unstable-v1.h"
#include <QMap>
#include <QJsonArray>
#include <QSet>
#include <QPointer>
#include <QSocketNotifier>
#include <QTimer>
#include <QUuid>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <map>
#include <poll.h>
#include <unistd.h>
#include <wayland-client.h>

struct ClipboardBridge::Impl : QObject {
    struct Offer { zwlr_data_control_offer_v1 *proxy; QStringList types; bool invalid = false; };
    struct Seat {
        Impl *owner;
        uint32_t global;
        wl_seat *seat = nullptr;
        QString name;
        zwlr_data_control_manager_v1 *manager = nullptr;
        zwlr_data_control_device_v1 *device = nullptr;
        Offer *selected = nullptr;
        bool initial = true, clearPending = false;
    };
    struct Source { Impl *owner; zwlr_data_control_source_v1 *proxy; QMap<QString, QByteArray> data; };
    struct Batch {
        quint64 epoch;
        int pending = 0;
        qint64 total = 0;
        bool failed = false;
        QMap<QString, QByteArray> data;
    };
    struct Transfer : QObject {
        int fd;
        QSocketNotifier::Type type;
        quint64 epoch = 0;
        QSocketNotifier *notifier;
        QTimer timeout;
        QByteArray data;
        qint64 offset = 0;
        std::function<void()> finish;
        explicit Transfer(int descriptor, QSocketNotifier::Type type, QObject *parent) : QObject(parent), fd(descriptor), type(type) {
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
            notifier = new QSocketNotifier(fd, type, this);
            timeout.setSingleShot(true);
            timeout.setInterval(4000);
            connect(&timeout, &QTimer::timeout, this, [this] { if (finish) finish(); });
            timeout.start();
        }
        ~Transfer() override { if (fd >= 0) ::close(fd); }
        void done() { notifier->setEnabled(false); timeout.stop(); if (fd >= 0) { ::close(fd); fd = -1; } deleteLater(); }
    };
    wl_display *display = nullptr;
    wl_registry *registry = nullptr;
    wl_callback *registrySync = nullptr;
    QSocketNotifier *notifier = nullptr, *writeNotifier = nullptr;
    std::map<uint32_t, std::unique_ptr<Seat>> seats;
    std::map<zwlr_data_control_offer_v1 *, std::unique_ptr<Offer>> offers;
    std::map<zwlr_data_control_source_v1 *, std::unique_ptr<Source>> sources;
    QSet<QString> allowed;
    QMap<QString, QByteArray> sharedPayload;
    bool sharedSelectionKnown = false;
    QString primary, mode = "isolated", lockScope = "none", error, displayName;
    QByteArray marker = "application/x-cornice-clipboard-" + QUuid::createUuid().toByteArray(QUuid::WithoutBraces);
    uint32_t managerGlobal = 0, managerVersion = 0;
    qint64 maxBytes = 16 * 1024 * 1024;
    quint64 epoch = 0, transfers = 0;
    QTimer retry;
    explicit Impl(const QString &name, QObject *parent) : QObject(parent), displayName(name) {
        retry.setInterval(1000);
        connect(&retry, &QTimer::timeout, this, [this] { if (mode == "shared" && !display) open(); });
        retry.start();
    }
    ~Impl() override { close(); }
    bool enabled(const Seat &seat) const {
        return mode == "shared" && allowed.contains(seat.name) && lockScope != "full" &&
               !(lockScope == "human" && seat.name == primary);
    }
    void cancelTransfers(bool readersOnly, quint64 batch = 0) {
        for (auto *child : findChildren<QObject *>(QString(), Qt::FindDirectChildrenOnly)) {
            auto *transfer = dynamic_cast<Transfer *>(child);
            if (transfer && (!readersOnly || transfer->type == QSocketNotifier::Read) && (!batch || transfer->epoch == batch))
                transfer->done();
        }
    }
    int activeWriters() const {
        int count = 0;
        for (auto *child : findChildren<QObject *>(QString(), Qt::FindDirectChildrenOnly)) {
            const auto *transfer = dynamic_cast<Transfer *>(child);
            if (transfer && transfer->fd >= 0 && transfer->type == QSocketNotifier::Write) ++count;
        }
        return count;
    }
    void discard(Offer *offer) {
        if (!offer) return;
        const auto proxy = offer->proxy;
        zwlr_data_control_offer_v1_destroy(proxy);
        offers.erase(proxy);
    }
    void close() {
        ++epoch;
        for (auto *child : findChildren<QObject *>(QString(), Qt::FindDirectChildrenOnly))
            if (dynamic_cast<Transfer *>(child)) delete child;
        delete notifier; delete writeNotifier;
        notifier = writeNotifier = nullptr;
        // Destroy local proxies even on IO failure; the server releases every
        // associated resource when this connection goes away.
        for (const auto &[proxy, ignored] : sources) wl_proxy_destroy(reinterpret_cast<wl_proxy *>(proxy));
        for (const auto &[proxy, ignored] : offers) wl_proxy_destroy(reinterpret_cast<wl_proxy *>(proxy));
        sources.clear(); offers.clear();
        sharedPayload.clear(); sharedSelectionKnown = false;
        for (auto &[id, seat] : seats) {
            if (seat->device) wl_proxy_destroy(reinterpret_cast<wl_proxy *>(seat->device));
            if (seat->manager) wl_proxy_destroy(reinterpret_cast<wl_proxy *>(seat->manager));
            if (seat->seat) wl_proxy_destroy(reinterpret_cast<wl_proxy *>(seat->seat));
        }
        seats.clear();
        if (registrySync) wl_proxy_destroy(reinterpret_cast<wl_proxy *>(registrySync));
        registrySync = nullptr;
        if (registry) wl_proxy_destroy(reinterpret_cast<wl_proxy *>(registry));
        if (display) wl_display_disconnect(display);
        registry = nullptr; display = nullptr; managerGlobal = managerVersion = 0;
    }
    void connectionLost() {
        error = "Clipboard connection lost; reconnecting";
        if (notifier) notifier->setEnabled(false);
        if (writeNotifier) writeNotifier->setEnabled(false);
        // Flush can fail inside a protocol callback. Destroying its queue in
        // that callback would invalidate the active Wayland dispatch stack.
        const QPointer<QSocketNotifier> current(notifier);
        QTimer::singleShot(0, this, [this, current] {
            if (current && current == notifier) close();
        });
    }
    void flush() {
        if (!display) return;
        const auto result = wl_display_flush(display);
        if (result < 0 && errno != EAGAIN && errno != EINTR) { connectionLost(); return; }
        if (writeNotifier) writeNotifier->setEnabled(result < 0);
    }
    void dispatchReady() {
        if (!display) return;
        auto *current = display;
        if (wl_display_get_error(current)) { connectionLost(); return; }
        // A Qt readiness notification is a hint, not a license to wait for
        // more events. Drain already queued callbacks, then read only bytes
        // which are presently available. The connection has one reader.
        while (wl_display_prepare_read(current) != 0) {
            if (wl_display_dispatch_pending(current) < 0) { connectionLost(); return; }
            if (current != display) return;
            if (wl_display_get_error(current)) { connectionLost(); return; }
        }
        pollfd fd{wl_display_get_fd(current), POLLIN, 0};
        int ready;
        do { ready = poll(&fd, 1, 0); } while (ready < 0 && errno == EINTR);
        if (ready > 0 && (fd.revents & POLLIN)) {
            if (wl_display_read_events(current) < 0) { connectionLost(); return; }
        } else {
            wl_display_cancel_read(current);
            if (ready < 0 || (fd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                connectionLost(); return;
            }
        }
        if (wl_display_dispatch_pending(current) < 0) { connectionLost(); return; }
        if (current == display) flush();
    }
    void open() {
        try { display = HyprlandAdapter::connectNamedDisplay(displayName); }
        catch (const std::exception &failure) { error = QString::fromUtf8(failure.what()); return; }
        if (!display) { error = "Cannot connect to clipboard display"; return; }
        registry = wl_display_get_registry(display);
        static const wl_registry_listener listener = {
            [](void *data, wl_registry *r, uint32_t id, const char *interface, uint32_t version) {
                auto *self = static_cast<Impl *>(data);
                if (!strcmp(interface, "zwlr_data_control_manager_v1")) {
                    self->managerGlobal = id; self->managerVersion = std::min(version, 2u);
                    for (auto &[global, seat] : self->seats) self->bind(*seat);
                } else if (!strcmp(interface, "wl_seat") && version >= 5) {
                    auto seat = std::make_unique<Seat>();
                    seat->owner = self; seat->global = id;
                    seat->seat = static_cast<wl_seat *>(wl_registry_bind(r, id, &wl_seat_interface, 5));
                    static const wl_seat_listener names = {
                        [](void *, wl_seat *, uint32_t) {},
                        [](void *data, wl_seat *, const char *name) {
                            auto *seat = static_cast<Seat *>(data); seat->name = QString::fromUtf8(name); seat->owner->bind(*seat);
                        }};
                    wl_seat_add_listener(seat->seat, &names, seat.get());
                    self->seats[id] = std::move(seat);
                }
            },
            [](void *data, wl_registry *, uint32_t id) {
                auto *self = static_cast<Impl *>(data);
                const auto it = self->seats.find(id);
                if (it == self->seats.end()) return;
                auto &seat = *it->second;
                self->discard(seat.selected);
                if (seat.device) zwlr_data_control_device_v1_destroy(seat.device);
                if (seat.manager) zwlr_data_control_manager_v1_destroy(seat.manager);
                wl_seat_destroy(seat.seat); self->seats.erase(it);
            }};
        wl_registry_add_listener(registry, &listener, this);
        // Registry negotiation is asynchronous: an unresponsive compositor
        // must not block the Broker's input/health/event loop.
        registrySync = wl_display_sync(display);
        static const wl_callback_listener synced = {
            [](void *data, wl_callback *callback, uint32_t) {
                auto *self = static_cast<Impl *>(data);
                wl_callback_destroy(callback); self->registrySync = nullptr;
                if (!self->managerGlobal) {
                    self->error = "Clipboard sharing requires wlr-data-control";
                    if (self->notifier) self->notifier->setEnabled(false);
                    QTimer::singleShot(0, self, [self] { self->close(); });
                }
            }};
        wl_callback_add_listener(registrySync, &synced, this);
        notifier = new QSocketNotifier(wl_display_get_fd(display), QSocketNotifier::Read, this);
        connect(notifier, &QSocketNotifier::activated, this, [this] { dispatchReady(); });
        writeNotifier = new QSocketNotifier(wl_display_get_fd(display), QSocketNotifier::Write, this);
        writeNotifier->setEnabled(false);
        connect(writeNotifier, &QSocketNotifier::activated, this, [this] { flush(); });
        flush();
        error.clear();
    }
    void bind(Seat &seat) {
        if (!enabled(seat) || seat.device || !managerGlobal) return;
        // A manager per seat keeps protocol source/device association explicit.
        seat.manager = static_cast<zwlr_data_control_manager_v1 *>(wl_registry_bind(registry, managerGlobal, &zwlr_data_control_manager_v1_interface, managerVersion));
        seat.device = zwlr_data_control_manager_v1_get_data_device(seat.manager, seat.seat);
        static const zwlr_data_control_device_v1_listener listener = {
            [](void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *proxy) {
                auto *seat = static_cast<Seat *>(data); auto *self = seat->owner;
                auto offer = std::make_unique<Offer>(); offer->proxy = proxy;
                static const zwlr_data_control_offer_v1_listener types = {
                    [](void *data, zwlr_data_control_offer_v1 *, const char *mime) {
                        auto *offer = static_cast<Offer *>(data);
                        if (offer->types.size() < 64 && strlen(mime) < 512) offer->types.append(QString::fromUtf8(mime));
                        else offer->invalid = true;
                    }};
                zwlr_data_control_offer_v1_add_listener(proxy, &types, offer.get()); self->offers[proxy] = std::move(offer);
            },
            [](void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *proxy) {
                auto &seat = *static_cast<Seat *>(data); auto *self = seat.owner;
                const auto it = self->offers.find(proxy);
                auto *offer = it == self->offers.end() ? nullptr : it->second.get();
                if (seat.selected != offer) self->discard(seat.selected);
                seat.selected = offer;
                const bool initial = seat.initial; seat.initial = false;
                if (!self->enabled(seat)) return;
                if (!offer) {
                    // Acknowledge our own NULL selection instead of echoing it
                    // back indefinitely across all devices.
                    if (seat.clearPending) { seat.clearPending = false; return; }
                    if (!initial) { ++self->epoch; self->cancelTransfers(true); self->publish({}); }
                    else if (self->sharedSelectionKnown) self->publish(self->sharedPayload, &seat);
                    return;
                }
                seat.clearPending = false;
                if (offer->types.contains(QString::fromUtf8(self->marker))) return;
                if (offer->invalid) {
                    ++self->epoch; self->cancelTransfers(true);
                    self->error = "Clipboard offer exceeds MIME sharing limits"; return;
                }
                self->receive(seat, *offer);
            },
            [](void *data, zwlr_data_control_device_v1 *) {
                auto &seat = *static_cast<Seat *>(data); seat.owner->discard(seat.selected); seat.selected = nullptr;
                zwlr_data_control_device_v1_destroy(seat.device); seat.device = nullptr;
                zwlr_data_control_manager_v1_destroy(seat.manager); seat.manager = nullptr; seat.initial = true;
            },
            [](void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *proxy) {
                auto *seat = static_cast<Seat *>(data); const auto it = seat->owner->offers.find(proxy);
                if (it != seat->owner->offers.end()) seat->owner->discard(it->second.get());
            }};
        zwlr_data_control_device_v1_add_listener(seat.device, &listener, &seat);
        flush();
    }
    void receive(const Seat &, const Offer &offer) {
        cancelTransfers(true);
        auto batch = std::make_shared<Batch>(); batch->epoch = ++epoch;
        batch->pending = offer.types.size();
        for (const auto &type : offer.types) {
            int pipefd[2];
            if (pipe2(pipefd, O_CLOEXEC)) {
                error = "Cannot allocate clipboard transfer pipe";
                batch->failed = true; cancelTransfers(true, batch->epoch); break;
            }
            zwlr_data_control_offer_v1_receive(offer.proxy, type.toUtf8().constData(), pipefd[1]); ::close(pipefd[1]);
            auto *reader = new Transfer(pipefd[0], QSocketNotifier::Read, this); reader->epoch = batch->epoch;
            auto complete = [this, reader, batch, type](bool success) {
                if (reader->fd < 0) return;
                ::close(reader->fd); reader->fd = -1;
                if (success) batch->data[type] = reader->data; else { batch->failed = true; cancelTransfers(true, batch->epoch); }
                --batch->pending; reader->done();
                if (!batch->pending && batch->epoch == epoch && !batch->failed) { publish(batch->data); error.clear(); ++transfers; }
            };
            reader->finish = [this, complete] { error = "Clipboard transfer timed out"; complete(false); };
            connect(reader->notifier, &QSocketNotifier::activated, reader, [this, reader, batch, complete] {
                char bytes[16384];
                while (true) {
                    const auto count = ::read(reader->fd, bytes, sizeof(bytes));
                    if (count > 0) {
                        batch->total += count;
                        if (batch->total > maxBytes) { error = "Clipboard exceeds configured sharing limit"; complete(false); break; }
                        reader->data.append(bytes, count);
                    } else if (!count) { complete(true); break; }
                    else if (errno != EAGAIN && errno != EINTR) { complete(false); break; }
                    else if (errno == EAGAIN) break;
                }
            });
        }
        flush();
    }
    void publish(const QMap<QString, QByteArray> &payload, Seat *only = nullptr) {
        if (!only) { sharedPayload = payload; sharedSelectionKnown = true; }
        for (auto &[id, seat] : seats) {
            if ((only && seat.get() != only) || !enabled(*seat) || !seat->device) continue;
            if (payload.isEmpty()) {
                if (seat->selected && !seat->clearPending) {
                    seat->clearPending = true;
                    zwlr_data_control_device_v1_set_selection(seat->device, nullptr);
                }
                continue;
            }
            auto source = std::make_unique<Source>(); source->owner = this; source->data = payload;
            source->proxy = zwlr_data_control_manager_v1_create_data_source(seat->manager);
            static const zwlr_data_control_source_v1_listener listener = {
                [](void *data, zwlr_data_control_source_v1 *, const char *mime, int32_t fd) {
                    auto *source = static_cast<Source *>(data); auto *self = source->owner;
                    if (self->lockScope == "full" || self->mode != "shared" || self->activeWriters() >= 16) {
                        ::close(fd); self->error = "Clipboard transfer blocked or concurrency limit reached"; return;
                    }
                    auto *writer = new Transfer(fd, QSocketNotifier::Write, self);
                    writer->data = source->data.value(QString::fromUtf8(mime));
                    writer->finish = [writer] { writer->done(); };
                    connect(writer->notifier, &QSocketNotifier::activated, writer, [writer] {
                        while (writer->offset < writer->data.size()) {
                            const auto count = ::write(writer->fd, writer->data.constData() + writer->offset, writer->data.size() - writer->offset);
                            if (count > 0) writer->offset += count;
                            else if (count < 0 && errno == EINTR) continue;
                            else if (count < 0 && errno == EAGAIN) return;
                            else { writer->done(); return; }
                        }
                        writer->done();
                    });
                },
                [](void *data, zwlr_data_control_source_v1 *proxy) {
                    auto *source = static_cast<Source *>(data); auto *self = source->owner;
                    zwlr_data_control_source_v1_destroy(proxy); self->sources.erase(proxy);
                }};
            zwlr_data_control_source_v1_add_listener(source->proxy, &listener, source.get());
            for (auto it = payload.begin(); it != payload.end(); ++it) zwlr_data_control_source_v1_offer(source->proxy, it.key().toUtf8().constData());
            zwlr_data_control_source_v1_offer(source->proxy, marker.constData());
            zwlr_data_control_device_v1_set_selection(seat->device, source->proxy);
            const auto proxy = source->proxy; sources[proxy] = std::move(source);
        }
        flush();
    }
};

ClipboardBridge::ClipboardBridge(const QString &display, QObject *parent) : QObject(parent), m(std::make_unique<Impl>(display, this)) {}
ClipboardBridge::~ClipboardBridge() = default;
void ClipboardBridge::configure(const QStringList &seatNames, const QString &primarySeat, const QString &mode, qint64 maxBytes, const QString &lockScope) {
    const QSet<QString> names(seatNames.begin(), seatNames.end());
    maxBytes = std::clamp<qint64>(maxBytes, 1024, 64 * 1024 * 1024);
    if (names != m->allowed || mode != m->mode || lockScope != m->lockScope || maxBytes != m->maxBytes) {
        ++m->epoch;
        // A revoked policy or superseded selection closes its pipes immediately.
        m->cancelTransfers(lockScope != "full" && mode == "shared");
    }
    m->allowed = names; m->primary = primarySeat; m->mode = mode; m->lockScope = lockScope;
    m->maxBytes = std::clamp<qint64>(maxBytes, 1024, 64 * 1024 * 1024);
    if (mode != "shared") { if (m->display) m->close(); return; }
    if (!m->display) m->open();
    else { for (auto &[id, seat] : m->seats) m->bind(*seat); m->flush(); }
}
QJsonObject ClipboardBridge::status() const {
    QJsonArray seats;
    for (const auto &[global, seat] : m->seats)
        seats.append(QJsonObject{{"name",seat->name},{"enabled",m->enabled(*seat)},{"bound",seat->device != nullptr}});
    return {{"mode", m->mode}, {"connected", m->display != nullptr && m->managerGlobal != 0},
        {"seats",seats}, {"error", m->error}, {"transfers", static_cast<qint64>(m->transfers)}};
}
