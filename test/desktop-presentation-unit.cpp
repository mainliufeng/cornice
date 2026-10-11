// Test-only private Broker transport; exercise the real DesktopPresentation
// QObject and event loop without a compositor, window, GPU or session bus.
#include "DesktopPresentation.hpp"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QLocalServer>
#include <QPointer>
#include <QTemporaryDir>
#include <QThread>
#include <cstdio>
#include <functional>
#include <stdexcept>

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
static void waitFor(const std::function<bool()> &condition) {
    QElapsedTimer deadline;
    deadline.start();
    while (!condition()) {
        require(deadline.elapsed() < 2000, "private presentation transport timed out");
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        QThread::msleep(1);
    }
}
class Fixture : public QObject {
  public:
    QTemporaryDir runtime{"/tmp/cornice-presentation-unit-XXXXXX"};
    QLocalServer server;
    QPointer<QLocalSocket> socket;
    QByteArray input;
    QList<QJsonObject> requests;
    DesktopPresentation view;
    int returned = 0;
    int changes = 0;
    Fixture() {
        require(runtime.isValid(), "private fixture directory failed");
        require(server.listen(runtime.filePath("broker.sock")), "private fixture listen failed");
        connect(&server, &QLocalServer::newConnection, this, [this] {
            socket = server.nextPendingConnection();
            connect(socket, &QLocalSocket::readyRead, this, [this] {
                input += socket->readAll();
                while (input.contains('\n')) {
                    const auto separator = input.indexOf('\n');
                    requests.append(QJsonDocument::fromJson(input.left(separator)).object());
                    input.remove(0, separator + 1);
                }
            });
        });
        connect(&view, &DesktopPresentation::returned, this, [this] { ++returned; });
        connect(&view, &DesktopPresentation::stateChanged, this, [this] { ++changes; });
        require(view.setProperty("socketPath", server.fullServerName()), "socket property unavailable");
        require(view.setProperty("desktop", "old"), "desktop property unavailable");
        require(view.setProperty("active", true), "active property unavailable");
        const auto initial = next();
        require(initial["method"] == "present", "initial request was not present");
        reply(initial, QJsonObject{{"active", true}, {"name", "old"}, {"workspace", "current"}});
        waitFor([this] { return view.state()["name"] == "old"; });
        require(returned == 0, "initial presentation unexpectedly returned");
    }
    QJsonObject next() {
        waitFor([this] { return !requests.isEmpty(); });
        return requests.takeFirst();
    }
    void write(const QJsonObject &value) {
        require(socket && socket->state() == QLocalSocket::ConnectedState, "private socket disconnected");
        socket->write(QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n');
        socket->flush();
    }
    void reply(const QJsonObject &request, const QJsonObject &state) {
        write(QJsonObject{{"id", request["id"]}, {"ok", true}, {"result", state}});
    }
    void fail(const QJsonObject &request) {
        write(QJsonObject{{"id", request["id"]}, {"ok", false}, {"error", "old target no longer exists"}});
    }
};

static void switchedTarget(const QString &change, const QString &oldReply) {
    const bool workspaceOnly = change == "workspace";
    const bool sameTarget = change == "refresh";
    Fixture fixture;
    fixture.view.refreshStatus();
    const auto previous = fixture.next();
    require(previous["method"] == "present-status", "missing pending old-target status");
    fixture.view.takeHandoff("retired-request");
    const QString target = workspaceOnly || sameTarget ? "old" : "new";
    const QString workspace = workspaceOnly ? "slot:2" : "current";
    if (sameTarget) fixture.view.refreshView();
    else require(fixture.view.setProperty(workspaceOnly ? "workspace" : "desktop", workspaceOnly ? workspace : target),
                 "target property unavailable");
    fixture.view.takeHandoff("new-request");
    const int changesBefore = fixture.changes;
    if (oldReply == "error") fixture.fail(previous);
    else fixture.reply(previous, QJsonObject{{"active", oldReply == "active"}, {"name", "stale"}});
    waitFor([&] { return fixture.returned != 0 || !fixture.requests.isEmpty(); });
    require(fixture.returned == 0, "stale reply closed the newly selected target");
    const auto present = fixture.next();
    require(fixture.changes == changesBefore, "stale reply overwrote presentation state");
    require(fixture.view.property("error").toString().isEmpty(), "stale error leaked into new target");
    require(present["method"] == "present", "new target was not presented after draining old RPC");
    const auto params = present["params"].toObject();
    require(params["name"] == target && params["workspace"] == workspace, "new request used stale target");
    require(params["requestId"].toString().isEmpty(), "presentation inherited stale takeover request");
    fixture.reply(present, QJsonObject{{"active", true}, {"name", target}, {"workspace", workspace}});
    const auto takeover = fixture.next();
    require(takeover["method"] == "takeover", "new control intent was lost during target switch");
    require(takeover["params"].toObject()["requestId"] == "new-request", "old control intent replaced new handoff");
    fixture.reply(takeover, QJsonObject{{"active", true}, {"name", target}, {"workspace", workspace}, {"humanControl", true}});
    waitFor([&] { return fixture.view.humanControl(); });
    require(fixture.view.state()["name"] == target && fixture.view.state()["workspace"] == workspace,
            "fresh target state was not applied");
    // Duplicate replies from an already consumed request must also be inert.
    fixture.fail(takeover);
    bool drained = false;
    QTimer::singleShot(20, &fixture, [&] { drained = true; });
    waitFor([&] { return drained; });
    require(fixture.returned == 0, "duplicate consumed reply closed a valid view");
    fixture.view.refreshStatus();
    const auto finalStatus = fixture.next();
    require(fixture.returned == 0, "duplicate consumed reply closed a valid view");
    fixture.reply(finalStatus, QJsonObject{{"active", false}});
    waitFor([&] { return fixture.returned == 1; });
    std::printf("PASS %s change drains stale %s without losing new handoff or normal return\n",
                change.toUtf8().constData(), oldReply.toUtf8().constData());
}
static void disabledTarget() {
    Fixture fixture;
    fixture.view.refreshStatus();
    const auto previous = fixture.next();
    require(fixture.view.setProperty("active", false), "active property unavailable");
    require(fixture.view.state().isEmpty(), "disabled view retained active state");
    require(fixture.view.setProperty("desktop", "reopened"), "desktop property unavailable");
    require(fixture.view.setProperty("active", true), "active property unavailable");
    const auto reopened = fixture.next();
    // The disconnected connection's old request can arrive on the new socket.
    fixture.fail(previous);
    fixture.reply(reopened, QJsonObject{{"active", true}, {"name", "reopened"}});
    waitFor([&] { return fixture.view.state()["name"] == "reopened"; });
    require(fixture.returned == 0, "closed connection's old reply affected reopened view");
    fixture.view.refreshStatus();
    fixture.fail(fixture.next());
    waitFor([&] { return fixture.returned == 1; });
    require(fixture.view.property("error").toString() == "old target no longer exists",
            "current target error was incorrectly discarded");
    std::puts("PASS reconnect discards old response IDs and retains current target errors");
}
static void endpointIdentity() {
    QTemporaryDir runtime("/tmp/cornice-endpoint-unit-XXXXXX");
    require(runtime.isValid(), "endpoint runtime fixture failed");
    const auto previous = qgetenv("XDG_RUNTIME_DIR"); qputenv("XDG_RUNTIME_DIR", runtime.path().toUtf8());
    DesktopPresentation resolver;
    const auto endpoint = resolver.endpoint("test");
    const auto invalid = resolver.endpoint("..");
    qputenv("XDG_RUNTIME_DIR", previous);
    require(endpoint["socket"] == runtime.path() + "/cornice/ipc-9f86d081884c7d659a2feaa0c55ad015/desktop.sock" && !endpoint.contains("error"),
            "native QML resolver differs from fixed SHA256 endpoint identity");
    require(invalid["error"].toString().contains("instance") && !invalid.contains("socket"), "native QML resolver accepted non-instance path");
    std::puts("PASS native QML endpoint resolver matches fixed SHA256 identity and returns explicit invalid-instance diagnostic");
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        for (const auto &response : {QString("inactive"), QString("error"), QString("active")}) {
            for (const auto &change : {QString("desktop"), QString("workspace"), QString("refresh")})
                switchedTarget(change, response);
        }
        disabledTarget();
        endpointIdentity();
        return 0;
    } catch (const std::exception &failure) {
        std::fprintf(stderr, "FAIL %s\n", failure.what());
        return 1;
    }
}
