#include "Accessibility.hpp"
#include <QCoreApplication>
#include <QDateTime>
#include <QJsonDocument>
#include <QProcess>
#include <QUuid>
#include <QTimer>
#include <memory>
#include <stdexcept>
#include <functional>

namespace {
void fail(const QString &message) { throw std::runtime_error(message.toStdString()); }
QString address(const QJsonObject &window) {
    return window.value("address").toString(window.value("windowId").toString());
}
} // namespace
void Accessibility::validateWindow(const QJsonObject &window, const QJsonArray &allWindows) {
    const auto pid = window.value("pid").toInt();
    const auto title = window.value("title").toString();
    if (pid <= 0 || title.isEmpty() || address(window).isEmpty())
        fail("native accessibility unsupported: window has no trustworthy PID/title/identity");
    int matches = 0;
    bool found = false;
    for (const auto &value : allWindows) {
        const auto candidate = value.toObject();
        if (candidate.value("pid").toInt() == pid && candidate.value("title").toString() == title) {
            ++matches;
            found |= address(candidate) == address(window);
        }
    }
    if (!found || matches != 1)
        fail("native accessibility unsupported: PID/title maps to missing or ambiguous compositor windows");
}
Accessibility::~Accessibility() {
    for (const auto &process : m_processes)
        if (process) {
            process->disconnect();
            process->kill();
            process->waitForFinished(500);
        }
}
QProcess *Accessibility::runAsync(QJsonObject request, QObject *context, Completion complete) {
    auto *process = new QProcess(context);
    auto *timeout = new QTimer(process);
    timeout->setSingleShot(true);
    timeout->setInterval(4500);
    auto done = std::make_shared<bool>(false);
    auto output = std::make_shared<QByteArray>();
    auto finish = [this, process, timeout, done, output, complete](QString error) {
        if (*done)
            return;
        *done = true;
        timeout->stop();
        m_processes.removeAll(process);
        if (error.isEmpty())
            error = process->property("corniceCancelReason").toString();
        QJsonObject result;
        if (error.isEmpty()) {
            *output += process->readAllStandardOutput();
            if (output->size() > 2 * 1024 * 1024)
                error = "Native accessibility response budget exceeded";
            else {
                result = QJsonDocument::fromJson(*output).object();
                if (process->exitStatus() != QProcess::NormalExit || process->exitCode() != 0 ||
                    !result.value("ok").toBool())
                    error = result.value("error").toString("Native accessibility helper failed");
            }
        }
        complete(result, error);
        process->deleteLater();
    };
    QObject::connect(process, &QProcess::started, context, [process, request] {
        process->write(QJsonDocument(request).toJson(QJsonDocument::Compact));
        process->closeWriteChannel();
    });
    QObject::connect(process, &QProcess::readyReadStandardOutput, context, [process, output] {
        *output += process->readAllStandardOutput();
        if (output->size() > 2 * 1024 * 1024) {
            process->setProperty("corniceCancelReason", "Native accessibility response budget exceeded");
            process->kill();
        }
    });
    QObject::connect(process, &QProcess::finished, context, [finish](int, QProcess::ExitStatus) { finish({}); });
    QObject::connect(process, &QProcess::errorOccurred, context, [finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            finish("Native accessibility helper unavailable");
    });
    QObject::connect(timeout, &QTimer::timeout, context, [process] {
        process->setProperty("corniceCancelReason", "Native accessibility timed out; application did not answer");
        process->kill();
    });
    m_processes.append(process);
    process->setProgram(QCoreApplication::applicationDirPath() + "/cornice-native-accessibility");
    QTimer::singleShot(0, context, [process, timeout, finish] {
        const auto cancelled = process->property("corniceCancelReason").toString();
        if (!cancelled.isEmpty()) { finish(cancelled); return; }
        timeout->start();
        process->start();
    });
    return process;
}
void Accessibility::invalidate(const QString &scope) {
    for (auto it = m_elements.begin(); it != m_elements.end();) {
        if (it->scope == scope || it->expires < QDateTime::currentMSecsSinceEpoch())
            it = m_elements.erase(it);
        else
            ++it;
    }
}
QProcess *Accessibility::snapshotAsync(const QJsonObject &window, const QJsonArray &allWindows, const QString &scope,
                                       int maxNodes, int maxDepth, QObject *context, Completion complete) {
    if (scope.isEmpty())
        fail("Native accessibility requires a desktop scope");
    validateWindow(window, allWindows);
    if (m_elements.size() > 4096)
        m_elements.clear();
    return runAsync({{"operation", "snapshot"},
                     {"window", window},
                     {"maxNodes", qBound(1, maxNodes, 300)},
                     {"maxDepth", qBound(1, maxDepth, 20)}},
                    context, [this, window, scope, complete](QJsonObject result, QString error) {
                        if (!error.isEmpty()) {
                            complete({}, error);
                            return;
                        }
                        invalidate(scope);
                        std::function<QJsonObject(QJsonObject)> expose = [&](QJsonObject node) {
                            const auto identity = node.take("identity").toObject();
                            if (!identity.isEmpty()) {
                                const auto ref = QUuid::createUuid().toString(QUuid::WithoutBraces);
                                m_elements.insert(
                                    ref, {scope, window, identity, QDateTime::currentMSecsSinceEpoch() + 60000});
                                node.insert("elementRef", ref);
                            }
                            QJsonArray children;
                            for (const auto &child : node.value("children").toArray())
                                children.append(expose(child.toObject()));
                            node.insert("children", children);
                            return node;
                        };
                        result.insert("tree", expose(result.value("tree").toObject()));
                        result.insert("windowId", window.value("windowId").toString(address(window)));
                        result.insert("source", "atspi");
                        result.remove("ok");
                        complete(result, {});
                    });
}
QJsonObject Accessibility::elementWindow(const QString &scope, const QString &elementRef) {
    auto it = m_elements.find(elementRef);
    if (it == m_elements.end() || it->scope != scope || it->expires < QDateTime::currentMSecsSinceEpoch())
        fail("native element reference expired or belongs to another desktop; request a fresh tree");
    return it->window;
}
QProcess *Accessibility::actAsync(const QString &scope, const QString &elementRef, const QJsonObject &freshWindow,
                                  const QJsonArray &allWindows, const QString &action, const QString &text,
                                  const QJsonObject &authorization, QObject *context, Completion complete) {
    const auto previous = elementWindow(scope, elementRef);
    if (address(previous) != address(freshWindow) || previous.value("pid") != freshWindow.value("pid") ||
        previous.value("title") != freshWindow.value("title"))
        fail("Native element window changed; request a fresh tree");
    validateWindow(freshWindow, allWindows);
    if (action != "click" && action != "setText" && action != "focus")
        fail("Unsupported native element action");
    if (text.size() > 8192)
        fail("Native element text exceeds budget");
    const auto identity = m_elements.value(elementRef).identity;
    invalidate(scope); // In-flight mutation also makes old references unavailable.
    return runAsync({{"operation", "action"},
                     {"window", freshWindow},
                     {"identity", identity},
                     {"action", action},
                     {"text", text},
                     {"authorization", authorization}},
                    context, [complete](QJsonObject result, QString error) {
                        result.remove("ok");
                        complete(result, error);
                    });
}
