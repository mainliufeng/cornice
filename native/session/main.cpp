#include "cornice-human-lock-v1.h"
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusReply>
#include <QDBusUnixFileDescriptor>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QSocketNotifier>
#include <QTimer>
#include <QVariantMap>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <wayland-client.h>

// logind delay FD stays open until the compositor reports a presented full
// lock. Full lock input revocation happens in Hyprland, before presentation.
class SessionGuard : public QObject {
  Q_OBJECT
public:
  wl_display *display = nullptr;
  cornice_human_lock_manager_v1 *manager = nullptr;
  cornice_session_guard_v1 *guardian = nullptr;
  ~SessionGuard() override {
    if (display)
      wl_display_disconnect(display);
  }
  bool supervise() {
    display = wl_display_connect(nullptr);
    if (!display)
      return false;
    auto *registry = wl_display_get_registry(display);
    static const wl_registry_listener listener{
        [](void *data, wl_registry *registry, uint32_t id, const char *name,
           uint32_t) {
          if (!strcmp(name, "cornice_human_lock_manager_v1")) {
            auto *self = static_cast<SessionGuard *>(data);
            self->manager =
                static_cast<cornice_human_lock_manager_v1 *>(wl_registry_bind(
                    registry, id, &cornice_human_lock_manager_v1_interface, 1));
          }
        },
        [](void *, wl_registry *, uint32_t) {}};
    wl_registry_add_listener(registry, &listener, this);
    if (wl_display_roundtrip(display) < 0 || !manager)
      return false;
    guardian = cornice_human_lock_manager_v1_get_guard(manager);
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
  bool sleeping = false, hint = false, suspendRequested = false,
       lidClosed = false;
  bool readinessKnown = false, ready = false, suspendInFlight = false;
  QString sleepMethod = "Suspend";
  QByteArray commands;
  void emitEvent(const char *name) {
    const auto data = QJsonDocument(QJsonObject{{"event", name}})
                          .toJson(QJsonDocument::Compact);
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
  void requestSuspend(const QString &method = "Suspend") {
    if (suspendRequested || sleeping)
      return;
    sleepMethod = method;
    suspendRequested = true;
    emitEvent("full-lock-required");
  }
  void watchLid() {
    if (!lid.isValid())
      return;
    auto message = QDBusMessage::createMethodCall(
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.DBus.Properties", "GetAll");
    message << "org.freedesktop.login1.Manager";
    const QDBusReply<QVariantMap> reply = bus.call(message, QDBus::Block, 500);
    if (!reply.isValid())
      return;
    const auto properties = reply.value();
    const bool closed = properties.value("LidClosed").toBool();
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
      if (methods.contains(action))
        requestSuspend(methods[action]);
      else if (action == "lock")
        emitEvent("lid-lock-required");
      else if (action != "ignore")
        emitEvent("lid-action-unsupported");
    }
    lidClosed = closed;
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
      if (lock.isEmpty())
        return;
      const bool locked = lock["locked"].toBool();
      const bool fullSecure =
          locked && lock["scope"] == "session" && lock["secure"].toBool();
      if (!sleeping && !suspendInFlight)
        gateSleep();
      const bool secureHint = locked && lock["secure"].toBool();
      if (secureHint != hint && !session.isEmpty()) {
        auto message = QDBusMessage::createMethodCall(
            "org.freedesktop.login1", session, "org.freedesktop.login1.Session",
            "SetLockedHint");
        message << secureHint;
        const auto reply = bus.call(message, QDBus::Block, 500);
        if (reply.type() == QDBusMessage::ReplyMessage)
          hint = secureHint;
      }
      if (suspendRequested && fullSecure) {
        suspendRequested = false;
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
                [this](QDBusPendingCallWatcher *result) {
                  emitEvent(result->isError() ? "suspend-failed"
                                              : "suspend-accepted");
                  if (result->isError()) {
                    suspendInFlight = false;
                    gateSleep();
                  }
                  result->deleteLater();
                });
        emitEvent("suspend-requested");
        QTimer::singleShot(5000, this, [this] {
          if (suspendInFlight && !sleeping) {
            suspendInFlight = false;
            gateSleep();
            emitEvent("suspend-unconfirmed");
          }
        });
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
