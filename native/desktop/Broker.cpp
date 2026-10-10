#include "Broker.hpp"
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
    QFile file(m_directory + "/desktops.json");
    if (file.open(QIODevice::ReadOnly)) {
        const auto saved = json(file.readAll()).object();
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
    main.primary = true; main.number = 1; main.agentAllowed = false;
    main.configurationOwner = uuid() + uuid();
    pause("main");
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
    QJsonArray workspaceSlots;
    const auto workspace = result["workspace"].toString().remove("name:");
    for (int i = 1; i <= 10; ++i) {
        const auto value = primary ? QString::number(i) : m_desktops.contains(name) ? m_desktops.at(name).workspaceSlots.value(i) : QString{};
        workspaceSlots.append(QJsonObject{{"id", i}, {"name", value}, {"active", workspace == QString(value).remove("name:")}});
    }
    if (m_desktops.contains(name)) {
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
                                  {"agentAllowed", desktop.agentAllowed}, {"number", desktop.number}, {"workspaceSlots", workspaceMap}};
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
                    try {
                        reply = handle(json(line).object(), socket);
                    } catch (const std::exception &error) {
                        reply = {{"ok", false}, {"error", QString::fromUtf8(error.what())}};
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
                m_localVoiceClients.remove(socket);
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
        it = m_bindings.erase(it);
    }
}

void Broker::releaseAcquisition(QLocalSocket *owner) {
    if (!m_acquisitions.contains(owner)) return;
    const auto lease = m_acquisitions.take(owner);
    const auto token = lease["token"].toString();
    if (!m_bindings.contains(token)) return;
    m_bindings.remove(token);
    try {
        const auto actual = state(lease["name"].toString());
        if (actual["seatId"] == lease["seatId"] && actual["generation"] == lease["generation"] &&
            actual["controlMode"].toString() == "agent") pause(lease["name"].toString());
    } catch (...) {}
}

