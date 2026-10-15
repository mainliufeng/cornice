#include "ApplicationScope.hpp"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>
#include <QUuid>
#include <sys/stat.h>
#include <unistd.h>

namespace {
struct Property { QString name; QDBusVariant value; };
using Properties = QList<Property>;
struct Command { QString program; QStringList argv; bool ignoreFailure = false; };
using Commands = QList<Command>;
struct Auxiliary { QString name; Properties properties; };
using Auxiliaries = QList<Auxiliary>;
QDBusArgument &operator<<(QDBusArgument &a, const Property &p) { a.beginStructure(); a << p.name << p.value; a.endStructure(); return a; }
const QDBusArgument &operator>>(const QDBusArgument &a, Property &p) { a.beginStructure(); a >> p.name >> p.value; a.endStructure(); return a; }
QDBusArgument &operator<<(QDBusArgument &a, const Command &c) { a.beginStructure(); a << c.program << c.argv << c.ignoreFailure; a.endStructure(); return a; }
const QDBusArgument &operator>>(const QDBusArgument &a, Command &c) { a.beginStructure(); a >> c.program >> c.argv >> c.ignoreFailure; a.endStructure(); return a; }
QDBusArgument &operator<<(QDBusArgument &a, const Auxiliary &u) { a.beginStructure(); a << u.name << u.properties; a.endStructure(); return a; }
const QDBusArgument &operator>>(const QDBusArgument &a, Auxiliary &u) { a.beginStructure(); a >> u.name >> u.properties; a.endStructure(); return a; }
const QString managerPath = "/org/freedesktop/systemd1", managerInterface = "org.freedesktop.systemd1.Manager", managerService = "org.freedesktop.systemd1";
QString objectPath(const QString &name) {
    QString encoded;
    for (const auto c : name.toUtf8()) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) encoded += QChar(c);
        else encoded += "_" + QString::number(static_cast<unsigned char>(c),16).rightJustified(2,'0');
    }
    return managerPath + "/unit/" + encoded;
}
bool serviceParent() {
    QFile file("/proc/self/cgroup"); if (!file.open(QIODevice::ReadOnly)) return true;
    const auto parts = QString::fromUtf8(file.readAll()).trimmed().split('/');
    for (auto it = parts.crbegin(); it != parts.crend(); ++it) {
        if (it->endsWith(".scope")) return false;
        if (it->endsWith(".service")) return !it->startsWith("user@");
    }
    return false;
}
QString callerSlice() {
    QFile file("/proc/self/cgroup"); if (!file.open(QIODevice::ReadOnly)) return "app.slice";
    return ApplicationScope::sliceForCgroup(QString::fromUtf8(file.readAll()).trimmed());
}
QVariantList baseProperties(const QString &program, const QStringList &arguments, const QProcessEnvironment &environment, const QString &log, const QStringList &managerKeys, bool notify = false) {
    QVariantList p;
    auto add = [&](QString name, QVariant value) { p.append(QVariant::fromValue(Property{std::move(name),QDBusVariant(std::move(value))})); };
    add("ExecStart",QVariant::fromValue(Commands{{program,QStringList{program}+arguments,false}}));
    add("Environment",environment.toStringList()); add("Slice",callerSlice());
    const auto unset=ApplicationScope::unsetManagerKeys(environment,managerKeys,notify);
    if (!unset.isEmpty()) add("UnsetEnvironment",unset);
    add("CollectMode","inactive-or-failed"); add("TimeoutStartUSec",qulonglong(5000000));
    add("TimeoutStopUSec",qulonglong(3000000)); add("KillMode","control-group");
    if (!log.isEmpty()) { add("StandardOutputFileToAppend",log); add("StandardErrorFileToAppend",log); }
    return p;
}
}
Q_DECLARE_METATYPE(Property)
Q_DECLARE_METATYPE(Properties)
Q_DECLARE_METATYPE(Command)
Q_DECLARE_METATYPE(Commands)
Q_DECLARE_METATYPE(Auxiliary)
Q_DECLARE_METATYPE(Auxiliaries)

QStringList ApplicationScope::unsetManagerKeys(const QProcessEnvironment &environment, const QStringList &managerKeys, bool notify) {
    QStringList unset;
    for (const auto &key:managerKeys) {
        // systemd creates fresh per-unit metadata after applying Environment.
        // In particular a Type=notify guard must retain its own NOTIFY_SOCKET.
        if (key=="INVOCATION_ID" || key=="JOURNAL_STREAM" || (notify && key=="NOTIFY_SOCKET")) continue;
        if (!environment.contains(key)) unset.append(key);
    }
    return unset;
}

