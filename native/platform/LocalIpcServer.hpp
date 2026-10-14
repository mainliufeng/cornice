#pragma once

#include <QByteArray>
#include <QLockFile>
#include <QLocalServer>
#include <QLocalSocket>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QtQml/qqmlregistration.h>
#include <memory>

// JSON-line framing lives here; request dispatch remains in the shell. Each
// accepted connection owns its socket and is retired on disconnect, regardless
// of how long other connections or the listener remain alive.
class LocalIpcConnection final : public QObject {
    Q_OBJECT
    QML_ANONYMOUS
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
public:
    static constexpr qsizetype MaxFrameBytes = 1024 * 1024;
    static constexpr qint64 MaxQueuedWriteBytes = 2 * 1024 * 1024;
    explicit LocalIpcConnection(QLocalSocket* socket, QObject* parent);
    bool connected() const;
    Q_INVOKABLE bool write(const QString& text);
    Q_INVOKABLE bool flush();
    void close();
signals:
    void connectedChanged();
    void lineReceived(const QString& line);
    void transportError(const QString& reason);
    void closed();
private:
    void receive();
    void fail(const QString& reason);
    QLocalSocket* m_socket;
    QByteArray m_frame;
    bool m_retired = false;
    bool m_receiveQueued = false;
};

class LocalIpcServer : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(bool listening READ listening NOTIFY listeningChanged)
    Q_PROPERTY(QString errorString READ errorString NOTIFY errorStringChanged)
    Q_PROPERTY(int activeConnectionCount READ activeConnectionCount NOTIFY activeConnectionCountChanged)
public:
    static constexpr int MaxConnections = 128;
    explicit LocalIpcServer(QObject* parent = nullptr);
    ~LocalIpcServer() override;
    QString path() const { return m_path; }
    void setPath(const QString& path);
    bool active() const { return m_active; }
    void setActive(bool active);
    bool listening() const { return m_server.isListening(); }
    QString errorString() const { return m_errorString; }
    int activeConnectionCount() const { return m_connections.size(); }
signals:
    void pathChanged();
    void activeChanged();
    void listeningChanged();
    void errorStringChanged();
    void activeConnectionCountChanged();
    void request(QObject* connection, const QString& line);
    void connectionError(const QString& reason);
private:
    void start();
    void bind();
    void failStart(const QString& reason);
    void finishProbe();
    void stop();
    void accept();
    void setError(const QString& error);
    QLocalServer m_server;
    QSet<LocalIpcConnection*> m_connections;
    QString m_path;
    QString m_errorString;
    bool m_active = false;
    quint64 m_generation = 0;
    std::unique_ptr<QLockFile> m_pathLock;
    QPointer<QLocalSocket> m_probe;
};
