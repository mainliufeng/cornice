#include "LocalIpcServer.hpp"

#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QProcess>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QTimer>
#include <algorithm>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <sys/stat.h>
#include <vector>

namespace {
void require(bool condition, const char* reason) {
    if (!condition) throw std::runtime_error(reason);
}
void drain() {
    QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    // A manual test pump must explicitly perform the deferred deletions that
    // the application's ordinary outer event loop delivers on every turn.
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
}
void until(const std::function<bool()>& condition, const char* reason, int timeout = 5000) {
    QElapsedTimer timer;
    timer.start();
    while (!condition()) {
        require(timer.elapsed() < timeout, reason);
        drain();
    }
}
void connectTo(QLocalSocket& socket, const QString& path) {
    socket.connectToServer(path);
    until([&] { return socket.state() == QLocalSocket::ConnectedState; }, "client did not connect");
}
void send(QLocalSocket& socket, int sequence) {
    const auto data = QJsonDocument(QJsonObject{{"seq", sequence}}).toJson(QJsonDocument::Compact) + '\n';
    require(socket.write(data) == data.size(), "request write failed");
    socket.flush();
}
void response(QLocalSocket& socket, int sequence) {
    until([&] { return socket.canReadLine(); }, "request did not receive a response");
    const auto result = QJsonDocument::fromJson(socket.readLine()).object();
    require(result.value("ok").toBool() && result.value("result").toInt() == sequence,
            "QML request/response changed content");
}
qint64 rssKiB() {
    QFile status(QStringLiteral("/proc/self/status"));
    require(status.open(QIODevice::ReadOnly), "cannot inspect pressure process memory");
    const auto match = QRegularExpression(QStringLiteral("VmRSS:\\s+(\\d+)"))
                           .match(QString::fromUtf8(status.readAll()));
    require(match.hasMatch(), "RSS measurement missing");
    return match.captured(1).toLongLong();
}
}

