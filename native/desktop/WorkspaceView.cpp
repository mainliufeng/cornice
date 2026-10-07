#include "WorkspaceView.hpp"
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPainter>
#include <QUuid>
#include <chrono>

WorkspaceView::WorkspaceView(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setAcceptedMouseButtons(Qt::NoButton);
    connect(this, &WorkspaceView::targetChanged, this, &WorkspaceView::reset);
    connect(&m_socket, &QLocalSocket::connected, this, &WorkspaceView::request);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this] { clear(m_socket.errorString()); });
    connect(&m_socket, &QLocalSocket::disconnected, this, [this] { clear("Desktop service disconnected"); });
    connect(&m_socket, &QLocalSocket::readyRead, this, [this] {
        m_input += m_socket.readAll();
        if (m_input.size() > 1024 * 1024) {
            m_socket.abort();
            clear("Invalid frame metadata");
            return;
        }
        while (m_input.contains('\n')) {
            const auto reply = QJsonDocument::fromJson(m_input.left(m_input.indexOf('\n'))).object();
            m_input.remove(0, m_input.indexOf('\n') + 1);
            m_pending = false;
            m_timeout.stop();
            if (reply["event"].toString() == "frame-invalidated") {
                clear(reply["reason"].toString());
                continue;
            }
            if (!reply["ok"].toBool()) {
                clear(reply["error"].toString());
                continue;
            }
            const auto metadata = reply["result"].toObject();
            const auto dimensions = metadata["pixelSize"].toArray();
            const auto width = dimensions[0].toInt(), height = dimensions[1].toInt();
            if (width <= 0 || height <= 0 || width > 16384 || height > 16384) {
                clear("Invalid frame dimensions");
                return;
            }
            QFile buffer(metadata["buffer"].toString());
            if (!buffer.open(QIODevice::ReadOnly) || buffer.size() != static_cast<qint64>(width) * height * 4) {
                clear("Frame buffer unavailable");
                return;
            }
            // Own the pixels before the next request. Use read(), not mmap:
            // lock revocation may truncate the shared file at any moment, and
            // dereferencing a concurrently truncated mapping can cause SIGBUS.
            QImage owned(width, height, QImage::Format_ARGB32);
            const auto bytes = static_cast<qint64>(width) * height * 4;
            if (owned.isNull() || buffer.read(reinterpret_cast<char *>(owned.bits()), bytes) != bytes) {
                clear("Frame revoked or incomplete");
                return;
            }
            m_image = std::move(owned);
            m_metadata = metadata;
            m_error.clear();
            update();
            emit frameChanged();
        }
    });
    m_timer.setTimerType(Qt::PreciseTimer);
    m_timer.setInterval(67);
    connect(&m_timer, &QTimer::timeout, this, &WorkspaceView::request);
    m_timeout.setSingleShot(true);
    m_timeout.setInterval(2000);
    connect(&m_timeout, &QTimer::timeout, this, [this] {
        m_socket.abort();
        clear("Frame timed out");
    });
}
void WorkspaceView::reset() {
    m_timer.stop();
    m_timeout.stop();
    m_socket.abort();
    m_input.clear();
    m_pending = false;
    clear("");
    if (!m_active || m_desktop.isEmpty() || m_socketPath.isEmpty())
        return;
    m_socket.connectToServer(m_socketPath);
    m_timer.start();
}
void WorkspaceView::request() {
    if (!m_active || m_pending || m_socket.state() != QLocalSocket::ConnectedState)
        return;
    const QJsonObject request{{"id", QUuid::createUuid().toString(QUuid::WithoutBraces)},
                              {"method", "frame"},
                              {"params", QJsonObject{{"name", m_desktop}, {"workspace", m_workspace}}}};
    m_pending = true;
    m_timeout.start();
    m_socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
}
void WorkspaceView::clear(const QString &error) {
    m_image = QImage();
    m_metadata = {};
    m_error = error;
    update();
    emit frameChanged();
}
void WorkspaceView::paint(QPainter *painter) {
    painter->fillRect(boundingRect(), QColor("#141414"));
    if (m_image.isNull())
        return;
    QSizeF size = m_image.size();
    size.scale(boundingRect().size(), Qt::KeepAspectRatio);
    const QRectF target((width() - size.width()) / 2, (height() - size.height()) / 2, size.width(), size.height());
    painter->drawImage(target, m_image);
    const auto frame = m_metadata["frameId"].toString();
    if (frame != m_paintedFrame) {
        m_paintedFrame = frame;
        ++m_paintedFrames;
        m_lastPaintMs =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
                .count();
        emit paintChanged();
    }
}
