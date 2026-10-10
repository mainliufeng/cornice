#include "Broker.hpp"
#include "ApplicationLaunch.hpp"
#include <QBuffer>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTemporaryFile>
#include <QUuid>
#include <signal.h>
#include <stdexcept>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <unistd.h>

static void fail(const QString &message) { throw std::runtime_error(message.toStdString()); }
static QJsonArray recoveredHandoffs(QJsonArray records) {
    while (records.size() > 20) records.removeFirst();
    for (int i = 0; i < records.size(); ++i) {
        auto record = records[i].toObject();
        if (record["status"] != "requested" && record["status"] != "in_progress") continue;
        record["status"] = "cancelled";
        record["note"] = "Desktop service restarted; request owner disconnected";
        record["updatedAt"] = QDateTime::currentMSecsSinceEpoch();
        auto events = record["events"].toArray();
        events.append(QJsonObject{{"status", "cancelled"}, {"note", record["note"]}, {"at", record["updatedAt"]}});
        while (events.size() > 20) events.removeFirst();
        record["events"] = events; records[i] = record;
    }
    return records;
}
static QString uuid() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
static void atom(const QString &value) {
    if (value.isEmpty() || value.size() > 128 || value.contains(QRegularExpression("[\\s/\\x00-\\x1f]")))
        fail("Invalid desktop argument");
}
static QJsonDocument json(const QByteArray &bytes) {
    QJsonParseError error;
    auto value = QJsonDocument::fromJson(bytes, &error);
    if (error.error != QJsonParseError::NoError)
        fail(QString::fromUtf8(bytes.left(300)));
    return value;
}
QString desktopSocket(const QString &instance) {
    if (!QRegularExpression("^[A-Za-z0-9_.-]{1,128}$").match(instance).hasMatch())
        fail("Explicit compositor instance required");
    const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty() || !QFileInfo(runtime).isDir())
        fail("XDG_RUNTIME_DIR required");
    return runtime + "/cornice/" + instance + "/desktop.sock";
}
QJsonObject desktopRequest(const QString &path, const QJsonObject &request) {
    QLocalSocket socket;
    socket.connectToServer(path);
    if (!socket.waitForConnected(2000))
        fail("Desktop service unavailable: " + socket.errorString());
    const auto bytes = QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n';
    socket.write(bytes);
    if (!socket.waitForBytesWritten(2000))
        fail("Desktop request write timed out");
    QByteArray response;
    while (!response.contains('\n')) {
        if (!socket.waitForReadyRead(5000))
            fail("Desktop response timed out");
        response += socket.readAll();
        if (response.size() > 64 * 1024 * 1024)
            fail("Desktop response too large");
    }
    return json(response.left(response.indexOf('\n'))).object();
}

