#include "DesktopActionRouter.hpp"
#include <QCoreApplication>
#include <QDBusAbstractInterface>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVirtualObject>
#include <QDebug>
#include <QEventLoop>
#include <QTimer>
#include <QProcess>
#include <iostream>

// Regression fixture: the pre-fix router could accept both requests while this
// legal shared producer used B for both actions. A passing test now requires
// refusal before any producer method, including for deferred consumption.
// A shared SNI producer whose optional setter stores one global token.
// It delays A's reply until B's setter runs, making interleaving deterministic.
class SharedItem : public QDBusVirtualObject {
public:
    bool deferredConsumption = false;
    int accepted = 0;
    QString token;
    QDBusMessage delayed;
    QStringList events, consumed;
    QString introspect(const QString&) const override {
        return R"(<interface name="org.kde.StatusNotifierItem">
          <method name="ProvideXdgActivationToken"><arg type="s" direction="in"/></method>
          <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
        </interface>)";
    }
    bool handleMessage(const QDBusMessage& message, const QDBusConnection& connection) override {
        message.setDelayedReply(true);
        if (message.member() == "ProvideXdgActivationToken" || message.member() == "Activate")
            std::cout << "received:" << message.member().toStdString() << std::endl;
        if (message.member() == "ProvideXdgActivationToken") {
            token = message.arguments().value(0).toString();
            events << "set:" + token;
            if (deferredConsumption) connection.send(message.createReply());
            else if (token == "A") delayed = message;
            else {
                connection.send(delayed.createReply());
                connection.send(message.createReply());
            }
            return true;
        }
        if (message.member() == "Activate") {
            if (deferredConsumption) {
                events << "accepted:" + token;
                // A normal asynchronous producer can acknowledge its handler
                // before the queued UI work consumes the global token.
                if (++accepted == 2) consumed << token << token;
            } else {
                events << "activate:" + token;
                consumed << token;
            }
            connection.send(message.createReply());
            if (consumed.size() == 2) {
                std::cout << "events:" << events.join(",").toStdString() << "\nconsumed:" << consumed.join(",").toStdString() << std::endl;
                QTimer::singleShot(100, qApp, &QCoreApplication::quit);
            }
            return true;
        }
        return false;
    }
};
class Handle : public QDBusAbstractInterface {
public:
    Handle(QObject* parent, const QString& service)
        : QDBusAbstractInterface(service, "/Item", "org.kde.StatusNotifierItem", QDBusConnection::sessionBus(), parent) {}
};
int main(int argc, char** argv) {
    QCoreApplication application(argc, argv);
    auto bus = QDBusConnection::sessionBus();
    if (application.arguments().contains("--service")) {
        SharedItem producer;
        producer.deferredConsumption = application.arguments().contains("--deferred");
        if (!bus.isConnected() || !bus.registerVirtualObject("/Item", &producer)) return 2;
        std::cout << bus.baseService().toStdString() << std::endl;
        QTimer::singleShot(9000, &application, &QCoreApplication::quit);
        return application.exec();
    }
    const bool deferred = application.arguments().contains("--deferred");
    QProcess service;
    service.start(application.applicationFilePath(), deferred ? QStringList{"--service", "--deferred"} : QStringList{"--service"});
    if (!service.waitForStarted(2000) || !service.waitForReadyRead(2000)) return 2;
    const auto owner = QString::fromUtf8(service.readLine()).trimmed();
    QObject item;
    Handle handle(&item, owner);
    DesktopActionRouter shellA, shellB;
    QEventLoop loop;
    int finished = 0, succeeded = 0;
    const auto complete = [&](const QString&, bool ok, const QString& error) {
        std::cout << "router completion: " << ok << " " << error.toStdString() << std::endl;
        ++finished; succeeded += ok;
        if (deferred && finished == 1)
            shellA.invokeTray(&item, nullptr, "Activate", {{"desktop", "B"}, {"context", "source-B"}, {"token", "B"}});
        if (finished == 2) loop.quit();
    };
    QObject::connect(&shellA, &DesktopActionRouter::actionFinished, complete);
    QObject::connect(&shellB, &DesktopActionRouter::actionFinished, complete);
    shellA.invokeTray(&item, nullptr, "Activate", {{"desktop", "A"}, {"context", "source-A"}, {"token", "A"}});
    if (!deferred) shellB.invokeTray(&item, nullptr, "Activate", {{"desktop", "B"}, {"context", "source-B"}, {"token", "B"}});
    QTimer::singleShot(7000, &loop, &QEventLoop::quit);
    loop.exec();
    // Let real bus messages drain before stopping only our synthetic child.
    QEventLoop drain;
    QTimer::singleShot(100, &drain, &QEventLoop::quit);
    drain.exec();
    service.kill(); service.waitForFinished(1000);
    const auto evidence = service.readAllStandardOutput();
    std::cout << evidence.constData() << "; finished=" << finished << "; succeeded=" << succeeded << std::endl;
    if (finished != 2 || succeeded != 0 || evidence.contains("received:")) return 1;
    std::cout << "PASS " << (deferred ? "deferred-consumption producer" : "concurrent router instances")
              << ": both Agent requests refused without sending any setter or action" << std::endl;
    return 0;
}
