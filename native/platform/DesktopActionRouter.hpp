#pragma once

#include <QObject>
#include <QVariantMap>
#include <QSet>
#include <QtQml/qqmlregistration.h>

// A source snapshot belongs to one invocation, never to the Shell's later
// selection. The compositor validates identity, generation and workspace.
class DesktopActionRouter : public QObject {
    Q_OBJECT
    QML_ELEMENT
public:
    explicit DesktopActionRouter(QObject* parent = nullptr);
    Q_INVOKABLE QString prepare(const QString& desktop, const QString& seat,
                               const QString& generation, const QString& workspace, const QString& output = QString{});
    Q_INVOKABLE QString invokeTray(QObject* item, QObject* entry, const QString& method,
                                  const QVariantMap& context, int delta = 0, bool horizontal = false);
signals:
    void prepared(const QString& request, const QVariantMap& context, const QString& error);
    void actionFinished(const QString& request, bool success, const QString& error);
private:
    // Bounds ordinary human actions; this is not a token association lock.
    QSet<QString> m_busyItems;
    int m_pending = 0;
};
