#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonDocument>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QPointer>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSet>
#include <QSocketNotifier>
#include <QTimer>
#include <cerrno>
#include <csignal>
#include <memory>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <deque>
#include <stdexcept>

// This process owns application lifetime, not desktop control authorization.
// Only the current Broker attachment exposes CDP, through its seat-checked proxy.
// It retains the debug pipe across Broker replacement and dies with the compositor.
class Runtime : public QObject {
    struct Write { QByteArray bytes; qsizetype sent = 0; QString cleanupSession; bool autoAttachReset = false; };
    struct Request { QPointer<QLocalSocket> owner; QJsonValue id; };
    QProcess browser;
    QLocalServer server;
    QLocalSocket compositor;
    QPointer<QLocalSocket> owner;
    QMap<qint64, Request> requests;
    QSet<QString> sessions, cleanupSessions;
    QJsonObject version, launchEnvironment;
    QString startupNonce;
    QString policy;
    QByteArray input;
    std::deque<Write> outgoing;
    qsizetype queued = 0;
    qint64 sequence = 0, versionId = 0;
    int readFd = -1, writeFd = -1;
    std::unique_ptr<QSocketNotifier> reader, writer;
    bool stopping = false, controlUnavailable = false, cleanupAutoAttach = false;

    static void fail(const QString &message) { throw std::runtime_error(message.toStdString()); }
    void queueCleanup() {
        while (cleanupAutoAttach || !cleanupSessions.isEmpty()) {
            const auto session = cleanupAutoAttach ? QString{} : *cleanupSessions.constBegin();
            QJsonObject message{{"id", sequence + 1}, {"method", cleanupAutoAttach ? "Target.setAutoAttach" : "Target.detachFromTarget"}};
            message["params"] = cleanupAutoAttach ? QJsonObject{{"autoAttach", false}, {"waitForDebuggerOnStart", false}, {"flatten", true}} : QJsonObject{{"sessionId", session}};
            auto bytes = QJsonDocument(message).toJson(QJsonDocument::Compact); bytes.append('\0');
            if (bytes.size() > 8 * 1024 * 1024) fail("Browser control cleanup is too large");
            if (queued + bytes.size() > 8 * 1024 * 1024) return;
            ++sequence; queued += bytes.size();
            outgoing.push_back({std::move(bytes), 0, session, cleanupAutoAttach});
            if (cleanupAutoAttach) cleanupAutoAttach = false;
            else cleanupSessions.remove(session);
        }
    }
    void disableControl() {
        // Losing debug transport is a control failure, not permission to close
        // the application. Preserve it until explicit close or compositor exit.
        controlUnavailable = true;
        if (reader) reader->setEnabled(false);
        if (writer) writer->setEnabled(false);
        requests.clear(); outgoing.clear(); queued = 0;
        sessions.clear(); cleanupSessions.clear(); cleanupAutoAttach = false;
        auto previous = owner; owner = nullptr;
        if (previous) previous->abort();
        qWarning("Browser runtime: control transport unavailable; application preserved");
    }
    void write(QJsonObject message) {
        if (controlUnavailable) fail("Browser control transport unavailable");
        if (cleanupAutoAttach || !cleanupSessions.isEmpty()) {
            flush();
            if (cleanupAutoAttach || !cleanupSessions.isEmpty())
                fail("Browser control cleanup is pending; command not sent");
        }
        auto bytes = QJsonDocument(message).toJson(QJsonDocument::Compact); bytes.append('\0');
        if (queued + bytes.size() > 8 * 1024 * 1024) fail("Browser command queue is full");
        queued += bytes.size(); outgoing.push_back({bytes}); flush();
    }
    void flush() {
        while (true) {
            queueCleanup();
            if (outgoing.empty()) break;
            auto &next = outgoing.front();
            auto count = ::write(writeFd, next.bytes.constData() + next.sent, next.bytes.size() - next.sent);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { if (writer) writer->setEnabled(true); return; }
            if (count <= 0) fail("Browser pipe write failed");
            next.sent += count;
            if (next.sent == next.bytes.size()) { queued -= next.bytes.size(); outgoing.pop_front(); }
        }
        if (writer) writer->setEnabled(false);
    }
    void deliver(QLocalSocket *socket, QJsonObject message) {
        if (!socket || socket->state() != QLocalSocket::ConnectedState) return;
        if (socket->bytesToWrite() > 8 * 1024 * 1024) { socket->abort(); return; }
        auto bytes = QJsonDocument(message).toJson(QJsonDocument::Compact); bytes.append('\0');
        socket->write(bytes);
    }
    void receive() {
        char buffer[65536];
        while (true) {
            auto count = ::read(readFd, buffer, sizeof buffer);
            if (count > 0) { input.append(buffer, count); if (input.size() > 64 * 1024 * 1024) fail("Browser response too large"); }
            else if (count < 0 && errno == EINTR) continue;
            else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            else fail("Browser pipe closed");
        }
        while (input.contains('\0')) {
            auto frame = input.left(input.indexOf('\0')); input.remove(0, frame.size() + 1);
            const auto message = QJsonDocument::fromJson(frame).object();
            if (message.contains("id")) {
                const auto id = message["id"].toVariant().toLongLong();
                if (id == versionId) version = message["result"].toObject();
                const auto request = requests.take(id);
                if (request.owner && request.owner == owner) {
                    auto result = message; result["id"] = request.id;
                    const auto session = message["result"].toObject()["sessionId"].toString();
                    if (!session.isEmpty()) sessions.insert(session);
                    deliver(owner, result);
                }
            } else if (owner) {
                const auto session = message["params"].toObject()["sessionId"].toString();
                if (!session.isEmpty() && message["method"] == "Target.attachedToTarget") sessions.insert(session);
                deliver(owner, message);
            }
        }
    }
    void detach() {
        owner = nullptr; requests.clear();
        if (stopping || controlUnavailable) {
            outgoing.clear(); queued = 0;
            cleanupSessions.clear(); cleanupAutoAttach = false;
            if (writer) writer->setEnabled(false);
            return;
        }
        // Requeue wholly unsent cleanup and deduplicate it. Only the submitted
        // pipe prefix must finish exactly once; unsent user commands are dropped.
        for (const auto &entry : outgoing) {
            if (entry.sent) continue;
            if (!entry.cleanupSession.isEmpty()) cleanupSessions.insert(entry.cleanupSession);
            if (entry.autoAttachReset) cleanupAutoAttach = true;
        }
        if (!outgoing.empty() && outgoing.front().sent) {
            auto submitted = std::move(outgoing.front());
            outgoing.clear(); queued = submitted.bytes.size();
            outgoing.push_back(std::move(submitted));
            qWarning("Browser runtime: submitted command outcome unconfirmed after control detached");
        } else { outgoing.clear(); queued = 0; }
        cleanupAutoAttach = true;
        cleanupSessions.unite(sessions); sessions.clear();
        // Queue capacity simply defers cleanup until the pipe drains. A failure
        // here can revoke control, but cannot implicitly terminate the browser.
        try { flush(); } catch (...) { disableControl(); }
    }
    void shutdown() {
        if (stopping) return;
        stopping = true;
        if (owner) owner->abort();
        browser.terminate();
        if (!browser.waitForFinished(2000)) { browser.kill(); browser.waitForFinished(1000); }
        QCoreApplication::quit();
    }
    void attach(QLocalSocket *socket, QByteArray &pending) {
        while (pending.contains('\0')) {
            auto frame = pending.left(pending.indexOf('\0')); pending.remove(0, frame.size() + 1);
            if (frame.size() > 1024 * 1024) { socket->abort(); return; }
            const auto message = QJsonDocument::fromJson(frame).object();
            // Public CDP cannot become private lifecycle control by adding op.
            if (message.contains("op") && (message.contains("id") || message.contains("method"))) {
                socket->abort(); return;
            }
            if (message["op"] == "shutdown") { deliver(socket, {{"ok", true}}); socket->flush(); shutdown(); return; }
            if (message["op"] == "detach" && owner == socket) {
                detach();
                if (!stopping && !controlUnavailable) owner = socket;
                continue;
            }
            if (message["op"] == "attach") {
                if (controlUnavailable) {
                    deliver(socket, {{"ok", false}, {"error", "Managed browser control transport is unavailable; application preserved"}});
                    socket->disconnectFromServer(); return;
                }
                if (browser.state() != QProcess::Running) {
                    deliver(socket, {{"ok", false}, {"error", "Managed browser has exited"}});
                    socket->flush(); shutdown(); return;
                }
                if (message["policy"].toString() != policy) {
                    deliver(socket, {{"ok", false}, {"error", "Managed browser configuration changed; close this desktop's browser before relaunching"}});
                    socket->disconnectFromServer(); return;
                }
                if (!message["requestedEnvironment"].isObject()) {
                    deliver(socket, {{"ok", false}, {"error", "Invalid managed browser launch environment metadata"}});
                    socket->disconnectFromServer(); return;
                }
                const auto requested = message["requestedEnvironment"].toObject();
                bool matches = true;
                for (auto it = requested.begin(); it != requested.end(); ++it)
                    if (!it.value().isString() || !launchEnvironment.contains(it.key()) ||
                        launchEnvironment.value(it.key()) != it.value()) { matches = false; break; }
                if (!matches) {
                    deliver(socket, {{"ok", false}, {"error", "Managed browser launch environment changed; close this desktop's browser before relaunching"}});
                    socket->disconnectFromServer(); return;
                }
                if (owner && owner != socket && owner->state() == QLocalSocket::ConnectedState) {
                    deliver(socket, {{"ok", false}, {"error", "Managed browser is attached to another live desktop service"}});
                    socket->disconnectFromServer(); return;
                }
                if (owner != socket) {
                    detach();
                    if (stopping || controlUnavailable) {
                        deliver(socket, {{"ok", false}, {"error", "Managed browser control transport is unavailable; application preserved"}});
                        socket->disconnectFromServer(); return;
                    }
                    owner = socket;
                }
                deliver(socket, {{"ok", true}, {"pid", browser.processId()}, {"version", version}, {"launchEnvironment", launchEnvironment}, {"startupNonce", startupNonce}});
                socket->setProperty("attached", true);
            } else if (owner == socket && socket->property("attached").toBool()) {
                if (!message["id"].isDouble() || !message["method"].isString() || requests.size() >= 256) { socket->abort(); return; }
                auto command = message; const auto id = ++sequence;
                requests[id] = {socket, message["id"]}; command["id"] = id;
                try { write(command); } catch (...) { requests.remove(id); socket->abort(); }
            } else { socket->abort(); return; }
        }
    }
public:
    Runtime(const QString &path, const QString &program, QStringList arguments, const QString &log, QString configuration)
        : policy(std::move(configuration)) {
        int commands[2], responses[2];
        if (pipe2(commands, O_CLOEXEC) || pipe2(responses, O_CLOEXEC)) fail("Cannot create browser pipe");
        int childRead = fcntl(commands[0], F_DUPFD_CLOEXEC, 10), childWrite = fcntl(responses[1], F_DUPFD_CLOEXEC, 10);
        close(commands[0]); close(responses[1]); writeFd = commands[1]; readFd = responses[0];
        if (childRead < 0 || childWrite < 0) fail("Cannot map browser pipe");
        auto environment = QProcessEnvironment::systemEnvironment();
        startupNonce = environment.value("CORNICE_BROWSER_STARTUP_NONCE");
        environment.remove("CORNICE_BROWSER_STARTUP_NONCE");
        environment.remove("CORNICE_BROWSER_REQUESTED_ENV");
        environment.remove("CORNICE_BROWSER_POLICY");
        for (const auto &key : environment.keys()) launchEnvironment[key] = environment.value(key);
        browser.setProcessEnvironment(environment);
        browser.setProgram(program); arguments.prepend("--remote-debugging-pipe"); browser.setArguments(arguments);
        browser.setStandardOutputFile(log, QIODevice::Append); browser.setStandardErrorFile(log, QIODevice::Append);
        browser.setChildProcessModifier([childRead, childWrite, write = writeFd, read = readFd] {
            dup2(childRead, 3); dup2(childWrite, 4);
            if (write != 3 && write != 4) close(write);
            if (read != 3 && read != 4) close(read);
            close(childRead); close(childWrite);
        });
        browser.start(); bool started = browser.waitForStarted(2000); close(childRead); close(childWrite);
        if (!started) fail("Cannot start managed browser");
        fcntl(readFd, F_SETFL, fcntl(readFd, F_GETFL) | O_NONBLOCK);
        fcntl(writeFd, F_SETFL, fcntl(writeFd, F_GETFL) | O_NONBLOCK);
        versionId = ++sequence; write({{"id", versionId}, {"method", "Browser.getVersion"}});
        QElapsedTimer deadline; deadline.start();
        while (version.isEmpty() && deadline.elapsed() < 8000) { pollfd fd{readFd, POLLIN, 0}; poll(&fd, 1, 100); receive(); }
        if (version.isEmpty()) fail("Managed browser did not open its debug pipe; close the old browser before starting CDP");
        reader = std::make_unique<QSocketNotifier>(readFd, QSocketNotifier::Read, this);
        writer = std::make_unique<QSocketNotifier>(writeFd, QSocketNotifier::Write, this); writer->setEnabled(false);
        connect(reader.get(), &QSocketNotifier::activated, this, [this] { try { receive(); } catch (...) { disableControl(); } });
        connect(writer.get(), &QSocketNotifier::activated, this, [this] { try { flush(); } catch (...) { disableControl(); } });
        connect(&browser, &QProcess::finished, this, [this] { shutdown(); });
        if (browser.state() != QProcess::Running) fail("Managed browser exited during initialization");
        server.setSocketOptions(QLocalServer::UserAccessOption);
        QLocalServer::removeServer(path);
        if (!server.listen(path)) fail("Cannot listen on browser runtime socket");
        connect(&server, &QLocalServer::newConnection, this, [this] {
            while (auto *socket = server.nextPendingConnection()) {
                auto pending = std::make_shared<QByteArray>();
                connect(socket, &QLocalSocket::readyRead, this, [this, socket, pending] {
                    pending->append(socket->readAll());
                    if (pending->size() > 2 * 1024 * 1024) { socket->abort(); return; }
                    attach(socket, *pending);
                });
                connect(socket, &QLocalSocket::disconnected, this, [this, socket] { if (owner == socket) detach(); socket->deleteLater(); });
                QTimer::singleShot(3000, socket, [socket] { if (!socket->property("attached").toBool()) socket->abort(); });
            }
        });
        const auto instance = qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
        compositor.connectToServer(qEnvironmentVariable("XDG_RUNTIME_DIR") + "/hypr/" + instance + "/.socket2.sock");
        if (!compositor.waitForConnected(2000)) fail("Compositor unavailable for browser runtime");
        connect(&compositor, &QLocalSocket::disconnected, this, [this] { shutdown(); });
        connect(&compositor, &QLocalSocket::readyRead, this, [this] { compositor.readAll(); });
    }
    ~Runtime() override {
        shutdown();
        QObject::disconnect(&browser, nullptr, this, nullptr);
        QObject::disconnect(&compositor, nullptr, this, nullptr);
        QObject::disconnect(&server, nullptr, this, nullptr);
        for (auto *socket : server.findChildren<QLocalSocket *>()) QObject::disconnect(socket, nullptr, this, nullptr);
        if (writeFd >= 0) close(writeFd);
        if (readFd >= 0) close(readFd);
    }
};

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv); std::signal(SIGPIPE, SIG_IGN);
    const auto arguments = app.arguments();
    if (arguments.size() != 6) return 2;
    QLockFile lock(arguments[1] + ".lock"); lock.setStaleLockTime(0);
    if (!lock.tryLock(0)) return 0;
    try {
        QStringList browserArguments;
        for (const auto &value : QJsonDocument::fromJson(arguments[3].toUtf8()).array()) browserArguments.append(value.toString());
        Runtime runtime(arguments[1], arguments[2], browserArguments, arguments[4], arguments[5]);
        return app.exec();
    } catch (const std::exception &error) { qCritical("Browser runtime: %s", error.what()); return 1; }
}
