#pragma once
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QLocalSocket>
#include <QQmlEngine>
#include <QQuickPaintedItem>
#include <QTimer>

// Read-only until an explicit, socket-owned human takeover is granted.
class WorkspaceView : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString socketPath MEMBER m_socketPath NOTIFY targetChanged)
    Q_PROPERTY(QString desktop MEMBER m_desktop NOTIFY targetChanged)
    Q_PROPERTY(QString workspace MEMBER m_workspace NOTIFY targetChanged)
    Q_PROPERTY(bool active MEMBER m_active NOTIFY targetChanged)
    Q_PROPERTY(bool humanControl READ humanControl NOTIFY controlChanged)
    Q_PROPERTY(QString error READ error NOTIFY frameChanged)
    Q_PROPERTY(QJsonObject metadata READ metadata NOTIFY frameChanged)
    Q_PROPERTY(quint64 paintedFrames READ paintedFrames NOTIFY paintChanged)
    Q_PROPERTY(quint64 lastPaintMs MEMBER m_lastPaintMs NOTIFY paintChanged)
  public:
    explicit WorkspaceView(QQuickItem *parent = nullptr);
    void paint(QPainter *) override;
    bool humanControl() const { return m_humanControl; }
    Q_INVOKABLE void takeControl(bool enabled);
    Q_INVOKABLE void fit(int width, int height, double scale);
    Q_INVOKABLE void commitText(const QString &text);
    QVariant inputMethodQuery(Qt::InputMethodQuery query) const override;
    QString error() const { return m_error; }
    QJsonObject metadata() const { return m_metadata; }
    quint64 paintedFrames() const { return m_paintedFrames; }
  signals:
    void targetChanged();
    void frameChanged();
    void paintChanged();
    void controlChanged();

  protected:
    void mousePressEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void hoverMoveEvent(QHoverEvent *) override;
    void wheelEvent(QWheelEvent *) override;
    void keyPressEvent(QKeyEvent *) override;
    void keyReleaseEvent(QKeyEvent *) override;
    void inputMethodEvent(QInputMethodEvent *) override;
    void focusOutEvent(QFocusEvent *) override;

  private:
    QRectF viewport() const;
    bool point(const QPointF &, QJsonObject &) const;
    void enqueue(const QJsonObject &);
    void setControl(bool enabled);
    void key(QKeyEvent *, bool pressed);
    void reset();
    void request();
    void clear(const QString &error);
    QLocalSocket m_socket;
    QTimer m_timer, m_timeout;
    QString m_socketPath, m_desktop, m_workspace = "current", m_error;
    bool m_active = false, m_pending = false, m_humanControl = false, m_needFrame = true;
    QString m_pendingId, m_pendingMethod, m_controlRequest;
    QJsonArray m_events;
    QJsonObject m_fit, m_lastMove;
    quint64 m_paintedFrames = 0, m_lastPaintMs = 0;
    QString m_paintedFrame;
    QImage m_image;
    QJsonObject m_metadata;
    QByteArray m_input;
};
