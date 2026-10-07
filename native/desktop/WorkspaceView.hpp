#pragma once
#include <QImage>
#include <QJsonObject>
#include <QLocalSocket>
#include <QQmlEngine>
#include <QQuickPaintedItem>
#include <QTimer>

// Read-only consumer. No target input device or agent credential is created.
class WorkspaceView : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString socketPath MEMBER m_socketPath NOTIFY targetChanged)
    Q_PROPERTY(QString desktop MEMBER m_desktop NOTIFY targetChanged)
    Q_PROPERTY(QString workspace MEMBER m_workspace NOTIFY targetChanged)
    Q_PROPERTY(bool active MEMBER m_active NOTIFY targetChanged)
    Q_PROPERTY(QString error READ error NOTIFY frameChanged)
    Q_PROPERTY(QJsonObject metadata READ metadata NOTIFY frameChanged)
    Q_PROPERTY(quint64 paintedFrames READ paintedFrames NOTIFY paintChanged)
    Q_PROPERTY(quint64 lastPaintMs MEMBER m_lastPaintMs NOTIFY paintChanged)
  public:
    explicit WorkspaceView(QQuickItem *parent = nullptr);
    void paint(QPainter *) override;
    QString error() const { return m_error; }
    QJsonObject metadata() const { return m_metadata; }
    quint64 paintedFrames() const { return m_paintedFrames; }
  signals:
    void targetChanged();
    void frameChanged();
    void paintChanged();

  private:
    void reset();
    void request();
    void clear(const QString &error);
    QLocalSocket m_socket;
    QTimer m_timer, m_timeout;
    QString m_socketPath, m_desktop, m_workspace = "current", m_error;
    bool m_active = false, m_pending = false;
    quint64 m_paintedFrames = 0, m_lastPaintMs = 0;
    QString m_paintedFrame;
    QImage m_image;
    QJsonObject m_metadata;
    QByteArray m_input;
};
