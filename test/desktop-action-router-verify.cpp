#include "DesktopActionRouter.hpp"
#include <QCoreApplication>
#include <QDBusAbstractInterface>
#include <QDBusConnection>
#include <QDBusContext>
#include <QTemporaryDir>
#include <QDir>
#include <QFile>
#include <QEventLoop>
#include <QTimer>
#include <stdexcept>
#include <iostream>

static QStringList events;
class TokenItem : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierItem")
public:
    QString identity;
public slots:
    void ProvideXdgActivationToken(const QString& token) { events << identity + ":token:" + token; }
    void Activate(int, int) { events << identity + ":activate"; }
    void SecondaryActivate(int, int) { events << identity + ":secondary"; }
    void Scroll(int delta, const QString& orientation) { events << identity + ":scroll:" + QString::number(delta) + ":" + orientation; }
};
class PlainItem : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierItem")
public slots:
    void Activate(int, int) { events << "plain:activate"; }
    void SecondaryActivate(int, int) { events << "plain:secondary"; }
    void Scroll(int delta, const QString& orientation) { events << "plain:scroll:" + QString::number(delta) + ":" + orientation; }
};
class DeniedItem : public QObject, protected QDBusContext {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierItem")
public slots:
    void Activate(int, int) {
        events << "denied:attempt";
        sendErrorReply(QDBusError::AccessDenied, "denied by fixture");
    }
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
        TokenItem first, second; PlainItem plain; DeniedItem denied;
        first.identity = "first"; second.identity = "second";
        require(bus.registerObject("/first", &first, QDBusConnection::ExportAllSlots)
                && bus.registerObject("/second", &second, QDBusConnection::ExportAllSlots)
                && bus.registerObject("/plain", &plain, QDBusConnection::ExportAllSlots)
                && bus.registerObject("/denied", &denied, QDBusConnection::ExportAllSlots), "export synthetic SNI services");
        QObject a, b, unsupported, accessDenied;
        Handle ah(&a, bus.baseService(), "/first"), bh(&b, bus.baseService(), "/second"),
            ph(&unsupported, bus.baseService(), "/plain"), dh(&accessDenied, bus.baseService(), "/denied");
        MenuEntry menu;
        QObject::connect(&menu, &MenuEntry::triggered, [&] { events << "second:menu"; });
        QTemporaryDir tools;
        QFile ctl(tools.path() + "/hyprctl");
        require(ctl.open(QIODevice::WriteOnly), "private source validator fixture");
        ctl.write("#!/usr/bin/python3\nimport json,sys\nassert sys.argv[1:5]==['-j','--','seat','validate-context']\nsource=sys.argv[-1]\nprint(json.dumps({'valid':source!='expired', 'name':'A' if source in ('agent-context','takeover') else 'main', 'seatId':'seat-A', 'generation':'7', 'mode':'readonly' if source=='read-only' else 'control'}))\n");
        ctl.close(); ctl.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        qputenv("PATH", tools.path().toUtf8() + ":" + qgetenv("PATH"));
        QDir().mkpath(tools.path() + "/bin");
        QFile broker(tools.path() + "/bin/cornice-desktop");
        require(broker.open(QIODevice::WriteOnly), "private takeover validator fixture");
        broker.write("#!/usr/bin/python3\nimport pathlib,sys\nassert sys.argv[1:]==['state','A']\nprint((pathlib.Path(__file__).parent.parent/'state.json').read_text())\n");
        broker.close(); broker.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        qputenv("CORNICE_PATH", tools.path().toUtf8());
        const auto takeoverState = [&](const QByteArray& value) {
            QFile state(tools.path() + "/state.json");
            require(state.open(QIODevice::WriteOnly | QIODevice::Truncate), "write current takeover state");
            state.write(value);
        };
        const QVariantMap human{{"desktop", "main"}, {"context", "human-valid"}};
        const QVariantMap agent{{"desktop", "A"}, {"context", "agent-context"}};
        DesktopActionRouter router;
        const auto invoke = [&](QObject* item, const QString& method, QVariantMap context,
                                QObject* entry = nullptr, int delta = 0) {
            QEventLoop loop; bool success = false, completed = false;
            QString request;
            auto connection = QObject::connect(&router, &DesktopActionRouter::actionFinished,
                [&](const QString& id, bool ok, const QString&) {
                    if (id == request) { completed = true; success = ok; loop.quit(); }
                });
            context.insert("token", "fixture-token");
            request = router.invokeTray(item, entry, method, context, delta);
            QTimer::singleShot(4500, &loop, &QEventLoop::quit);
            loop.exec(); QObject::disconnect(connection);
            require(completed, "bounded asynchronous completion");
            return success;
        };
        for (auto* item : {&a, &unsupported}) {
            for (const auto& method : {"Activate", "SecondaryActivate", "Scroll", "Menu"})
                require(!invoke(item, method, agent, &menu), "Agent action is refused before setter, menu signal or ordinary dispatch");
        }
        require(events.isEmpty(), "optional setter presence never enables an unbound Agent request");
        // Independent router instances model independent desktop Shells. This
        // catches the previous per-object lock: both calls formerly succeeded
        // while a shared producer could consume B for both actions.
        {
            DesktopActionRouter shellA, shellB;
            QEventLoop loop; int completed = 0, succeeded = 0;
            const auto finish = [&](const QString&, bool ok, const QString&) {
                ++completed; succeeded += ok; if (completed == 2) loop.quit();
            };
            QObject::connect(&shellA, &DesktopActionRouter::actionFinished, finish);
            QObject::connect(&shellB, &DesktopActionRouter::actionFinished, finish);
            shellA.invokeTray(&a, nullptr, "Activate", {{"desktop", "A"}, {"context", "A"}, {"token", "A"}});
            shellB.invokeTray(&a, nullptr, "Activate", {{"desktop", "B"}, {"context", "B"}, {"token", "B"}});
            QTimer::singleShot(4500, &loop, &QEventLoop::quit); loop.exec();
            require(completed == 2 && succeeded == 0 && events.isEmpty(), "concurrent Shells cannot set or consume each other's Agent token");
        }
        require(!invoke(&a, "Activate", {{"desktop", "main"}})
                && !invoke(&a, "Activate", {{"desktop", "main"}, {"context", "agent-context"}})
                && !invoke(&a, "Activate", {{"desktop", "main"}, {"context", "expired"}})
                && !invoke(&a, "Activate", {{"desktop", "main"}, {"context", "read-only"}})
                && events.isEmpty(), "missing, relabeled, expired and read-only sources cannot use human compatibility");
        require(invoke(&a, "Activate", human)
                && invoke(&b, "SecondaryActivate", human)
                && invoke(&b, "Menu", human, &menu)
                && invoke(&a, "Scroll", human, nullptr, -120), "validated human compatibility keeps exact ordinary actions");
        require(events == QStringList{"first:activate", "second:secondary", "second:menu", "first:scroll:-120:vertical"},
                "human dispatch neither calls a global setter nor confuses duplicate item identities");
        MenuEntry legacyMenu;
        QObject::connect(&legacyMenu, &MenuEntry::triggered, [&] { events << "plain:menu"; });
        require(invoke(&unsupported, "Activate", human)
                && invoke(&unsupported, "SecondaryActivate", human)
                && invoke(&unsupported, "Scroll", human, nullptr, -120)
                && invoke(&unsupported, "Menu", human, &legacyMenu), "tokenless human tray compatibility remains available");
        const auto before = events.size();
        require(!invoke(&accessDenied, "Activate", human) && events.mid(before) == QStringList{"denied:attempt"},
                "ordinary action authorization error is returned without a retry or fallback");
        require(!invoke(&b, "Menu", human, &second), "non-menu objects cannot dispatch a signal");
        const QVariantMap takeover{{"desktop", "A"}, {"context", "takeover"}, {"humanTakeover", true}};
        const auto start = events.size();
        for (const auto& state : {
                R"({"name":"A","controlMode":"agent","seatId":"seat-A","generation":"7"})",
                R"({"name":"A","controlMode":"paused","seatId":"seat-A","generation":"7"})",
                R"({"name":"B","controlMode":"human","seatId":"seat-A","generation":"7"})",
                R"({"name":"A","controlMode":"human","seatId":"other-seat","generation":"7"})",
                R"({"name":"A","controlMode":"human","seatId":"seat-A","generation":"8"})"}) {
            takeoverState(state);
            require(!invoke(&b, "Menu", takeover, &menu) && events.size() == start,
                    "a forged human flag, ended takeover or changed seat cannot dispatch any menu action");
        }
        takeoverState(R"({"name":"A","controlMode":"human","seatId":"seat-A","generation":"7"})");
        require(!invoke(&b, "Menu", {{"desktop", "A"}, {"context", "human-valid"}, {"humanTakeover", true}}, &menu)
                && events.size() == start, "primary context cannot be relabeled as secondary human takeover");
        require(invoke(&b, "Menu", takeover, &menu) && invoke(&a, "Activate", takeover)
                && invoke(&b, "SecondaryActivate", takeover) && invoke(&a, "Scroll", takeover, nullptr, -120),
                "verified physical takeover supports menus, activation and scrolling on the selected desktop");
        require(events.mid(start) == QStringList{"second:menu", "first:activate", "second:secondary", "first:scroll:-120:vertical"},
                "human takeover dispatch preserves exact duplicate item identity");
        require(!events.join(',').contains(":token:"), "no invocation writes a process-global activation token");
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << std::endl; return 1; }
}
#include "desktop-action-router-verify.moc"
