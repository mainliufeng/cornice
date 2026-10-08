#include "WorkspaceView.hpp"
#include <QCursor>
#include <QFile>
#include <QGuiApplication>
#include <QHoverEvent>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QUuid>
#include <QWheelEvent>
#include <chrono>
#include <linux/input-event-codes.h>
#include <utility>

WorkspaceView::WorkspaceView(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setAcceptedMouseButtons(Qt::AllButtons);
    setAcceptHoverEvents(true);
    setFlag(ItemAcceptsInputMethod, true);
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
            if (reply["event"].toString() == "control-revoked") {
                setControl(false);
                m_events = {};
                continue;
            }
            if (reply["event"].toString() == "frame-invalidated") {
                setControl(false);
                clear(reply["reason"].toString());
                continue;
            }
            if (reply["id"].toString() != m_pendingId)
                continue;
            m_pending = false;
            m_timeout.stop();
            if (!reply["ok"].toBool()) {
                if (m_humanControl) {
                    m_controlRequest = "release";
                    setControl(false);
                }
                clear(reply["error"].toString());
                QTimer::singleShot(0, this, &WorkspaceView::request);
                continue;
            }
            if (m_pendingMethod != "frame") {
                if (m_pendingMethod == "takeover")
                    setControl(true);
                if (m_pendingMethod == "release")
                    setControl(false);
                m_needFrame = true;
                QTimer::singleShot(0, this, &WorkspaceView::request);
                continue;
            }
            m_needFrame = false;
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
            if (m_humanControl)
                QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
            m_error.clear();
            update();
            emit frameChanged();
            if (!m_events.isEmpty() || !m_controlRequest.isEmpty())
                QTimer::singleShot(0, this, &WorkspaceView::request);
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
    m_events = {};
    m_controlRequest.clear();
    m_fit = {};
    m_lastMove = {};
    setControl(false);
    m_pending = false;
    m_needFrame = true;
    clear("");
    if (!m_active || m_desktop.isEmpty() || m_socketPath.isEmpty())
        return;
    m_socket.connectToServer(m_socketPath);
    m_timer.start();
}
void WorkspaceView::request() {
    if (!m_active || m_pending || m_socket.state() != QLocalSocket::ConnectedState)
        return;
    QString method = "frame";
    QJsonObject params{{"name", m_desktop}, {"workspace", m_workspace}};
    if (!m_controlRequest.isEmpty()) {
        method = std::exchange(m_controlRequest, {});
        m_events = {};
    } else if (!m_fit.isEmpty() && !m_humanControl) {
        method = "fit";
        params = std::exchange(m_fit, {});
        params["name"] = m_desktop;
    } else if (m_humanControl && !m_needFrame && !m_events.isEmpty()) {
        method = "human.input";
        params["frameId"] = m_metadata["frameId"];
        params["events"] = m_events;
        m_events = {};
    }
    m_pendingId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_pendingMethod = method;
    const QJsonObject request{{"id", m_pendingId}, {"method", method}, {"params", params}};
    m_pending = true;
    m_timeout.start();
    m_socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
}
void WorkspaceView::clear(const QString &error) {
    if (m_humanControl && m_socket.state() == QLocalSocket::ConnectedState)
        m_controlRequest = "release";
    setControl(false);
    m_events = {};
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
    painter->drawImage(viewport(), m_image);
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

QRectF WorkspaceView::viewport() const {
    QSizeF size = m_image.size();
    size.scale(boundingRect().size(), Qt::KeepAspectRatio);
    return {(width() - size.width()) / 2, (height() - size.height()) / 2, size.width(), size.height()};
}
bool WorkspaceView::point(const QPointF &position, QJsonObject &event) const {
    if (!m_humanControl || m_image.isNull())
        return false;
    const auto rect = viewport();
    if (!rect.contains(position))
        return false;
    event["x"] = (position.x() - rect.x()) * m_image.width() / rect.width();
    event["y"] = (position.y() - rect.y()) * m_image.height() / rect.height();
    return true;
}
void WorkspaceView::setControl(bool enabled) {
    if (m_humanControl == enabled)
        return;
    m_humanControl = enabled;
    setCursor(enabled ? Qt::BlankCursor : Qt::ArrowCursor);
    if (enabled)
        forceActiveFocus();
    QGuiApplication::inputMethod()->update(Qt::ImQueryAll);
    emit controlChanged();
}
void WorkspaceView::takeControl(bool enabled) {
    if (!m_active || m_workspace != "current" || m_socket.state() != QLocalSocket::ConnectedState)
        return;
    m_controlRequest = enabled ? "takeover" : "release";
    if (!enabled)
        setControl(false);
    request();
}
void WorkspaceView::enqueue(const QJsonObject &event) {
    if (!m_humanControl)
        return;
    if (event["action"] == "move") {
        if (event == m_lastMove)
            return;
        m_lastMove = event;
    }
    if (event["action"] == "move" && !m_events.isEmpty() && m_events.last().toObject()["action"] == "move")
        m_events.removeLast();
    if (m_events.size() >= 64) {
        takeControl(false);
        return;
    }
    m_events.append(event);
    request();
}
static int buttonCode(Qt::MouseButton button) {
    switch (button) {
    case Qt::LeftButton:
        return BTN_LEFT;
    case Qt::RightButton:
        return BTN_RIGHT;
    case Qt::MiddleButton:
        return BTN_MIDDLE;
    case Qt::BackButton:
        return BTN_SIDE;
    case Qt::ForwardButton:
        return BTN_EXTRA;
    default:
        return 0;
    }
}
void WorkspaceView::mousePressEvent(QMouseEvent *event) {
    event->accept();
    QJsonObject move{{"action", "move"}};
    if (!point(event->position(), move) || !buttonCode(event->button()))
        return;
    forceActiveFocus();
    // Keep motion and button in one validated batch, avoiding a focus-changing
    // cursor update between the snapshot and the button press.
    m_events.append(move);
    enqueue({{"action", "button"}, {"code", buttonCode(event->button())}, {"pressed", true}});
}
void WorkspaceView::mouseReleaseEvent(QMouseEvent *event) {
    event->accept();
    if (buttonCode(event->button()))
        enqueue({{"action", "button"}, {"code", buttonCode(event->button())}, {"pressed", false}});
}
void WorkspaceView::mouseMoveEvent(QMouseEvent *event) {
    event->accept();
    QJsonObject move{{"action", "move"}};
    if (point(event->position(), move))
        enqueue(move);
}
void WorkspaceView::hoverMoveEvent(QHoverEvent *event) {
    QJsonObject move{{"action", "move"}};
    if (point(event->position(), move))
        enqueue(move);
}
void WorkspaceView::wheelEvent(QWheelEvent *event) {
    event->accept();
    if (!m_humanControl)
        return;
    const auto pixels = event->pixelDelta();
    const auto angles = event->angleDelta();
    const bool wheel = pixels.isNull() && angles.x() % 120 == 0 && angles.y() % 120 == 0;
    const auto delta = pixels.isNull() ? angles / 12 : pixels;
    const auto sendAxis = [this, wheel](int amount, int angle, const QString &axis) {
        QJsonObject input{{"action", "scroll"}, {"delta", -amount}, {"axis", axis},
                          {"source", wheel ? "wheel" : "continuous"}};
        if (wheel)
            input["steps"] = -angle / 120;
        enqueue(input);
    };
    if (delta.y())
        sendAxis(delta.y(), angles.y(), "vertical");
    if (delta.x())
        sendAxis(delta.x(), angles.x(), "horizontal");
    if (event->phase() == Qt::ScrollEnd) {
        enqueue({{"action", "scroll"}, {"delta", 0}, {"axis", "vertical"}, {"source", "continuous"}});
        enqueue({{"action", "scroll"}, {"delta", 0}, {"axis", "horizontal"}, {"source", "continuous"}});
    }
}
void WorkspaceView::key(QKeyEvent *event, bool pressed) {
    event->accept();
    if (!m_humanControl || event->isAutoRepeat())
        return;
    if (event->key() == Qt::Key_Escape && event->modifiers().testFlag(Qt::ControlModifier) &&
        event->modifiers().testFlag(Qt::AltModifier)) {
        takeControl(false);
        return;
    }
    // Qt's Wayland scan codes are XKB codes (evdev + 8).
    const auto code = event->nativeScanCode();
    if (code >= 8 && code <= 255)
        enqueue({{"action", "key"}, {"code", static_cast<int>(code - 8)}, {"pressed", pressed}});
}
void WorkspaceView::keyPressEvent(QKeyEvent *event) { key(event, true); }
void WorkspaceView::keyReleaseEvent(QKeyEvent *event) { key(event, false); }
void WorkspaceView::commitText(const QString &text) {
    if (!text.isEmpty())
        enqueue({{"action", "text"}, {"text", text}});
}
void WorkspaceView::inputMethodEvent(QInputMethodEvent *event) {
    commitText(event->commitString());
    event->accept();
}
QVariant WorkspaceView::inputMethodQuery(Qt::InputMethodQuery query) const {
    if (query == Qt::ImEnabled)
        return m_humanControl;
    if (query == Qt::ImCursorRectangle) {
        const auto cursor = m_metadata["cursor"].toArray();
        const auto rect = viewport();
        const auto logical = m_metadata["logicalSize"].toArray();
        const auto origin = m_metadata["position"].toArray();
        if (cursor.size() == 2 && logical[0].toDouble() > 0 && logical[1].toDouble() > 0)
            return QRectF(
                rect.x() + (cursor[0].toDouble() - origin[0].toDouble()) * rect.width() / logical[0].toDouble(),
                rect.y() + (cursor[1].toDouble() - origin[1].toDouble()) * rect.height() / logical[1].toDouble(), 1,
                20);
        return QRectF(0, 0, 1, 20);
    }
    return QQuickPaintedItem::inputMethodQuery(query);
}
void WorkspaceView::focusOutEvent(QFocusEvent *event) {
    enqueue({{"action", "release"}});
    QQuickPaintedItem::focusOutEvent(event);
}

void WorkspaceView::fit(int width, int height, double scale) {
    if (m_humanControl)
        return;
    m_fit = {{"width", width}, {"height", height}, {"scale", scale}};
    request();
}
