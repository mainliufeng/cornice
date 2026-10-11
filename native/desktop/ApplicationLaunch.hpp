#pragma once
#include <QJsonObject>
#include <QProcessEnvironment>
#include <QStringList>

struct ApplicationLaunchPlan {
    QString program, backend, profile, rule;
    QStringList arguments, requestedArguments, warnings;
    QJsonObject environment, requestedEnvironment;
    QByteArray policy, basePolicy;
    QJsonObject toJson() const;
    static ApplicationLaunchPlan fromJson(const QJsonObject &value);
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
