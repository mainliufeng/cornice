#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QPointer>
#include <QProcess>
#include <QString>
#include <functional>

// The broker supplies freshly seat/workspace-filtered compositor windows. This
// class never chooses a desktop or performs an unscoped accessibility search.
class Accessibility {
  public:
    using Completion = std::function<void(QJsonObject, QString)>;
    ~Accessibility();
    QProcess *snapshotAsync(const QJsonObject &window, const QJsonArray &allWindows, const QString &scope, int maxNodes,
                            int maxDepth, QObject *context, Completion complete);
    QJsonObject elementWindow(const QString &scope, const QString &elementRef);
    QProcess *actAsync(const QString &scope, const QString &elementRef, const QJsonObject &freshWindow,
                       const QJsonArray &allWindows, const QString &action, const QString &text,
                       const QJsonObject &authorization, QObject *context, Completion complete);
    void invalidate(const QString &scope);

  private:
    struct Element {
        QString scope;
        QJsonObject window, identity;
        qint64 expires;
    };
    QMap<QString, Element> m_elements;
    QList<QPointer<QProcess>> m_processes;
    QProcess *runAsync(QJsonObject request, QObject *context, Completion complete);
    static void validateWindow(const QJsonObject &window, const QJsonArray &allWindows);
};