QJsonObject Broker::acquireDesktop(const QJsonObject &params, QLocalSocket *owner) {
    if (m_acquisitions.contains(owner)) return m_acquisitions[owner];
    const auto controller = params["controller"].toString();
    if (!QRegularExpression("^[A-Za-z0-9_-]{1,64}$").match(controller).hasMatch()) fail("Invalid controller identity");
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
        binding.heartbeat.start();
        lease["created"] = created;
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
    if (method == "register-local-voice") {
        if (!request["token"].toString().isEmpty() || !owner) fail("Local service connection required");
        struct ucred peer{}; socklen_t size = sizeof(peer);
        if (getsockopt(owner->socketDescriptor(), SOL_SOCKET, SO_PEERCRED, &peer, &size) || peer.uid != getuid() || peer.pid <= 0)
            fail("Local service identity unavailable");
        m_localVoiceClients[owner] = peer.pid;
        for (const auto &[name, desktop] : m_desktops) configureDesktop(name);
        return {{"ok", true}, {"registered", true}};
    }

    if (method == "acquire-desktop") {
        if (!request["token"].toString().isEmpty() || !owner) fail("Local allocation connection required");
        return {{"ok", true}, {"id", id}, {"result", acquireDesktop(request["params"].toObject(), owner)}};
    }

    const auto token = request["token"].toString();
    const bool writing = method == "desktop.input" || method == "desktop.workspace" || method == "desktop.focus" ||
                         method == "desktop.launch" || method == "desktop.browser";
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
            binding->heartbeat.restart();
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
    if (method == "controller-action") {
        invokeControllerAction(params);
        return {{"processed", true}};
    }

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
    if (method == "state" || method == "desktop.state")
        return state(name);
    if (method == "pause") {
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
    if (m_humanOwner && m_humanBinding.name == name && (method == "resume" || method == "bind" || method == "launch"))
        fail("End human control before granting agent input");
    if (method == "resume") {
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
        if (desktop.browser && !desktop.browser->running())
            desktop.browser.reset();
        if (!desktop.browser) {
            auto environment = QProcessEnvironment::systemEnvironment();
            environment.remove("WAYLAND_SOCKET");
            environment.remove("DISPLAY");
            environment.insert("WAYLAND_DISPLAY", actual["display"].toString());
            environment.insert("HYPRLAND_INSTANCE_SIGNATURE", m_instance);
            const auto profile = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) +
                                 "/cornice/desktops/" + name + "/chrome";
            QDir().mkpath(profile);
            desktop.browser = std::make_unique<BrowserSession>(
                params["executable"].toString(QStandardPaths::findExecutable("google-chrome-stable").isEmpty()
                                                  ? QStandardPaths::findExecutable("chromium")
                                                  : QStandardPaths::findExecutable("google-chrome-stable")),
                QStringList{"--user-data-dir=" + profile, "--ozone-platform=wayland", "--no-first-run",
                            "--no-default-browser-check", "about:blank"},
                environment, m_directory + "/browser-" + name + ".log", [this, name](const QString &token) {
                    if (!m_bindings.contains(token))
                        return false;
                    const auto &credential = m_bindings[token];
                    if (credential.name != name)
                        return false;
                    const auto current = state(name);
                    return current["seatId"].toString() == credential.id &&
                           current["generation"].toString() == credential.generation && !current["paused"].toBool() &&
                           current["available"].toBool() && managed(name).agentAllowed &&
                           !(m_humanOwner && m_humanBinding.name == name);
                });
        }
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
        if ((!binding && actual["humanLocked"].toBool()) || actual["paused"].toBool() || !actual["available"].toBool())
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
        const auto executable = QFileInfo(args.first()).fileName();
        const bool chromium =
            executable == "chromium" || executable == "google-chrome" || executable == "google-chrome-stable";
        const bool firefox = executable == "firefox";
        if (chromium || firefox) {
            for (const auto &arg : args) {
                if (arg.startsWith("--remote-debugging"))
                    fail("Use desktop.browser for authorized CDP; raw debug endpoints "
                         "are disabled");
                if (arg.startsWith("--user-data-dir") || arg == "-profile" || arg == "--profile" ||
                    arg.startsWith("--profile="))
                    fail("Browser profile is managed per desktop; omit profile overrides");
            }
            const auto profile = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) +
                                 "/cornice/desktops/" + name + (chromium ? "/chrome" : "/firefox");
            QDir().mkpath(profile);
            if (chromium) {
                args.insert(1, "--user-data-dir=" + profile);
                args.insert(2, "--ozone-platform=wayland");
            } else {
                args.insert(1, "--no-remote");
                args.insert(2, "--profile");
                args.insert(3, profile);
            }
        }
        QProcess process;
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.remove("WAYLAND_SOCKET");
        environment.remove("DISPLAY");
        environment.insert("WAYLAND_DISPLAY", actual["display"].toString());
        environment.insert("HYPRLAND_INSTANCE_SIGNATURE", m_instance);
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
            {"argument", argument}, {"physicalOnly", argument.startsWith("voice-")}, {"release", release}, {"viewOnly", readonly}, {"overrideInherited", true}});
    };
    if (!desktop.primary) for (int i = 1; i <= 10; ++i) {
        const auto workspace = desktop.workspaceSlots.value(i);
        if (desktop.lastConfiguration.isEmpty()) m_compositor.ensureWorkspace(name, desktop.id, workspace);
        const auto key = QString::number(i % 10);
        add({"SUPER", key}, "workspace", workspace, false);
        add({"SUPER", "SHIFT", key}, "move", workspace, false);
        add({"SUPER", key}, "workspace", workspace, true);
    }
    if (!desktop.primary) {
        add({"SUPER", "A"}, "notify", "prompt", false);
        add({"SUPER", "A"}, "notify", "prompt", true);
    }
    if (!desktop.primary && !m_localVoiceClients.isEmpty()) for (bool readonly : {false, true}) {
        add({"F8"}, "notify", "voice-press", readonly);
        add({"F8"}, "notify", "voice-release", readonly, true);
        add({"F9"}, "notify", "voice-command", readonly);
        add({"F9"}, "notify", "voice-stop", readonly, true);
        add({"SUPER", "ALT", "Return"}, "notify", "voice-commit", readonly);
        add({"SUPER", "ALT", "O"}, "notify", "voice-raw", readonly);
        add({"SUPER", "ALT", "Escape"}, "notify", "voice-cancel", readonly);
    }
    QJsonArray overlays;
    const QStringList shellLayers{"cornice-bar", "cornice-desktop-menu", "cornice-agent-prompt", "cornice-panel",
                                  "cornice-menu", "cornice-status-tooltip", "cornice-window-tooltip", "cornice-notification-popups"};
    QSet<qint64> shellPids, voicePids;
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
                {"keyboard", space == "cornice-agent-prompt" || space == "cornice-panel" || space == "cornice-menu"},
                {"localInView", space == "cornice-bar" || space == "cornice-desktop-menu"}});
    for (const auto pid : m_localVoiceClients) voicePids.insert(pid);
    for (const auto pid : voicePids)
        overlays.append(QJsonObject{{"name", "hyprvoice"}, {"pid", pid}, {"keyboard", false}});
    const QJsonObject configuration{{"owner", desktop.configurationOwner}, {"seatName", name}, {"seatId", desktop.id},
        {"bindings", bindings}, {"overlays", overlays}, {"callback", m_socketPath}};
    if (configuration == desktop.lastConfiguration) {
        try { m_compositor.renew(desktop.configurationOwner); return; }
        catch (const std::exception &) { /* Reload or expired lease: restore atomically. */ }
    }
    const auto configured = m_compositor.configure(configuration);
    desktop.lastConfiguration = configuration;
    desktop.bindingOverrides = configured["inheritedOverrides"].toArray();
}