int main(int argc, char** argv) {
    QGuiApplication application(argc, argv);
    if (argc == 3 && QString::fromLocal8Bit(argv[1]) == QStringLiteral("--crash-listener")) {
        LocalIpcServer child;
        child.setPath(QString::fromLocal8Bit(argv[2]));
        child.setActive(true);
        if (!child.listening()) return 2;
        std::cout << "READY" << std::endl;
        return application.exec();
    }
    try {
        const int total = argc > 1 ? QString::fromLocal8Bit(argv[1]).toInt() : 160000;
        require(total >= 1000 && total <= 1000000, "pressure count must be 1000..1000000");
        QTemporaryDir directory(QStringLiteral("/tmp/cornice-ipc-XXXXXX"));
        require(directory.isValid(), "private test directory unavailable");
        const auto path = directory.path() + QStringLiteral("/shell.sock");
        QQmlEngine engine;
        engine.addImportPath(QStringLiteral(CORNICE_TEST_QML_IMPORT_PATH));
        engine.rootContext()->setContextProperty(QStringLiteral("testSocketPath"), path);
        QQmlComponent component(&engine);
        component.setData(R"QML(
import QtQml
import Cornice.Platform 1.0
LocalIpcServer {
    path: testSocketPath
    active: true
    onRequest: (connection, line) => {
        const request = JSON.parse(line)
        if (request.large) connection.write("x".repeat(2097153))
        else connection.write(JSON.stringify({ok: true, result: request.seq}) + "\n")
        connection.flush()
    }
}
)QML", QUrl(QStringLiteral("file:///cornice-local-ipc-test.qml")));
        if (component.isError()) std::cerr << component.errorString().toStdString();
        std::unique_ptr<QObject> object(component.create());
        require(bool(object), "real Cornice.Platform QML component did not load");
        auto* server = qobject_cast<LocalIpcServer*>(object.get());
        require(server && server->active() && server->listening(), "QML listener did not bind");
        struct stat endpoint {};
        require(::stat(QFile::encodeName(path).constData(), &endpoint) == 0 &&
                (endpoint.st_mode & 0777) == 0600, "socket is not user-only");

        // A second listener must neither replace nor remove the original live
        // pathname, including after the failing listener is destroyed.
        {
            LocalIpcServer conflict;
            conflict.setPath(path);
            conflict.setActive(true);
            require(!conflict.listening() && !conflict.errorString().isEmpty(), "duplicate bind succeeded");
        }
        QLocalSocket persistent;
        connectTo(persistent, path);
        send(persistent, -1);
        response(persistent, -1);
        until([&] { return server->activeConnectionCount() == 1; }, "persistent client not retained");

        const auto objectsPerConnection = server->findChildren<QObject*>().size();
        require(objectsPerConnection >= 2, "persistent socket ownership missing");

        // Split/coalesced UTF-8 frames on one long-lived connection use the same
        // actual QML dispatcher as short-lived maintenance clients.
        persistent.write("{\"seq\":-2");
        persistent.flush();
        drain();
        require(!persistent.canReadLine(), "incomplete frame was dispatched");
        persistent.write("}\n{\"seq\":-3}\r\n");
        persistent.flush();
        response(persistent, -2);
        response(persistent, -3);

        bool unicodeReceived = false;
        QObject::connect(server, &LocalIpcServer::request, [&](QObject*, const QString& line) {
            if (QJsonDocument::fromJson(line.toUtf8()).object().value("label").toString() ==
                QString::fromUtf8("中文🍊")) unicodeReceived = true;
        });
        const auto unicode = QByteArray("{\"seq\":-6,\"label\":\"") + QByteArray("中文🍊") + QByteArray("\"}\n");
        const auto split = unicode.indexOf(QByteArray("中文")) + 1;
        persistent.write(unicode.left(split));
        persistent.flush();
        drain();
        persistent.write(unicode.mid(split));
        persistent.flush();
        response(persistent, -6);
        require(unicodeReceived, "split UTF-8 frame did not preserve characters");
        QByteArray coalesced;
        for (int index = 0; index < 300; ++index)
            coalesced += QJsonDocument(QJsonObject{{"seq", index + 2000000}}).toJson(QJsonDocument::Compact) + '\n';
        persistent.write(coalesced);
        persistent.flush();
        for (int index = 0; index < 300; ++index) response(persistent, index + 2000000);
        std::cout << "PASS split Unicode and coalesced frames across dispatch turns\n";

        int ticks = 0;
        QTimer responsiveness;
        QObject::connect(&responsiveness, &QTimer::timeout, [&] { ++ticks; });
        responsiveness.start(1);
        qsizetype peakWrappers = 1;
        qsizetype peakSockets = 1;
        qsizetype peakObjects = 2;
        qint64 warmedRss = 0;
        QElapsedTimer pressure;
        pressure.start();
        for (int offset = 0; offset < total; offset += 64) {
            const int count = std::min(64, total - offset);
            std::vector<std::unique_ptr<QLocalSocket>> clients;
            for (int index = 0; index < count; ++index) {
                auto client = std::make_unique<QLocalSocket>();
                connectTo(*client, path);
                send(*client, offset + index);
                clients.push_back(std::move(client));
            }
            until([&] { return std::all_of(clients.begin(), clients.end(), [](const auto& client) {
                return client->canReadLine();
            }); }, "pressure batch did not receive responses");
            peakWrappers = std::max(peakWrappers, server->findChildren<LocalIpcConnection*>().size());
            peakSockets = std::max(peakSockets, server->findChildren<QLocalSocket*>().size());
            peakObjects = std::max(peakObjects, server->findChildren<QObject*>().size());
            require(server->activeConnectionCount() <= count + 1, "active connections exceeded batch size");
            for (int index = 0; index < count; ++index) {
                response(*clients[index], offset + index);
                clients[index]->disconnectFromServer();
            }
            until([&] {
                return server->activeConnectionCount() == 1 &&
                    server->findChildren<LocalIpcConnection*>().size() == 1 &&
                    server->findChildren<QLocalSocket*>().size() == 1 &&
                    server->findChildren<QObject*>().size() == objectsPerConnection;
            }, "disconnected wrappers or sockets accumulated while a client remained connected");
            if (offset >= 8192 && warmedRss == 0) warmedRss = rssKiB();
            if (offset % 4096 == 0) {
                send(persistent, -offset - 10);
                response(persistent, -offset - 10);
            }
        }
        require(peakWrappers <= 65 && peakSockets <= 65 && peakObjects <= 65 * objectsPerConnection,
                "QObject ownership exceeded bounded active sockets");
        require(ticks > 10, "listener starved the event loop under churn");
        if (warmedRss > 0) require(rssKiB() - warmedRss < 16384, "memory grew over 16 MiB after warm-up");
        send(persistent, -4);
        response(persistent, -4);
        std::cout << "PASS real QML persistent-client pressure: " << total << " connections, "
                  << pressure.elapsed() << " ms, peak wrappers=" << peakWrappers
                  << ", sockets=" << peakSockets << ", objects=" << peakObjects
                  << ", final wrappers=1, final objects=" << server->findChildren<QObject*>().size() << ", RSS KiB=" << rssKiB() << '\n';

        int transportErrors = 0;
        QObject::connect(server, &LocalIpcServer::connectionError, [&](const QString&) { ++transportErrors; });
        for (const auto& data : {QByteArray(LocalIpcConnection::MaxFrameBytes + 1, 'x'),
                                QByteArray("\xff\n", 2), QByteArray("\xe2\n", 2), QByteArray("{\"large\":true}\n")}) {
            QLocalSocket invalid;
            connectTo(invalid, path);
            invalid.write(data);
            invalid.flush();
            until([&] { return invalid.state() == QLocalSocket::UnconnectedState; },
                  "invalid or oversized frame/response was not disconnected");
            until([&] { return server->activeConnectionCount() == 1; }, "bounded-error client leaked");
        }
        require(transportErrors == 4, "actual bounded transport errors were not surfaced");
        send(persistent, -5);
        response(persistent, -5);
        std::cout << "PASS UTF-8/frame/output bounds and healthy persistent client\n";

        // The bound applies to persistent clients too; accepting one too many
        // rejects only that client and does not disturb the established ones.
        std::vector<std::unique_ptr<QLocalSocket>> saturation;
        for (int index = 1; index < LocalIpcServer::MaxConnections; ++index) {
            auto client = std::make_unique<QLocalSocket>();
            connectTo(*client, path);
            send(*client, index);
            response(*client, index);
            saturation.push_back(std::move(client));
        }
        require(server->activeConnectionCount() == LocalIpcServer::MaxConnections, "connection bound not exercised");
        QLocalSocket excess;
        connectTo(excess, path);
        until([&] { return excess.state() == QLocalSocket::UnconnectedState; }, "excess connection was not rejected");
        require(server->activeConnectionCount() == LocalIpcServer::MaxConnections,
                "excess client displaced an established client");
        saturation.clear();
        until([&] { return server->activeConnectionCount() == 1; }, "saturation clients leaked");
        std::cout << "PASS active connection bound preserves established clients\n";

        server->setActive(false);
        until([&] { return persistent.state() == QLocalSocket::UnconnectedState; }, "deactivation left client open");
        drain();
        require(!server->listening() && server->activeConnectionCount() == 0 &&
                server->findChildren<LocalIpcConnection*>().isEmpty() && !QFile::exists(path),
                "deactivation retained sockets or endpoint");
        auto replacement = std::make_unique<LocalIpcServer>();
        replacement->setPath(path);
        replacement->setActive(true);
        require(replacement->listening(), "replacement could not bind stopped endpoint");
        object.reset();
        require(QFile::exists(path) && replacement->listening(), "old server destruction unlinked replacement");
        replacement.reset();
        require(!QFile::exists(path), "replacement did not clean endpoint");
        std::cout << "PASS exclusive bind, deactivation, old-generation destruction and endpoint handoff\n";

        // A legacy listener has no native lock. Live probing must preserve it,
        // and a stale regular file/symlink must never be silently removed.
        QLocalServer legacy;
        require(legacy.listen(path), "legacy listener did not bind");
        {
            LocalIpcServer conflict;
            conflict.setPath(path);
            conflict.setActive(true);
            until([&] { return !conflict.errorString().isEmpty(); }, "legacy ownership probe did not complete");
            require(!conflict.listening() && QFile::exists(path), "legacy live endpoint was replaced");
            QLocalSocket legacyClient;
            connectTo(legacyClient, path);
            until([&] { return legacy.hasPendingConnections(); }, "legacy listener stopped responding");
        }
        legacy.close();
        QFile regular(path);
        require(regular.open(QIODevice::WriteOnly), "regular endpoint fixture unavailable");
        regular.write("preserve me");
        regular.close();
        {
            LocalIpcServer invalid;
            invalid.setPath(path);
            invalid.setActive(true);
            require(!invalid.listening() && !invalid.errorString().isEmpty(), "regular file accepted as endpoint");
        }
        require(regular.open(QIODevice::ReadOnly) && regular.readAll() == QByteArray("preserve me"),
                "regular endpoint was removed or changed");
        regular.close();
        require(regular.remove(), "could not retire regular fixture");
        const auto target = directory.path() + QStringLiteral("/target");
        QFile targetFile(target);
        require(targetFile.open(QIODevice::WriteOnly), "symlink target fixture unavailable");
        targetFile.close();
        require(QFile::link(target, path), "symlink endpoint fixture unavailable");
        {
            LocalIpcServer invalid;
            invalid.setPath(path);
            invalid.setActive(true);
            require(!invalid.listening() && !invalid.errorString().isEmpty(), "symlink accepted as endpoint");
        }
        require(QFileInfo(path).isSymbolicLink() && QFile::exists(target), "symlink endpoint changed");
        require(QFile::remove(path), "could not retire symlink fixture");
        std::cout << "PASS legacy live listener and unrelated filesystem entries are preserved\n";

        // SIGKILL leaves both the real socket inode and real lock behind. The
        // replacement must recover them without an updater-specific cleanup.
        QProcess crashed;
        crashed.start(QCoreApplication::applicationFilePath(), {QStringLiteral("--crash-listener"), path});
        require(crashed.waitForStarted(5000) && crashed.waitForReadyRead(5000) &&
                crashed.readAllStandardOutput().contains("READY"), "crash child did not listen");
        require(QFile::exists(path) && QFile::exists(path + QStringLiteral(".lock")), "crash fixture has no endpoint/lock");
        crashed.kill();
        require(crashed.waitForFinished(5000), "crash child did not terminate");
        {
            LocalIpcServer recovered;
            recovered.setPath(path);
            recovered.setActive(true);
            until([&] { return recovered.listening() || !recovered.errorString().isEmpty(); }, "stale recovery stalled");
            require(recovered.listening(), "dead listener endpoint/lock could not recover");
            QLocalSocket client;
            connectTo(client, path);
            client.write("{}\n");
            client.flush();
            bool received = false;
            QObject::connect(&recovered, &LocalIpcServer::request, [&](QObject*, const QString& line) {
                received = line == QStringLiteral("{}");
            });
            until([&] { return received; }, "recovered listener did not dispatch requests");
        }
        require(!QFile::exists(path) && !QFile::exists(path + QStringLiteral(".lock")),
                "recovered listener did not retire endpoint/lock");
        std::cout << "PASS SIGKILL stale socket/lock recovery and responsive replacement\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
