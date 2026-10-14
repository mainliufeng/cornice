// Test-only compositor transport and task sockets. Exercise the real Broker
// without a Wayland connection, GUI, GPU, user manager or current session.
#include "Broker.hpp"
#include "ClipboardBridge.hpp"
#include "DesktopEndpoint.hpp"
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QPointer>
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
            if (pieces.last() == "resume-composed") return "test-only resume refused before Wayland construction";
            require(pieces.last() == "pause", "pure fixture must never submit input");
            if (!state["paused"].toBool()) state["generation"] = QString::number(state["generation"].toString().toInt() + 1);
            state["paused"] = true;
            return object(state);
        }
        if (command.startsWith("seat present-control ")) {
            const bool takeover = command.endsWith(" yes");
            if (takeover) states["desktop2"]["paused"] = false;
            return object({{"active", true}, {"name", "desktop2"}, {"humanControl", takeover}, {"workspace", states["desktop2"]["workspace"]}});
        }
        if (command.startsWith("seat presentation "))
            return object({{"active", true}, {"name", "desktop2"}, {"humanControl", false}});
        if (command.startsWith("seat create-private-output ") || command.startsWith("eval hl.monitor(")) return "ok";
        if (command.startsWith("seat create ")) {
            const auto pieces = command.split(' '); states[pieces.at(2)]["output"] = pieces.at(3); return "ok";
        }
        if (command.startsWith("seat workspace ")) {
            const auto pieces = command.split(' '); states[pieces.at(2)]["workspace"] = pieces.at(3); return "ok";
        }
        if (command.startsWith("seat remove ")) { states.remove(command.mid(12)); return "ok"; }
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
    void setState(const QString &name, const QJsonObject &changes) {
        std::lock_guard lock(mutex);
        for (auto it = changes.begin(); it != changes.end(); ++it) states[name][it.key()] = it.value();
    }
    bool resumed() {
        std::lock_guard lock(mutex);
        return std::any_of(commands.cbegin(), commands.cend(), [](const QString &value) { return value.contains(" resume-composed"); });
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
    void runningTask() {
        auto &desktop = broker->m_desktops.at(target);
        compositor->setState(target, {{"paused", false}, {"humanLockPolicy", "continue"}});
        broker->m_acquisitions[harness->owner.get()] = {{"name", target}, {"seatId", desktop.id}, {"generation", "1"},
            {"token", "input-secret"}, {"taskToken", "task-secret"}, {"controller", "unit-controller"}, {"harness", "unit"},
            {"restoredDecision", static_cast<qint64>(desktop.inputDecision)}, {"restoredLockEpoch", "0"},
            {"heartbeatAt", QDateTime::currentMSecsSinceEpoch()}};
        broker->m_bindings["input-secret"] = Broker::Binding{target, desktop.id, "1", {}};
        auto &binding = broker->m_bindings["input-secret"];
        binding.controller = "unit-controller"; binding.harness = "unit"; binding.heartbeat.start();
    }
    void requireRestoreRejected() {
        bool refused = false;
        try { broker->task(request("restore")); }
        catch (const std::exception &failure) { refused = QString::fromUtf8(failure.what()).contains("Explicit operator restoration"); }
        require(refused && !compositor->resumed(), "interrupted or foreign task restored control");
    }
    void dailyLockContinuity() {
        runningTask();
        for (int epoch = 0; epoch <= 2; ++epoch) {
            compositor->setState(target, {{"lockEpoch", QString::number(epoch)}, {"humanLocked", epoch == 1}, {"lockScope", "human"}});
            const auto restored = broker->task(request("restore"));
            require(restored["restored"].toBool() && restored["binding"].toObject()["token"] == "input-secret" &&
                restored["binding"].toObject()["generation"] == "1", "daily lock changed or rejected the still-live task binding");
        }
        require(!compositor->resumed(), "daily-lock restoration granted new native input");
        std::puts("PASS daily lock epoch 0/1/2 preserves restoration of the existing exact task grant without resume");
    }
    void dailyLockRelease() {
        runningTask();
        compositor->setState(target, {{"lockEpoch", "1"}, {"humanLocked", true}, {"lockScope", "human"}});
        compositor->setState(target, {{"lockEpoch", "2"}, {"humanLocked", false}});
        broker->m_presentations[human->owner.get()] = "fixture-presentation";
        broker->perform("takeover", {{"name", target}}, nullptr, human->owner.get());
        require(broker->m_restoreTaskOnRelease, "daily-lock epoch hid the task interrupted by normal takeover");
        bool submitted = false;
        try { broker->perform("release", {{"name", target}}, nullptr, human->owner.get()); }
        catch (const std::exception &failure) { submitted = QString::fromUtf8(failure.what()).contains("test-only resume refused"); }
        require(submitted && compositor->resumed() && !broker->m_humanOwner,
            "normal release did not submit restoration of the task interrupted after daily unlock");
        std::puts("PASS normal release after daily unlock submits resume; test transport deliberately refuses before Wayland/new-binding construction");
    }
    void continuityRejected(const QString &reason) {
        runningTask();
        auto &lease = broker->m_acquisitions[harness->owner.get()];
        auto &binding = broker->m_bindings["input-secret"];
        auto &desktop = broker->m_desktops.at(target);
        if (reason == "full") compositor->setState(target, {{"humanLocked", true}, {"lockScope", "session"}, {"lockEpoch", "1"}, {"generation", "2"}, {"paused", true}});
        else if (reason == "full-unlocked") compositor->setState(target, {{"humanLocked", false}, {"lockEpoch", "2"}, {"generation", "2"}, {"paused", true}});
        else if (reason == "full-resumed") compositor->setState(target, {{"humanLocked", false}, {"lockEpoch", "2"}, {"generation", "2"}, {"paused", false}});
        else if (reason == "pause") compositor->setState(target, {{"generation", "2"}, {"paused", true}});
        else if (reason == "native-paused") compositor->setState(target, {{"paused", true}});
        else if (reason == "unavailable") compositor->setState(target, {{"available", false}});
        else if (reason == "permission") desktop.agentAllowed = false;
        else if (reason == "decision") ++desktop.inputDecision;
        else if (reason == "binding-name") binding.name = "main";
        else if (reason == "binding-id") binding.id = "foreign-seat";
        else if (reason == "binding-generation") binding.generation = "2";
        else if (reason == "missing-binding") broker->m_bindings.remove("input-secret");
        else if (reason == "lease-generation") lease["generation"] = "2";
        else if (reason == "lease-seat") lease["seatId"] = "foreign-seat";
        else if (reason == "viewer-loss" || reason == "human-control") {
            broker->m_presentations[human->owner.get()] = "fixture-presentation";
            broker->perform("takeover", {{"name", target}}, nullptr, human->owner.get());
            if (reason == "viewer-loss") broker->endTakeover("Viewer disconnected");
        } else throw std::runtime_error("unknown continuity fixture case");
        if (reason == "lease-seat") {
            bool refused = false;
            try { broker->task(request("restore")); }
            catch (const std::exception &failure) { refused = QString::fromUtf8(failure.what()).contains("Desktop lifecycle changed"); }
            require(refused && !compositor->resumed(), "foreign lease seat restored control");
        } else requireRestoreRejected();
        std::printf("PASS task continuity rejects %s without a new input grant\n", qPrintable(reason));
    }
    void takeoverStillGuarded(const QString &reason) {
        runningTask();
        if (reason == "locked") compositor->setState(target, {{"humanLocked", true}, {"lockScope", "human"}, {"lockEpoch", "1"}});
        else if (reason == "expired") broker->m_acquisitions[harness->owner.get()]["heartbeatAt"] = QDateTime::currentMSecsSinceEpoch() - 6000;
        else if (reason != "during-lock") throw std::runtime_error("unknown takeover fixture case");
        broker->m_presentations[human->owner.get()] = "fixture-presentation";
        broker->perform("takeover", {{"name", target}}, nullptr, human->owner.get());
        if (reason == "during-lock") {
            require(broker->m_restoreTaskOnRelease, "running task was not remembered before takeover");
            compositor->setState(target, {{"lockEpoch", "1"}});
        } else require(!broker->m_restoreTaskOnRelease, "locked or expired task became eligible for automatic release restoration");
        broker->perform("release", {{"name", target}}, nullptr, human->owner.get());
        require(!compositor->resumed(), "lock or expired task bypassed the takeover release boundary");
        std::printf("PASS takeover restoration retains %s boundary\n", qPrintable(reason));
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
    void mainOnlyLogin(bool legacy) {
        broker->perform("remove", {{"name", target}}, nullptr, nullptr);
        require(broker->m_desktops.size() == 1 && broker->m_definitions.size() == 1, "remove did not persist a main-only topology");
        const auto statePath = broker->m_statePath;
        QFile persistent(statePath); require(persistent.open(QIODevice::ReadOnly), "main-only definitions were not saved");
        const auto definition = QJsonDocument::fromJson(persistent.readAll()).object()["desktops"].toObject(); persistent.close();
        require(definition.size() == 1 && definition.contains("main"), "secondary deletion left a durable definition");
        broker.reset(); compositor.reset(); instance += "-new-login";
        const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        if (legacy) {
            require(QFile::remove(statePath), "private legacy fixture could not remove persistent definition");
            document(runtime + "/cornice/" + instance + "/desktops.json", definition);
        }
        compositor = std::make_unique<CompositorFixture>(runtime + "/hypr/" + instance);
        broker = std::make_unique<Broker>(instance); broker->m_watchdog.stop();
        require(broker->m_desktops.size() == 1 && broker->m_desktops.contains("main") && !compositor->saw("seat create "), "new compositor login recreated a deleted secondary desktop");
        require(broker->m_desktops.at("main").stableId == "main-fixture" && broker->state("main")["paused"].toBool(), "main-only restore lost identity or enabled input");
        std::printf("PASS deleted secondary remains deleted on a new compositor transport with %s main-only definitions\n", legacy ? "legacy runtime" : "persistent");
    }
    void firstInstallation() {
        const auto statePath = broker->m_statePath;
        broker.reset(); compositor.reset();
        require(QFile::remove(statePath), "private fresh fixture could not remove saved definitions");
        instance += "-first-install"; const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        compositor = std::make_unique<CompositorFixture>(runtime + "/hypr/" + instance);
        broker = std::make_unique<Broker>(instance); broker->m_watchdog.stop();
        require(broker->m_desktops.size() == 2 && broker->m_desktops.contains("desktop2") && compositor->saw("seat create desktop2 "), "first installation did not create its default empty secondary desktop");
        require(broker->state("desktop2")["paused"].toBool() && broker->state("desktop2")["humanLockPolicy"] == "pause", "fresh desktop changed the default paused lock policy");
        std::puts("PASS genuine first installation seeds exactly one paused default secondary desktop");
    }
    void invalidDefinitions() {
        const auto statePath = broker->m_statePath;
        broker.reset(); compositor.reset(); instance += "-invalid-definitions";
        const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        compositor = std::make_unique<CompositorFixture>(runtime + "/hypr/" + instance);
        QFile persistent(statePath); require(persistent.open(QIODevice::WriteOnly | QIODevice::Truncate), "broken persistent fixture failed");
        require(persistent.write("{") == 1, "broken persistent fixture write failed"); persistent.close();
        bool refused = false;
        try { Broker invalid(instance); } catch (const std::exception &) { refused = true; }
        require(refused && !compositor->saw("seat control ") && !compositor->saw("seat create "), "broken persistent definition was treated as fresh or changed input");
        require(QFile::remove(statePath), "broken persistent fixture removal failed");
        const auto legacy = runtime + "/cornice/" + instance + "/desktops.json"; QDir().mkpath(QFileInfo(legacy).path());
        QFile file(legacy); require(file.open(QIODevice::WriteOnly), "broken legacy fixture failed");
        require(file.write("[]") == 2, "broken legacy fixture write failed"); file.close();
        refused = false;
        try { Broker invalid(instance); } catch (const std::exception &failure) { refused = QString::fromUtf8(failure.what()).contains("Unsupported runtime desktop definitions"); }
        require(refused && !compositor->saw("seat control ") && !compositor->saw("seat create "), "broken legacy definition was treated as fresh or changed input");
        std::puts("PASS malformed persistent and non-object legacy definitions fail before input changes without fresh seeding");
    }
    void clipboardPolicyFailClosed(const QString &fault) {
        require(broker->m_clipboard && broker->m_clipboardError.isEmpty(), "fixture did not create its actual isolated clipboard bridge");
        require(broker->clipboardStatus()["mode"] == "isolated" && !broker->clipboardStatus()["connected"].toBool(),
                "clipboard failure fixture must not connect to Wayland");
        // Observe destruction, not a raw address: an allocator could reuse that
        // address during recovery without proving the old QObject was retired.
        QPointer<ClipboardBridge> oldBridge(broker->m_clipboard.get());
        const auto policyPath = temporary.filePath("config/cornice/config.json");
        QString expectedError;
        if (fault == "malformed-policy") {
            QFile policy(policyPath);
            require(policy.open(QIODevice::WriteOnly | QIODevice::Truncate), "malformed clipboard policy fixture failed");
            require(policy.write("{malformed-clipboard-policy") == 27, "malformed clipboard policy write failed");
            policy.close();
            expectedError = "malformed-clipboard-policy";
        } else if (fault == "invalid-policy") {
            document(policyPath, {{"agentDesktop", QJsonObject{{"clipboard", QJsonObject{{"mode", "invalid-unit-mode"}}}}}});
            expectedError = "Invalid clipboard policy";
        } else if (fault == "flag-string" || fault == "flag-number" || fault == "flag-null") {
            const QJsonValue invalid = fault == "flag-string" ? QJsonValue("false") :
                fault == "flag-number" ? QJsonValue(0) : QJsonValue(QJsonValue::Null);
            compositor->setState("main", {{"humanLocked", invalid}});
            expectedError = "Invalid clipboard session lock flag";
        } else if (fault == "unknown-scope") {
            compositor->setState("main", {{"humanLocked", true}, {"lockScope", "unknown-unit-scope"}});
            expectedError = "Invalid clipboard session lock scope";
        } else throw std::runtime_error("unknown clipboard policy fixture case");
        // Exercise the production retry entry point against actual file reads
        // and this fixture's private compositor IPC; no copied parser or bridge.
        broker->refreshClipboardPolicy();
        require(!broker->m_clipboard && oldBridge.isNull(), "invalid clipboard policy/state retained the old bridge QObject");
        const auto failed = broker->clipboardStatus();
        require(!broker->m_clipboardError.isEmpty() && broker->m_clipboardError.contains(expectedError) &&
                failed["error"] == broker->m_clipboardError && !failed["connected"].toBool(),
                "clipboard refresh failure did not report its policy/state error");
        broker->refreshClipboardPolicy();
        require(!broker->m_clipboard && oldBridge.isNull() && broker->clipboardStatus()["error"] == broker->m_clipboardError &&
                broker->m_clipboardError.contains(expectedError), "invalid clipboard retry resurrected a bridge or lost the error");
        document(policyPath, {{"agentDesktop", QJsonObject{{"clipboard", QJsonObject{{"mode", "isolated"}}}}}});
        compositor->setState("main", {{"humanLocked", fault == "unknown-scope"},
                                      {"lockScope", fault == "unknown-scope" ? "full" : "none"}});
        broker->refreshClipboardPolicy();
        require(broker->m_clipboard && oldBridge.isNull() && broker->m_clipboardError.isEmpty(),
                "correct clipboard policy/state did not rebuild after a failed refresh");
        const auto recovered = broker->clipboardStatus();
        require(recovered["mode"] == "isolated" && !recovered["connected"].toBool() && recovered["error"].toString().isEmpty(),
                "clipboard recovery retained an error or attempted a Wayland connection");
        require(!compositor->resumed(), "clipboard policy recovery changed input control");
        std::printf("PASS actual Broker refresh retires the bridge on %s, preserves its error, and rebuilds after policy/state repair\n", qPrintable(fault));
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
        run([](auto &fixture) { fixture.dailyLockContinuity(); });
        run([](auto &fixture) { fixture.dailyLockRelease(); });
        for (const auto &reason : {"full", "full-unlocked", "full-resumed", "pause", "native-paused", "unavailable", "permission", "decision", "binding-name", "binding-id", "binding-generation", "missing-binding", "lease-generation", "lease-seat", "viewer-loss", "human-control"})
            run([reason](auto &fixture) { fixture.continuityRejected(reason); });
        for (const auto &reason : {"locked", "expired", "during-lock"})
            run([reason](auto &fixture) { fixture.takeoverStillGuarded(reason); });
        run([](auto &fixture) { fixture.retained(); });
        for (const auto &fault : {"malformed-policy", "invalid-policy", "flag-string", "flag-number", "flag-null", "unknown-scope"})
            run([fault](auto &fixture) { fixture.clipboardPolicyFailClosed(fault); });
        run([](auto &fixture) { fixture.sharedWorkspace(); });
        run([](auto &fixture) { fixture.endpointGolden(); });
        run([](auto &fixture) { fixture.earlyConnection(); });
        run([](auto &fixture) { fixture.duplicateEndpoint(); });
        run([](auto &fixture) { fixture.failedEndpoint(); });
        run([](auto &fixture) { fixture.mainOnlyLogin(false); });
        run([](auto &fixture) { fixture.mainOnlyLogin(true); });
        run([](auto &fixture) { fixture.firstInstallation(); });
        run([](auto &fixture) { fixture.invalidDefinitions(); });
        { BrokerHandoffFixture fixture("handoff-unit", true); fixture.staleEndpoint(); fixture.verify(); }
        { BrokerHandoffFixture fixture(QString(73, 'a')); fixture.longSignature(); fixture.verify(); }
        return 0;
    } catch (const std::exception &failure) { std::fprintf(stderr, "FAIL %s\n", failure.what()); return 1; }
}
