#include "Broker.hpp"
#include <QBuffer>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QTemporaryFile>
#include <QUuid>
#include <stdexcept>
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
      m_directory(QFileInfo(m_socketPath).path()) {
    QDir().mkpath(m_directory);
    QFile::setPermissions(m_directory, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    for (const auto &file : QDir(m_directory).entryList({"frame-*", "shot-*"}, QDir::Files))
        QFile::remove(m_directory + "/" + file);
    const auto caps = json(compositor("seat capabilities", true)).object();
    const auto features = caps["features"].toArray();
    for (const QString name :
         {"seat-input", "seat-identity", "atomic-snapshot", "readonly-workspace", "argb-frame", "input-pause"})
        if (!features.contains(name))
            fail("Required compositor capability missing: " + name);
    if (caps["protocol"].toInt() != 1)
        fail("Unsupported compositor seat protocol");
    QFile file(m_directory + "/desktops.json");
    if (file.open(QIODevice::ReadOnly)) {
        const auto saved = json(file.readAll()).object();
        for (auto it = saved.begin(); it != saved.end(); ++it) {
            try {
                const auto actual = state(it.key());
                if (actual["seatId"].toString() != it.value().toString())
                    continue;
                m_desktops.emplace(it.key(), Desktop{it.value().toString(), {}});
                pause(it.key()); // Crash recovery revokes survivors; no automatic write restoration.
            } catch (...) {
            }
        }
    }
    connect(&m_watchdog, &QTimer::timeout, this, [this] {
        bool invalidateFrames = false;
        for (auto &[name, desktop] : m_desktops) {
            try {
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
            for (auto it = m_buffers.begin(); it != m_buffers.end(); ++it) {
                QFile file(it.value());
                if (file.open(QIODevice::WriteOnly))
                    file.resize(0);
                it.key()->write("{\"event\":\"frame-invalidated\",\"reason\":\"session locked\"}\n");
            }
        }
    });
}

Broker::~Broker() {
    for (auto &[name, desktop] : m_desktops) {
        try {
            pause(name);
        } catch (...) {
        }
    }
    for (const auto &file : m_buffers)
        QFile::remove(file);
    m_server.close();
}

QByteArray Broker::compositor(const QString &command, bool asJson) {
    const auto path = qEnvironmentVariable("XDG_RUNTIME_DIR") + "/hypr/" + m_instance + "/.socket.sock";
    QLocalSocket socket;
    socket.connectToServer(path);
    if (!socket.waitForConnected(1000))
        fail("Bound compositor unavailable");
    socket.write((asJson ? "j/" : "/") + command.toUtf8());
    if (!socket.waitForBytesWritten(1000))
        fail("Compositor write timed out");
    QByteArray answer;
    while (socket.state() == QLocalSocket::ConnectedState) {
        if (socket.bytesAvailable() == 0 && !socket.waitForReadyRead(2000) &&
            socket.state() == QLocalSocket::ConnectedState)
            fail("Compositor response timed out");
        answer += socket.readAll();
        if (answer.size() > 8 * 1024 * 1024)
            fail("Compositor response too large");
    }
    answer += socket.readAll();
    return answer.trimmed();
}

QJsonObject Broker::state(const QString &name) {
    atom(name);
    return json(compositor("seat state " + name, true)).object();
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
    for (const auto &[name, desktop] : m_desktops)
        saved[name] = desktop.id;
    QSaveFile file(m_directory + "/desktops.json");
    if (!file.open(QIODevice::WriteOnly))
        fail("Cannot save desktop lifecycle record");
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    file.write(QJsonDocument(saved).toJson());
    if (!file.commit())
        fail("Cannot commit desktop lifecycle record");
}
void Broker::pause(const QString &name) {
    auto &desktop = managed(name);
    const auto actual = state(name);
    const auto reply =
        compositor("seat control " + name + " " + desktop.id + " " + actual["generation"].toString() + " pause", true);
    json(reply);
    desktop.driver.reset();
}

void Broker::listen() {
    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    // The launcher holds an instance lock before stale socket removal.
    QLocalServer::removeServer(m_socketPath);
    if (!m_server.listen(m_socketPath))
        fail("Cannot listen on desktop socket: " + m_server.errorString());
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
                if (m_buffers.contains(socket))
                    QFile::remove(m_buffers.take(socket));
                delete input;
                socket->deleteLater();
            });
        }
    });
}

QJsonObject Broker::handle(const QJsonObject &request, QLocalSocket *owner) {
    const auto id = request["id"].toString();
    if (id.isEmpty() || id.size() > 128)
        fail("Request ID required");
    const auto method = request["method"].toString();
    const auto token = request["token"].toString();
    const bool writing = method == "desktop.input" || method == "desktop.workspace" || method == "desktop.focus" ||
                         method == "desktop.launch";
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
            fail("Agent binding revoked; obtain a new binding after resynchronization");
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
        if (method == "desktop.input" && binding) {
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
                            const QString &format) {
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
    auto result =
        json(compositor("seat snapshot " + name + " " + id + " " + workspace + " argb " + path, true)).object();
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
        if (!image.save(&buffer, "PNG"))
            fail("Snapshot encoding failed");
        result["pngBase64"] = QString::fromLatin1(png.toBase64());
    }
    return result;
}

