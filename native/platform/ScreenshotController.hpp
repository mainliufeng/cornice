#pragma once
#include <QObject>
#include <QQuickItem>
#include <QRectF>
#include <QSize>
#include <QtQml/qqmlregistration.h>

// Core shell functionality, independent of the optional agent desktop module.
// Owns export, atomic persistence, clipboard publication and cancellation.
class ScreenshotController : public QObject {
    Q_OBJECT
    QML_ELEMENT
public:
    using QObject::QObject;
    Q_INVOKABLE void save(QQuickItem* frame, QRectF region, QSize sourceSize, const QString& destination);
    Q_INVOKABLE void cancel();
signals:
    void saved(const QString& path);
    void failed(const QString& reason);
private:
    quint64 m_revision = 0;
};
