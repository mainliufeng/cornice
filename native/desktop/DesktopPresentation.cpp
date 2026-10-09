#include "DesktopPresentation.hpp"
#include <QJsonDocument>
#include <QUuid>
DesktopPresentation::DesktopPresentation(QObject *parent) : QObject(parent) {
    connect(this, &DesktopPresentation::targetChanged, this, &DesktopPresentation::reset);
    connect(&m_socket, &QLocalSocket::connected, this, &DesktopPresentation::request);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this] {
        m_error = m_socket.errorString();
        m_state = {};
        emit stateChanged();
        if (m_active)
            emit returned();
    });
    connect(&m_socket, &QLocalSocket::readyRead, this, [this] {
        m_input += m_socket.readAll();
        if (m_input.size() > 1024 * 1024) {
            m_error = "Desktop control response too large";
            m_state = {};
            m_socket.abort();
            emit stateChanged();
            emit returned();
            return;
        }
        while (m_input.contains('\n')) {
            const auto line = m_input.left(m_input.indexOf('\n'));
            m_input.remove(0, line.size() + 1);
            const auto reply = QJsonDocument::fromJson(line).object();
            if (reply["id"].toString() != m_id)
                continue;
            m_pending = false;
            m_timeout.stop();
            if (!reply["ok"].toBool()) {
                m_error = reply["error"].toString();
                m_state = {};
                emit stateChanged();
                m_socket.abort();
                emit returned();
                return;
            }
            m_state = reply["result"].toObject();
            m_error.clear();
            emit stateChanged();
            if (!m_state["active"].toBool()) {
                emit returned();
                return;
            }
            if (m_present || !m_control.isEmpty() || m_refresh)
                QTimer::singleShot(0, this, &DesktopPresentation::request);
        }
    });
    m_poll.setInterval(500);
    connect(&m_poll, &QTimer::timeout, this, &DesktopPresentation::refreshStatus);
    m_timeout.setSingleShot(true);
    m_timeout.setInterval(3000);
    connect(&m_timeout, &QTimer::timeout, this, [this] {
        m_socket.abort();
        m_state = {};
        m_error = "Desktop control unavailable";
        emit stateChanged();
        emit returned();
    });
}
void DesktopPresentation::reset() {
    if (m_active && !m_desktop.isEmpty() && !m_socketPath.isEmpty() && m_connectedPath == m_socketPath &&
        m_socket.state() == QLocalSocket::ConnectedState) {
        m_present = true;
        m_control.clear();
        request();
        return;
    }
    m_poll.stop();
    m_timeout.stop();
    m_socket.abort();
    m_input.clear();
    m_pending = false;
    m_refresh = false;
    m_present = true;
    m_control.clear();
    m_state = {};
    m_error.clear();
    emit stateChanged();
    if (!m_active || m_desktop.isEmpty() || m_socketPath.isEmpty())
        return;
    m_connectedPath = m_socketPath;
    m_socket.connectToServer(m_socketPath);
    m_poll.start();
}
void DesktopPresentation::request() {
    if (!m_active || m_pending || m_socket.state() != QLocalSocket::ConnectedState)
        return;
    m_method = m_present ? "present" : m_control.isEmpty() ? "present-status" : m_control;
    if (m_present)
        m_present = false;
    else
        m_control.clear();
    m_refresh = false;
    m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QJsonObject request{{"id", m_id},
                              {"method", m_method},
                              {"params", QJsonObject{{"name", m_desktop}, {"workspace", m_workspace}}}};
    m_pending = true;
    m_timeout.start();
    m_socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
}
void DesktopPresentation::takeControl(bool enabled) {
    m_control = enabled ? "takeover" : "release";
    request();
}

void DesktopPresentation::refreshView() {
    m_present = true;
    request();
}

void DesktopPresentation::refreshStatus() {
    m_refresh = true;
    request();
}
