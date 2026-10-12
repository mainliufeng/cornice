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

class ClipboardBridge;
class ApplicationScope;
struct ApplicationLaunchPlan;

QString desktopSocket(const QString &instance);
QJsonObject desktopRequest(const QString &socket, const QJsonObject &request);

class Broker : public QObject {
    Q_OBJECT
  public:
    explicit Broker(QString instance);
    ~Broker();
    void listen();

  private:
    friend class BrokerHandoffFixture; // Test-only private transport fixture.
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
        quint64 inputDecision = 0;
        QByteArray browserPolicy, browserConfiguration;
        QString stableId, geometry, outputName, initialWorkspace, lockPolicy = "pause";
        quint64 revision = 1;

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
    QJsonObject handle(const QJsonObject &, QLocalSocket *, const ApplicationLaunchPlan *launchPlan = nullptr);
    void deferLaunch(const QJsonObject &, QLocalSocket *, const QString &);
    void deferApplication(const QJsonObject &, QLocalSocket *, const QString &, ApplicationScope *, const QStringList &);
    void handleNative(const QJsonObject &, QLocalSocket *);
    void deferBrowser(const QJsonObject &, QLocalSocket *, const QString &, bool firstLaunch, const QStringList &warnings, std::shared_ptr<ApplicationLaunchPlan> plan = {});
    QJsonObject perform(const QString &method, const QJsonObject &, Binding *, QLocalSocket *, const ApplicationLaunchPlan *launchPlan = nullptr);
    QJsonObject capture(const QString &name, const QString &id, const QString &workspace, QLocalSocket *owner,
                        const QString &format, bool agent = false);
    Desktop &managed(const QString &name);
    void save();
    QJsonObject resourceLimits() const;
    void updateClipboard();
    QJsonObject clipboardStatus() const;
    void checkResources(const QString &geometry, const QString &replacing = {});
    QJsonObject definition(const QString &name);
    void restoreDefinition(const QString &name, const QJsonObject &spec);
    void closeDesktopApps(const QString &name);
    bool occupied(const QString &name) const;
    void retireBinding(const QString &token);
    QMap<QLocalSocket *, QJsonObject>::iterator taskLease(const QJsonObject &request);
    QJsonObject renewTaskBinding(QLocalSocket *owner);
    bool taskControlContinuous(const QJsonObject &lease, const QJsonObject &actual) const;
    QJsonObject task(const QJsonObject &request);
    void waitTask(const QJsonObject &request, QLocalSocket *owner);
    void publishTaskState(const QString &name);
    void initializeSlots(const QString &name, const QJsonObject &saved = {});
    void configureDesktop(const QString &name);
    void ensureBrowser(const QString &name, const QString &program = {}, const QStringList &arguments = {}, const ApplicationLaunchPlan *prepared = nullptr);

    QJsonObject acquireDesktop(const QJsonObject &, QLocalSocket *);
    void releaseAcquisition(QLocalSocket *);
    QJsonObject handoff(const QJsonObject &);
    void transitionHandoff(const QString &name, const QString &id, const QString &status, const QString &note);
    void resolveHandoff(const QString &name, const QString &id, const QString &status, const QString &note, const QString &reason);
    QString m_humanRequestId;
    void revokeBindings(const QString &name);
    void startShell(const QString &name);
    void pause(const QString &name);
    void endTakeover(const QString &reason, bool requeueRequest = true);
    void resume(const QString &name);
    void validateFrame(const Binding &, const QString &frame, const QJsonObject &actual);
    int m_nextDesktopNumber = 2;
    QString m_instance, m_socketPath, m_directory, m_statePath;
    bool m_restoring = true;
    QJsonObject m_definitions, m_restoreErrors, m_capabilities;
    QMap<QString, QByteArray> m_taskStates;
    std::unique_ptr<ClipboardBridge> m_clipboard;
    QString m_clipboardError;
    QMap<QString,QJsonArray> m_windows;
    QMap<QString,qint64> m_windowsAt;
    QJsonArray m_clients;
    qint64 m_clientsAt=0;
    struct Waiter { QString id, name, taskToken; quint64 revision; qint64 deadline; };
    QMap<QLocalSocket *, Waiter> m_taskWaiters;
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
    QMap<QString, QByteArray> m_pendingBrowserHashes;
    QMap<QString, QByteArray> m_pendingLaunchHashes;
    QMap<QString, QPointer<QProcess>> m_launchJobs;
    QMap<QString, QPointer<ApplicationScope>> m_applicationJobs;
    QMap<QString, QByteArray> m_pendingApplicationHashes;
    QLocalSocket *m_humanOwner = nullptr;
    Binding m_humanBinding;
    QElapsedTimer m_humanHeartbeat;
    bool m_restoreTaskOnRelease = false;
    quint64 m_takeoverInputDecision = 0;
    QJsonValue m_takeoverLockEpoch;
    QMap<QLocalSocket *, QString> m_buffers;
    QMap<QLocalSocket *, QString> m_presentations;
    QMap<QLocalSocket *, QJsonObject> m_presentationStates;
    QMap<QLocalSocket *, QJsonArray> m_localOverlays;
    QMap<QLocalSocket *, QJsonObject> m_acquisitions;
    QMap<QString, QJsonObject> m_completed;
    QMap<QString, QByteArray> m_requestHashes;
};
