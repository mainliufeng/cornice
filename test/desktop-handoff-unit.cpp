// Test-only compositor transport and task sockets. Exercise the real Broker
// without a Wayland connection, GUI, GPU, user manager or current session.
#include "Broker.hpp"
#include "DesktopEndpoint.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QThread>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <functional>
#include <mutex>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
static void waitFor(const std::function<bool()> &condition) {
    QElapsedTimer deadline; deadline.start();
    while (!condition()) {
        require(deadline.elapsed() < 2000, "private fixture transport timed out");
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
        QThread::msleep(1);
    }
}
static void document(const QString &path, const QJsonObject &object) {
    QDir().mkpath(QFileInfo(path).path());
    QFile file(path); require(file.open(QIODevice::WriteOnly), "private fixture file failed");
    require(file.write(QJsonDocument(object).toJson()) > 0, "private fixture write failed");
}
class CompositorFixture {
    int control = -1, events = -1;
    std::thread thread;
    std::atomic<bool> stopping{false};
    std::mutex mutex;
    QMap<QString, QJsonObject> states;
    QJsonArray clients;
    QList<int> eventPeers;
    QStringList commands;
    QString error;
    static int listenAt(const QString &path) {
        const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        require(fd >= 0, "private compositor socket failed");
        sockaddr_un address{}; address.sun_family = AF_UNIX;
        const auto name = path.toUtf8(); require(name.size() < sizeof(address.sun_path), "private socket path too long");
        memcpy(address.sun_path, name.constData(), name.size());
        require(!::bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)), "private compositor bind failed");
        require(!::listen(fd, 8), "private compositor listen failed");
        return fd;
    }
    QByteArray answer(const QByteArray &wire) {
        std::lock_guard lock(mutex);
        const QString command = QString::fromUtf8(wire.mid(wire.indexOf('/') + 1));
        commands.append(command);
        auto object = [](const QJsonObject &value) { return QJsonDocument(value).toJson(QJsonDocument::Compact); };
        auto array = [](const QJsonArray &value) { return QJsonDocument(value).toJson(QJsonDocument::Compact); };
        if (command == "seat capabilities") return object({{"protocol", 1}, {"features", QJsonArray{
            "seat-input", "seat-identity", "atomic-snapshot", "readonly-workspace", "argb-frame", "input-pause",
            "composed-seat-input", "seat-shell-v1", "native-seat-presentation-v1", "primary-desktop-v1", "managed-seat-config-v1"}}});
        if (command.startsWith("seat state ")) return object(states.value(command.mid(11)));
        if (command.startsWith("seat windows ")) {
            const auto name = command.mid(13); QJsonArray windows;
            auto workspace = states[name]["workspace"].toString(); if (workspace.startsWith("name:")) workspace.remove(0, 5);
            for (const auto &value : clients) if (value.toObject()["mapped"].toBool() && value.toObject()["workspace"].toObject()["name"] == workspace) windows.append(value);
            return array(windows);
        }
        if (command == "clients") return array(clients);
        if (command == "layers") return object({});
        if (command.startsWith("seat ensure-workspace ") || command.startsWith("seat configuration-remove ") ||
            command.startsWith("seat configuration-renew ")) return "ok";
        if (command.startsWith("seat configure ")) return object({{"configured", true}});
        if (command.startsWith("seat control ")) {
            const auto pieces = command.split(' '); auto &state = states[pieces.at(2)];
            require(pieces.last() == "pause", "pure fixture must never submit input/resume");
            if (!state["paused"].toBool()) state["generation"] = QString::number(state["generation"].toString().toInt() + 1);
            state["paused"] = true;
            return object(state);
        }
        if (command.startsWith("seat present-control ")) {
            const bool takeover = command.endsWith(" yes");
            if (takeover) states["desktop2"]["paused"] = false;
            return object({{"active", true}, {"name", "desktop2"}, {"humanControl", takeover}, {"workspace", states["desktop2"]["workspace"]}});
        }
        if (command.startsWith("dispatch hl.dsp.window.close(")) return "ok";
        throw std::runtime_error(("Unexpected private compositor request: " + command).toStdString());
    }
  public:
    explicit CompositorFixture(const QString &directory) {
        QDir().mkpath(directory);
        for (const auto &name : {QString("main"), QString("desktop2")}) states[name] = QJsonObject{
            {"name", name}, {"primary", name == "main"}, {"seatId", "seat-" + name}, {"generation", "1"},
            {"paused", true}, {"available", true}, {"humanLocked", false}, {"lockEpoch", "0"},
            {"workspace", name == "main" ? "1" : "cornice-agent-desktop2-ws-1"}, {"display", "private-test-no-wayland"},
            {"position", QJsonArray{0, 0}}, {"logicalSize", QJsonArray{1280, 800}}, {"pixelSize", QJsonArray{1280, 800}},
            {"humanLockPolicy", "pause"}};
        control = listenAt(directory + "/.socket.sock"); events = listenAt(directory + "/.socket2.sock");
        thread = std::thread([this] {
            while (!stopping) {
                pollfd descriptors[]{{control, POLLIN, 0}, {events, POLLIN, 0}};
                if (::poll(descriptors, 2, 20) < 1) continue;
                for (int i = 0; i < 2; ++i) {
                    if (!(descriptors[i].revents & POLLIN)) continue;
                    const int peer = ::accept4(descriptors[i].fd, nullptr, nullptr, SOCK_CLOEXEC);
                    if (peer < 0) continue;
                    if (i == 1) { eventPeers.append(peer); continue; }
                    QByteArray input; char bytes[65536]; pollfd readable{peer, POLLIN, 0};
                    while (::poll(&readable, 1, input.isEmpty() ? 1000 : 2) > 0) {
                        const auto count = ::recv(peer, bytes, sizeof(bytes), MSG_DONTWAIT);
                        if (count <= 0) break;
                        input.append(bytes, count);
                    }
                    QByteArray output;
                    try { output = answer(input); }
                    catch (const std::exception &failure) { std::lock_guard lock(mutex); error = failure.what(); output = "fixture rejected command"; }
                    ::send(peer, output.constData(), output.size(), MSG_NOSIGNAL); ::close(peer);
                }
            }
        });
    }
    ~CompositorFixture() {
        stopping = true; thread.join();
        for (const auto fd : eventPeers) ::close(fd);
        ::close(control); ::close(events);
    }
    void setWorkspace(const QString &name, const QString &workspace) { std::lock_guard lock(mutex); states[name]["workspace"] = workspace; }
    void setClients(const QJsonArray &value) { std::lock_guard lock(mutex); clients = value; }
    bool saw(const QString &prefix) { std::lock_guard lock(mutex); return std::any_of(commands.cbegin(), commands.cend(), [&prefix](const QString &value) { return value.startsWith(prefix); }); }
    int commandCount() { std::lock_guard lock(mutex); return commands.size(); }
    void verify() { std::lock_guard lock(mutex); require(error.isEmpty(), qPrintable(error)); }
};
struct TaskSocket {
    QLocalServer listener;
    QLocalSocket client;
    std::unique_ptr<QLocalSocket> owner;
    QByteArray input;
    explicit TaskSocket(const QString &path) {
        require(listener.listen(path), "private task listen failed");
        client.connectToServer(path); require(client.waitForConnected(1000), "private task connect failed");
        waitFor([&] { return listener.hasPendingConnections(); }); owner.reset(listener.nextPendingConnection());
    }
    QList<QJsonObject> read() {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
        input += client.readAll(); QList<QJsonObject> result;
        while (input.contains('\n')) {
            const auto at = input.indexOf('\n'); result.append(QJsonDocument::fromJson(input.left(at)).object()); input.remove(0, at + 1);
        }
        return result;
    }
    QJsonObject waitReply(const QString &id) {
        QJsonObject reply;
        waitFor([&] { for (const auto &value : read()) if (value["id"] == id) reply = value; return !reply.isEmpty(); });
        return reply;
    }
};
class BrokerHandoffFixture {
    QTemporaryDir temporary;
    QString instance;
    std::unique_ptr<CompositorFixture> compositor;
    std::unique_ptr<TaskSocket> human, harness;
    std::unique_ptr<Broker> broker;
    QString target = "desktop2";
    const QString requestId = "test-request";
    QJsonObject request(const QString &action) const {
        return {{"id", "task-rpc"}, {"token", "task-secret"}, {"controller", "unit-controller"}, {"params", QJsonObject{{"action", action}}}};
    }
    void checkReply(const QJsonObject &reply, const QString &status, bool resolved) {
        require(reply["ok"].toBool(), "event wait unexpectedly failed");
        const auto result = reply["result"].toObject(); const auto control = result["control"].toObject();
        require(result["cooperationResolved"].toBool() == resolved, "event wait woke on intermediate outcome");
        require(result["interrupted"].toBool(), "event wait exposed transient running input");
        require(control["paused"].toBool() && control["agentPaused"].toBool(), "outcome was published before input pause");
        require(!control["presentation"].toObject()["humanControl"].toBool(), "outcome was published before native control withdrawal");
        const auto record = control["handoff"].toObject(); require(record["status"] == status, "unexpected handoff outcome");
        const auto events = record["events"].toArray();
        require(events.size() == 3 && events[0].toObject()["status"] == "requested" && events[1].toObject()["status"] == "in_progress" && events[2].toObject()["status"] == status,
                "terminal transition added a transient requested event");
        if (resolved) {
            require(record["resumeGeneration"] == control["generation"] && record["resumeLockEpoch"] == control["lockEpoch"] && record.contains("resumeDecision"), "event wait missed persisted resume boundary");
            QFile saved(broker->m_statePath); require(saved.open(QIODevice::ReadOnly), "cooperation history not persisted");
            const auto persisted = QJsonDocument::fromJson(saved.readAll()).object()["desktops"].toObject()[target].toObject()["handoffs"].toArray().last().toObject();
            require(persisted["status"] == status && persisted["resumeGeneration"] == control["generation"], "final outcome/boundary were not persisted together");
        }
    }
  public:
    explicit BrokerHandoffFixture(QString signature = "handoff-unit", bool stale = false)
        : temporary(signature.size() > 64 ? "/tmp/ce-XXXXXX" : "/tmp/cornice-handoff-unit-XXXXXX"), instance(std::move(signature)) {
        require(temporary.isValid(), "private runtime failed");
        const auto runtime = instance.size() > 64 ? temporary.path() : temporary.filePath("rt"); QDir().mkpath(runtime);
        qputenv("XDG_RUNTIME_DIR", runtime.toUtf8()); qputenv("XDG_CONFIG_HOME", temporary.filePath("config").toUtf8());
        qputenv("XDG_STATE_HOME", temporary.filePath("state").toUtf8()); qputenv("HOME", temporary.path().toUtf8());
        qunsetenv("CORNICE_PATH"); qunsetenv("WAYLAND_DISPLAY"); qunsetenv("DISPLAY"); qunsetenv("HYPRLAND_INSTANCE_SIGNATURE"); qunsetenv("DBUS_SESSION_BUS_ADDRESS");
        document(temporary.filePath("state/cornice/desktops.json"), {{"schema", 1}, {"desktops", QJsonObject{
            {"main", QJsonObject{{"stableId", "main-fixture"}}}, {"desktop2", QJsonObject{{"number", 2}, {"agentAllowed", true}, {"output", "fixture-output"}}}}}});
        document(temporary.filePath("config/cornice/config.json"), {{"agentDesktop", QJsonObject{{"clipboard", QJsonObject{{"mode", "isolated"}}}}}});
        compositor = std::make_unique<CompositorFixture>(runtime + "/hypr/" + instance);
        if (stale) {
            const auto path = desktopSocket(instance); QDir().mkpath(QFileInfo(path).path());
            const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0); require(fd >= 0, "stale fixture socket failed");
            sockaddr_un address{}; address.sun_family = AF_UNIX; const auto encoded = QFile::encodeName(path);
            memcpy(address.sun_path, encoded.constData(), encoded.size());
            require(!::bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)), "stale fixture bind failed"); ::close(fd);
        }
        broker = std::make_unique<Broker>(instance); broker->m_watchdog.stop();
        human = std::make_unique<TaskSocket>(runtime + "/human.sock"); harness = std::make_unique<TaskSocket>(runtime + "/task.sock");
    }
    ~BrokerHandoffFixture() { broker.reset(); }
    void verify() { compositor->verify(); }
    void begin(bool primary = false) {
        if (primary) target = "main";
        auto &desktop = broker->m_desktops.at(target); desktop.agentAllowed = true;
        broker->m_acquisitions[harness->owner.get()] = {{"name", target}, {"seatId", desktop.id}, {"generation", "1"},
            {"token", "input-secret"}, {"taskToken", "task-secret"}, {"controller", "unit-controller"}, {"harness", "unit"}};
        desktop.handoffs = QJsonArray{QJsonObject{{"id", requestId}, {"controller", "unit-controller"}}};
        broker->transitionHandoff(target, requestId, "requested", "Agent requested human assistance");
        if (primary) broker->perform("handoff-start", {{"name", target}, {"requestId", requestId}}, nullptr, human->owner.get());
        else {
            broker->m_presentations[human->owner.get()] = "fixture-presentation";
            broker->perform("takeover", {{"name", target}, {"requestId", requestId}}, nullptr, human->owner.get());
        }
        harness->read();
        auto wait = request("wait"); wait["id"] = "wait-rpc"; wait["params"] = QJsonObject{{"seconds", 30}};
        broker->waitTask(wait, harness->owner.get());
        require(broker->m_taskWaiters.contains(harness->owner.get()), "waiter did not subscribe to interrupted task");
    }
    void complete(bool primary = false) {
        begin(primary);
        broker->perform("handoff-complete", {{"name", target}, {"requestId", requestId}}, nullptr, human->owner.get());
        checkReply(harness->waitReply("wait-rpc"), "completed", true);
        require(!broker->m_humanOwner && broker->m_humanRequestId.isEmpty(), "completed takeover owner survived");
        std::puts(primary ? "PASS primary completion publishes paused terminal record and resume boundary once" : "PASS native human completion wakes actual waiter only after control withdrawal and sealed terminal outcome");
    }
    void resolve(const QString &outcome) {
        begin(); auto resolve = request("resolve"); resolve["params"] = QJsonObject{{"action", "resolve"}, {"requestId", requestId}, {"outcome", outcome}, {"note", "Remote user resolved the task"}};
        broker->handoff(resolve); checkReply(harness->waitReply("wait-rpc"), outcome, true);
        std::printf("PASS agent %s resolution publishes one paused terminal outcome\n", qPrintable(outcome));
    }
    void interrupted() {
        begin(); broker->endTakeover("Human control ended");
        checkReply(harness->waitReply("wait-rpc"), "requested", false);
        std::puts("PASS ordinary takeover release requeues assistance only after native control/input withdrawal");
    }
    void disconnected() {
        begin(); broker->releaseAcquisition(harness->owner.get());
        const auto reply = harness->waitReply("wait-rpc");
        require(!reply["ok"].toBool() && reply["error"] == "Task reservation released", "disconnected task waiter was not retired");
        const auto actual = broker->state(target); const auto events = actual["handoff"].toObject()["events"].toArray();
        require(actual["paused"].toBool() && !actual["presentation"].toObject()["humanControl"].toBool(), "owner cleanup left native input active");
        require(events.size() == 3 && events.last().toObject()["status"] == "cancelled", "owner cleanup published intermediate requested state");
        std::puts("PASS task owner release cancels assistance without transient requeue and retires actual waiter");
    }
    void retained() {
        QJsonArray clients;
        for (const auto &workspace : {QString("cornice-agent-desktop2-ws-1"), QString("cornice-agent-desktop2-ws-2"), QString("elsewhere")})
            clients.append(QJsonObject{{"mapped", true}, {"workspace", QJsonObject{{"name", workspace}}}, {"address", "0x1234"}});
        clients.append(QJsonObject{{"mapped", false}, {"workspace", QJsonObject{{"name", "cornice-agent-desktop2-ws-2"}}}});
        compositor->setClients(clients);
        for (const auto &workspace : {QString("cornice-agent-desktop2-ws-1"), QString("name:cornice-agent-desktop2-ws-1")}) {
            compositor->setWorkspace(target, workspace); broker->m_windowsAt.clear(); broker->m_clientsAt = 0;
            const auto actual = broker->state(target);
            require(actual["windowCount"].toInt() == 1 && actual["retainedWindowCount"].toInt() == 2, "current workspace windows counted twice");
        }
        broker->m_desktops.at(target).workspaceSlots[1] = "name:prefixname:segment";
        compositor->setWorkspace(target, "name:prefixname:segment");
        const auto actual = broker->state(target);
        require(actual["workspaceName"] == "prefixname:segment" && actual["workspaceSlots"].toArray()[0].toObject()["active"].toBool(), "workspace normalization removed an internal name prefix");
        std::puts("PASS retained windows compare canonical workspace names once and preserve internal name prefixes");
    }
    void endpointGolden() {
        const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        const auto golden = runtime + "/cornice/ipc-9f86d081884c7d659a2feaa0c55ad015/desktop.sock";
        require(desktopSocket("test") == golden, "C++ endpoint differs from fixed SHA256 golden identity");
        QProcess cli; cli.setProgram(QCoreApplication::applicationDirPath() + "/cornice-desktop-runtime"); cli.setArguments({"--instance", "test", "endpoint"});
        cli.start(); require(cli.waitForFinished(2000) && cli.exitCode() == 0 && QString::fromUtf8(cli.readAllStandardOutput()).trimmed() == golden, "CLI endpoint differs from shared C++ identity");
        std::puts("PASS C++ and real CLI endpoint match fixed SHA256 golden identity");
    }
    void longSignature() {
        const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        const auto old = runtime + "/cornice/" + instance + "/desktop.sock";
        require(QFile::encodeName(old).size() >= 108 && QFile::encodeName(broker->m_socketPath).size() <= 107, "long signature fixture did not reach actual AF_UNIX boundary");
        require(broker->m_server.isListening() && QFileInfo::exists(broker->m_directory + "/desktops.json"), "bounded endpoint did not preserve original instance runtime data");
        require(broker->state("desktop2")["seatId"] == "seat-desktop2", "real Broker did not initialize long instance through private compositor transport");
        std::puts("PASS 73-byte compositor instance starts actual Broker with old 109-byte endpoint replaced by bounded IPC and unchanged data directory");
    }
    void earlyConnection() {
        QLocalSocket client; client.connectToServer(broker->m_socketPath); require(client.waitForConnected(1000), "early client could not connect to preclaimed endpoint");
        client.write("{\"id\":\"early-rpc\",\"method\":\"doctor\"}\n"); client.flush();
        waitFor([&] { return broker->m_server.hasPendingConnections(); });
        // Force both newConnection and the accepted socket's first readyRead
        // before the Broker attaches its request handlers.
        waitFor([&] { return broker->m_server.findChildren<QLocalSocket *>().first()->bytesAvailable() > 0; });
        broker->listen(); QByteArray reply;
        waitFor([&] { reply += client.readAll(); return reply.contains('\n'); });
        const auto value = QJsonDocument::fromJson(reply.left(reply.indexOf('\n'))).object();
        require(value["id"] == "early-rpc" && value["ok"].toBool(), "constructor-time client was lost before handlers attached");
        std::puts("PASS constructor-time connection and buffered first request are drained after endpoint publication");
    }
    void duplicateEndpoint() {
        const int before = compositor->commandCount(); bool refused = false;
        try { Broker duplicate(instance); }
        catch (const std::exception &failure) { refused = QString::fromUtf8(failure.what()).contains("already listening"); }
        require(refused && compositor->commandCount() == before && broker->m_server.isListening(), "duplicate Broker changed a seat or removed live endpoint");
        QLocalSocket probe; probe.connectToServer(broker->m_socketPath); require(probe.waitForConnected(1000), "duplicate startup removed original listener");
        std::puts("PASS duplicate active endpoint is rejected before any compositor request without unlinking the original listener");
    }
    void failedEndpoint() {
        const int before = compositor->commandCount(); const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        const auto blocked = desktopSocket("blocked"); QDir().mkpath(QFileInfo(blocked).path());
        QFile file(blocked); require(file.open(QIODevice::WriteOnly) && file.write("keep this file") == 14, "blocked endpoint file failed"); file.close();
        bool refused = false;
        try { Broker blockedBroker("blocked"); }
        catch (const std::exception &failure) { refused = QString::fromUtf8(failure.what()).contains("must be a local socket"); }
        require(refused && compositor->commandCount() == before && file.open(QIODevice::ReadOnly) && file.readAll() == "keep this file", "invalid endpoint modified compositor or deleted an unrelated file");
        file.close();
        const auto tooLong = temporary.filePath(QString(90, 'x')); QDir().mkpath(tooLong); qputenv("XDG_RUNTIME_DIR", tooLong.toUtf8());
        refused = false;
        try { Broker invalid("too-long-runtime"); }
        catch (const std::exception &failure) { refused = QString::fromUtf8(failure.what()).contains("exceeds 107"); }
        qputenv("XDG_RUNTIME_DIR", runtime.toUtf8());
        require(refused && compositor->commandCount() == before && !QFileInfo::exists(tooLong + "/cornice"), "overlong runtime startup changed a seat or wrote runtime state");
        std::puts("PASS blocked endpoint and overlong runtime fail closed before compositor requests, state publication or unrelated-file removal");
    }
    void staleEndpoint() {
        require(broker->m_server.isListening(), "stale endpoint was not replaced by actual listener");
        QLocalSocket probe; probe.connectToServer(broker->m_socketPath); require(probe.waitForConnected(1000), "stale endpoint startup did not create working listener");
        std::puts("PASS verified stale local socket is replaced by a working listener before compositor initialization");
    }
    void sharedWorkspace() {
        broker->m_desktops.at(target).privateOutput = "test-private-output";
        compositor->setClients(QJsonArray{QJsonObject{{"mapped", true}, {"workspace", QJsonObject{{"name", "cornice-agent-desktop2-ws-1"}}}, {"address", "0x1234"}}});
        compositor->setWorkspace("main", "cornice-agent-desktop2-ws-1");
        bool refused = false;
        try { broker->closeDesktopApps(target); }
        catch (const std::exception &failure) { refused = QString::fromUtf8(failure.what()).contains("another desktop"); }
        require(refused && !compositor->saw("dispatch hl.dsp.window.close("), "reset closed a workspace still viewed on another desktop");
        std::puts("PASS reset refuses a shared workspace before closing applications using canonical workspace identity");
    }
};
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        const auto run = [](auto test) { BrokerHandoffFixture fixture; test(fixture); fixture.verify(); };
        run([](auto &fixture) { fixture.complete(); });
        run([](auto &fixture) { fixture.complete(true); });
        run([](auto &fixture) { fixture.resolve("completed"); });
        run([](auto &fixture) { fixture.resolve("cancelled"); });
        run([](auto &fixture) { fixture.interrupted(); });
        run([](auto &fixture) { fixture.disconnected(); });
        run([](auto &fixture) { fixture.retained(); });
        run([](auto &fixture) { fixture.sharedWorkspace(); });
        run([](auto &fixture) { fixture.endpointGolden(); });
        run([](auto &fixture) { fixture.earlyConnection(); });
        run([](auto &fixture) { fixture.duplicateEndpoint(); });
        run([](auto &fixture) { fixture.failedEndpoint(); });
        { BrokerHandoffFixture fixture("handoff-unit", true); fixture.staleEndpoint(); fixture.verify(); }
        { BrokerHandoffFixture fixture(QString(73, 'a')); fixture.longSignature(); fixture.verify(); }
        return 0;
    } catch (const std::exception &failure) { std::fprintf(stderr, "FAIL %s\n", failure.what()); return 1; }
}