QString ApplicationScope::sliceForCgroup(const QString &path) {
    const auto parts=path.split('/');
    const auto boundary=parts.indexOf("user@"+QString::number(getuid())+".service");
    // Host user/session slices are outside the user manager's namespace. A
    // same-named transient slice would not inherit their resource controls.
    if (boundary<0) return "app.slice";
    for (auto index=parts.size()-1; index>boundary; --index)
        if (parts[index].endsWith(".slice")) return parts[index];
    return "app.slice";
}

ApplicationScope::ApplicationScope(ApplicationScopeSpec spec, QObject *parent)
    : QObject(parent), m_spec(std::move(spec)), m_connectionName("cornice-application-"+QUuid::createUuid().toString(QUuid::WithoutBraces)), m_bus(m_connectionName) {
    qDBusRegisterMetaType<Property>(); qDBusRegisterMetaType<Properties>();
    qDBusRegisterMetaType<Command>(); qDBusRegisterMetaType<Commands>();
    qDBusRegisterMetaType<Auxiliary>(); qDBusRegisterMetaType<Auxiliaries>();
    m_deadline.setSingleShot(true); m_deadline.setInterval(8000);
    connect(&m_deadline,&QTimer::timeout,this,[this] { finish(m_submitted ? "Application startup acknowledgement timed out; launch may have been submitted; inspect state before retrying" : "Application isolation startup timed out; no application was submitted"); });
    m_deadline.start(); QTimer::singleShot(0,this,[this] { begin(); });
}
ApplicationScope::~ApplicationScope() { QDBusConnection::disconnectFromBus(m_connectionName); }
void ApplicationScope::whenStarted(std::function<void(ApplicationScopeResult)> callback) {
    if (m_done) { const auto result = m_result; QTimer::singleShot(0,this,[callback=std::move(callback),result] { callback(result); }); }
    else m_callbacks.append(std::move(callback));
}
void ApplicationScope::finish(QString error) {
    if (m_done) return;
    m_done = true; m_deadline.stop(); m_result.error = std::move(error);
    const auto callbacks = std::move(m_callbacks);
    for (const auto &callback : callbacks) { const auto result = m_result; QTimer::singleShot(0,this,[callback,result] { callback(result); }); }
}
void ApplicationScope::cancel(const QString &reason) {
    finish(reason + (m_submitted ? "; application launch already submitted; outcome may be uncertain" : "; no application was submitted"));
}
bool ApplicationScope::checkSubmission() {
    if (m_done) return false;
    if (!m_submissionCheck) return true;
    QString error;
    try { error = m_submissionCheck(); }
    catch (...) { error = "Application control validation failed"; }
    if (!error.isEmpty()) { finish(error+"; no application was submitted"); return false; }
    return true;
}
void ApplicationScope::begin() {
    if (m_done) return;
    if (!QFileInfo(m_spec.program).isAbsolute()) {
        const auto paths = m_spec.environment.value("PATH").split(':',Qt::KeepEmptyParts);
        m_spec.program = QStandardPaths::findExecutable(m_spec.program,paths);
    }
    if (m_spec.program.isEmpty() || !QFileInfo(m_spec.program).isExecutable()) { finish("Application executable unavailable; no application was submitted"); return; }
    if (m_spec.environment.contains("XDG_ACTIVATION_TOKEN")) {
        const auto prefix = m_spec.environment.value("CORNICE_PATH", "/usr/share/cornice");
        const auto helper = prefix + "/bin/cornice-action-exec";
        if (!QFileInfo(helper).isExecutable()) { finish("Application routing helper unavailable; no application was submitted"); return; }
        m_spec.arguments = QStringList{"--", m_spec.program} + m_spec.arguments;
        m_spec.program = helper;
    }
    const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    const auto manager = runtime + "/systemd/private";
    struct stat identity{};
    if (::stat(manager.toLocal8Bit().constData(),&identity) != 0 || !S_ISSOCK(identity.st_mode)) {
        if (serviceParent()) { finish("Application isolation unavailable inside a managed service; no application was submitted"); return; }
        QProcess process; process.setProgram(m_spec.program); process.setArguments(m_spec.arguments);
        process.setProcessEnvironment(m_spec.environment); process.setWorkingDirectory(m_spec.workingDirectory);
        if (!m_spec.log.isEmpty()) { process.setStandardOutputFile(m_spec.log,QIODevice::Append); process.setStandardErrorFile(m_spec.log,QIODevice::Append); }
        if (!checkSubmission()) return;
        m_submitted = true;
        if (!process.startDetached(&m_result.pid)) { finish("Application launch failed"); return; }
        finish(); return;
    }
    m_bus = QDBusConnection::connectToBus("unix:path="+runtime+"/bus",m_connectionName);
    if (!m_bus.isConnected()) { finish("Application isolation manager connection failed; no application was submitted"); return; }
    if (!m_bus.connect(managerService,managerPath,managerInterface,"JobRemoved",this,SLOT(jobRemoved(uint,QDBusObjectPath,QString,QString)))) {
        finish("Application isolation manager subscription failed; no application was submitted"); return;
    }
    const auto instance = m_spec.environment.value("HYPRLAND_INSTANCE_SIGNATURE");
    if (instance.isEmpty() || instance.contains('/') || instance.contains(QChar(0))) { finish("Explicit compositor instance required for application lifetime"); return; }
    m_guard = "cornice-compositor-" + QString::fromLatin1(QCryptographicHash::hash((m_spec.environment.value("XDG_RUNTIME_DIR",runtime)+'\0'+instance).toUtf8(),QCryptographicHash::Sha256).toHex().left(32)) + ".service";
    m_result.unit = "cornice-application-"+QUuid::createUuid().toString(QUuid::WithoutBraces)+".service";
    m_result.managed = true;
    auto subscribe = QDBusMessage::createMethodCall(managerService,managerPath,managerInterface,"Subscribe");
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(subscribe,3000),this);
    connect(watcher,&QDBusPendingCallWatcher::finished,this,[this,watcher] {
        QDBusPendingReply<> reply = *watcher; watcher->deleteLater(); if (m_done) return;
        if (reply.isError()) { finish("Application isolation manager subscription failed ("+reply.error().name()+"); no application was submitted"); return; }
        readManagerEnvironment();
    });
}
void ApplicationScope::readManagerEnvironment() {
    auto message=QDBusMessage::createMethodCall(managerService,managerPath,"org.freedesktop.DBus.Properties","Get");
    message << managerInterface << "Environment";
    auto *watcher=new QDBusPendingCallWatcher(m_bus.asyncCall(message,3000),this);
    connect(watcher,&QDBusPendingCallWatcher::finished,this,[this,watcher] {
        QDBusPendingReply<QDBusVariant> reply=*watcher; watcher->deleteLater(); if (m_done) return;
        if (reply.isError()) { finish("Application manager environment unavailable; no application was submitted"); return; }
        // A user service otherwise inherits manager variables omitted by the
        // caller. Retain keys only, so unset and empty remain distinct without
        // storing or exposing another process's environment values.
        for (const auto &entry:reply.value().variant().toStringList()) {
            const auto separator=entry.indexOf('=');
            if (separator>0) m_managerEnvironmentKeys.append(entry.left(separator));
        }
        submitGuard();
    });
}
void ApplicationScope::submitGuard() {
    const auto program = QCoreApplication::applicationDirPath()+"/cornice-application-guard";
    if (!QFileInfo(program).isExecutable()) { finish("Application lifetime guard executable missing; no application was submitted"); return; }
    auto environment = QProcessEnvironment::systemEnvironment();
    for (const auto *key : {"NOTIFY_SOCKET","INVOCATION_ID","JOURNAL_STREAM","DISPLAY","WAYLAND_DISPLAY","WAYLAND_SOCKET","DBUS_SESSION_BUS_ADDRESS","HYPRLAND_INSTANCE_SIGNATURE"}) environment.remove(key);
    const auto socket = m_spec.environment.value("XDG_RUNTIME_DIR",qEnvironmentVariable("XDG_RUNTIME_DIR"))+"/hypr/"+m_spec.environment.value("HYPRLAND_INSTANCE_SIGNATURE")+"/.socket2.sock";
    auto properties = baseProperties(program,{socket},environment,{},m_managerEnvironmentKeys,true);
    properties.append(QVariant::fromValue(Property{"Type",QDBusVariant("notify")}));
    properties.append(QVariant::fromValue(Property{"Description",QDBusVariant("Cornice compositor application lifetime")}));
    submit(m_guard,properties,true);
}
void ApplicationScope::submitApplication() {
    if (!checkSubmission()) return;
    auto environment = m_spec.environment;
    for (const auto *key : {"NOTIFY_SOCKET","INVOCATION_ID","JOURNAL_STREAM"}) environment.remove(key);
    auto properties = baseProperties(m_spec.program,m_spec.arguments,environment,m_spec.log,m_managerEnvironmentKeys);
    properties.append(QVariant::fromValue(Property{"Type",QDBusVariant("exec")}));
    properties.append(QVariant::fromValue(Property{"ExitType",QDBusVariant("cgroup")}));
    properties.append(QVariant::fromValue(Property{"BindsTo",QDBusVariant(QStringList{m_guard})}));
    properties.append(QVariant::fromValue(Property{"After",QDBusVariant(QStringList{m_guard})}));
    properties.append(QVariant::fromValue(Property{"Description",QDBusVariant("Cornice desktop application")}));
    if (!m_spec.workingDirectory.isEmpty()) properties.append(QVariant::fromValue(Property{"WorkingDirectory",QDBusVariant(m_spec.workingDirectory)}));
    m_submitted = true;
    submit(m_result.unit,properties,false);
}
void ApplicationScope::submit(const QString &unit, const QVariantList &properties, bool guard) {
    if (m_done) return;
    Properties typed; for (const auto &property : properties) typed.append(property.value<Property>());
    m_waitGuard = guard; m_waitUnit = unit; m_job.clear(); m_earlyResults.clear();
    auto message = QDBusMessage::createMethodCall(managerService,managerPath,managerInterface,"StartTransientUnit");
    message << unit << "fail" << QVariant::fromValue(typed) << QVariant::fromValue(Auxiliaries{});
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message,5000),this);
    connect(watcher,&QDBusPendingCallWatcher::finished,this,[this,watcher,guard] {
        QDBusPendingReply<QDBusObjectPath> reply = *watcher; watcher->deleteLater(); if (m_done) return;
        if (reply.isError()) {
            if (guard && reply.error().name() == "org.freedesktop.systemd1.UnitExists") { inspectGuard(); return; }
            finish((guard ? "Application lifetime guard submission failed (" : "Application unit submission failed (") + reply.error().name() + ")" + (guard ? "; no application was submitted" : "; inspect state before retrying")); return;
        }
        m_job = reply.value().path();
        if (m_earlyResults.contains(m_job)) continueJob(m_earlyResults.take(m_job));
    });
}
void ApplicationScope::jobRemoved(uint, QDBusObjectPath job, QString unit, QString result) {
    if (m_done || unit != m_waitUnit) return;
    if (m_job.isEmpty()) { if (m_earlyResults.size() < 8) m_earlyResults[job.path()] = result; return; }
    if (m_job == job.path()) continueJob(result);
}
void ApplicationScope::continueJob(const QString &result) {
    if (result != "done") { finish(m_waitGuard ? "Application lifetime guard failed to start; no application was submitted" : "Application executable failed to start in its independent unit"); return; }
    if (m_waitGuard) submitApplication(); else inspectApplication();
}
void ApplicationScope::inspectGuard() {
    auto message = QDBusMessage::createMethodCall(managerService,objectPath(m_guard),"org.freedesktop.DBus.Properties","Get");
    message << "org.freedesktop.systemd1.Unit" << "ActiveState";
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message,3000),this);
    connect(watcher,&QDBusPendingCallWatcher::finished,this,[this,watcher] {
        QDBusPendingReply<QDBusVariant> reply = *watcher; watcher->deleteLater(); if (m_done) return;
        if (reply.isError()) { finish("Application lifetime guard is unavailable; no application was submitted"); return; }
        const auto state = reply.value().variant().toString();
        if (state == "activating") { QTimer::singleShot(100,this,[this] { if (!m_done) inspectGuard(); }); return; }
        if (state != "active") { finish("Application lifetime guard is not active; no application was submitted"); return; }
        submitApplication();
    });
}
void ApplicationScope::inspectApplication() {
    auto message = QDBusMessage::createMethodCall(managerService,objectPath(m_result.unit),"org.freedesktop.DBus.Properties","Get");
    message << "org.freedesktop.systemd1.Service" << "MainPID";
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message,3000),this);
    connect(watcher,&QDBusPendingCallWatcher::finished,this,[this,watcher] {
        QDBusPendingReply<QDBusVariant> reply = *watcher; watcher->deleteLater(); if (m_done) return;
        if (reply.isError()) {
            if (reply.error().name() == "org.freedesktop.DBus.Error.UnknownObject" || reply.error().name() == "org.freedesktop.systemd1.NoSuchUnit") {
                // Type=exec's successful start job proves exec happened; rapid
                // commands may already be collected before PID inspection.
                m_result.exited = true; finish(); return;
            }
            finish("Application started but its PID acknowledgement is unavailable; inspect state before retrying"); return;
        }
        m_result.pid = reply.value().variant().toLongLong();
        m_result.exited = m_result.pid == 0; finish();
    });
}
