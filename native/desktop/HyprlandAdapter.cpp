#include "HyprlandAdapter.hpp"
#include <QLocalSocket>
#include <QJsonDocument>
#include <QJsonArray>
#include <stdexcept>

HyprlandAdapter::HyprlandAdapter(QString instance) : m_instance(std::move(instance)) {}
QByteArray HyprlandAdapter::command(const QString &command, bool asJson) const {
    const auto path = qEnvironmentVariable("XDG_RUNTIME_DIR") + "/hypr/" + m_instance + "/.socket.sock";
    QLocalSocket socket;
    socket.connectToServer(path);
    if (!socket.waitForConnected(1000))
        throw std::runtime_error("Bound compositor unavailable");
    auto wireCommand = command;
    if (wireCommand.startsWith("seat lock-policy ")) {
        if (wireCommand.endsWith(" continue")) wireCommand.chop(9), wireCommand += " allow";
        else if (wireCommand.endsWith(" pause")) wireCommand.chop(6), wireCommand += " block";
    }
    socket.write((asJson ? "j/" : "/") + wireCommand.toUtf8());
    if (!socket.waitForBytesWritten(1000))
        throw std::runtime_error("Compositor write timed out");
    QByteArray answer;
    while (socket.state() == QLocalSocket::ConnectedState) {
        if (socket.bytesAvailable() == 0 && !socket.waitForReadyRead(2000) &&
            socket.state() == QLocalSocket::ConnectedState)
            throw std::runtime_error("Compositor response timed out");
        answer += socket.readAll();
        if (answer.size() > 8 * 1024 * 1024)
            throw std::runtime_error("Compositor response too large");
    }
    answer += socket.readAll();
    answer = answer.trimmed();
    const auto parsed = QJsonDocument::fromJson(answer);
    auto adapt = [](QJsonObject value) {
        if (value.contains("locked")) value["humanLocked"] = value.take("locked");
        if (value.contains("scopePolicy")) value["humanLockPolicy"] = value.take("scopePolicy").toString() == "allow" ? "continue" : "pause";
        if (value["lockScope"].toString() == "scoped") value["lockScope"] = "human";
        return value;
    };
    if (parsed.isObject() && (wireCommand.startsWith("seat state ") || wireCommand.startsWith("seat lock-policy ") || wireCommand.startsWith("seat control ")))
        return QJsonDocument(adapt(parsed.object())).toJson(QJsonDocument::Compact);
    if (parsed.isArray() && (wireCommand == "seat list" || wireCommand == "seat")) {
        QJsonArray result;
        for (const auto &value : parsed.array()) result.append(adapt(value.toObject()));
        return QJsonDocument(result).toJson(QJsonDocument::Compact);
    }
    return answer;
}

QJsonObject HyprlandAdapter::configure(const QJsonObject &configuration) const {
    const auto result = command("seat configure " + QString::fromUtf8(QJsonDocument(configuration).toJson(QJsonDocument::Compact)), true);
    const auto parsed = QJsonDocument::fromJson(result).object();
    if (!parsed["configured"].toBool()) throw std::runtime_error(result.constData());
    return parsed;
}
void HyprlandAdapter::renew(const QString &owner) const {
    const auto result = command("seat configuration-renew " + owner);
    if (result != "ok") throw std::runtime_error(result.constData());
}
void HyprlandAdapter::remove(const QString &owner) const {
    const auto result = command("seat configuration-remove " + owner);
    if (result != "ok") throw std::runtime_error(result.constData());
}
void HyprlandAdapter::ensureWorkspace(const QString &name, const QString &identity, const QString &workspace) const {
    const auto result = command("seat ensure-workspace " + name + " " + identity + " " + workspace);
    if (result != "ok") throw std::runtime_error(result.constData());
}
