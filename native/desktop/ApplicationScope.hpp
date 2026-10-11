#pragma once
#include <QObject>
#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QMap>
#include <QProcessEnvironment>
#include <QTimer>
#include <functional>

struct ApplicationScopeSpec {
    QString program, workingDirectory, log;
    QStringList arguments;
    QProcessEnvironment environment;
};
struct ApplicationScopeResult {
    qint64 pid = 0;
    QString error, unit;
    bool managed = false, exited = false;
};
// An application unit belongs to the compositor instance, never its shell or
// Broker service. Completion reports the executed application's real PID.
class ApplicationScope : public QObject {
    Q_OBJECT
public:
    explicit ApplicationScope(ApplicationScopeSpec spec, QObject *parent = nullptr);
    static QString sliceForCgroup(const QString &path);
    static QStringList unsetManagerKeys(const QProcessEnvironment &, const QStringList &, bool notify);
    ~ApplicationScope() override;
    void whenStarted(std::function<void(ApplicationScopeResult)> callback);
    void cancel(const QString &reason);
    void setSubmissionCheck(std::function<QString()> check) { m_submissionCheck = std::move(check); }
    bool submitted() const { return m_submitted; }
    bool preparingGuard() const { return !m_done && m_waitGuard; }
private slots:
    void jobRemoved(uint id, QDBusObjectPath job, QString unit, QString result);
private:
    void begin();
    void readManagerEnvironment();
    void submitGuard();
    void submitApplication();
    void submit(const QString &unit, const QVariantList &properties, bool guard);
    void inspectGuard();
    void inspectApplication();
    void finish(QString error = {});
    void continueJob(const QString &result);
    bool checkSubmission();
    ApplicationScopeSpec m_spec;
    ApplicationScopeResult m_result;
    QString m_connectionName, m_guard, m_waitUnit, m_job;
    QStringList m_managerEnvironmentKeys;
    QDBusConnection m_bus;
    QMap<QString, QString> m_earlyResults;
    QTimer m_deadline;
    bool m_done = false, m_submitted = false, m_waitGuard = false;
    QList<std::function<void(ApplicationScopeResult)>> m_callbacks;
    std::function<QString()> m_submissionCheck;
};
