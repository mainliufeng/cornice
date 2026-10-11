// Test double is confined to this unit: exercise the real BrowserSession event
// loop against delayed private transport and a fake pipe application. No GPU,
// actual compositor, GUI application, or host runtime is involved.
#include "BrowserSession.hpp"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QProcess>
#include <QSocketNotifier>
#include <QThread>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QTemporaryDir>
#include <QTimer>
#include <QTcpSocket>
#include <QUrl>
#include <QWebSocket>
#include <cstdio>
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <unistd.h>
#include <memory>
#include <stdexcept>

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
class Fixture : public QObject {
public:
    QLocalServer server;
    QString log;
    int delay;
    int detachCount = 0, attachCount = 0, shutdownCount = 0, privateGreetingRequests = 0;
    QJsonObject requestedEnvironment;
    bool invalidCdpEnvelope = false;
    QJsonObject launchEnvironment{{"HTTP_PROXY", "http://private-unit-proxy.invalid:8080"}, {"EMPTY_PROBE", ""}};
    Fixture(QString directory, QString name, int responseDelay) : log(directory + "/" + name), delay(responseDelay) {
        const auto path = directory + "/cb-" + QString::fromLatin1(QCryptographicHash::hash(log.toUtf8(), QCryptographicHash::Sha256).toHex().left(32)) + ".sock";
        require(server.listen(path), "private fixture listen failed");
        connect(&server, &QLocalServer::newConnection, this, [this] {
            while (auto *socket = server.nextPendingConnection()) {
                auto input = std::make_shared<QByteArray>();
                connect(socket, &QLocalSocket::readyRead, this, [this, socket, input] {
                    input->append(socket->readAll());
                    while (input->contains('\0')) {
                        const auto separator = input->indexOf('\0');
                        const auto message = QJsonDocument::fromJson(input->left(separator)).object();
                        input->remove(0, separator + 1);
                        if (message["op"] == "detach") ++detachCount;
                        if (message["op"] == "shutdown") ++shutdownCount;
                        if (message["method"] == "Unit.emitPrivateGreeting") {
                            ++privateGreetingRequests;
                            for (const auto &key : message.keys())
                                if (key != "id" && key != "method" && key != "params" && key != "sessionId") invalidCdpEnvelope = true;
                            auto privateFrame = QJsonDocument(QJsonObject{{"ok",true},{"pid",900001},{"launchEnvironment",launchEnvironment}}).toJson(QJsonDocument::Compact);
                            privateFrame.append('\0'); socket->write(privateFrame);
                        }
                        if (message["op"] == "attach") {
                            ++attachCount;
                            require(message["policy"] == "unit", "policy was lost during async startup");
                            requestedEnvironment = message["requestedEnvironment"].toObject();
                            bool matches = message["requestedEnvironment"].isObject();
                            for (auto it = requestedEnvironment.begin(); it != requestedEnvironment.end(); ++it)
                                if (!launchEnvironment.contains(it.key()) || launchEnvironment.value(it.key()) != it.value()) matches = false;
                            QTimer::singleShot(delay, socket, [this, socket, matches] {
                                const QJsonObject greeting = matches ? QJsonObject{{"ok",true}, {"pid",900001},
                                    {"version", QJsonObject{{"product","Unit browser"}}}, {"launchEnvironment", launchEnvironment}} :
                                    QJsonObject{{"ok",false}, {"error","Managed browser launch environment changed; close this desktop's browser before relaunching"}};
                                auto reply = QJsonDocument(greeting).toJson(QJsonDocument::Compact);
                                reply.append('\0'); socket->write(reply);
                            });
                        }
                    }
                });
            }
        });
    }
    ~Fixture() override {
        disconnect(&server, nullptr, this, nullptr);
        for (auto *socket : server.findChildren<QLocalSocket *>()) disconnect(socket, nullptr, this, nullptr);
    }
};