Broker::Broker(QString instance)
    : m_instance(std::move(instance)), m_socketPath(desktopSocket(m_instance)),
      m_directory(QFileInfo(m_socketPath).path()), m_compositor(m_instance) {
    QDir().mkpath(m_directory);
    QFile::setPermissions(m_directory, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    for (const auto &file : QDir(m_directory).entryList({"frame-*", "shot-*"}, QDir::Files))
        QFile::remove(m_directory + "/" + file);
    const auto caps = json(compositor("seat capabilities", true)).object();
    const auto features = caps["features"].toArray();
    for (const QString name : {"seat-input", "seat-identity", "atomic-snapshot", "readonly-workspace", "argb-frame",
                               "input-pause", "composed-seat-input", "seat-shell-v1", "native-seat-presentation-v1", "primary-desktop-v1", "managed-seat-config-v1"})
        if (!features.contains(name))
            fail("Required compositor capability missing: " + name);
    if (caps["protocol"].toInt() != 1)
        fail("Unsupported compositor seat protocol");
    QJsonArray mainHandoffs;
    QFile file(m_directory + "/desktops.json");
    if (file.open(QIODevice::ReadOnly)) {
        const auto saved = json(file.readAll()).object();
        mainHandoffs = recoveredHandoffs(saved["main"].toObject()["handoffs"].toArray());
        for (auto it = saved.begin(); it != saved.end(); ++it) {
            if (it.key() == "main") continue;
            try {
                const auto actual = state(it.key());
                if (actual["seatId"].toString() !=
                    (it.value().isString() ? it.value().toString() : it.value().toObject()["seatId"].toString()))
                    continue;
                m_desktops.emplace(it.key(), Desktop{it.value().isString() ? it.value().toString()
                                                                           : it.value().toObject()["seatId"].toString(),
                                                     {},
                                                     {},
                                                     {},
                                                     {}});
                if (it.value().isObject())
                    m_desktops.at(it.key()).privateOutput = it.value().toObject()["privateOutput"].toString();
                auto &recovered = m_desktops.at(it.key());
                recovered.agentAllowed = it.value().toObject()["agentAllowed"].toBool(true);
                recovered.handoffs = recoveredHandoffs(it.value().toObject()["handoffs"].toArray());
                recovered.number = it.value().toObject()["number"].toInt(m_nextDesktopNumber);
                m_nextDesktopNumber = std::max(m_nextDesktopNumber, recovered.number + 1);
                initializeSlots(it.key(), it.value().toObject()["workspaceSlots"].toObject());
                // Recovery revokes survivors; never restore input automatically.
                pause(it.key());
                startShell(it.key());
            } catch (...) {
            }
        }
    }
    const auto primary = state("main");
    m_desktops.emplace("main", Desktop{primary["seatId"].toString(), {}, {}, {}, {}});
    auto &main = m_desktops.at("main");
    main.primary = true; main.number = 1; main.agentAllowed = false;main.handoffs = mainHandoffs;
    main.configurationOwner = uuid() + uuid();
    pause("main");
    // A fresh session provides exactly one task-ready secondary desktop. Reuse
    // recovered desktops, including ones explicitly created by external tasks.
    if (m_desktops.size() == 1) {
        const auto size = primary["pixelSize"].toArray();
        perform("create", {{"name", "desktop2"}, {"virtual-output",
            QString("%1x%2").arg(size.at(0).toInt()).arg(size.at(1).toInt())}}, nullptr, nullptr);
    }
    save();
    m_configurationHeartbeat.start();
    connect(&m_watchdog, &QTimer::timeout, this, [this] {
        if (m_configurationHeartbeat.elapsed() >= 1000) {
            m_configurationHeartbeat.restart();
            for (auto &[name, desktop] : m_desktops) {
                try { configureDesktop(name); desktop.configurationError.clear(); }
                catch (const std::exception &error) { desktop.configurationError = QString::fromUtf8(error.what()); }
            }
        }
        if (m_humanOwner) {
            try {
                const auto actual = state(m_humanBinding.name);
                if (m_humanHeartbeat.elapsed() > 3000 || actual["humanLocked"].toBool() || actual["paused"].toBool() ||
                    !actual["available"].toBool() || actual["seatId"].toString() != m_humanBinding.id ||
                    actual["generation"].toString() != m_humanBinding.generation)
                    endTakeover("Human control revoked");
            } catch (...) {
                endTakeover("Desktop unavailable");
            }
        }
        QList<QLocalSocket *> expiredAcquisitions;
        for (auto it = m_acquisitions.begin(); it != m_acquisitions.end(); ++it)
            if (QDateTime::currentMSecsSinceEpoch() - it.value()["heartbeatAt"].toVariant().toLongLong() > 5000)
                expiredAcquisitions.append(it.key());
        for (auto it = m_bindings.begin(); it != m_bindings.end(); ++it) {
            if (it->controller.isEmpty() || !it->heartbeat.isValid() || it->heartbeat.elapsed() <= 5000) continue;
            for (auto owner = m_acquisitions.begin(); owner != m_acquisitions.end(); ++owner)
                if (owner.value()["token"].toString() == it.key()) expiredAcquisitions.append(owner.key());
            it->controller.clear();
            try {
                const auto actual = state(it->name);
                if (actual["seatId"].toString() == it->id && actual["generation"].toString() == it->generation &&
                    actual["controlMode"].toString() == "agent") pause(it->name);
            } catch (...) {}
        }
        for (auto *owner : expiredAcquisitions) { releaseAcquisition(owner); owner->abort(); }
        bool invalidateFrames = false;
        for (auto &[name, desktop] : m_desktops) {
            try {
                startShell(name);
                const auto actual = state(name);
                if (!actual["available"].toBool())
                    invalidateFrames = true;
                if (actual["seatId"].toString() != desktop.id || !actual["available"].toBool() ||
                    actual["paused"].toBool())
                    desktop.driver.reset();
            } catch (...) {
                desktop.driver.reset();
                invalidateFrames = true;
            }
        }
        if (invalidateFrames)
            for (auto it = m_buffers.begin(); it != m_buffers.end(); ++it) {
                QFile file(it.value());
                if (file.open(QIODevice::WriteOnly))
                    file.resize(0);
            }
    });
    m_watchdog.start(250);
    m_events.connectToServer(qEnvironmentVariable("XDG_RUNTIME_DIR") + "/hypr/" + m_instance + "/.socket2.sock");
    connect(&m_events, &QLocalSocket::disconnected, this, [] { QCoreApplication::quit(); });
    connect(&m_events, &QLocalSocket::readyRead, this, [this] {
        m_eventInput += m_events.readAll();
        while (m_eventInput.contains('\n')) {
            const auto line = m_eventInput.left(m_eventInput.indexOf('\n'));
            m_eventInput.remove(0, line.size() + 1);
            if (line != "sessionlock>>locked")
                continue;
            endTakeover("Session locked");
            for (auto it = m_buffers.begin(); it != m_buffers.end(); ++it) {
                QFile file(it.value());
                if (file.open(QIODevice::WriteOnly))
                    file.resize(0);
                it.key()->write("{\"event\":\"frame-invalidated\",\"reason\":\"session "
                                "locked\"}\n");
            }
        }
    });
}

Broker::~Broker() {
    for (auto &[name, desktop] : m_desktops) {
        try {
            pause(name);
            if (!desktop.configurationOwner.isEmpty()) m_compositor.remove(desktop.configurationOwner);
        } catch (...) {
        }
    }
    for (const auto &file : m_buffers)
        QFile::remove(file);
    m_server.close();
}

QByteArray Broker::compositor(const QString &command, bool asJson) {
    return m_compositor.command(command, asJson);
}

QJsonObject Broker::state(const QString &name) {
    atom(name);
    auto result = json(compositor("seat state " + name, true)).object();
    const bool human = m_humanOwner && m_humanBinding.name == name;
    const bool primary = result.value("primary").toBool();
    result["primary"] = primary;
    if (m_desktops.contains(name)) {
        const auto &desktop = m_desktops.at(name);
        result["agentAllowed"] = desktop.agentAllowed;
        result["number"] = desktop.number;
        result["label"] = QString("桌面 %1").arg(desktop.number) + (primary ? " · 主桌面" : "");
    }
    result["controlMode"] = human || (primary && result["paused"].toBool()) ? "human" : result["paused"].toBool() ? "paused" : "agent";
    result["agentPaused"] = human || result["paused"].toBool();
    QString harness;
    bool occupied = false;
    for (const auto &lease : m_acquisitions) if (lease["name"].toString() == name) {
        occupied = true; harness = lease["harness"].toString(); break;
    }
    if (!occupied) for (const auto &binding : m_bindings)
        if (binding.name == name && !binding.controller.isEmpty() && binding.heartbeat.isValid() &&
            binding.heartbeat.elapsed() <= 5000) { occupied = true; harness = binding.harness; break; }
    result["harness"] = harness;
    result["occupied"] = occupied;
    const bool locked = result["humanLocked"].toBool() &&
        !(result["lockScope"].toString() == "human" && result["humanLockPolicy"].toString() == "continue");
    result["activity"] = locked ? "locked" : !result["available"].toBool() ? "unavailable" : human ? "takeover" :
        !occupied ? "idle" : result["agentPaused"].toBool() ? "paused" : "running";
    QJsonArray workspaceSlots;
    const auto workspace = result["workspace"].toString().remove("name:");
    for (int i = 1; i <= 10; ++i) {
        const auto value = primary ? QString::number(i) : m_desktops.contains(name) ? m_desktops.at(name).workspaceSlots.value(i) : QString{};
        workspaceSlots.append(QJsonObject{{"id", i}, {"name", value}, {"active", workspace == QString(value).remove("name:")}});
    }
    if (m_desktops.contains(name)) {
        QJsonArray records;
        for (const auto &entry : m_desktops.at(name).handoffs) { auto record = entry.toObject(); record.remove("controller");record.remove("rpcId"); records.append(record); }
        result["handoffs"] = records;
        if (!records.isEmpty()) result["handoff"] = records.last();
        result["bindingOverrides"] = m_desktops.at(name).bindingOverrides;
        result["configurationError"] = m_desktops.at(name).configurationError;
    }
    result["workspaceName"] = workspace;
    result["workspaceSlots"] = workspaceSlots;
    return result;
}
void Broker::startShell(const QString &name) {
    auto &desktop = m_desktops.at(name);
    if (QDateTime::currentMSecsSinceEpoch() < desktop.shellRestartAt || desktop.privateOutput.isEmpty() ||
        (desktop.shell && desktop.shell->state() != QProcess::NotRunning))
        return;
    const auto prefix = qEnvironmentVariable("CORNICE_PATH");
    if (prefix.isEmpty() || !QFileInfo::exists(prefix + "/shell/shell.qml"))
        return;
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.remove("WAYLAND_SOCKET");
    environment.remove("DISPLAY");
    environment.insert("WAYLAND_DISPLAY", state(name)["display"].toString());
    environment.insert("CORNICE_DESKTOP_NAME", name);
    environment.insert("CORNICE_DESKTOP_OUTPUT", desktop.privateOutput);
    environment.insert(
        "CORNICE_SHELL_SOCKET",
        qEnvironmentVariable("XDG_RUNTIME_DIR") + "/cs-" +
            QString::fromLatin1(
                QCryptographicHash::hash(m_instance.toUtf8(), QCryptographicHash::Sha256).toHex().left(8)) +
            "-" + name + ".sock");
    environment.insert("QS_DISABLE_FILE_WATCHER", "1");
    desktop.shellRestartAt = QDateTime::currentMSecsSinceEpoch() + 5000;
    desktop.shell = std::make_unique<QProcess>();
    const auto parentPid = getpid();
    desktop.shell->setChildProcessModifier([parentPid] {
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (getppid() != parentPid)
            _exit(1);
    });
    desktop.shell->setProcessEnvironment(environment);
    desktop.shell->setProgram(prefix + "/bin/cornice-qs");
    desktop.shell->setArguments({"-p", prefix + "/shell"});
    desktop.shell->setStandardOutputFile(m_directory + "/shell-" + name + ".log", QIODevice::Append);
    desktop.shell->setStandardErrorFile(m_directory + "/shell-" + name + ".log", QIODevice::Append);
    desktop.shell->start();
}
Broker::Desktop &Broker::managed(const QString &name) {
    auto it = m_desktops.find(name);
    if (it == m_desktops.end())
        fail("Desktop is not managed by cornice");
    const auto actual = state(name);
    if (actual["seatId"].toString() != it->second.id)
        fail("Desktop lifecycle changed; stale reference rejected");
    return it->second;
}
void Broker::save() {
    QJsonObject saved;
    for (const auto &[name, desktop] : m_desktops) {
        QJsonObject workspaceMap;
        for (auto it = desktop.workspaceSlots.begin(); it != desktop.workspaceSlots.end(); ++it)
            workspaceMap[QString::number(it.key())] = it.value();
        saved[name] = QJsonObject{{"seatId", desktop.id}, {"privateOutput", desktop.privateOutput},
                                  {"agentAllowed", desktop.agentAllowed}, {"number", desktop.number}, {"workspaceSlots", workspaceMap}, {"handoffs", desktop.handoffs}};
    }
    QSaveFile file(m_directory + "/desktops.json");
    if (!file.open(QIODevice::WriteOnly))
        fail("Cannot save desktop lifecycle record");
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    file.write(QJsonDocument(saved).toJson());
    if (!file.commit())
        fail("Cannot commit desktop lifecycle record");
}
void Broker::pause(const QString &name) {
    if (m_humanOwner && m_humanBinding.name == name) {
        endTakeover("Human control ended");
        return;
    }
    auto &desktop = managed(name);
    const auto actual = state(name);
    const auto reply =
        compositor("seat control " + name + " " + desktop.id + " " + actual["generation"].toString() + " pause", true);
    json(reply);
    desktop.driver.reset();
}

void Broker::endTakeover(const QString &reason) {
    if (!m_humanOwner)
        return;
    auto *owner = m_humanOwner;
    const auto name = m_humanBinding.name;
    m_humanOwner = nullptr;
    m_humanBinding = {};
    const auto requestId = m_humanRequestId;
    m_humanRequestId.clear();
    if (!requestId.isEmpty() && m_desktops.contains(name)) {
        const auto last = m_desktops.at(name).handoffs.last().toObject();
        if (last["id"] == requestId && last["status"] == "in_progress")
            transitionHandoff(name, requestId, "requested", reason);
    }
    try {
        if (m_presentations.contains(owner)) compositor("seat present-control " + m_presentations[owner] + " no");
        pause(name);
    } catch (...) {
        if (m_desktops.contains(name))
            m_desktops.at(name).driver.reset();
    }
    owner->write(
        QJsonDocument(QJsonObject{{"event", "control-revoked"}, {"reason", reason}}).toJson(QJsonDocument::Compact) +
        '\n');
}

void Broker::resume(const QString &name) {
    auto &desktop = managed(name);
    desktop.driver.reset();
    const auto actual = state(name);
    if (!desktop.agentAllowed) fail("Agent control is disabled for this desktop");
    if (actual["humanLocked"].toBool())
        fail("Unlock session before granting control");
    if (!actual["available"].toBool()) fail("Desktop output unavailable");
    json(compositor(
        "seat control " + name + " " + desktop.id + " " + actual["generation"].toString() + " resume-composed" + (desktop.primary ? " " + QString::number(getpid()) : ""), true));
    const auto resumed = state(name);
    try {
        desktop.captureGrant.clear();
        desktop.captureGrant = uuid() + uuid();
        json(compositor("seat export-grant " + name + " " + desktop.id + " " + resumed["generation"].toString() +
                            " " + desktop.captureGrant,
                        true));
        desktop.driver =
            std::make_unique<SeatDriver>(resumed["display"].toString(), resumed["seatName"].toString(name), resumed["output"].toString());
    } catch (...) {
        pause(name);
        throw;
    }
}

void Broker::listen() {
    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    // The launcher holds an instance lock before stale socket removal.
    QLocalServer::removeServer(m_socketPath);
    if (!m_server.listen(m_socketPath))
        fail("Cannot listen on desktop socket: " + m_server.errorString());
    QSaveFile active(qEnvironmentVariable("XDG_RUNTIME_DIR") + "/cornice/active.json");
    if (!active.open(QIODevice::WriteOnly)) fail("Cannot publish active desktop endpoint");
    active.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    active.write(QJsonDocument(QJsonObject{{"instance", m_instance}, {"socket", m_socketPath}, {"pid", getpid()}}).toJson());
    if (!active.commit()) fail("Cannot publish active desktop endpoint");
    connect(&m_server, &QLocalServer::newConnection, this, [this] {
        while (auto *socket = m_server.nextPendingConnection()) {
            struct ucred credential{};
            socklen_t size = sizeof(credential);
            if (getsockopt(socket->socketDescriptor(), SOL_SOCKET, SO_PEERCRED, &credential, &size) ||
                credential.uid != getuid()) {
                socket->abort();
                socket->deleteLater();
                continue;
            }
            auto *input = new QByteArray;
            connect(socket, &QLocalSocket::readyRead, this, [this, socket, input] {
                *input += socket->readAll();
                if (input->size() > 1024 * 1024) {
                    socket->abort();
                    return;
                }
                while (input->contains('\n')) {
                    const auto line = input->left(input->indexOf('\n'));
                    input->remove(0, line.size() + 1);
                    QJsonObject reply;
                    QString requestId;
                    try {
                        const auto request = json(line).object();
                        requestId = request["id"].toString();
                        const auto method = request["method"].toString();
                        if (method == "desktop.snapshot" || method == "desktop.action") {
                            handleNative(request, socket);
                            continue;
                        }
                        reply = handle(request, socket);
                    } catch (const std::exception &error) {
                        reply = {{"ok", false}, {"id", requestId}, {"error", QString::fromUtf8(error.what())}};
                    }
                    socket->write(QJsonDocument(reply).toJson(QJsonDocument::Compact) + '\n');
                }
            });
            connect(socket, &QLocalSocket::disconnected, this, [this, socket, input] {
                if (m_humanOwner == socket)
                    endTakeover("Viewer disconnected");
                if (m_presentations.contains(socket)) compositor("seat unpresent " + m_presentations.take(socket));
                if (m_buffers.contains(socket))
                    QFile::remove(m_buffers.take(socket));
                m_localOverlays.remove(socket);
                releaseAcquisition(socket);
                delete input;
                socket->deleteLater();
            });
        }
    });
}

void Broker::revokeBindings(const QString &name) {
    for (auto it = m_bindings.begin(); it != m_bindings.end();) {
        if (it->name != name) { ++it; continue; }
        const auto prefix = it.key() + ":";
        for (auto done = m_completed.begin(); done != m_completed.end();) {
            if (!done.key().startsWith(prefix)) { ++done; continue; }
            m_requestHashes.remove(done.key());
            done = m_completed.erase(done);
        }
        // Retire a native helper immediately, before its next event-loop turn.
        // The eventual completion will discard results and will not restore history.
        if (auto process = m_nativeJobs.value(it.key())) {
            process->setProperty("corniceCancelReason", "Native task binding revoked or changed");
            process->kill();
        }
        m_accessibility.invalidate(it->snapshotId);
        it = m_bindings.erase(it);
    }
}

void Broker::releaseAcquisition(QLocalSocket *owner) {
    if (!m_acquisitions.contains(owner)) return;
    const auto lease = m_acquisitions.take(owner);
    const auto token = lease["token"].toString();
    const auto name = lease["name"].toString();
    if (m_desktops.contains(name) && !m_desktops.at(name).handoffs.isEmpty()) {
        const auto record = m_desktops.at(name).handoffs.last().toObject();
        if (record["controller"] == lease["controller"] && (record["status"] == "requested" || record["status"] == "in_progress")) {
            transitionHandoff(name, record["id"].toString(), "cancelled", "Harness disconnected");
            if (m_humanRequestId == record["id"].toString()) endTakeover("Request owner disconnected");
        }
    }
    if (!m_bindings.contains(token)) return;
    m_accessibility.invalidate(m_bindings[token].snapshotId);
    m_bindings.remove(token);
    try {
        const auto actual = state(lease["name"].toString());
        if (actual["seatId"] == lease["seatId"] && actual["generation"] == lease["generation"] &&
            actual["controlMode"].toString() == "agent") pause(lease["name"].toString());
    } catch (...) {}
}


void Broker::transitionHandoff(const QString &name, const QString &id, const QString &status, const QString &note) {
    auto &records = m_desktops.at(name).handoffs;
    for (int i = 0; i < records.size(); ++i) {
        auto record = records[i].toObject();
        if (record["id"] != id) continue;
        record["status"] = status;
        record["note"] = note;
        record["updatedAt"] = QDateTime::currentMSecsSinceEpoch();
        auto events = record["events"].toArray();
        events.append(QJsonObject{{"status", status}, {"note", note}, {"at", record["updatedAt"]}});
        while (events.size() > 20) events.removeFirst();
        record["events"] = events;
        records[i] = record;
        save();
        return;
    }
    fail("Cooperation request no longer exists");
}

void Broker::sealHandoff(const QString &name, const QString &id) {
    auto &desktop = m_desktops.at(name);
    auto record = desktop.handoffs.last().toObject();
    if (record["id"] != id) fail("Cooperation request changed");
    const auto actual = state(name);
    record["resumeGeneration"] = actual["generation"];
    record["resumeLockEpoch"] = actual["lockEpoch"];
    record["resumeDecision"] = static_cast<qint64>(desktop.inputDecision);
    desktop.handoffs[desktop.handoffs.size()-1] = record;
    save();
}

QJsonObject Broker::handoff(const QJsonObject &request) {
    // The task reservation outlives an input generation. It authorizes only
    // cooperation records for this task, never input or desktop management.
    auto lease = m_acquisitions.end();
    const auto token = request["token"].toString();
    if (token.isEmpty()) fail("Task cooperation credential required");
    for (auto it = m_acquisitions.begin(); it != m_acquisitions.end(); ++it)
        if (it.value()["taskToken"].toString() == token) { lease = it; break; }
    if (lease == m_acquisitions.end() || lease.value()["controller"] != request["controller"])
        fail("Unknown or foreign task reservation");
    const auto name = lease.value()["name"].toString();
    auto &desktop = managed(name);
    if (desktop.id != lease.value()["seatId"].toString()) fail("Desktop lifecycle changed");
    lease.value()["heartbeatAt"] = QDateTime::currentMSecsSinceEpoch();
    if (m_bindings.contains(lease.value()["token"].toString())) m_bindings[lease.value()["token"].toString()].heartbeat.restart();
    const auto params = request["params"].toObject();
    const auto action = params["action"].toString("status");
    if (action == "status") return {{"state", state(name)}};
    auto record = desktop.handoffs.isEmpty() ? QJsonObject{} : desktop.handoffs.last().toObject();
    if (action == "request") {
        const auto title = params["title"].toString().trimmed();
        const auto instructions = params["instructions"].toString().trimmed();
        for (const auto &entry : desktop.handoffs) {
            const auto previous = entry.toObject();
            if (previous["rpcId"] == request["id"]) {
                if (previous["title"] != title || previous["instructions"] != instructions) fail("Request ID reused for different cooperation request");
                if (previous["status"] == "completed" || previous["status"] == "cancelled") fail("Cooperation request already resolved; inspect history");
            }
        }
        if (title.isEmpty() || title.size() > 160 || instructions.isEmpty() || instructions.size() > 4000)
            fail("Provide a title (1-160 characters) and human instructions (1-4000 characters)");
        if (record["status"] == "requested" || record["status"] == "in_progress") {
            if (record["controller"] == lease.value()["controller"] && record["title"] == title && record["instructions"] == instructions)
                return {{"state", state(name)}};
            fail("Resolve the active cooperation request first");
        }
        const auto actual = state(name);
        if (!desktop.agentAllowed || actual["humanLocked"].toBool() || !actual["available"].toBool() || actual["agentPaused"].toBool() || actual["generation"] != lease.value()["generation"] || !m_bindings.contains(lease.value()["token"].toString()))
            fail("Active desktop control required to request takeover");
        pause(name);
        revokeBindings(name);
        record = {{"id", uuid()}, {"rpcId", request["id"]}, {"controller", lease.value()["controller"]}, {"harness", lease.value()["harness"]},
                  {"title", title}, {"instructions", instructions}, {"createdAt", QDateTime::currentMSecsSinceEpoch()}};
        desktop.handoffs.append(record);
        while (desktop.handoffs.size() > 20) desktop.handoffs.removeFirst();
        transitionHandoff(name, record["id"].toString(), "requested", "Agent requested human assistance");
    } else {
        if (record.isEmpty() || record["id"] != params["requestId"] || record["controller"] != lease.value()["controller"])
            fail("This task does not own that cooperation request");
        if (action == "resolve") {
            const auto outcome = params["outcome"].toString();
            const auto note = params["note"].toString().trimmed();
            if ((outcome != "completed" && outcome != "cancelled") || note.isEmpty() || note.size() > 2000)
                fail("Expected completed or cancelled with an explanation (1-2000 characters)");
            if (record["status"] == "completed" || record["status"] == "cancelled") {
                if (record["status"] != outcome) fail("Cooperation request already resolved differently");
            } else {
                // Never release unrelated manual control on the same desktop.
                if (m_humanOwner && m_humanBinding.name == name && m_humanRequestId != record["id"].toString())
                    fail("This request does not own the current human takeover");
                transitionHandoff(name, record["id"].toString(), outcome, note);
                if (m_humanRequestId == record["id"].toString()) endTakeover("Agent resolved cooperation request");
                sealHandoff(name, record["id"].toString());
            }
        } else if (action == "resume") {
            if (record["status"] != "completed" && record["status"] != "cancelled") fail("Resolve cooperation before resuming input");
            if (m_humanOwner && m_humanBinding.name == name) fail("Another human takeover is active");
            if (record["restored"].toBool()) {
                const auto actual = state(name);
                if (!m_bindings.contains(lease.value()["token"].toString()) || actual["generation"] != lease.value()["generation"] || actual["agentPaused"].toBool())
                    fail("Subsequent interruption requires explicit operator restoration");
            } else {
                const auto actual = state(name);
                if (actual["generation"] != record["resumeGeneration"] || actual["lockEpoch"] != record["resumeLockEpoch"] ||
                    record["resumeDecision"].toVariant().toULongLong() != desktop.inputDecision)
                    fail("Subsequent interruption requires explicit operator restoration");
                resume(name); revokeBindings(name);
                auto binding = perform("bind", {{"name", name}}, nullptr, lease.key());
                auto &input = m_bindings[binding["token"].toString()];
                input.controller = lease.value()["controller"].toString(); input.harness = lease.value()["harness"].toString(); input.heartbeat.start();
                for (auto it = binding.begin(); it != binding.end(); ++it) lease.value()[it.key()] = it.value();
                record["restored"] = true; desktop.handoffs[desktop.handoffs.size()-1] = record; save();
            }
            return {{"state", state(name)}, {"binding", lease.value()}};
        } else fail("Expected cooperation request, status, resolve or resume");
    }
    return {{"state", state(name)}};
}

QJsonObject Broker::acquireDesktop(const QJsonObject &params, QLocalSocket *owner) {
    if (m_acquisitions.contains(owner)) return m_acquisitions[owner];
    const auto controller = params["controller"].toString();
    if (!QRegularExpression("^[A-Za-z0-9_-]{1,64}$").match(controller).hasMatch()) fail("Invalid controller identity");
    const auto harness = params["harness"].toString("external");
    if (!QRegularExpression("^[A-Za-z0-9_.-]{1,64}$").match(harness).hasMatch()) fail("Invalid harness identity");
    if (state("main")["humanLocked"].toBool()) fail("Unlock session before acquiring a desktop");
    const auto preferred = params["preferredDesktop"].toString();
    if (!preferred.isEmpty()) {
        atom(preferred);
        if (!m_desktops.contains(preferred)) fail("Requested desktop does not exist");
        if (!managed(preferred).agentAllowed) fail("Agent control is disabled for this desktop");
    }
    const auto free = [this](const QString &name) {
        const auto &desktop = m_desktops.at(name);
        if (!desktop.agentAllowed || (m_humanOwner && m_humanBinding.name == name)) return false;
        for (const auto &lease : m_acquisitions) if (lease["name"].toString() == name) return false;
        const auto actual = state(name);
        if (!actual["available"].toBool() || actual["humanLocked"].toBool() || !actual["paused"].toBool()) return false;
        for (const auto &binding : m_bindings)
            if (binding.name == name && ((binding.id == actual["seatId"].toString() && binding.generation == actual["generation"].toString()) ||
                (!binding.controller.isEmpty() && binding.heartbeat.isValid() && binding.heartbeat.elapsed() <= 5000))) return false;
        return true;
    };
    QString name;
    bool created = false;
    if (!params["createNew"].toBool()) {
        if (!preferred.isEmpty()) {
            if (free(preferred)) name = preferred;
        } else {
            int number = INT_MAX;
            for (const auto &[candidate, desktop] : m_desktops)
                if (!desktop.primary && !desktop.privateOutput.isEmpty() && desktop.number < number && free(candidate)) {
                    name = candidate; number = desktop.number;
                }
        }
    }
    if (name.isEmpty()) {
        if (m_desktops.size() >= 32) fail("Desktop allocation limit reached (32); remove an unused desktop first");
        name = "desktop-" + uuid().left(12);
        const auto size = state("main")["pixelSize"].toArray();
        const auto geometry = QString("%1x%2").arg(size.at(0).toInt()).arg(size.at(1).toInt());
        perform("create", {{"name", name}, {"virtual-output", geometry}}, nullptr, nullptr);
        created = true;
    }
    try {
        resume(name);
        auto lease = perform("bind", {{"name", name}}, nullptr, owner);
        auto &binding = m_bindings[lease["token"].toString()];
        binding.controller = controller;
        binding.harness = harness;
        binding.heartbeat.start();
        lease["created"] = created;
        lease["harness"] = harness;
        lease["controller"] = controller;
        lease["taskToken"] = uuid() + uuid();
        lease["heartbeatAt"] = QDateTime::currentMSecsSinceEpoch();
        m_acquisitions[owner] = lease;
        return lease;
    } catch (...) {
        try { pause(name); } catch (...) {}
        throw;
    }
}

QJsonObject Broker::handle(const QJsonObject &request, QLocalSocket *owner) {
    const auto id = request["id"].toString();
    if (id.isEmpty() || id.size() > 128)
        fail("Request ID required");
    const auto method = request["method"].toString();
    if (method == "register-local-overlay") {
        if (!request["token"].toString().isEmpty() || !owner) fail("Local application connection required");
        struct ucred credential{};
        socklen_t size = sizeof(credential);
        if (getsockopt(owner->socketDescriptor(), SOL_SOCKET, SO_PEERCRED, &credential, &size) || credential.uid != getuid())
            fail("Local application peer required");
        const auto spaces = request["params"].toObject()["namespaces"].toArray();
        if (spaces.isEmpty() || spaces.size() > 8) fail("Overlay namespaces required");
        QJsonArray routes;
        for (const auto &value : spaces) {
            const auto space = value.toString();
            if (!QRegularExpression("^[a-zA-Z0-9_.-]{1,80}$").match(space).hasMatch()) fail("Invalid overlay namespace");
            routes.append(QJsonObject{{"name", space}, {"pid", credential.pid}, {"keyboard", false}, {"localInView", true}});
        }
        m_localOverlays[owner] = routes;
        for (const auto &[name, desktop] : m_desktops) configureDesktop(name);
        return {{"ok", true}, {"id", id}, {"result", QJsonObject{{"registered", true}}}};
    }
    if (method == "acquire-desktop") {
        if (!request["token"].toString().isEmpty() || !owner) fail("Local allocation connection required");
        return {{"ok", true}, {"id", id}, {"result", acquireDesktop(request["params"].toObject(), owner)}};
    }

    if (method == "desktop.handoff")
        return {{"ok", true}, {"id", id}, {"result", handoff(request)}};
    const auto token = request["token"].toString();
    const bool writing = method == "desktop.input" || method == "desktop.workspace" || method == "desktop.focus" ||
                         method == "desktop.launch" || method == "desktop.browser" || method == "desktop.action";
    const bool releasing = method == "desktop.release";
    const auto key = token + ":" + id;
    const auto fingerprint =
        QCryptographicHash::hash(QJsonDocument(request).toJson(QJsonDocument::Compact), QCryptographicHash::Sha256);
    Binding *binding = nullptr;
    if (method.startsWith("desktop.")) {
        if (token.isEmpty())
            fail("Bound agent credential required");
        if (!m_bindings.contains(token))
            fail("Agent binding revoked or unknown");
        binding = &m_bindings[token];
        const auto actual = state(binding->name);
        if (actual["seatId"].toString() != binding->id || actual["generation"].toString() != binding->generation)
            fail("Agent binding revoked; obtain a new binding after "
                 "resynchronization");
        const auto controller = request["controller"].toString();
        if (!controller.isEmpty()) {
            if (!QRegularExpression("^[A-Za-z0-9_-]{1,64}$").match(controller).hasMatch()) fail("Invalid controller identity");
            if (!binding->controller.isEmpty() && binding->controller != controller) fail("Another harness owns this desktop binding");
            binding->controller = controller;
            if (binding->harness.isEmpty()) {
                const auto harness = request["harness"].toString("external");
                if (!QRegularExpression("^[A-Za-z0-9_.-]{1,64}$").match(harness).hasMatch()) fail("Invalid harness identity");
                binding->harness = harness;
            }
            binding->heartbeat.restart();
            for (auto it = m_acquisitions.begin(); it != m_acquisitions.end(); ++it)
                if (it.value()["token"].toString() == token) it.value()["heartbeatAt"] = QDateTime::currentMSecsSinceEpoch();
        } else if ((writing || releasing) && !binding->controller.isEmpty()) fail("Another harness owns this desktop binding");
        if (writing && (!managed(binding->name).agentAllowed || actual["agentPaused"].toBool() ||
                        (m_humanOwner && m_humanBinding.name == binding->name)))
            fail("Agent control is disabled or owned by a human");
        if (writing && (actual["paused"].toBool() || !actual["available"].toBool()))
            fail("Desktop input paused or unavailable");
    } else if (!token.isEmpty())
        fail("Agent credential cannot access desktop management");
    if (writing && m_completed.contains(key)) {
        if (m_requestHashes[key] != fingerprint)
            fail("Request ID reused for different action");
        return m_completed[key];
    }
    if (writing && m_completed.size() >= 4096)
        fail("Request history full; obtain a new binding after resynchronization");
    QJsonObject reply;
    try {
        reply = {{"ok", true}, {"id", id}, {"result", perform(method, request["params"].toObject(), binding, owner)}};
    } catch (const std::exception &error) {
        if (method == "desktop.input" && binding &&
            QString::fromUtf8(error.what()) != "Screenshot became stale; capture again") {
            try {
                pause(binding->name);
            } catch (...) {
            }
        }
        reply = {{"ok", false}, {"id", id}, {"error", QString::fromUtf8(error.what())}};
    }
    if (writing) {
        // Retry deduplication is bounded to this live service; a service restart
        // revokes every credential instead of replaying uncertain actions.
        m_completed[key] = reply;
        m_requestHashes[key] = fingerprint;
    }
    return reply;
}

// Accessibility calls may wait on an application's event loop. Never run them
// synchronously on the broker event loop: presentation and input ownership must
// keep receiving heartbeats while an unrelated window is slow.
void Broker::handleNative(const QJsonObject &request, QLocalSocket *owner) {
    const auto token = request["token"].toString();
    const auto id = request["id"].toString();
    const auto method = request["method"].toString();
    const bool writing = method == "desktop.action";
    const auto key = token + ":" + id;
    const auto fingerprint = QCryptographicHash::hash(QJsonDocument(request).toJson(QJsonDocument::Compact), QCryptographicHash::Sha256);
    // Reuse the normal credential/controller/generation validation and heartbeat
    // path; this read does not enter mutation retry history.
    auto validationRequest = request;
    validationRequest["method"] = "desktop.state";
    const auto validated = handle(validationRequest, owner);
    if (!validated["ok"].toBool()) fail(validated["error"].toString());
    const auto actual = validated["result"].toObject();
    auto &binding = m_bindings[token];
    const auto name = binding.name;
    const auto params = request["params"].toObject();
    const bool blocked = actual["humanLocked"].toBool() &&
        !(actual["lockScope"].toString() == "human" && actual["humanLockPolicy"].toString() == "continue");
    if (!managed(name).agentAllowed || actual["agentPaused"].toBool() || !actual["available"].toBool() || blocked)
        fail("Native accessibility requires active desktop control");
    if (writing && request["controller"].toString().isEmpty() && !binding.controller.isEmpty())
        fail("Another harness owns this desktop binding");
    if (writing && m_completed.contains(key)) {
        if (m_requestHashes[key] != fingerprint) fail("Request ID reused for different action");
        owner->write(QJsonDocument(m_completed[key]).toJson(QJsonDocument::Compact) + '\n');
        return;
    }
    if (writing && m_pendingNativeHashes.contains(key)) {
        if (m_pendingNativeHashes[key] != fingerprint) fail("Request ID reused for different action");
        fail("Native action is still in progress; outcome is uncertain, do not duplicate the action");
    }
    if (writing && m_completed.size() >= 4096) fail("Request history full; obtain a new binding after resynchronization");
    if (m_nativeJobs.contains(token)) fail("Another native request is in progress for this task; wait for it to finish");
    if (m_nativeJobs.size() >= 8) fail("Native accessibility request limit reached; retry after an existing request finishes");
    auto targetId = params["windowId"].toString(actual["windowId"].toString());
    QString targetAddress;
    if (writing) {
        if (params["snapshotId"].toString().isEmpty() || params["snapshotId"].toString() != binding.snapshotId)
            fail("Native snapshot expired or belongs to another task; request a fresh tree");
        for (const QString field : {"seatId", "generation", "workspace", "viewEpoch", "lockEpoch"})
            if (binding.snapshotState[field] != actual[field]) fail("Native desktop changed; request a fresh tree");
        targetAddress = m_accessibility.elementWindow(binding.snapshotId, params["elementRef"].toString())["address"].toString();
        if (params["action"].toString() == "setText" && !params["text"].isString())
            fail("Native setText requires explicit text, including an explicit empty string to clear");
    }
    QJsonObject member;
    for (const auto &value : json(compositor("seat windows " + name, true)).array()) {
        const auto window = value.toObject();
        if (writing ? window["address"].toString() == targetAddress : window["id"].toString() == targetId) member = window;
    }
    if (member.isEmpty()) fail("Native window is outside this desktop's current workspace");
    const auto all = json(compositor("clients", true)).array();
    QJsonObject window;
    for (const auto &value : all) if (value.toObject()["address"] == member["address"]) window = value.toObject();
    if (window.isEmpty()) fail("Native window disappeared; observe again");
    if (!writing) {
        m_accessibility.invalidate(binding.snapshotId);
        binding.snapshotId = uuid();
        binding.snapshotState = actual;
    }
    const auto scope = binding.snapshotId;
    const auto controller = binding.controller;
    QPointer<QLocalSocket> weakOwner(owner);
    auto currentError = [this, token, name, actual, scope, controller, member, weakOwner]() -> QString {
        if (!weakOwner || weakOwner->state() != QLocalSocket::ConnectedState) return "Native request owner disconnected";
        const auto currentBinding = m_bindings.constFind(token);
        if (currentBinding == m_bindings.cend() || currentBinding->name != name || currentBinding->snapshotId != scope || currentBinding->controller != controller)
            return "Native task binding revoked or changed";
        if (!m_desktops.contains(name) || !managed(name).agentAllowed) return "Native desktop permission revoked";
        const auto fresh = state(name);
        const bool locked = fresh["humanLocked"].toBool() &&
            !(fresh["lockScope"].toString() == "human" && fresh["humanLockPolicy"].toString() == "continue");
        if (fresh["agentPaused"].toBool() || !fresh["available"].toBool() || locked) return "Native desktop control interrupted";
        for (const QString field : {"seatId", "generation", "workspace", "viewEpoch", "lockEpoch"})
            if (actual[field] != fresh[field]) return "Native desktop identity/view changed";
        bool stillPresent = false;
        for (const auto &value : json(compositor("seat windows " + name, true)).array()) {
            const auto candidate = value.toObject();
            stillPresent |= candidate["id"] == member["id"] && candidate["address"] == member["address"];
        }
        return stillPresent ? QString{} : QString("Native window left the authorized workspace");
    };
    auto complete = [this, token, id, key, fingerprint, writing, scope, controller, member, weakOwner, currentError](QJsonObject result, QString error) {
        m_nativeJobs.remove(token);
        m_pendingNativeHashes.remove(key);
        try { const auto changed = currentError(); if (!changed.isEmpty()) error = changed; }
        catch (const std::exception &exception) { error = QString::fromUtf8(exception.what()); }
        QJsonObject reply;
        if (error.isEmpty()) {
            if (!writing) { result["snapshotId"] = scope; result["windowId"] = member["id"]; }
            reply = {{"ok", true}, {"id", id}, {"result", result}};
        } else {
            m_accessibility.invalidate(scope);
            if (writing) error += "; native action outcome may be uncertain; inspect state before retrying";
            reply = {{"ok", false}, {"id", id}, {"error", error}};
        }
        // Revocation already retires this token's history. A late completion must
        // not recreate entries for a revoked or replaced task binding.
        const auto retained = m_bindings.constFind(token);
        if (writing && retained != m_bindings.cend() && retained->controller == controller && retained->snapshotId == scope) {
            m_completed[key] = reply;
            m_requestHashes[key] = fingerprint;
        }
        if (weakOwner && weakOwner->state() == QLocalSocket::ConnectedState)
            weakOwner->write(QJsonDocument(reply).toJson(QJsonDocument::Compact) + '\n');
    };
    QProcess *process;
    if (writing) {
        auto authorization = actual;
        authorization["instance"] = m_instance;
        authorization["runtimeDirectory"] = qEnvironmentVariable("XDG_RUNTIME_DIR");
        process = m_accessibility.actAsync(scope, params["elementRef"].toString(), window, all,
            params["action"].toString(), params["text"].toString(), authorization, this, complete);
        m_pendingNativeHashes[key] = fingerprint;
    } else {
        process = m_accessibility.snapshotAsync(window, all, scope, params["maxNodes"].toInt(160),
            params["maxDepth"].toInt(12), this, complete);
    }
    m_nativeJobs[token] = process;
    auto *guard = new QTimer(process);
    guard->setInterval(100);
    connect(guard, &QTimer::timeout, this, [process, currentError] {
        QString error;
        try { error = currentError(); }
        catch (const std::exception &exception) { error = QString::fromUtf8(exception.what()); }
        if (!error.isEmpty()) { process->setProperty("corniceCancelReason", error); process->kill(); }
    });
    connect(process, &QProcess::finished, guard, &QTimer::stop);
    connect(owner, &QLocalSocket::disconnected, process, [process] {
        process->setProperty("corniceCancelReason", "Native request owner disconnected");
        process->kill();
    });
    guard->start();
}

QJsonObject Broker::capture(const QString &name, const QString &id, const QString &workspace, QLocalSocket *owner,
                            const QString &format, bool agent) {
    atom(workspace);
    QString path;
    std::unique_ptr<QTemporaryFile> temporary;
    if (format == "argb") {
        if (!m_buffers.contains(owner)) {
            QTemporaryFile file(m_directory + "/frame-XXXXXX");
            if (!file.open())
                fail("Cannot allocate frame buffer");
            file.setAutoRemove(false);
            m_buffers[owner] = file.fileName();
        }
        path = m_buffers[owner];
    } else {
        temporary = std::make_unique<QTemporaryFile>(m_directory + "/shot-XXXXXX");
        if (!temporary->open())
            fail("Cannot allocate capture buffer");
        path = temporary->fileName();
    }
    auto command = QString(agent ? "seat agent-snapshot " : "seat snapshot ") + name + " " + id + " " + workspace +
                   " argb " + path;
    if (agent)
        command += " " + state(name)["generation"].toString() + " " + managed(name).captureGrant;
    auto result = json(compositor(command, true)).object();
    result["instance"] = m_instance;
    if (format == "argb")
        result["buffer"] = path;
    else {
        QFile raw(path);
        if (!raw.open(QIODevice::ReadOnly))
            fail("Cannot read snapshot buffer");
        const auto pixels = result["pixelSize"].toArray();
        const auto width = pixels[0].toInt(), height = pixels[1].toInt();
        const auto bytes = raw.readAll();
        if (bytes.size() != static_cast<qsizetype>(width) * height * 4)
            fail("Incomplete capture buffer");
        QImage image(reinterpret_cast<const uchar *>(bytes.constData()), width, height, width * 4,
                     QImage::Format_ARGB32);
        QByteArray png;
        QBuffer buffer(&png);
        buffer.open(QIODevice::WriteOnly);
        if (format != "png" && format != "jpeg") fail("Unsupported screenshot encoding");
        if (!image.save(&buffer, format == "jpeg" ? "JPEG" : "PNG", format == "jpeg" ? 85 : -1))
            fail("Snapshot encoding failed");
        if (format == "jpeg") {
            if (png.size() > 12 * 1024 * 1024) fail("Screenshot exceeds the 12 MiB budget; use structured observation");
            result["imageBase64"] = QString::fromLatin1(png.toBase64());
            result["mimeType"] = "image/jpeg";
        } else result["pngBase64"] = QString::fromLatin1(png.toBase64());
    }
    return result;
}

void Broker::validateFrame(const Binding &binding, const QString &frame, const QJsonObject &actual) {
    if (!binding.frames.contains(frame))
        fail("Own screenshot frame required before input");
    const auto captured = binding.frames[frame];
    for (const QString field : {"seatId", "generation", "workspace", "windowId", "position", "logicalSize", "pixelSize",
                                "scale", "transform", "lockEpoch", "viewEpoch"})
        if (captured[field] != actual[field])
            fail("Screenshot became stale; capture again");
}

QJsonObject Broker::perform(const QString &method, const QJsonObject &params, Binding *binding, QLocalSocket *owner) {
    if (method == "doctor")
        return {{"instance", m_instance}, {"capabilities", json(compositor("seat capabilities", true)).object()}};
    if (method == "list") {
        QJsonArray desktops;
        desktops.append(state("main"));
        for (const auto &[name, desktop] : m_desktops) {
            if (desktop.primary) continue;
            try {
                desktops.append(state(name));
            } catch (const std::exception &error) {
                desktops.append(QJsonObject{{"name", name}, {"error", QString::fromUtf8(error.what())}});
            }
        }
        return {{"desktops", desktops}, {"workspaces", json(compositor("workspaces", true)).array()}};
    }
    const auto name = binding ? binding->name : params["name"].toString();
    atom(name);
    if (method == "create") {
        if (m_desktops.contains(name))
            fail("Desktop already managed");
        const auto workspace = params["workspace"].toString("name:cornice-agent-" + name + "-ws-1");
        atom(workspace);
        auto output = params["output"].toString();
        const auto geometry = params["virtual-output"].toString(output.isEmpty() ? "1920x1080" : "");
        bool privateOutput = !geometry.isEmpty();
        if (privateOutput) {
            if (!output.isEmpty() ||
                !QRegularExpression("^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$").match(geometry).hasMatch())
                fail("Expected virtual output dimensions, e.g. 1920x1080");
            const auto dimensions = geometry.split('x');
            if (dimensions[0].toInt() > 8192 || dimensions[1].toInt() > 8192)
                fail("Virtual output dimensions exceed 8192");
            output = "cornice-agent-" + name + "-" + uuid();
            const auto createdOutput = compositor("seat create-private-output " + output);
            if (createdOutput != "ok")
                fail(QString::fromUtf8(createdOutput));
            const auto configured = compositor("eval hl.monitor({output='" + output + "',mode='" + geometry +
                                               "',position='auto',scale=1})");
            if (configured != "ok") {
                compositor("output remove " + output);
                fail(QString::fromUtf8(configured));
            }
        }
        atom(output);
        const auto created = compositor("seat create " + name + " " + output);
        if (created != "ok") {
            if (privateOutput)
                compositor("output remove " + output);
            fail(QString::fromUtf8(created));
        }
        try {
            const auto actual = state(name);
            m_desktops.emplace(name,
                               Desktop{actual["seatId"].toString(), {}, privateOutput ? output : QString{}, {}, {}});
            m_desktops.at(name).number = m_nextDesktopNumber++;
            initializeSlots(name);
            const auto switched = compositor("seat workspace " + name + " " + workspace);
            if (switched != "ok")
                fail(QString::fromUtf8(switched));
            pause(name);
            configureDesktop(name);
            if (params.contains("human-lock-policy")) {
                const auto paused = state(name);
                const auto policy = params["human-lock-policy"].toString();
                atom(policy);
                json(compositor("seat lock-policy " + name + " " + paused["seatId"].toString() + " " +
                                    paused["generation"].toString() + " " + policy,
                                true));
            }
            save();
            startShell(name);
        } catch (...) {
            compositor("seat remove " + name);
            m_desktops.erase(name);
            if (privateOutput)
                compositor("output remove " + output);
            throw;
        }
        return state(name);
    }
    auto &desktop = managed(name);
    if (method == "allow-agent") {
        if (state(name)["humanLocked"].toBool()) fail("Unlock session before changing desktop permission");
        if (!params["allowed"].isBool()) fail("Boolean agent permission required");
        ++desktop.inputDecision;
        desktop.agentAllowed = params["allowed"].toBool();
        if (!desktop.agentAllowed) {
            if (!(m_humanOwner && m_humanBinding.name == name)) pause(name);
            desktop.captureGrant.clear();
            revokeBindings(name);
        }
        save();
        return state(name);
    }
    if (method == "detach") {
        const auto credential = params["bindingToken"].toString();
        if (m_bindings.contains(credential) && m_bindings[credential].name == name &&
            m_bindings[credential].id == params["seatId"].toString() &&
            m_bindings[credential].generation == params["generation"].toString()) {
            const auto current = state(name);
            if (current["seatId"] == params["seatId"] && current["generation"] == params["generation"] &&
                current["controlMode"].toString() == "agent") pause(name);
            revokeBindings(name);
        }
        return state(name);
    }
    if (method == "stop-job") {
        const auto current = state(name);
        if (current["seatId"] == params["seatId"] && current["generation"] == params["generation"] &&
            current["controlMode"].toString() == "agent")
            pause(name);
        return state(name);
    }
    if (method == "view-focus") {
        const auto address = params["address"].toString();
        if (!QRegularExpression("^0x[0-9a-fA-F]+$").match(address).hasMatch())
            fail("Invalid window address");
        const auto reply = compositor("seat focus " + name + " address:" + address);
        if (reply != "ok")
            fail(QString::fromUtf8(reply));
        return state(name);
    }
    if (method == "view-workspace") {
        if (desktop.primary) fail("Primary workspace changes use native workspace controls");
        const auto slot = params["slot"].toInt();
        if (slot < 1 || slot > 10 || state(name)["humanLocked"].toBool())
            fail("Expected workspace 1–10 in unlocked session");
        const auto reply =
            compositor("seat view-workspace " + name + " " + desktop.workspaceSlots.value(slot));
        if (reply != "ok")
            fail(QString::fromUtf8(reply));
        return state(name);
    }
    if (method == "handoff-start" || method == "handoff-complete") {
        if (desktop.handoffs.isEmpty()) fail("No cooperation request on this desktop");
        const auto record = desktop.handoffs.last().toObject();
        const auto requestId = record["id"].toString();
        if (params["requestId"] != record["id"]) fail("Cooperation request changed; refresh before acting");
        if (method == "handoff-start") {
            if (!desktop.primary || m_humanOwner || record["status"] != "requested" || state(name)["humanLocked"].toBool())
                fail("Use native presentation to take over a secondary desktop");
            pause(name);
            transitionHandoff(name, requestId, "in_progress", "Human took control");
        } else {
            if (record["status"] != "in_progress" || (!desktop.primary && (m_humanRequestId != requestId || !m_humanOwner)))
                fail("Take over the requested desktop before completing it");
            transitionHandoff(name, requestId, "completed", "Human marked the task completed");
            if (m_humanRequestId == requestId) endTakeover("Cooperation task completed");
            sealHandoff(name, requestId);
        }
        return state(name);
    }
    if (method == "state" || method == "desktop.state")
        return state(name);
    if (method == "pause") {
        ++desktop.inputDecision;
        pause(name);
        return state(name);
    }
    if (method == "lock-policy") {
        if (desktop.primary) {
            if (params["policy"].toString() != "pause") fail("Primary desktop always pauses on session lock");
            return state(name);
        }
        const auto actual = state(name);
        const auto policy = params["policy"].toString();
        atom(policy);
        return json(compositor("seat lock-policy " + name + " " + desktop.id + " " + actual["generation"].toString() +
                                   " " + policy,
                               true))
            .object();
    }
    if (method == "present") {
        configureDesktop(name);
        if (desktop.primary) fail("Primary desktop already uses the native display");
        if (state("main")["controlMode"].toString() == "agent") pause("main");
        if (m_humanOwner == owner &&
            (m_humanBinding.name != name || params["workspace"].toString("current") != "current"))
            endTakeover("Desktop view changed");
        if (!m_presentations.contains(owner))
            m_presentations[owner] = uuid() + uuid();
        const auto monitors = json(compositor("monitors", true)).array();
        QString output;
        QJsonObject physical;
        for (const auto &value : monitors) {
            const auto monitor = value.toObject();
            if (monitor["name"].toString().startsWith("cornice-agent-"))
                continue;
            if (output.isEmpty() || monitor["focused"].toBool()) {
                output = monitor["name"].toString();
                physical = monitor;
            }
        }
        atom(output);
        if (!desktop.privateOutput.isEmpty() && m_humanOwner != owner)
            perform("fit",
                    QJsonObject{{"name", name},
                                {"width", physical["width"]},
                                {"height", physical["height"]},
                                {"scale", physical["scale"]}},
                    nullptr, owner);
        const auto workspace = params["workspace"].toString("current");
        atom(workspace);
        if (workspace != "current") m_compositor.ensureWorkspace(name, desktop.id, workspace);
        return json(compositor("seat present " + name + " " + desktop.id + " " + output + " " + workspace + " " +
                                   m_presentations[owner],
                               true))
            .object();
    }
    if (method == "present-status") {
        if (!m_presentations.contains(owner))
            return {{"active", false}};
        if (m_humanOwner == owner)
            m_humanHeartbeat.restart();
        return json(compositor("seat presentation " + m_presentations[owner], true)).object();
    }
    if (method == "takeover") {
        const auto requestId = params["requestId"].toString();
        if (!requestId.isEmpty() && (desktop.handoffs.isEmpty() || desktop.handoffs.last().toObject()["id"] != requestId || desktop.handoffs.last().toObject()["status"] != "requested"))
            fail("Cooperation request changed or resolved; refresh before takeover");
        if (!m_presentations.contains(owner))
            fail("Native presentation required before takeover");
        if (m_humanOwner && m_humanOwner != owner)
            fail("Another viewer owns human control");
        if (m_humanOwner == owner)
            return json(compositor("seat presentation " + m_presentations[owner], true)).object();
        pause(name);
        auto result = json(compositor("seat present-control " + m_presentations[owner] + " yes", true)).object();
        const auto actual = state(name);
        m_humanBinding = Binding{name, desktop.id, actual["generation"].toString(), {}, {}};
        m_humanOwner = owner;
        m_humanHeartbeat.start();
        if (!desktop.handoffs.isEmpty()) {
            const auto record = desktop.handoffs.last().toObject();
            if (record["status"] == "requested") {
                m_humanRequestId = record["id"].toString();
                transitionHandoff(name, m_humanRequestId, "in_progress", "Human took control");
            }
        }
        return result;
    }
    if (method == "release") {
        if (m_humanOwner != owner)
            fail("This viewer does not own human control");
        endTakeover("Human control ended");
        return json(compositor("seat presentation " + m_presentations[owner], true)).object();
    }
    if (method == "fit") {
        if (desktop.privateOutput.isEmpty())
            return {{"adapted", false}, {"reason", "Shared output retains its geometry"}};
        if (m_humanOwner && m_humanBinding.name == name)
            fail("End human control before resizing the desktop");
        const int width = params["width"].toInt(), height = params["height"].toInt();
        const double scale = params["scale"].toDouble();
        if (width < 320 || height < 240 || width > 8192 || height > 8192 || scale < 1 || scale > 4)
            fail("Invalid viewer geometry");
        const auto actual = state(name);
        if (actual["output"].toString() != desktop.privateOutput)
            fail("Private desktop output changed");
        const auto pixels = actual["pixelSize"].toArray();
        if (pixels[0].toInt() != width || pixels[1].toInt() != height || actual["scale"].toDouble() != scale) {
            atom(desktop.privateOutput);
            const auto result =
                compositor("eval hl.monitor({output='" + desktop.privateOutput + "',mode='" + QString::number(width) +
                           "x" + QString::number(height) + "',position='auto',scale=" + QString::number(scale) + "})");
            if (result != "ok")
                fail(QString::fromUtf8(result));
        }
        return {{"adapted", true}};
    }
    bool humanLaunch = false;
    if ((method == "launch" || method == "desktop.launch") && params.contains("humanSeatId")) {
        const auto actual = state(name);
        humanLaunch = !binding && m_humanOwner && m_humanBinding.name == name &&
            params["humanSeatId"].toString() == desktop.id && params["humanGeneration"].toString() == m_humanBinding.generation &&
            actual["generation"].toString() == m_humanBinding.generation && actual["controlMode"] == "human";
        if (!humanLaunch) fail("Human launch requires current takeover seat and generation");
    }
    if (m_humanOwner && m_humanBinding.name == name && (method == "resume" || method == "bind" || (method == "launch" && !humanLaunch)))
        fail("End human control before granting agent input");
    if (method == "resume") {
        ++desktop.inputDecision;
        resume(name);
        return state(name);
    }
    if (method == "remove") {
        if (desktop.primary) fail("The primary desktop cannot be removed");
        pause(name);
        const auto reply = compositor("seat remove " + name);
        if (reply != "ok")
            fail(QString::fromUtf8(reply));
        const auto privateOutput = desktop.privateOutput;
        revokeBindings(name);
        m_desktops.erase(name);
        if (!privateOutput.isEmpty())
            compositor("output remove " + privateOutput);
        save();
        return {{"removed", name}, {"sharedWindowsPreserved", true}};
    }
    if (method == "bind") {
        if (!desktop.agentAllowed) fail("Agent control is disabled for this desktop");
        const auto actual = state(name);
        if (actual["humanLocked"].toBool() || actual["paused"].toBool() || !actual["available"].toBool() ||
            !desktop.driver)
            fail("Resume desktop before binding an agent");
        revokeBindings(name);
        const auto token = uuid() + uuid();
        m_bindings[token] = Binding{name, desktop.id, actual["generation"].toString(), {}};
        return {{"socket", m_socketPath},
                {"instance", m_instance},
                {"name", name},
                {"seatId", desktop.id},
                {"generation", actual["generation"]},
                {"token", token}};
    }
    if (method == "frame" || method == "capture" || method == "desktop.capture") {
        const auto workspace = method == "frame" ? params["workspace"].toString("current") : QString("current");
        auto result = capture(name, desktop.id, workspace, owner, method == "frame" ? "argb" : params["encoding"].toString("png"),
                              method == "desktop.capture");
        if (binding) {
            if (binding->frameOrder.size() >= 16)
                binding->frames.remove(binding->frameOrder.takeFirst());
            auto metadata = result;
            metadata.remove("pngBase64");
            metadata.remove("imageBase64");
            const auto frame = result["frameId"].toString();
            binding->frames[frame] = metadata;
            binding->frameOrder.append(frame);
        }
        return result;
    }
    if (method == "desktop.browser") {
        const auto actual = state(name);
        if (!binding || actual["paused"].toBool() || !actual["available"].toBool())
            fail("Browser requires an active agent binding");
        ensureBrowser(name, params["executable"].toString());
        QString token;
        for (auto it = m_bindings.begin(); it != m_bindings.end(); ++it)
            if (&it.value() == binding) {
                token = it.key();
                break;
            }
        return {{"cdpUrl", desktop.browser->endpoint(token)}, {"transport", "authorized-proxy-to-pipe"}};
    }
    if (method == "windows" || method == "desktop.windows")
        return {{"windows", json(compositor("seat windows " + name, true)).array()}};
    if (method == "launch" || method == "desktop.launch") {
        const auto actual = state(name);
        if ((!binding && actual["humanLocked"].toBool()) || (actual["paused"].toBool() && !humanLaunch) || !actual["available"].toBool())
            fail("Desktop writes paused");
        const auto argv = params["argv"].toArray();
        if (argv.isEmpty() || argv.size() > 128)
            fail("Application argv required");
        QStringList args;
        for (const auto &arg : argv) {
            if (!arg.isString() || arg.toString().contains(QChar(0)))
                fail("Invalid application argument");
            args.append(arg.toString());
        }
        const auto plan = ApplicationLaunch::prepare(args, name, desktop.primary);
        if (plan.backend == "chromium") {
            const bool starting = !desktop.browser || !desktop.browser->running();
            ensureBrowser(name, args.first(), args.mid(1));
            if (starting) return {{"pid", desktop.browser->pid()}, {"seatId", desktop.id}};
        }
        args = QStringList{plan.program} + plan.arguments;
        QProcess process;
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.remove("WAYLAND_SOCKET");
        environment.remove("DISPLAY");
        environment.insert("WAYLAND_DISPLAY", actual["display"].toString());
        environment.insert("HYPRLAND_INSTANCE_SIGNATURE", m_instance);
        plan.applyEnvironment(environment);
        const auto localBin = QDir::homePath() + "/.local/bin";
        environment.insert("PATH", localBin + ":" + environment.value("PATH"));
        process.setStandardOutputFile(m_directory + "/" + name + "-launch.log", QIODevice::Append);
        process.setStandardErrorFile(m_directory + "/" + name + "-launch.log", QIODevice::Append);
        process.setProcessEnvironment(environment);
        process.setProgram(args.takeFirst());
        process.setArguments(args);
        qint64 pid = 0;
        if (!process.startDetached(&pid))
            fail("Application launch failed");
        return {{"pid", pid}, {"seatId", desktop.id}};
    }
    if (method == "desktop.release") { pause(name); return state(name); }
    if (method == "desktop.workspace" || method == "desktop.focus") {
        auto value = params[method == "desktop.workspace" ? "workspace" : "windowId"].toString();
        if (method == "desktop.workspace" && params.contains("slot")) {
            const int slot = params["slot"].toInt();
            if (slot < 1 || slot > 10) fail("Workspace slot must be 1–10");
            value = desktop.primary ? QString::number(slot) : desktop.workspaceSlots.value(slot);
        }
        atom(value);
        const auto reply = compositor("seat act " + name + " " + desktop.id + " " + binding->generation + " " +
                                      (method == "desktop.workspace" ? "workspace " : "focus ") + value);
        if (reply != "ok")
            fail(QString::fromUtf8(reply));
        return state(name);
    }
    if (method == "desktop.input") {
        const auto actual = state(name);
        validateFrame(*binding, params["frameId"].toString(), actual);
        if (!desktop.driver)
            fail("Seat driver unavailable; resume explicitly");
        const auto pixels = actual["pixelSize"].toArray();
        desktop.driver->input(params, pixels[0].toInt(), pixels[1].toInt());
        return {{"processed", true}, {"seatId", desktop.id}, {"generation", binding->generation}};
    }
    fail("Unknown desktop method");
    return {};
}

void Broker::ensureBrowser(const QString &name, const QString &program, const QStringList &arguments) {
    auto &desktop = managed(name);
    const auto plan = ApplicationLaunch::browser(name, desktop.primary, program, arguments);
    if (desktop.browser && !desktop.browser->running()) desktop.browser.reset();
    if (desktop.browser) {
        if (desktop.browserPolicy != plan.policy)
            fail("Managed browser configuration changed; close this desktop's browser before relaunching");
        return;
    }
    const auto actual = state(name);
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.remove("WAYLAND_SOCKET");
    environment.remove("DISPLAY");
    environment.insert("WAYLAND_DISPLAY", actual["display"].toString());
    environment.insert("HYPRLAND_INSTANCE_SIGNATURE", m_instance);
    plan.applyEnvironment(environment);
    const auto localBin = QDir::homePath() + "/.local/bin";
    environment.insert("PATH", localBin + ":" + environment.value("PATH"));
    auto args = plan.arguments;
    if (arguments.isEmpty()) args.append("about:blank");
    desktop.browserPolicy = plan.policy;
    desktop.browser = std::make_unique<BrowserSession>(plan.program, args, environment,
        m_directory + "/browser-" + name + ".log", [this, name](const QString &token) {
            if (!m_bindings.contains(token)) return false;
            const auto &credential = m_bindings[token];
            if (credential.name != name) return false;
            const auto current = state(name);
            return current["seatId"].toString() == credential.id && current["generation"].toString() == credential.generation &&
                !current["paused"].toBool() && current["available"].toBool() && managed(name).agentAllowed &&
                !(m_humanOwner && m_humanBinding.name == name);
        });
}

void Broker::initializeSlots(const QString &name, const QJsonObject &saved) {
    auto &desktop = m_desktops.at(name);
    desktop.configurationOwner = uuid() + uuid();
    for (int i = 1; i <= 10; ++i) {
        const auto value = saved[QString::number(i)].toString("name:cornice-agent-" + name + "-ws-" + QString::number(i));
        atom(value);
        desktop.workspaceSlots[i] = value;
    }
}

void Broker::configureDesktop(const QString &name) {
    auto &desktop = m_desktops.at(name);
    const auto actual = state(name);
    if (actual["seatId"].toString() != desktop.id) fail("Stale configuration target");
    if (actual["humanLocked"].toBool()) {
        if (!desktop.lastConfiguration.isEmpty()) m_compositor.renew(desktop.configurationOwner);
        return;
    }
    QJsonArray bindings;
    auto add = [&](const QStringList &keys, const QString &action, const QString &argument, bool readonly, bool release = false) {
        bindings.append(QJsonObject{{"keys", QJsonArray::fromStringList(keys)}, {"action", action},
            {"argument", argument}, {"release", release}, {"viewOnly", readonly}, {"overrideInherited", true}});
    };
    if (!desktop.primary) for (int i = 1; i <= 10; ++i) {
        const auto workspace = desktop.workspaceSlots.value(i);
        if (desktop.lastConfiguration.isEmpty()) m_compositor.ensureWorkspace(name, desktop.id, workspace);
        const auto key = QString::number(i % 10);
        add({"SUPER", key}, "workspace", workspace, false);
        add({"SUPER", "SHIFT", key}, "move", workspace, false);
        add({"SUPER", key}, "workspace", workspace, true);
    }
    QJsonArray overlays;
    const QStringList shellLayers{"cornice-bar", "cornice-desktop-menu", "cornice-panel",
                                  "cornice-menu", "cornice-screenshot", "cornice-screenshot-notice", "cornice-status-tooltip", "cornice-window-tooltip", "cornice-notification-popups"};
    QSet<qint64> shellPids;
    const auto outputs = json(compositor("layers", true)).object();
    for (auto output = outputs.begin(); output != outputs.end(); ++output) {
        const auto levels = output.value().toObject()["levels"].toObject();
        for (auto level = levels.begin(); level != levels.end(); ++level)
            for (const auto &value : level.value().toArray()) {
                const auto layer = value.toObject();
                const auto space = layer["namespace"].toString();
                if (!shellLayers.contains(space)) continue;
                if (layer["pid"].toInteger() <= 0) continue;
                shellPids.insert(layer["pid"].toInteger());
            }
    }
    // The popup shares its shell process with the bar but is created on demand.
    // Register its route before it appears, so its first pointer event is native.
    for (const auto pid : shellPids)
        for (const auto &space : shellLayers)
            overlays.append(QJsonObject{{"name", space}, {"pid", pid},
                {"keyboard", space == "cornice-panel" || space == "cornice-menu" || space == "cornice-screenshot"},
                {"localInView", space == "cornice-bar" || space == "cornice-desktop-menu" || space == "cornice-screenshot" || space == "cornice-screenshot-notice"}});
    for (const auto &routes : m_localOverlays)
        for (const auto &route : routes) overlays.append(route);
    const QJsonObject configuration{{"owner", desktop.configurationOwner}, {"seatName", name}, {"seatId", desktop.id},
        {"bindings", bindings}, {"overlays", overlays}};
    if (configuration == desktop.lastConfiguration) {
        try { m_compositor.renew(desktop.configurationOwner); return; }
        catch (const std::exception &) { /* Reload or expired lease: restore atomically. */ }
    }
    const auto configured = m_compositor.configure(configuration);
    desktop.lastConfiguration = configuration;
    desktop.bindingOverrides = configured["inheritedOverrides"].toArray();
}
