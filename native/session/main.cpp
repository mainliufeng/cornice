#include "../desktop/HyprlandAdapter.hpp"
#include "SleepRequest.hpp"
#include "hyprland-lock-scope-v1.h"
#include <QCoreApplication>
#include <QDBusError>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusReply>
#include <QDBusUnixFileDescriptor>
#include <QJsonDocument>
#include <QJsonObject>
#include <QElapsedTimer>
#include <QLocalSocket>
#include <QSocketNotifier>
#include <QTimer>
#include <QVariantMap>
#include <cstdio>
#include <exception>
#include <cstring>
#include <unistd.h>
#include <syslog.h>
#include <wayland-client.h>

// logind delay FD stays open until the compositor reports a presented full
// lock. Full lock input revocation happens in Hyprland, before presentation.
class SessionGuard : public QObject {
  Q_OBJECT
public:
  wl_display *display = nullptr;
  hyprland_lock_scope_manager_v1 *manager = nullptr;
  hyprland_lock_guard_v1 *guardian = nullptr;
  ~SessionGuard() override {
    if (display)
      wl_display_disconnect(display);
  }
  bool supervise() {
    try {
      display = HyprlandAdapter(qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE"))
                    .connectManagementDisplay();
    } catch (const std::exception &error) {
      fprintf(stderr, "Session guard management connection failed: %s\n", error.what());
      return false;
    }
    if (!display)
      return false;
    auto *registry = wl_display_get_registry(display);
    static const wl_registry_listener listener{
        [](void *data, wl_registry *registry, uint32_t id, const char *name,
           uint32_t) {
          if (!strcmp(name, "hyprland_lock_scope_manager_v1")) {
            auto *self = static_cast<SessionGuard *>(data);
            self->manager =
                static_cast<hyprland_lock_scope_manager_v1 *>(wl_registry_bind(
                    registry, id, &hyprland_lock_scope_manager_v1_interface, 1));
          }
        },
        [](void *, wl_registry *, uint32_t) {}};
    wl_registry_add_listener(registry, &listener, this);
    if (wl_display_roundtrip(display) < 0 || !manager)
      return false;
    guardian = hyprland_lock_scope_manager_v1_get_guard(manager);
    if (wl_display_roundtrip(display) < 0)
      return false;
    auto *notifier = new QSocketNotifier(wl_display_get_fd(display),
                                         QSocketNotifier::Read, this);
    connect(notifier, &QSocketNotifier::activated, this, [this] {
      if (wl_display_dispatch(display) < 0)
        QCoreApplication::quit();
    });
    return true;
  }
  QDBusConnection bus = QDBusConnection::systemBus();
  QDBusUnixFileDescriptor delay, gate, lid;
  QTimer poll, retry;
  QString session;
  bool sleeping = false, hint = false, lidClosed = false, lidQueryFailed = false;
  bool readinessKnown = false, ready = false, suspendInFlight = false;
  unsigned callSerial = 0;
  SleepRequest request;
  QElapsedTimer clock;
  QString sleepMethod = "Suspend";
  QByteArray commands;
  void emitEvent(const char *name, QJsonObject details = {}) {
    details["event"] = name;
    if (!details.contains("source"))
      details["source"] = request.fromLid ? "lid" : "manual";
    details["attempt"] = int(request.attempts);
    details["generation"] = int(request.generation);
    const auto data = QJsonDocument(details).toJson(QJsonDocument::Compact);
    // stdout is consumed by QML. Keep a separate persistent journal record,
    // including the D-Bus failure rather than just an ephemeral UI state.
    syslog(LOG_NOTICE, "%s", data.constData());
    fwrite(data.data(), 1, data.size(), stdout);
    fputc('\n', stdout);
    fflush(stdout);
  }
  QJsonObject state() {
    QLocalSocket socket;
    socket.connectToServer(qEnvironmentVariable("XDG_RUNTIME_DIR") + "/hypr/" +
                           qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE") +
                           "/.socket.sock");
    if (!socket.waitForConnected(500))
      return {};
    socket.write("j/seat lock-state");
    if (!socket.waitForBytesWritten(500))
      return {};
    QByteArray answer;
    while (socket.waitForReadyRead(500))
      answer += socket.readAll();
    answer += socket.readAll();
    return QJsonDocument::fromJson(answer).object();
  }
  void reportReadiness() {
    const bool value = delay.isValid() && lid.isValid() && gate.isValid() &&
                       !sleeping && !suspendInFlight;
    if (!readinessKnown || value != ready) {
      readinessKnown = true;
      ready = value;
      emitEvent(value ? "inhibitor-ready" : "inhibitor-unavailable");
    }
  }
  void gateSleep() {
    if (gate.isValid())
      return;
    auto message = QDBusMessage::createMethodCall(
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "Inhibit");
    message << "sleep" << "cornice"
            << "Use cornice suspend to secure all agent desktops first"
            << "block";
    const auto reply = bus.call(message, QDBus::Block, 1500);
    if (reply.type() == QDBusMessage::ReplyMessage &&
        !reply.arguments().isEmpty())
      gate = reply.arguments()[0].value<QDBusUnixFileDescriptor>();
    if (!gate.isValid())
      emitEvent("sleep-gate-unavailable");
    reportReadiness();
  }
  void requestSuspend(const QString &method = "Suspend", bool fromLid = false) {
    if (request.active || suspendInFlight || sleeping)
      return;
    sleepMethod = method;
    // Retrying shutdown/reboot would introduce a new destructive action.
    const bool canRetry = method == "Suspend" || method == "Hibernate" ||
                          method == "HybridSleep" || method == "SuspendThenHibernate";
    request.begin(clock.elapsed(), fromLid, canRetry ? 3 : 1);
    emitEvent("full-lock-required");
  }
  bool watchLid() {
    if (!lid.isValid())
      return false;
    auto message = QDBusMessage::createMethodCall(
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.DBus.Properties", "GetAll");
    message << "org.freedesktop.login1.Manager";
    const QDBusReply<QVariantMap> reply = bus.call(message, QDBus::Block, 500);
    if (!reply.isValid() || !reply.value().contains("LidClosed")) {
      if (!lidQueryFailed)
        emitEvent("lid-query-failed", {{"error", reply.error().name()},
                                        {"message", reply.error().message()}});
      lidQueryFailed = true;
      return false;
    }
    if (lidQueryFailed)
      emitEvent("lid-query-recovered");
    lidQueryFailed = false;
    const auto properties = reply.value();
    const bool closed = properties.value("LidClosed").toBool();
    if (!closed && request.lidOpened())
      emitEvent("lid-request-cancelled", {{"callInFlight", suspendInFlight}});
    if (closed && !lidClosed) {
      QString action =
          properties.value("HandleLidSwitch", "suspend").toString();
      if (properties.value("Docked").toBool())
        action = properties.value("HandleLidSwitchDocked", "ignore").toString();
      else if (properties.value("OnExternalPower").toBool() &&
               !properties.value("HandleLidSwitchExternalPower")
                    .toString()
                    .isEmpty())
        action = properties.value("HandleLidSwitchExternalPower").toString();
      const QMap<QString, QString> methods{
          {"suspend", "Suspend"},
          {"hibernate", "Hibernate"},
          {"hybrid-sleep", "HybridSleep"},
          {"suspend-then-hibernate", "SuspendThenHibernate"},
          {"poweroff", "PowerOff"},
          {"reboot", "Reboot"}};
      emitEvent("lid-policy", {{"action", action}, {"source", "lid"},
                                {"docked", properties.value("Docked").toBool()},
                                {"externalPower", properties.value("OnExternalPower").toBool()}});
      if (methods.contains(action))
        requestSuspend(methods[action], true);
      else if (action == "lock")
        emitEvent("lid-lock-required");
      else if (action != "ignore")
        emitEvent("lid-action-unsupported");
    }
    lidClosed = closed;
    return true;
  }
  void inhibitLid() {
    if (lid.isValid())
      return;
    auto message = QDBusMessage::createMethodCall(
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "Inhibit");
    message << "handle-lid-switch" << "cornice"
            << "Secure all desktops before the configured lid action"
            << "block";
    const auto reply = bus.call(message, QDBus::Block, 1500);
    if (reply.type() == QDBusMessage::ReplyMessage &&
        !reply.arguments().isEmpty())
      lid = reply.arguments()[0].value<QDBusUnixFileDescriptor>();
    if (!lid.isValid())
      emitEvent("lid-control-unavailable");
  }
  void consume(const QByteArray &data) {
    commands += data;
    while (commands.contains('\n')) {
      auto line = commands.left(commands.indexOf('\n'));
      commands.remove(0, line.size() + 1);
      if (line == "suspend")
        requestSuspend();
    }
    if (commands.size() > 4096)
      QCoreApplication::quit();
  }
  void inhibit() {
    auto message = QDBusMessage::createMethodCall(
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "Inhibit");
    message << "sleep" << "cornice"
            << "Present a full session lock before sleep" << "delay";
    const auto reply = bus.call(message, QDBus::Block, 1500);
    if (reply.type() == QDBusMessage::ReplyMessage &&
        !reply.arguments().isEmpty()) {
      delay = reply.arguments()[0].value<QDBusUnixFileDescriptor>();
    } else {
      delay = {};
    }
    reportReadiness();
  }
  SessionGuard() {
    clock.start();
    auto query = QDBusMessage::createMethodCall(
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "GetSessionByPID");
    query << uint(getpid());
    const auto reply = bus.call(query, QDBus::Block, 1500);
    if (reply.type() == QDBusMessage::ReplyMessage &&
        !reply.arguments().isEmpty())
      session = reply.arguments()[0].value<QDBusObjectPath>().path();
    bus.connect("org.freedesktop.login1", "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager", "PrepareForSleep", this,
                SLOT(prepare(bool)));
    connect(&poll, &QTimer::timeout, this, [this] {
      const auto lock = state();
      const bool locked = lock["locked"].toBool();
      const bool fullSecure =
          locked && lock["scope"] == "session" && lock["secure"].toBool();
      if (!sleeping && !suspendInFlight)
        gateSleep();
      const bool secureHint = locked && lock["secure"].toBool();
      if (!lock.isEmpty() && secureHint != hint && !session.isEmpty()) {
        auto message = QDBusMessage::createMethodCall(
            "org.freedesktop.login1", session, "org.freedesktop.login1.Session",
            "SetLockedHint");
        message << secureHint;
        const auto reply = bus.call(message, QDBus::Block, 500);
        if (reply.type() == QDBusMessage::ReplyMessage)
          hint = secureHint;
      }
      if (request.active && !suspendInFlight && request.expired(clock.elapsed())) {
        emitEvent("sleep-request-expired", {{"locked", locked},
                    {"scope", lock["scope"]}, {"secure", lock["secure"]},
                    {"stateAvailable", !lock.isEmpty()}});
        request.cancel();
      }
      if (request.active && !suspendInFlight && !fullSecure &&
          request.retryLock(clock.elapsed())) {
        if (request.fromLid && (!watchLid() || !request.active))
          return;
        emitEvent("sleep-lock-wait", {{"locked", locked},
                    {"scope", lock["scope"]}, {"secure", lock["secure"]},
                    {"stateAvailable", !lock.isEmpty()}});
        emitEvent("full-lock-required");
      }
      if (!sleeping && !suspendInFlight && request.ready(clock.elapsed(), fullSecure)) {
        // The 500ms lid observer may lag a physical opening. Re-read immediately
        // before every lid-triggered API call; an unavailable query is not consent.
        if (request.fromLid && (!watchLid() || !request.active || !lidClosed))
          return;
        const auto confirmed = state();
        if (!confirmed["locked"].toBool() || confirmed["scope"] != "session" ||
            !confirmed["secure"].toBool())
          return;
        const auto token = request.takeAttempt();
        const auto call = ++callSerial;
        suspendInFlight = true;
        gate = {};
        reportReadiness();
        auto message = QDBusMessage::createMethodCall(
            "org.freedesktop.login1", "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager", sleepMethod);
        message << true;
        auto *pending =
            new QDBusPendingCallWatcher(bus.asyncCall(message), this);
        connect(pending, &QDBusPendingCallWatcher::finished, this,
                [this, token, call](QDBusPendingCallWatcher *result) {
          if (call != callSerial) {
            result->deleteLater();
            return;
          }
          if (result->isError()) {
            const auto error = result->error();
            emitEvent("suspend-failed", {{"error", error.name()},
                                        {"message", error.message()},
                                        {"method", sleepMethod}});
            suspendInFlight = false;
            const bool retryable = error.type() != QDBusError::AccessDenied &&
                error.type() != QDBusError::InvalidArgs &&
                error.type() != QDBusError::UnknownMethod &&
                error.type() != QDBusError::UnknownInterface &&
                error.type() != QDBusError::NotSupported &&
                error.type() != QDBusError::NoReply &&
                error.type() != QDBusError::Timeout &&
                error.type() != QDBusError::TimedOut &&
                error.type() != QDBusError::Disconnected &&
                !error.name().contains("AuthFailed") &&
                !error.name().contains("NotAuthorized") &&
                !error.name().contains("Cancelled");
            if (request.current(token)) {
              const bool again = request.failed(clock.elapsed(), retryable);
              emitEvent(again ? "sleep-retry-scheduled" : "sleep-request-stopped");
            }
            if (!sleeping)
              gateSleep();
          } else {
            emitEvent("suspend-accepted");
            // Never retry while the first D-Bus call is still pending (e.g. an
            // authentication prompt). Start confirmation timing only after reply.
            if (!sleeping)
              QTimer::singleShot(5000, this, [this, token, call] {
                if (call != callSerial || !suspendInFlight || sleeping)
                  return;
                suspendInFlight = false;
                emitEvent("suspend-unconfirmed");
                if (request.current(token)) {
                  // An accepted operation with no signal has an uncertain
                  // outcome. Do not duplicate it or bypass other inhibitors.
                  request.cancel();
                  emitEvent("sleep-request-stopped", {{"reason", "accepted-without-prepare"}});
                }
                gateSleep();
              });
          }
          result->deleteLater();
        });
        emitEvent("suspend-requested", {{"method", sleepMethod}});
      }
      if (sleeping && delay.isValid() && lock["scope"] == "session" &&
          lock["secure"].toBool()) {
        delay = {};
        emitEvent("sleep-lock-secure");
        reportReadiness();
      }
    });
    poll.start(100);
    auto *lidPoll = new QTimer(this);
    connect(lidPoll, &QTimer::timeout, this, [this] { watchLid(); });
    lidPoll->start(500);
    connect(&retry, &QTimer::timeout, this, [this] {
      if (!sleeping && !suspendInFlight) {
        inhibitLid();
        gateSleep();
        if (!delay.isValid())
          inhibit();
      }
    });
    retry.start(15000);
    inhibitLid();
    gateSleep();
    inhibit();
  }
public slots:
  void prepare(bool value) {
    sleeping = value;
    request.cancel();
    suspendInFlight = false;
    ++callSerial;
    emitEvent(value ? "prepare-for-sleep" : "sleep-resumed");
    reportReadiness();
    if (value)
      emitEvent("full-lock-required");
    else {
      suspendInFlight = false;
      emitEvent("resumed");
      gateSleep();
      inhibit();
    }
  }
};
int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  openlog("cornice-session-guard", LOG_PID, LOG_USER);
  if (qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE").isEmpty())
    return 2;
  SessionGuard guard;
  if (!guard.supervise())
    return 2;
  // EOF from Cornice means its guard is no longer supervised. The compositor
  // retains any lock; the FD cannot silently leak into an orphaned helper.
  auto *input = new QSocketNotifier(STDIN_FILENO, QSocketNotifier::Read, &app);
  QObject::connect(input, &QSocketNotifier::activated, &app, [&app, &guard] {
    char bytes[1024];
    const auto count = read(STDIN_FILENO, bytes, sizeof(bytes));
    if (count <= 0)
      app.quit();
    else
      guard.consume(QByteArray(bytes, count));
  });
  return app.exec();
}
#include "main.moc"