// Exercise the actual helper's pipe lifecycle with an intentionally blocked
// command reader. The long session IDs make cleanup exceed its 8 MiB budget.
static constexpr int cleanupSessionCount = 144;
class PipeFixture : public QObject {
    QByteArray input;
    QString gate, emitted, completed;
    QSocketNotifier reader{3,QSocketNotifier::Read,this};
    QTimer events, resume;
    int emittedCount = 0, detachedCount = 0;
    static void marker(const QString &path) {
        QFile file(path); require(file.open(QIODevice::WriteOnly), "pipe fixture marker failed");
        file.write("ready");
    }
    static void send(QJsonObject message) {
        auto bytes = QJsonDocument(message).toJson(QJsonDocument::Compact); bytes.append('\0');
        qsizetype sent = 0;
        while (sent < bytes.size()) {
            const auto count = ::write(4,bytes.constData()+sent,bytes.size()-sent);
            if (count < 0 && errno == EINTR) continue;
            require(count > 0,"pipe fixture response failed"); sent += count;
        }
    }
    void receive() {
        char buffer[65536];
        while (true) {
            const auto count = ::read(3,buffer,sizeof buffer);
            if (count > 0) input.append(buffer,count);
            else if (count < 0 && errno == EINTR) continue;
            else if (count < 0 && errno == EAGAIN) break;
            else { QCoreApplication::quit(); return; }
        }
        while (input.contains('\0')) {
            const auto separator = input.indexOf('\0');
            const auto message = QJsonDocument::fromJson(input.left(separator)).object();
            input.remove(0,separator+1);
            const auto method = message["method"].toString();
            QJsonObject result;
            if (method == "Browser.getVersion") result = {{"product","Pipe unit browser"}};
            if (method == "Target.detachFromTarget") {
                ++detachedCount;
                if (detachedCount == cleanupSessionCount) marker(completed);
            }
            send({{"id",message["id"]},{"result",result}});
            if (method == "Unit.emitSessions") { reader.setEnabled(false); events.start(5); resume.start(10); return; }
            if (method == "Unit.closeRead") { reader.setEnabled(false); ::close(3); return; }
        }
    }
public:
    PipeFixture(QString gatePath, QString emittedPath, QString completedPath)
        : gate(std::move(gatePath)), emitted(std::move(emittedPath)), completed(std::move(completedPath)) {
        require(fcntl(3,F_SETFL,fcntl(3,F_GETFL)|O_NONBLOCK) == 0,"pipe fixture descriptor setup failed");
        connect(&reader,&QSocketNotifier::activated,this,[this] { receive(); });
        connect(&events,&QTimer::timeout,this,[this] {
            const auto session = QString::number(++emittedCount) + QString(65536,QLatin1Char('x'));
            send({{"method","Target.attachedToTarget"},{"params",QJsonObject{{"sessionId",session}}}});
            if (emittedCount == cleanupSessionCount) { events.stop(); marker(emitted); }
        });
        connect(&resume,&QTimer::timeout,this,[this] {
            if (QFile::exists(gate)) { resume.stop(); reader.setEnabled(true); receive(); }
        });
    }
};

