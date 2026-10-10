#pragma once
#include <QJsonObject>
#include <QLocalSocket>
#include <QObject>
#include <QQmlEngine>
#include <QTimer>

// Control and status only. Hyprland owns all presentation and input.
class DesktopPresentation : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString socketPath MEMBER m_socketPath NOTIFY targetChanged)
    Q_PROPERTY(QString desktop MEMBER m_desktop NOTIFY targetChanged)
    Q_PROPERTY(QString workspace MEMBER m_workspace NOTIFY targetChanged)
    Q_PROPERTY(bool active MEMBER m_active NOTIFY targetChanged)
    Q_PROPERTY(QJsonObject state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString error MEMBER m_error NOTIFY stateChanged)
    Q_PROPERTY(bool humanControl READ humanControl NOTIFY stateChanged)
  public:
    explicit DesktopPresentation(QObject *parent = nullptr);
    QJsonObject state() const { return m_state; }
    bool humanControl() const { return m_state["humanControl"].toBool(); }
    Q_INVOKABLE void takeControl(bool enabled);
    Q_INVOKABLE void takeHandoff(const QString &requestId);
    Q_INVOKABLE void refreshView();
    Q_INVOKABLE void refreshStatus();
  signals:
    void targetChanged();
    void stateChanged();
    void returned();

  private:
    void reset();
    void request();
    QLocalSocket m_socket;
    QTimer m_poll, m_timeout;
    QString m_socketPath, m_desktop, m_workspace = "current", m_error, m_control, m_id, m_method,
                                     m_connectedPath, m_handoffId;
    QJsonObject m_state;
    QByteArray m_input;
    bool m_active = false, m_pending = false, m_present = true, m_refresh = false;
};

#include <QImage>
#include <QQuickPaintedItem>

// Read-only low-rate preview. Never owns a seat or forwards pointer/keyboard input.
class DesktopThumbnail : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString socketPath MEMBER m_socketPath NOTIFY targetChanged)
    Q_PROPERTY(QString desktop MEMBER m_desktop NOTIFY targetChanged)
    Q_PROPERTY(bool active MEMBER m_active NOTIFY targetChanged)
    Q_PROPERTY(QString error READ error NOTIFY statusChanged)
    Q_PROPERTY(int frameCount READ frameCount NOTIFY statusChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY statusChanged)
    Q_PROPERTY(int invalidations READ invalidations NOTIFY statusChanged)
  public:
    explicit DesktopThumbnail(QQuickItem *parent = nullptr);
    void paint(QPainter *painter) override;
    QString error() const { return m_error; }
    int frameCount() const { return m_frameCount; }
    bool hasFrame() const { return !m_image.isNull(); }
    int invalidations() const { return m_invalidations; }
  signals:
    void targetChanged();
    void statusChanged();
  private:
    void reset();
    void request();
    void unavailable(const QString &error);
    QLocalSocket m_socket;
    QTimer m_poll, m_timeout;
    QString m_socketPath, m_desktop, m_error, m_id;
    QByteArray m_input;
    QImage m_image;
    bool m_active = false, m_pending = false;
    int m_frameCount = 0, m_invalidations = 0;
};