void Broker::invokeControllerAction(const QJsonObject &event) {
    const auto name = event["seat"].toString();
    if (!m_desktops.contains(name)) return;
    const auto &desktop = m_desktops.at(name);
    const auto actual = state(name);
    const auto action = event["action"].toString();
    const bool voice = action.startsWith("voice-") && QStringList{"press", "release", "command", "stop", "commit", "raw", "cancel"}.contains(action.mid(6));
    if (event["owner"].toString() != desktop.configurationOwner || event["seatId"].toString() != desktop.id ||
        event["generation"] != actual["generation"] || actual["humanLocked"].toBool() || (action != "prompt" && !voice)) return;
    if (event["mode"].toString() == "readonly") {
        const auto owner = event["viewOwner"].toString();
        if (owner.isEmpty() || !m_presentations.values().contains(owner)) return;
        const auto view = json(compositor("seat presentation " + owner, true)).object();
        if (view["name"].toString() != name || !view["active"].toBool() || view["humanControl"].toBool()) return;
    }
    const auto actionId = event["actionId"].toString();
    if (actionId.isEmpty()) return;
    const auto validation = json(compositor("seat validate-context " + actionId + " " + desktop.configurationOwner, true)).object();
    if (!validation["valid"].toBool() || validation["seatId"].toString() != desktop.id) return;
    if (voice) {
        QProcess process;
        const auto bundled = qEnvironmentVariable("CORNICE_PATH") + "/bin/hyprvoice";
        const auto binary = QFileInfo(bundled).isExecutable() ? bundled : QStandardPaths::findExecutable("hyprvoice");
        if (binary.isEmpty()) return;
        process.start(binary, {action.mid(6)});
        if (!process.waitForFinished(1500)) process.kill();
        return;
    }
    QProcess process;
    auto environment = QProcessEnvironment::systemEnvironment();
    if (event["mode"].toString() == "readonly" || desktop.privateOutput.isEmpty()) {
        environment.remove("CORNICE_DESKTOP_NAME");
        environment.remove("CORNICE_SHELL_SOCKET");
    } else environment.insert("CORNICE_DESKTOP_NAME", name);
    process.setProcessEnvironment(environment);
    process.setProgram(qEnvironmentVariable("CORNICE_PATH") + "/bin/cornice");
    process.setArguments({"ipc", "desktop", "prompt", name});
    process.startDetached();
}