void Broker::validateFrame(const Binding &binding, const QString &frame, const QJsonObject &actual) {
    if (!binding.frames.contains(frame))
        fail("Own screenshot frame required before input");
    const auto captured = binding.frames[frame];
    for (const QString field : {"seatId", "generation", "workspace", "windowId", "position", "logicalSize", "pixelSize",
                                "scale", "transform"})
        if (captured[field] != actual[field])
            fail("Screenshot became stale; capture again");
}

QJsonObject Broker::perform(const QString &method, const QJsonObject &params, Binding *binding, QLocalSocket *owner) {
    if (method == "doctor")
        return {{"instance", m_instance}, {"capabilities", json(compositor("seat capabilities", true)).object()}};
    if (method == "list") {
        QJsonArray desktops;
        for (const auto &[name, desktop] : m_desktops) {
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
        const auto workspace = params["workspace"].toString("10"), output = params["output"].toString();
        atom(workspace);
        atom(output);
        const auto created = compositor("seat create " + name + " " + output);
        if (created != "ok")
            fail(QString::fromUtf8(created));
        try {
            const auto actual = state(name);
            m_desktops.emplace(name, Desktop{actual["seatId"].toString(), {}});
            const auto switched = compositor("seat workspace " + name + " " + workspace);
            if (switched != "ok")
                fail(QString::fromUtf8(switched));
            pause(name);
            save();
        } catch (...) {
            compositor("seat remove " + name);
            m_desktops.erase(name);
            throw;
        }
        return state(name);
    }
    auto &desktop = managed(name);
    if (method == "state" || method == "desktop.state")
        return state(name);
    if (method == "pause") {
        pause(name);
        return state(name);
    }
    if (method == "resume") {
        desktop.driver.reset();
        const auto actual = state(name);
        // Require a fresh view before granting input. Resume revokes all previous devices.
        capture(name, desktop.id, "current", owner, "png");
        json(compositor("seat control " + name + " " + desktop.id + " " + actual["generation"].toString() + " resume",
                        true));
        const auto resumed = state(name);
        try {
            desktop.driver =
                std::make_unique<SeatDriver>(resumed["display"].toString(), name, resumed["output"].toString());
        } catch (...) {
            pause(name);
            throw;
        }
        return state(name);
    }
    if (method == "remove") {
        pause(name);
        const auto reply = compositor("seat remove " + name);
        if (reply != "ok")
            fail(QString::fromUtf8(reply));
        m_desktops.erase(name);
        save();
        return {{"removed", name}, {"sharedWindowsPreserved", true}};
    }
    if (method == "bind") {
        const auto actual = state(name);
        if (actual["paused"].toBool() || !actual["available"].toBool() || !desktop.driver)
            fail("Resume desktop before binding an agent");
        for (auto it = m_bindings.begin(); it != m_bindings.end();) {
            if (it.value().name != name) {
                ++it;
                continue;
            }
            const auto prefix = it.key() + ":";
            for (auto done = m_completed.begin(); done != m_completed.end();) {
                if (!done.key().startsWith(prefix)) {
                    ++done;
                    continue;
                }
                m_requestHashes.remove(done.key());
                done = m_completed.erase(done);
            }
            it = m_bindings.erase(it);
        }
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
        auto result = capture(name, desktop.id, workspace, owner, method == "frame" ? "argb" : "png");
        if (binding) {
            if (binding->frameOrder.size() >= 16)
                binding->frames.remove(binding->frameOrder.takeFirst());
            auto metadata = result;
            metadata.remove("pngBase64");
            const auto frame = result["frameId"].toString();
            binding->frames[frame] = metadata;
            binding->frameOrder.append(frame);
        }
        return result;
    }
    if (method == "windows" || method == "desktop.windows")
        return {{"windows", json(compositor("seat windows " + name, true)).array()}};
    if (method == "launch" || method == "desktop.launch") {
        const auto actual = state(name);
        if (actual["paused"].toBool() || !actual["available"].toBool())
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
                if (arg.startsWith("--user-data-dir") || arg == "-profile" || arg == "--profile" ||
                    arg.startsWith("--profile="))
                    fail("Browser profile is managed per desktop; omit profile overrides");
            }
            const auto profile = m_directory + "/profiles/" + name + "/" + desktop.id;
            QDir().mkpath(profile);
            if (chromium)
                args.insert(1, "--user-data-dir=" + profile);
            else {
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
    if (method == "desktop.workspace" || method == "desktop.focus") {
        const auto value = params[method == "desktop.workspace" ? "workspace" : "windowId"].toString();
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
