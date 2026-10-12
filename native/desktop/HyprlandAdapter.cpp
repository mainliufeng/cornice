#include "HyprlandAdapter.hpp"
#include <QDir>
#include <QLocalSocket>
#include <QJsonDocument>
#include <QJsonArray>
#include <stdexcept>
#include <fcntl.h>
#include <wayland-client.h>

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

wl_display *HyprlandAdapter::connectManagementDisplay() const {
    if (m_instance.isEmpty())
        return wl_display_connect(nullptr);

    const auto capabilities = command("seat capabilities", true);
    // Official compositors without the seat API keep their normal connection.
    if (capabilities == "unknown request")
        return wl_display_connect(nullptr);
    const auto document = QJsonDocument::fromJson(capabilities);
    if (!document.isObject() || !document.object()["features"].isArray())
        throw std::runtime_error("Invalid compositor seat capabilities");
    if (!document.object()["features"].toArray().contains("management-display-v1"))
        return wl_display_connect(nullptr);

    const auto response = QJsonDocument::fromJson(command("seat management-display", true));
    const auto name = response.object()["display"].toString();
    if (!response.isObject() || name.trimmed().isEmpty() || name.contains(QChar(0)))
        throw std::runtime_error("Compositor management display unavailable");
    const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (!QDir::isAbsolutePath(name) && runtime.isEmpty())
        throw std::runtime_error("Management display runtime directory unavailable");
    const auto path = QDir::isAbsolutePath(name) ? name : QDir(runtime).filePath(name);
    QLocalSocket socket;
    socket.connectToServer(path);
    if (!socket.waitForConnected(1000))
        throw std::runtime_error("Management Wayland connection failed: " + socket.errorString().toStdString());
    // wl_display_connect(name) still prefers an inherited WAYLAND_SOCKET FD.
    // Connect explicitly so a secondary client's environment cannot select its
    // restricted connection. Wayland owns this duplicate, including on failure.
    const auto fd = fcntl(static_cast<int>(socket.socketDescriptor()), F_DUPFD_CLOEXEC, 0);
    if (fd < 0)
        throw std::runtime_error("Management Wayland descriptor duplication failed");
    const auto display = wl_display_connect_to_fd(fd);
    if (!display)
        throw std::runtime_error("Management Wayland display initialization failed");
    return display;
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
