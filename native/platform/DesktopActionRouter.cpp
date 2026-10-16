#include "DesktopActionRouter.hpp"
#include "../common/ApplicationLocation.hpp"
#include <QFileInfo>
#include <QJsonArray>
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

QString DesktopActionRouter::checkApplication(const QStringList& argv, const QString& desktop) {
    const auto request = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const auto prefix = qEnvironmentVariable("CORNICE_PATH", "/usr/share/cornice");
    auto helper = prefix + "/native/bin/cornice-desktop-runtime";
    if (!QFileInfo::exists(helper)) helper = prefix + "/native/build/cornice-desktop-runtime";
    // Core-only installs have no multi-desktop policy/runtime.
    if (!QFileInfo::exists(helper)) {
        QTimer::singleShot(0, this, [=, this] { emit applicationChecked(request, {}); });
        return request;
    }
    if (m_pending >= 8) {
        QTimer::singleShot(0, this, [=, this] { emit applicationChecked(request, "Application check busy; try again"); });
        return request;
    }
    auto* process = new QProcess(this);
    ++m_pending;
    auto* timer = new QTimer(process); timer->setSingleShot(true);
    connect(timer, &QTimer::timeout, process, &QProcess::kill);
    const auto finish = [=, this] {
        --m_pending;
        const bool ok = process->exitStatus() == QProcess::NormalExit && process->exitCode() == 0;
        auto error = QString::fromUtf8(process->readAllStandardError()).trimmed();
        if (!ok && error.isEmpty()) error = "Application check failed or timed out";
        emit applicationChecked(request, ok ? QString{} : error);
        process->deleteLater();
    };
    connect(process, &QProcess::finished, this, finish);
    connect(process, &QProcess::errorOccurred, this, [finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) finish();
    });
    process->start(helper, {"check-singleton", desktop, desktop == "main" ? "true" : "false",
        QString::fromUtf8(QJsonDocument(QJsonArray::fromStringList(argv)).toJson(QJsonDocument::Compact))});
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
    // The KDE setter and the following SNI/DBusMenu call are not one request.
    // Its process-global token may be overwritten by another Shell or consumed
    // after the action reply. Neither a local lock nor a successful setter is
    // a request-to-surface contract. Do not send even the setter for Agent
    // actions until such an atomic contract is actually implemented.
    const auto source = context.value("context").toString();
    const auto sourceDesktop = context.value("desktop").toString();
    const bool humanTakeover = sourceDesktop != "main" && context.value("humanTakeover").toBool();
    if (sourceDesktop != "main" && !humanTakeover) {
        const QDBusReply<QString> owner = target->connection().interface()->serviceOwner(target->service());
        const QDBusReply<uint> pid = owner.isValid() ? target->connection().interface()->servicePid(owner.value()) : QDBusReply<uint>{};
        const auto desktop = pid.isValid() ? CorniceApplication::desktopForPid(pid.value()) : QString{};
        if (!desktop.isEmpty() && desktop != context.value("desktop").toString())
            reject(QStringLiteral("此应用已在") + CorniceApplication::label(desktop)
                + QStringLiteral("运行，无法从当前桌面的托盘打开。请切换到应用所在的桌面使用。"));
        else reject("Per-request tray activation is unavailable; no action was sent");
        return request;
    }
    if (!QRegularExpression("^[^\\s\\x00]+$").match(source).hasMatch()) {
        reject("Tray action requires a current human source");
        return request;
    }
    // Preserve the existing human compatibility path as an ordinary action,
    // without supplying any source token or claiming precise window placement.
    // A primary label is not authority: revalidate before dispatch below.
    const QDBusReply<QString> owner = target->connection().interface()->serviceOwner(target->service());
    const QDBusReply<uint> pid = owner.isValid() ? target->connection().interface()->servicePid(owner.value()) : QDBusReply<uint>{};
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
    const auto finish = [=, this](bool ok, const QString& error) {
        m_busyItems.remove(key);
        emit actionFinished(request, ok, error);
    };
    const auto dispatch = [=, this] {
        if (!guard) { finish(false, "Tray item disappeared"); return; }
        if (method == "Menu") {
            if (!menu) { finish(false, "Menu entry disappeared"); return; }
            if (uniqueDestination) {
                const bool ok = QMetaObject::invokeMethod(menu, "triggered", Qt::DirectConnection);
                finish(ok, ok ? QString{} : "Menu entry disappeared");
                return;
            }
            // Pin the unique owner and exact selected path, including duplicate
            // logical item IDs. Never resolve a replacement registration.
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
    };
    auto* validation = new QProcess(this);
    auto* timer = new QTimer(validation);
    timer->setSingleShot(true);
    connect(timer, &QTimer::timeout, validation, &QProcess::kill);
    connect(validation, &QProcess::finished, this, [=, this] {
        const auto value = QJsonDocument::fromJson(validation->readAllStandardOutput()).object();
        const bool valid = validation->exitStatus() == QProcess::NormalExit && validation->exitCode() == 0
            && value["valid"].toBool() && value["name"].toString() == sourceDesktop && value["mode"] == "control";
        validation->deleteLater();
        if (!valid) { finish(false, "Tray action requires a current human source"); return; }
        if (!humanTakeover) { dispatch(); return; }
        // A control context alone also exists for Agent input. Only the Broker
        // knows whether physical takeover is active. Match its current seat and
        // generation to the compositor-validated context; a QML flag is not
        // authority. No process-global activation token is provided.
        auto* takeover = new QProcess(this);
        auto* deadline = new QTimer(takeover);
        deadline->setSingleShot(true);
        connect(deadline, &QTimer::timeout, takeover, &QProcess::kill);
        connect(takeover, &QProcess::finished, this, [=] {
            const auto state = QJsonDocument::fromJson(takeover->readAllStandardOutput()).object();
            const bool allowed = takeover->exitStatus() == QProcess::NormalExit && takeover->exitCode() == 0
                && state["name"].toString() == sourceDesktop && state["controlMode"] == "human"
                && !value["seatId"].toString().isEmpty() && state["seatId"] == value["seatId"]
                && !value["generation"].toString().isEmpty() && state["generation"] == value["generation"];
            takeover->deleteLater();
            if (!allowed) { finish(false, "Tray action requires current human takeover of this desktop"); return; }
            dispatch();
        });
        connect(takeover, &QProcess::errorOccurred, this, [takeover, finish](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart) {
                finish(false, "Human takeover validation unavailable");
                takeover->deleteLater();
            }
        });
        deadline->start(3000);
        const auto helper = qEnvironmentVariable("CORNICE_PATH", "/usr/share/cornice") + "/bin/cornice-desktop";
        takeover->start(helper, {"state", sourceDesktop});
    });
    connect(validation, &QProcess::errorOccurred, this, [validation, finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            finish(false, "Human action context validation unavailable");
            validation->deleteLater();
        }
    });
    timer->start(3000);
    validation->start("hyprctl", {"-j", "--", "seat", "validate-context", source});
    return request;
}
