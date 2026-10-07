#pragma once
#include "SeatDriver.hpp"
#include "BrowserSession.hpp"
#include <QJsonArray>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMap>
#include <QObject>
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
    };
    struct Binding {
        QString name, id, generation;
        QMap<QString, QJsonObject> frames;
        QStringList frameOrder;
    };
    QByteArray compositor(const QString &command, bool json = false);
    QJsonObject state(const QString &name);
    QJsonObject handle(const QJsonObject &, QLocalSocket *);
    QJsonObject perform(const QString &method, const QJsonObject &, Binding *, QLocalSocket *);
    QJsonObject capture(const QString &name, const QString &id, const QString &workspace, QLocalSocket *owner,
                        const QString &format, bool agent = false);
    Desktop &managed(const QString &name);
    void save();
    void pause(const QString &name);
    void validateFrame(const Binding &, const QString &frame, const QJsonObject &actual);
    QString m_instance, m_socketPath, m_directory;
    QLocalServer m_server;
    QLocalSocket m_events;
    QByteArray m_eventInput;
    QTimer m_watchdog;
    std::map<QString, Desktop> m_desktops;
    QMap<QString, Binding> m_bindings;
    QMap<QLocalSocket *, QString> m_buffers;
    QMap<QString, QJsonObject> m_completed;
    QMap<QString, QByteArray> m_requestHashes;
};
