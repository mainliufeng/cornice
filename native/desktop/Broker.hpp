#pragma once
#include "BrowserSession.hpp"
#include "Accessibility.hpp"
#include "HyprlandAdapter.hpp"
#include "SeatDriver.hpp"
#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMap>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <map>
#include <memory>

QString desktopSocket(const QString &instance);
QJsonObject desktopRequest(const QString &socket, const QJsonObject &request);

class Broker : public QObject {
    Q_OBJECT
  public:
    explicit Broker(QString instance);
    ~Broker();
    void listen();

  private:
    struct Desktop {
        QString id;
        QString captureGrant, privateOutput;
        std::unique_ptr<SeatDriver> driver;
        std::unique_ptr<BrowserSession> browser;
        std::unique_ptr<QProcess> shell;
        qint64 shellRestartAt = 0;
        bool agentAllowed = true;
        bool primary = false;
        int number = 0;
        QMap<int, QString> workspaceSlots;
        QString configurationOwner, configurationError;
        QJsonObject lastConfiguration;
        QJsonArray bindingOverrides;
        QJsonArray handoffs;

    };
    struct Binding {
        QString name, id, generation;
        QMap<QString, QJsonObject> frames;
        QStringList frameOrder;
        QString controller, harness, snapshotId;
        QJsonObject snapshotState;
        QElapsedTimer heartbeat;
    };
    QByteArray compositor(const QString &command, bool json = false);
    QJsonObject state(const QString &name);
    QJsonObject handle(const QJsonObject &, QLocalSocket *);
    void handleNative(const QJsonObject &, QLocalSocket *);
    QJsonObject perform(const QString &method, const QJsonObject &, Binding *, QLocalSocket *);
    QJsonObject capture(const QString &name, const QString &id, const QString &workspace, QLocalSocket *owner,
                        const QString &format, bool agent = false);
    Desktop &managed(const QString &name);
    void save();
    void initializeSlots(const QString &name, const QJsonObject &saved = {});
    void configureDesktop(const QString &name);

    QJsonObject acquireDesktop(const QJsonObject &, QLocalSocket *);
    void releaseAcquisition(QLocalSocket *);
    QJsonObject handoff(const QJsonObject &);
    void transitionHandoff(const QString &name, const QString &id, const QString &status, const QString &note);
    QString m_humanRequestId;
    void revokeBindings(const QString &name);
    void startShell(const QString &name);
    void pause(const QString &name);
    void endTakeover(const QString &reason);
    void resume(const QString &name);
    void validateFrame(const Binding &, const QString &frame, const QJsonObject &actual);
    int m_nextDesktopNumber = 2;
    QString m_instance, m_socketPath, m_directory;
    QLocalServer m_server;
    QLocalSocket m_events;
    QByteArray m_eventInput;
    QTimer m_watchdog;
    QElapsedTimer m_configurationHeartbeat;
    HyprlandAdapter m_compositor;
    std::map<QString, Desktop> m_desktops;
    QMap<QString, Binding> m_bindings;
    Accessibility m_accessibility;
    QMap<QString, QPointer<QProcess>> m_nativeJobs;
    QMap<QString, QByteArray> m_pendingNativeHashes;
    QLocalSocket *m_humanOwner = nullptr;
    Binding m_humanBinding;
    QElapsedTimer m_humanHeartbeat;
    QMap<QLocalSocket *, QString> m_buffers;
    QMap<QLocalSocket *, QString> m_presentations;
    QMap<QLocalSocket *, QJsonObject> m_acquisitions;
    QMap<QString, QJsonObject> m_completed;
    QMap<QString, QByteArray> m_requestHashes;
};