static void verifyRuntimePipe(const QString &directory) {
    auto spin = [](std::function<bool()> condition, int timeout = 5000) {
        QElapsedTimer elapsed; elapsed.start();
        while (!condition() && elapsed.elapsed() < timeout) {
            QCoreApplication::processEvents(QEventLoop::AllEvents,20); QThread::msleep(2);
        }
        return condition();
    };
    const auto compositorPath = directory + "/hypr/unit/.socket2.sock";
    require(QDir().mkpath(QFileInfo(compositorPath).path()),"private compositor transport directory failed");
    QLocalServer compositor;
    require(compositor.listen(compositorPath),"private compositor transport listen failed");
    const auto path = directory + "/pipe-runtime.sock", gate = directory + "/pipe-gate", emitted = directory + "/pipe-emitted", completed = directory + "/pipe-completed";
    QProcess runtime;
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.insert("HYPRLAND_INSTANCE_SIGNATURE","unit"); environment.insert("XDG_RUNTIME_DIR",directory);
    environment.insert("HTTP_PROXY","http://private-unit-proxy.invalid:8080");
    environment.insert("CORNICE_BROWSER_REQUESTED_ENV","{}"); environment.insert("CORNICE_BROWSER_POLICY","unit");
    runtime.setProcessEnvironment(environment);
    runtime.setProgram(QCoreApplication::applicationDirPath()+"/cornice-browser-runtime");
    runtime.setArguments({path,QCoreApplication::applicationFilePath(),
        QString::fromUtf8(QJsonDocument(QJsonArray{"--pipe-browser-fixture",gate,emitted,completed}).toJson(QJsonDocument::Compact)),directory+"/pipe-browser.log","unit"});
    runtime.setStandardOutputFile(directory+"/pipe-runtime.log"); runtime.setStandardErrorFile(directory+"/pipe-runtime.log",QIODevice::Append);
    runtime.start(); require(runtime.waitForStarted(1000),"real helper fixture failed to start");
    QLocalSocket owner;
    auto shutdown = [&] {
        QLocalSocket close; close.connectToServer(path);
        if (close.waitForConnected(500)) {
            close.write(QByteArray("{\"op\":\"shutdown\"}\0",18)); close.flush(); close.waitForBytesWritten(100);
        }
        spin([&] { return runtime.state() == QProcess::NotRunning; },3000);
    };
    try {
        require(spin([&] { return compositor.hasPendingConnections() && QFile::exists(path); }),"real helper fixture did not become ready");
        auto *compositorConnection = compositor.nextPendingConnection();
        require(compositorConnection,"helper did not connect to the private compositor transport");
        owner.connectToServer(path); require(owner.waitForConnected(1000),"real helper owner connection failed");
        QByteArray input, rejectedInput;
        QList<QJsonObject> received;
        int eventCount = 0;
        // Disconnect captures before these local buffers unwind on a failure.
        QObject readScope;
        QObject::connect(&owner,&QLocalSocket::readyRead,&readScope,[&] {
            input.append(owner.readAll());
            while (input.contains('\0')) {
                const auto separator = input.indexOf('\0');
                const auto message = QJsonDocument::fromJson(input.left(separator)).object(); input.remove(0,separator+1);
                if (message["method"] == "Target.attachedToTarget") ++eventCount;
                else received.append(message);
            }
        });
        auto send = [&](QJsonObject message) { auto bytes = QJsonDocument(message).toJson(QJsonDocument::Compact); bytes.append('\0'); owner.write(bytes); owner.flush(); };
        auto reply = [&](int id) {
            for (const auto &message : received) if (message["id"].toInt() == id) return true;
            return false;
        };
        send({{"op","attach"},{"policy","unit"},{"requestedEnvironment",QJsonObject{}}});
        require(spin([&] { return !received.isEmpty(); }),"real helper greeting missing");
        const auto greeting = received.takeFirst();
        require(greeting["ok"].toBool() && greeting["pid"].toInteger() > 0,"real helper attachment failed");
        const auto launched = greeting["launchEnvironment"].toObject();
        require(launched["HTTP_PROXY"] == environment.value("HTTP_PROXY") && !launched.contains("CORNICE_BROWSER_POLICY") && !launched.contains("CORNICE_BROWSER_REQUESTED_ENV"),"real helper retained the wrong launch environment");
        const auto browserPid = greeting["pid"].toInteger();
        std::puts("PASS real helper privately reports the actual application environment without internal control metadata");
        QLocalSocket rejected;
        QObject::connect(&rejected,&QLocalSocket::readyRead,&readScope,[&] { rejectedInput.append(rejected.readAll()); });
        rejected.connectToServer(path); require(rejected.waitForConnected(500),"environment rejection fixture connection failed");
        auto request = QJsonDocument(QJsonObject{{"op","attach"},{"policy","unit"},{"requestedEnvironment",QJsonObject{{"HTTP_PROXY","http://changed-unit-proxy.invalid:8080"}}}}).toJson(QJsonDocument::Compact); request.append('\0'); rejected.write(request); rejected.flush();
        require(spin([&] { return rejectedInput.contains('\0'); }),"real helper environment rejection missing");
        require(!QJsonDocument::fromJson(rejectedInput.left(rejectedInput.indexOf('\0'))).object()["ok"].toBool() && ::kill(browserPid,0) == 0,"environment mismatch replaced or killed the actual helper application");
        send({{"id",1},{"method","Unit.ping"}}); require(spin([&] { return reply(1); }),"environment rejection stole the existing owner control");
        std::puts("PASS real helper refuses an explicit environment mismatch before changing live ownership");
        QLocalSocket mixed;
        mixed.connectToServer(path); require(mixed.waitForConnected(500),"mixed protocol fixture connection failed");
        auto injection = QJsonDocument(QJsonObject{{"op","shutdown"},{"id",7},{"method","Browser.getVersion"}}).toJson(QJsonDocument::Compact); injection.append('\0'); mixed.write(injection); mixed.flush();
        require(spin([&] { return mixed.state() == QLocalSocket::UnconnectedState; }) && runtime.state() == QProcess::Running && ::kill(browserPid,0) == 0,"mixed CDP/private envelope reached helper shutdown");
        send({{"id",6},{"method","Unit.ping"}}); require(spin([&] { return reply(6); }),"mixed protocol rejection changed live owner control");
        std::puts("PASS real helper rejects mixed private-control and CDP envelopes without affecting the live owner");
        send({{"id",2},{"method","Unit.emitSessions"}});
        require(spin([&] { return eventCount == cleanupSessionCount && QFile::exists(emitted); }),"cleanup fixture session emission failed");
        send({{"op","detach"}});
        QElapsedTimer settle; settle.start();
        require(spin([&] { return settle.elapsed() >= 200; },1000),"detach observation timed out");
        require(runtime.state() == QProcess::Running && ::kill(browserPid,0) == 0 && owner.state() == QLocalSocket::ConnectedState,"detach cleanup exceeding the queue budget terminated the application or control transport");
        QFile release(gate); require(release.open(QIODevice::WriteOnly),"cleanup fixture gate failed"); release.write("ready"); release.close();
        require(spin([&] { return QFile::exists(completed); }),"deferred cleanup did not drain every session after pipe progress resumed");
        send({{"id",3},{"method","Unit.ping"}}); require(spin([&] { return reply(3); }),"deferred cleanup did not preserve usable control transport");
        std::puts("PASS detach cleanup exceeding 8 MiB drains in bounded batches and preserves application lifetime");
        send({{"id",4},{"method","Unit.closeRead"}}); require(spin([&] { return reply(4); }),"pipe failure fixture did not close its command reader");
        send({{"id",5},{"method","Unit.ping"}});
        require(spin([&] { return owner.state() == QLocalSocket::UnconnectedState; }),"broken command pipe did not revoke control");
        require(runtime.state() == QProcess::Running && ::kill(browserPid,0) == 0,"broken command pipe terminated the application");
        std::puts("PASS debug pipe failure revokes control and keeps the application alive until explicit close");
        shutdown();
        require(runtime.state() == QProcess::NotRunning && ::kill(browserPid,0) != 0,"explicit close failed to terminate the owned fake application");
        std::puts("PASS explicit close still terminates the owned application after control transport failure");
    } catch (...) { shutdown(); throw; }
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    std::signal(SIGPIPE,SIG_IGN);
    if (app.arguments().contains("--pipe-browser-fixture")) {
        const auto arguments = app.arguments(); const auto index = arguments.indexOf("--pipe-browser-fixture");
        PipeFixture fixture(arguments.value(index+1),arguments.value(index+2),arguments.value(index+3));
        return app.exec();
    }
    QTemporaryDir temporary("/tmp/cornice-browser-startup-XXXXXX");
    require(temporary.isValid(), "temporary runtime failed");
    qputenv("XDG_RUNTIME_DIR", temporary.path().toUtf8());
    auto env = QProcessEnvironment::systemEnvironment(); env.insert("CORNICE_BROWSER_POLICY", "unit");
    const QString proxy = "http://private-unit-proxy.invalid:8080", changedProxy = "http://changed-unit-proxy.invalid:8080";
    env.insert("HTTP_PROXY", proxy);
    env.insert("CORNICE_BROWSER_REQUESTED_ENV", QString::fromUtf8(QJsonDocument(QJsonObject{{"HTTP_PROXY",proxy}}).toJson(QJsonDocument::Compact)));
    int beats = 0, result = 1, phase = 0;
    bool destroyedCallback = false;
    QTimer heartbeat; heartbeat.setInterval(20);
    QObject::connect(&heartbeat, &QTimer::timeout, &app, [&] { ++beats; }); heartbeat.start();
    QTimer deadline; deadline.setSingleShot(true); deadline.start(20000);
    QObject::connect(&deadline, &QTimer::timeout, &app, [&] { qCritical("FAIL async browser unit timed out"); app.quit(); });
    std::unique_ptr<Fixture> fixture;
    std::unique_ptr<BrowserSession> session;
    auto guarded = [&](std::function<void()> action) {
        return [&, action] { try { action(); } catch (const std::exception &failure) { qCritical("FAIL %s", failure.what()); app.quit(); } };
    };
    auto ready = [&](std::function<void(QString)> action) {
        return [&, action](QString error) { try { action(error); } catch (const std::exception &failure) { qCritical("FAIL %s", failure.what()); app.quit(); } };
    };
    auto connectSession = [&](const QProcessEnvironment &environment) {
        QElapsedTimer elapsed; elapsed.start();
        session = std::make_unique<BrowserSession>("unit-browser", QStringList{}, environment, fixture->log,
            [](const QString &) { return true; });
        require(elapsed.elapsed() < 250, "BrowserSession constructor blocked the event loop");
        require(session->starting() && !session->running(), "startup exposed a ready endpoint too early");
        require(!session->matchesLaunchEnvironment({}), "pending startup claimed a known environment");
    };
    auto make = [&](const QString &name, int delay) {
        fixture = std::make_unique<Fixture>(temporary.path(), name, delay);
        connectSession(env);
    };
    std::function<void()> next;
    next = guarded([&] {
        switch (phase++) {
        case 0:
            make("delayed",3500);
            session->whenReady(ready([&](QString error) { require(error.isEmpty() && session->running(), "delayed greeting did not finish startup"); next(); }));
            break;
        case 1: {
            require(beats >= 100, "delayed browser greeting blocked heartbeat processing");
            std::puts("PASS delayed browser startup keeps the event loop and heartbeat running");
            require(fixture->requestedEnvironment == QJsonObject{{"HTTP_PROXY",proxy}}, "explicit environment was lost from the private attach handshake");
            require(session->matchesLaunchEnvironment({}) && session->matchesLaunchEnvironment({{"HTTP_PROXY",proxy}}), "actual helper launch environment was not retained");
            require(!session->matchesLaunchEnvironment({{"HTTP_PROXY",changedProxy}}), "changed override matched an existing browser");
            require(!session->matchesLaunchEnvironment({{"MISSING_PROBE",""}}) && session->matchesLaunchEnvironment({{"EMPTY_PROBE",""}}), "missing variables were confused with empty values");
            require(!session->matchesLaunchEnvironment({{"HTTP_PROXY",42}}), "non-string override matched a browser environment");
            std::puts("PASS private launch environment retains explicit values and rejects changes or missing variables");
            const QUrl url(session->endpoint("unit-token") + "/json/version");
            auto *socket = new QTcpSocket(&app);
            auto bytes = std::make_shared<QByteArray>();
            QObject::connect(socket,&QTcpSocket::connected,socket,[socket,url] { socket->write("GET " + url.path().toUtf8() + " HTTP/1.1\r\nHost: localhost\r\n\r\n"); });
            QObject::connect(socket,&QTcpSocket::readyRead,socket,[socket,bytes] { bytes->append(socket->readAll()); });
            QObject::connect(socket,&QTcpSocket::disconnected,socket,guarded([&,socket,bytes] {
                bytes->append(socket->readAll());
                require(bytes->contains("200 OK") && bytes->contains("Unit browser"), "public discovery did not return the browser version");
                require(!bytes->contains("launchEnvironment") && !bytes->contains("HTTP_PROXY") && !bytes->contains(proxy.toUtf8()), "private environment leaked through public CDP discovery");
                std::puts("PASS public CDP discovery omits private browser launch environment");
                socket->deleteLater();
                QUrl websocketUrl(session->endpoint("unit-token") + "/devtools/browser/cornice"); websocketUrl.setScheme("ws");
                auto *injected = new QWebSocket(QString{},QWebSocketProtocol::VersionLatest,&app);
                QObject::connect(injected,&QWebSocket::connected,injected,[injected] {
                    injected->sendTextMessage(QString::fromUtf8(QJsonDocument(QJsonObject{{"id",91},{"method","Browser.getVersion"},{"op","shutdown"}}).toJson(QJsonDocument::Compact)));
                });
                QObject::connect(injected,&QWebSocket::disconnected,injected,guarded([&,injected,websocketUrl] {
                    require(fixture->shutdownCount == 0 && fixture->attachCount == 1 && session->running(),"public CDP injection reached private helper control");
                    std::puts("PASS public WebSocket CDP cannot inject private helper lifecycle operations");
                    injected->deleteLater();
                    auto *repeated = new QWebSocket(QString{},QWebSocketProtocol::VersionLatest,&app);
                    auto publicFrames = std::make_shared<QByteArray>();
                    QObject::connect(repeated,&QWebSocket::textMessageReceived,repeated,[publicFrames](QString frame) { publicFrames->append(frame.toUtf8()); });
                    QObject::connect(repeated,&QWebSocket::connected,repeated,[repeated] {
                        repeated->sendTextMessage(QString::fromUtf8(QJsonDocument(QJsonObject{{"id",92},{"method","Unit.emitPrivateGreeting"},{"policy","private"},{"launchEnvironment",QJsonObject{{"SECRET","private"}}}}).toJson(QJsonDocument::Compact)));
                    });
                    QObject::connect(repeated,&QWebSocket::disconnected,repeated,guarded([&,repeated,publicFrames] {
                        require(fixture->privateGreetingRequests == 1 && !fixture->invalidCdpEnvelope,"public CDP envelope was not isolated from private runtime fields");
                        require(publicFrames->isEmpty(),"a repeated private greeting was forwarded as a public CDP event");
                        std::puts("PASS repeated private runtime greeting is rejected before public WebSocket event delivery");
                        repeated->deleteLater(); next();
                    }));
                    repeated->open(websocketUrl);
                }));
                injected->open(websocketUrl);
            }));
            socket->connectToHost(url.host(),url.port());
            break;
        }
        case 2:
            session->revoke();
            QTimer::singleShot(100,&app,guarded([&] {
                require(fixture->detachCount > 0, "revocation did not detach helper control");
                session.reset(); fixture->delay = 0;
                auto ordinary = env; ordinary.remove("HTTP_PROXY"); ordinary.insert("CORNICE_BROWSER_REQUESTED_ENV","{}");
                connectSession(ordinary);
                session->whenReady(ready([&](QString error) { require(error.isEmpty() && session->running(), "default reconnection failed to preserve the existing browser"); next(); }));
            }));
            break;
        case 3: {
            require(fixture->requestedEnvironment.isEmpty() && session->matchesLaunchEnvironment({{"HTTP_PROXY",proxy}}), "default reconnect replaced the existing helper environment");
            std::puts("PASS default reconnection preserves the helper environment after Broker replacement");
            session.reset();
            auto changed = env;
            changed.insert("CORNICE_BROWSER_REQUESTED_ENV",QString::fromUtf8(QJsonDocument(QJsonObject{{"HTTP_PROXY",changedProxy}}).toJson(QJsonDocument::Compact)));
            connectSession(changed);
            session->whenReady(ready([&](QString error) {
                require(!error.isEmpty() && !session->running(), "changed environment exposed existing browser control");
                require(!error.contains(proxy) && !error.contains(changedProxy), "environment mismatch diagnostic exposed a private value");
                require(fixture->launchEnvironment["HTTP_PROXY"] == proxy, "rejected attach modified the retained helper environment");
                std::puts("PASS changed explicit environment is refused without exposing values or modifying the helper"); next();
            }));
            break;
        }
        case 4:
            session.reset(); fixture.reset(); make("cancelled",600);
            session->whenReady(ready([&](QString error) {
                require(!error.isEmpty() && !session->running(), "cancelled startup exposed browser control");
                std::puts("PASS startup cancellation returns an explicit error without exposing control"); next();
            }));
            QTimer::singleShot(20,&app,guarded([&] { session->revoke(); }));
            break;
        case 5:
            session.reset(); fixture.reset(); make("destroyed",500);
            session->whenReady([&](QString) { destroyedCallback = true; });
            QTimer::singleShot(20,&app,guarded([&] { session.reset(); }));
            QTimer::singleShot(800,&app,guarded([&] {
                require(!destroyedCallback, "destroyed browser session invoked a callback");
                std::puts("PASS destroyed startup cancels pending callback ownership");
                fixture.reset(); verifyRuntimePipe(temporary.path()); result = 0; app.quit();
            }));
            break;
        }
    });
    QTimer::singleShot(0,&app,next);
    app.exec();
    session.reset(); fixture.reset();
    return result;
}
