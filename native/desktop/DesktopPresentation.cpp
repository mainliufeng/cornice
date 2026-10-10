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
    const auto handoffId = m_method == "takeover" ? m_handoffId : QString{};
    if (m_method == "takeover") m_handoffId.clear();
    const QJsonObject request{{"id", m_id},
                              {"method", m_method},
                              {"params", QJsonObject{{"name", m_desktop}, {"workspace", m_workspace}, {"requestId", handoffId}}}};
    m_pending = true;
    m_timeout.start();
    m_socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
}
void DesktopPresentation::takeControl(bool enabled) {
    m_handoffId.clear();
    m_control = enabled ? "takeover" : "release";
    request();
}

void DesktopPresentation::takeHandoff(const QString &requestId) {
    m_handoffId = requestId;m_control = "takeover";request();
}

void DesktopPresentation::refreshView() {
    m_present = true;
    request();
}

void DesktopPresentation::refreshStatus() {
    m_refresh = true;
    request();
}

#include <QFile>
#include <QJsonArray>
#include <QPainter>

DesktopThumbnail::DesktopThumbnail(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setAcceptedMouseButtons(Qt::NoButton);
    connect(this, &DesktopThumbnail::targetChanged, this, &DesktopThumbnail::reset);
    connect(&m_socket, &QLocalSocket::connected, this, &DesktopThumbnail::request);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this] { unavailable(m_socket.errorString()); });
    connect(&m_socket, &QLocalSocket::readyRead, this, [this] {
        m_input += m_socket.readAll();
        if (m_input.size() > 1024 * 1024) {
            unavailable("Preview response too large");
            return;
        }
        while (m_input.contains('\n')) {
            const auto line = m_input.left(m_input.indexOf('\n'));
            m_input.remove(0, line.size() + 1);
            const auto reply = QJsonDocument::fromJson(line).object();
            // Unsolicited lock invalidation has no request ID. Drop cached
            // pixels immediately and discard any in-flight frame on this socket.
            if (reply["event"].toString() == "frame-invalidated") {
                ++m_invalidations;
                unavailable(reply["reason"].toString());
                return;
            }
            if (reply["id"].toString() != m_id) continue;
            m_pending = false;
            m_timeout.stop();
            if (!reply["ok"].toBool()) {
                unavailable(reply["error"].toString());
                return;
            }
            const auto frame = reply["result"].toObject();
            const auto size = frame["pixelSize"].toArray();
            const int width = size.size() > 0 ? size[0].toInt() : 0, height = size.size() > 1 ? size[1].toInt() : 0;
            const auto path = frame["buffer"].toString();
            if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || path.isEmpty()) {
                unavailable("Invalid preview frame");
                return;
            }
            QFile file(path);
            if (!file.open(QIODevice::ReadOnly)) { unavailable("Cannot read preview frame"); return; }
            const auto bytes = file.readAll();
            if (bytes.size() != qint64(width) * height * 4) { unavailable("Incomplete preview frame"); return; }
            const QImage source(reinterpret_cast<const uchar *>(bytes.constData()), width, height, width * 4, QImage::Format_ARGB32);
            // Store only a thumbnail; the Broker's owner-scoped raw buffer is reused.
            m_image = source.scaled(640, 400, Qt::KeepAspectRatio, Qt::SmoothTransformation);
            m_error.clear();
            ++m_frameCount;
            emit statusChanged();
            update();
        }
    });
    m_poll.setInterval(250);
    connect(&m_poll, &QTimer::timeout, this, &DesktopThumbnail::request);
    m_timeout.setSingleShot(true);
    m_timeout.setInterval(3000);
    connect(&m_timeout, &QTimer::timeout, this, [this] { unavailable("Preview unavailable"); });
}
void DesktopThumbnail::paint(QPainter *painter) {
    if (m_image.isNull()) return;
    const auto size = m_image.size().scaled(boundingRect().size().toSize(), Qt::KeepAspectRatio);
    const QRectF target((width() - size.width()) / 2, (height() - size.height()) / 2, size.width(), size.height());
    painter->setRenderHint(QPainter::SmoothPixmapTransform);
    painter->drawImage(target, m_image);
}
void DesktopThumbnail::unavailable(const QString &error) {
    m_pending = false;
    m_timeout.stop();
    m_socket.abort();
    m_input.clear();
    m_id.clear();
    m_image = {};
    m_error = error;
    emit statusChanged();
    update();
}
void DesktopThumbnail::reset() {
    m_poll.stop();
    m_timeout.stop();
    m_socket.abort();
    m_pending = false;
    m_input.clear();
    m_image = {};
    m_error.clear();
    update();
    emit statusChanged();
    if (!m_active || m_desktop.isEmpty() || m_socketPath.isEmpty()) return;
    m_socket.connectToServer(m_socketPath);
    m_poll.start();
}
void DesktopThumbnail::request() {
    if (!m_active || m_pending) return;
    if (m_socket.state() == QLocalSocket::UnconnectedState) {
        m_socket.connectToServer(m_socketPath);
        return;
    }
    if (m_socket.state() != QLocalSocket::ConnectedState) return;
    m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QJsonObject request{{"id",m_id},{"method","frame"},{"params",QJsonObject{{"name",m_desktop},{"workspace","current"}}}};
    m_pending = true;
    m_timeout.start();
    m_socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
}
