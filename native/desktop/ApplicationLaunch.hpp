#pragma once
#include <QJsonObject>
#include <QProcessEnvironment>
#include <QStringList>

struct ApplicationLaunchPlan {
    QString program, backend, profile, rule;
    QStringList arguments;
    QJsonObject environment;
    QByteArray policy;
    void applyEnvironment(QProcessEnvironment &target) const;
};

// Product launch policy comes from Cornice's merged configuration. The Broker
// retains compositor identity, authorization and browser transport ownership.
class ApplicationLaunch {
  public:
    static ApplicationLaunchPlan prepare(const QStringList &argv, const QString &desktop, bool primary);
    static ApplicationLaunchPlan browser(const QString &desktop, bool primary, const QString &program = {},
                                         const QStringList &arguments = {});
};
