#include "DesktopActionRouter.hpp"
#include <QDBusAbstractInterface>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QProcess>
#include <QRegularExpression>
#include <QTimer>
#include <QUuid>

DesktopActionRouter::DesktopActionRouter(QObject* parent) : QObject(parent) {}

QString DesktopActionRouter::prepare(const QString& desktop, const QString& seat,
                                     const QString& generation, const QString& workspace, const QString& output) {
    const auto request = QUuid::createUuid().toString(QUuid::WithoutBraces);
    // IPC command parsing is space separated. Reject instead of reinterpreting
    // a malformed source as another desktop or falling back to global focus.
    const auto sourceOutput = output.isEmpty() ? QString{"-"} : output;
    const QRegularExpression word("^[^\\s\\x00]+$");
    if (m_pending >= 32 || !word.match(desktop).hasMatch() || !word.match(seat).hasMatch()
        || !word.match(generation).hasMatch() || !word.match(workspace).hasMatch() || !word.match(sourceOutput).hasMatch()) {
        QTimer::singleShot(0, this, [this, request] { emit prepared(request, {}, "Invalid or busy source action"); });
        return request;
    }
    auto* process = new QProcess(this);
    ++m_pending;
    auto* timer = new QTimer(process);
    timer->setSingleShot(true);
    connect(timer, &QTimer::timeout, process, &QProcess::kill);
    const auto finish = [this, request, process]() {
        --m_pending;
        const auto document = QJsonDocument::fromJson(process->readAllStandardOutput());
        const auto value = document.object();
        const bool ok = process->exitStatus() == QProcess::NormalExit && process->exitCode() == 0
            && !value["context"].toString().isEmpty() && !value["token"].toString().isEmpty();
        emit prepared(request, ok ? value.toVariantMap() : QVariantMap{},
                      ok ? QString{} : "Source action expired or compositor routing is unavailable");
        process->deleteLater();
    };
    connect(process, &QProcess::finished, this, finish);
    connect(process, &QProcess::errorOccurred, this, [finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) finish();
    });
    process->start("hyprctl", {"-j", "--", "seat", "route-context", desktop, seat, generation, workspace, sourceOutput});
    timer->start(4000);
    return request;
}

QString DesktopActionRouter::invokeTray(QObject* item, QObject* entry, const QString& method,
                                        const QVariantMap& context, int delta, bool horizontal) {
    const auto request = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const auto reject = [this, request](const QString& error) {
        QTimer::singleShot(0, this, [this, request, error] { emit actionFinished(request, false, error); });
    };
    QDBusAbstractInterface* target = nullptr;
    if (item) {
        for (auto* candidate : item->findChildren<QDBusAbstractInterface*>()) {
            if (candidate->interface() == "org.kde.StatusNotifierItem") { target = candidate; break; }
        }
    }
    if (!target || context.value("token").toString().isEmpty()
        || !QStringList{"Activate", "SecondaryActivate", "Scroll", "Menu"}.contains(method)
        || (method == "Menu" && (!entry || entry->metaObject()->indexOfSignal("triggered()") < 0))) {
        reject("Tray item has no exact routable handle");
        return request;
    }
    // Resolve the unique owner once. A service-name replacement must never
    // receive the second half of an action intended for the old registration.
    const QDBusReply<QString> owner = target->connection().interface()->serviceOwner(target->service());
    const QDBusReply<uint> pid = owner.isValid() ? target->connection().interface()->servicePid(owner.value()) : QDBusReply<uint>{};
    // KDE's token setter is process-global. Different SNI paths (or bus
    // connections) from the same process must not overwrite each other's token.
    const auto key = pid.isValid() ? QString::number(pid.value()) : owner.value();
    if (!owner.isValid() || m_busyItems.contains(key) || m_busyItems.size() >= 32) {
        reject("Tray item disappeared or another action is pending");
        return request;
    }
    m_busyItems.insert(key);
    const auto connection = target->connection();
    const auto path = target->path();
    const bool uniqueDestination = target->service() == owner.value();
    const QPointer<QObject> guard(item), menu(entry);
    auto message = QDBusMessage::createMethodCall(owner.value(), path, target->interface(), "ProvideXdgActivationToken");
    message << context.value("token").toString();
    auto* tokenCall = new QDBusPendingCallWatcher(connection.asyncCall(message, 3000), this);
    connect(tokenCall, &QDBusPendingCallWatcher::finished, this,
            [=, this](QDBusPendingCallWatcher* call) {
        const QDBusPendingReply<> reply = *call;
        call->deleteLater();
        const auto finish = [=, this](bool ok, const QString& error) {
            m_busyItems.remove(key);
            emit actionFinished(request, ok, error);
        };
        if (reply.isError() || !guard) {
            finish(false, reply.isError() ? "Tray service does not accept per-action activation tokens: " + reply.error().name()
                                          : "Tray item disappeared");
            return;
        }
        if (method == "Menu") {
            if (!menu) { finish(false, "Menu entry disappeared"); return; }
            if (uniqueDestination) {
                // QS keeps this exact entry and the menu's unique bus owner.
                const bool ok = QMetaObject::invokeMethod(menu, "triggered", Qt::DirectConnection);
                finish(ok, ok ? QString{} : "Menu entry disappeared");
                return;
            }
            // A QS menu targeting a well-known name could be rebound between
            // token and Event. Pin its unique owner and exact object path in
            // the generic fallback instead of looking up a logical item ID.
            const auto route = context.value("menuPath").toList();
            if (route.isEmpty()) { finish(false, "Exact menu path required"); return; }
            auto* process = new QProcess(this);
            const auto helper = qEnvironmentVariable("CORNICE_PATH", "/usr/share/cornice") + "/bin/cornice-tray-activate";
            connect(process, &QProcess::finished, this, [process, finish](int exit, QProcess::ExitStatus status) {
                const bool ok = status == QProcess::NormalExit && exit == 0;
                finish(ok, ok ? QString{} : "Exact-owner menu dispatch failed or timed out");
                process->deleteLater();
            });
            connect(process, &QProcess::errorOccurred, this, [process, finish](QProcess::ProcessError error) {
                if (error == QProcess::FailedToStart) { finish(false, "Menu dispatcher unavailable"); process->deleteLater(); }
            });
            process->start("/usr/bin/timeout", {"--kill-after=1", "5", helper, "--service", owner.value(), "--object-path", path,
                "--label", route.last().toMap().value("text").toString(), "--path", QString::fromUtf8(QJsonDocument::fromVariant(route).toJson(QJsonDocument::Compact))});
            return;
        }
        auto action = QDBusMessage::createMethodCall(owner.value(), path, "org.kde.StatusNotifierItem", method);
        if (method == "Scroll") action << delta << (horizontal ? "horizontal" : "vertical");
        else action << 0 << 0;
        auto* actionCall = new QDBusPendingCallWatcher(connection.asyncCall(action, 3000), this);
        connect(actionCall, &QDBusPendingCallWatcher::finished, this, [finish](QDBusPendingCallWatcher* completed) {
            const QDBusPendingReply<> result = *completed;
            finish(!result.isError(), result.isError() ? result.error().name() : QString{});
            completed->deleteLater();
        });
    });
    return request;
}
