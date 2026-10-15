#include "DesktopActionRouter.hpp"
#include <QCoreApplication>
#include <QDBusAbstractInterface>
#include <QDBusConnection>
#include <QEventLoop>
#include <QTimer>
#include <QDebug>
#include <stdexcept>
#include <iostream>
#include <QProcess>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <functional>

static QStringList events;
class TokenItem : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierItem")
public:
    QString identity, token;
    std::function<void()> action;
public slots:
    void ProvideXdgActivationToken(const QString& token) { events << identity + ":token:" + token; this->token = token; }
    void Activate(int, int) { events << identity + ":activate"; if (action) action(); }
    void SecondaryActivate(int, int) { events << identity + ":secondary"; }
    void Scroll(int delta, const QString& orientation) { events << identity + ":scroll:" + QString::number(delta) + ":" + orientation; }
};
class PlainItem : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierItem")
public slots:
    void Activate(int, int) { events << "unsupported:activate"; }
};
class MenuEntry : public QObject {
    Q_OBJECT
signals:
    void triggered();
};
class Handle : public QDBusAbstractInterface {
public:
    Handle(QObject* parent, const QString& service, const QString& path)
        : QDBusAbstractInterface(service, path, "org.kde.StatusNotifierItem", QDBusConnection::sessionBus(), parent) {}
};
static void require(bool ok, const char* description) {
    if (!ok) throw std::runtime_error(description);
    std::cout << "PASS " << description << std::endl;
}
int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    try {
        auto bus = QDBusConnection::sessionBus();
        require(bus.isConnected() && bus.registerService("org.cornice.RouterTest"), "private bus registration");
        TokenItem first, second; PlainItem plain;
        first.identity = "first"; second.identity = "second";
        require(bus.registerObject("/first", &first, QDBusConnection::ExportAllSlots)
                && bus.registerObject("/second", &second, QDBusConnection::ExportAllSlots)
                && bus.registerObject("/plain", &plain, QDBusConnection::ExportAllSlots), "export synthetic SNI services");
        // These represent two registrations with identical logical IDs. The
        // router receives exact QObject handles and never searches by ID.
        QObject a, b, unsupported;
        Handle ah(&a, bus.baseService(), "/first"), bh(&b, bus.baseService(), "/second"), ph(&unsupported, bus.baseService(), "/plain");
        MenuEntry menu;
        QObject::connect(&menu, &MenuEntry::triggered, [&] { events << "second:menu"; });
        DesktopActionRouter router;
        const auto invoke = [&](QObject* item, const QString& method, const QString& token, QObject* entry = nullptr, int delta = 0) {
            QEventLoop loop; bool success = false, completed = false;
            QString request;
            auto connection = QObject::connect(&router, &DesktopActionRouter::actionFinished,
                [&](const QString& id, bool ok, const QString&) {
                    if (id == request) { completed = true; success = ok; loop.quit(); }
                });
            request = router.invokeTray(item, entry, method, {{"token", token}}, delta);
            QTimer::singleShot(4500, &loop, &QEventLoop::quit);
            loop.exec(); QObject::disconnect(connection);
            require(completed, "bounded asynchronous completion");
            return success;
        };
        require(invoke(&a, "Activate", "human"), "primary activation");
        require(invoke(&b, "SecondaryActivate", "agent-A"), "Agent A secondary action");
        require(invoke(&b, "Menu", "agent-B", &menu), "generic menu signal fallback");
        require(invoke(&a, "Scroll", "agent-B", nullptr, -120), "scroll keeps exact delta");
        require(events == QStringList{"first:token:human", "first:activate", "second:token:agent-A", "second:secondary",
                                     "second:token:agent-B", "second:menu", "first:token:agent-B", "first:scroll:-120:vertical"},
                "token precedes every exact-owner action and duplicate IDs cannot collide");
        require(!invoke(&unsupported, "Activate", "agent-A") && events.size() == 8,
                "unsupported token extension fails closed without sending Activate");
        require(!invoke(&b, "Menu", "agent-A", &second), "non-menu objects cannot dispatch fallback");
        if (!qEnvironmentVariable("CORNICE_ROUTE_E2E_CLIENT").isEmpty()) {
            require(qEnvironmentVariable("HYPRLAND_TEST_SANDBOX") == "1", "real compositor tests require the private sandbox");
            const auto ctl = [](const QStringList& arguments) {
                QProcess process; process.start("hyprctl", arguments);
                if (!process.waitForFinished(4000) || process.exitCode()) throw std::runtime_error("private IPC failed");
                const auto output = process.readAllStandardOutput();
                const auto document = QJsonDocument::fromJson(output);
                if (document.isNull()) throw std::runtime_error(("Invalid private IPC JSON: " + output).constData());
                return document;
            };
            QProcess client;
            client.setProgram(qEnvironmentVariable("CORNICE_ROUTE_E2E_CLIENT")); client.start();
            require(client.waitForStarted(3000) && client.waitForReadyRead(3000) && client.readLine().trimmed() == "ready", "shared service Wayland client starts");
            const auto command = [&](const QString& value) {
                client.write(value.toUtf8() + "\n"); client.waitForBytesWritten(1000);
                if (!client.waitForReadyRead(3000) || !client.readLine().startsWith("done")) throw std::runtime_error("Wayland command failed");
            };
            const auto prepare = [&](const QString& desktop) {
                const auto state = ctl({"-j", "seat", "state", desktop}).object();
                QEventLoop loop; QVariantMap context; QString error, request;
                auto connection = QObject::connect(&router, &DesktopActionRouter::prepared,
                    [&](const QString& id, const QVariantMap& value, const QString& failure) {
                        if (id == request) { context = value; error = failure; loop.quit(); }
                    });
                request = router.prepare(desktop, state["seatId"].toString(), state["generation"].toVariant().toString(), state["workspace"].toString());
                QTimer::singleShot(4500, &loop, &QEventLoop::quit); loop.exec(); QObject::disconnect(connection);
                if (!error.isEmpty()) std::cerr << desktop.toStdString() << ": " << error.toStdString() << "; state=" << QJsonDocument(state).toJson(QJsonDocument::Compact).constData() << std::endl;
                require(error.isEmpty() && !context.value("token").toString().isEmpty(), "real source snapshot yields an activation token");
                return context.value("token").toString();
            };
            const QStringList desktops{"main", "A", "B"};
            for (int index = 0; index < desktops.size(); ++index) {
                const auto desktop = desktops[index];
                const auto title = "route-sni-" + desktop;
                first.action = [&, index, title] {
                    command("create " + title);
                    command("activate " + first.token + " " + QString::number(index));
                    command("map " + QString::number(index));
                };
                require(invoke(&a, "Activate", prepare(desktop)), "real SNI action forwards its invocation token before map");
                const auto expected = desktop == "main" ? QString{"1"} : "route-" + desktop;
                bool found = false;
                for (const auto& value : ctl({"-j", "clients"}).array()) {
                    const auto window = value.toObject();
                    if (window["title"] == title) found = window["workspace"].toObject()["name"] == expected;
                }
                require(found, "real SNI-created window has its source workspace on first publication");
            }
            first.action = [&] { command("activate " + first.token + " 0"); };
            require(invoke(&a, "Activate", prepare("A")), "warm SNI activation uses a fresh A token");
            bool warm = false;
            for (const auto& value : ctl({"-j", "clients"}).array()) {
                const auto window = value.toObject();
                if (window["title"] == "route-sni-main") warm = window["workspace"].toObject()["name"] == "route-A";
            }
            require(warm, "existing shared-service root follows the fresh activation source");
            client.kill(); client.waitForFinished(3000);
        }
        qInfo() << "DesktopActionRouter verification complete";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << std::endl; return 1; }
}
#include "desktop-action-router-verify.moc"
