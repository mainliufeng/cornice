#include "LocalIpcServer.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QPointer>
#include <QStringDecoder>
#include <QTimer>
#include <cerrno>
#include <cstring>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

LocalIpcConnection::LocalIpcConnection(QLocalSocket* socket, QObject* parent)
    : QObject(parent), m_socket(socket) {
    m_socket->setParent(this);
    m_socket->setReadBufferSize(MaxFrameBytes + 1);
    connect(m_socket, &QLocalSocket::readyRead, this, &LocalIpcConnection::receive);
    connect(m_socket, &QLocalSocket::disconnected, this, &LocalIpcConnection::close);
    connect(m_socket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError error) {
        if (error != QLocalSocket::PeerClosedError) emit transportError(m_socket->errorString());
        close();
    });
    // Bytes may already be waiting when the listener accepts a connection.
    QMetaObject::invokeMethod(this, &LocalIpcConnection::receive, Qt::QueuedConnection);
}

bool LocalIpcConnection::connected() const {
    return !m_retired && m_socket->state() == QLocalSocket::ConnectedState;
}

bool LocalIpcConnection::write(const QString& text) {
    if (!connected()) return false;
    if (text.size() > MaxQueuedWriteBytes) {
        fail(QStringLiteral("IPC response buffer limit exceeded"));
        return false;
    }
    const auto bytes = text.toUtf8();
    if (bytes.size() > MaxQueuedWriteBytes || m_socket->bytesToWrite() > MaxQueuedWriteBytes - bytes.size()) {
        fail(QStringLiteral("IPC response buffer limit exceeded"));
        return false;
    }
    if (m_socket->write(bytes) != bytes.size()) {
        fail(m_socket->errorString());
        return false;
    }
    return true;
}

bool LocalIpcConnection::flush() {
    return connected() && m_socket->flush();
}

void LocalIpcConnection::fail(const QString& reason) {
    if (m_retired) return;
    emit transportError(reason);
    close();
}

void LocalIpcConnection::close() {
    if (m_retired) return;
    m_retired = true;
    m_frame.clear();
    m_socket->abort();
    emit connectedChanged();
    emit closed();
    deleteLater();
}

void LocalIpcConnection::receive() {
    m_receiveQueued = false;
    if (!connected()) return;
    // Yield after a bounded number of frames so a busy persistent client cannot
    // monopolize shell dispatch. Compact once per batch, rather than shifting a
    // large buffer for every small frame. Qt and incomplete frames are bounded.
    qsizetype consumed = 0;
    for (int dispatched = 0; dispatched < 64 && connected();) {
        auto newline = m_frame.indexOf('\n', consumed);
        if (newline < 0 && m_socket->bytesAvailable() > 0) {
            if (consumed > 0) {
                m_frame.remove(0, consumed);
                consumed = 0;
            }
            const auto room = MaxFrameBytes + 1 - m_frame.size();
            m_frame += m_socket->read(room);
            newline = m_frame.indexOf('\n');
        }
        if (newline < 0) {
            if (m_frame.size() - consumed > MaxFrameBytes) {
                fail(QStringLiteral("IPC request frame limit exceeded"));
                return;
            }
            break;
        }
        const auto length = newline - consumed;
        if (length > MaxFrameBytes) {
            fail(QStringLiteral("IPC request frame limit exceeded"));
            return;
        }
        // Each newline terminates a complete encoding unit. Stateless decoding
        // rejects an incomplete final UTF-8 sequence instead of saving it for a
        // frame that belongs to the next request.
        QStringDecoder decoder(QStringDecoder::Utf8, QStringConverter::Flag::Stateless);
        const QString line = decoder.decode(QByteArrayView(m_frame.constData() + consumed, length));
        if (decoder.hasError()) {
            fail(QStringLiteral("IPC request is not valid UTF-8"));
            return;
        }
        consumed = newline + 1;
        ++dispatched;
        QPointer<LocalIpcConnection> guard(this);
        emit lineReceived(line);
        if (!guard || !connected()) return;
    }
    if (consumed > 0) m_frame.remove(0, consumed);
    if ((m_socket->bytesAvailable() > 0 || m_frame.contains('\n')) && !m_receiveQueued) {
        m_receiveQueued = true;
        QMetaObject::invokeMethod(this, &LocalIpcConnection::receive, Qt::QueuedConnection);
    }
}

LocalIpcServer::LocalIpcServer(QObject* parent) : QObject(parent) {
    // UserAccessOption publishes with rename() on Unix and can replace another
    // listener's pathname. Bind the final path exclusively instead, apply its
    // permissions before accepting, and check peer identity on every socket.
    m_server.setSocketOptions(QLocalServer::NoOptions);
    m_server.setMaxPendingConnections(MaxConnections);
    m_server.setListenBacklogSize(MaxConnections);
    connect(&m_server, &QLocalServer::newConnection, this, &LocalIpcServer::accept);
}

LocalIpcServer::~LocalIpcServer() {
    stop();
    // Deferred deletion is correct during ordinary operation. Destroy remaining
    // wrappers now, before our active-set member and QObject's child teardown.
    for (auto* connection : findChildren<LocalIpcConnection*>(Qt::FindDirectChildrenOnly)) {
        disconnect(connection, nullptr, this, nullptr);
        delete connection;
    }
}

void LocalIpcServer::setPath(const QString& path) {
    if (path == m_path) return;
    stop();
    m_path = path;
    emit pathChanged();
    if (m_active) start();
}

void LocalIpcServer::setActive(bool active) {
    if (active == m_active) return;
    m_active = active;
    emit activeChanged();
    if (active) start();
    else stop();
}

void LocalIpcServer::setError(const QString& error) {
    if (error == m_errorString) return;
    m_errorString = error;
    emit errorStringChanged();
}

void LocalIpcServer::finishProbe() {
    if (!m_probe) return;
    auto* probe = m_probe.data();
    m_probe.clear();
    disconnect(probe, nullptr, this, nullptr);
    probe->abort();
    probe->deleteLater();
}

void LocalIpcServer::failStart(const QString& reason) {
    finishProbe();
    m_pathLock.reset();
    setError(reason);
}

void LocalIpcServer::start() {
    if (m_server.isListening() || m_probe || m_path.isEmpty()) return;
    if (!QDir::isAbsolutePath(m_path)) {
        setError(QStringLiteral("IPC socket path must be absolute"));
        return;
    }
    const auto encodedPath = QFile::encodeName(m_path);
    if (encodedPath.size() >= qsizetype(sizeof(sockaddr_un::sun_path))) {
        setError(QStringLiteral("IPC socket path is too long"));
        return;
    }
    m_pathLock = std::make_unique<QLockFile>(m_path + QStringLiteral(".lock"));
    // Locks do not expire while a live shell owns them. QLockFile still detects
    // a genuinely dead owner after a crash, without stealing a busy listener.
    m_pathLock->setStaleLockTime(0);
    if (!m_pathLock->tryLock(0)) {
        const auto reason = m_pathLock->error() == QLockFile::LockFailedError
            ? QStringLiteral("IPC endpoint is owned by another instance")
            : QStringLiteral("Cannot acquire IPC endpoint lock");
        failStart(reason);
        return;
    }
    struct stat endpoint {};
    if (::lstat(encodedPath.constData(), &endpoint) != 0) {
        if (errno == ENOENT) bind();
        else failStart(QString::fromLocal8Bit(std::strerror(errno)));
        return;
    }
    if (!S_ISSOCK(endpoint.st_mode) || endpoint.st_uid != ::getuid()) {
        failStart(QStringLiteral("Existing IPC endpoint is not a socket owned by this user"));
        return;
    }
    // Legacy listeners do not hold our lock. Probe asynchronously and preserve
    // any live endpoint. Only a definite refused/not-found connection permits
    // stale cleanup, with a second inode/owner check before unlinking.
    auto* probe = new QLocalSocket(this);
    m_probe = probe;
    const auto generation = m_generation;
    connect(probe, &QLocalSocket::connected, this, [this, probe, generation] {
        if (generation != m_generation || m_probe != probe) return;
        failStart(QStringLiteral("IPC endpoint already has a live listener"));
    });
    connect(probe, &QLocalSocket::errorOccurred, this,
        [this, probe, generation, endpoint, encodedPath](QLocalSocket::LocalSocketError error) {
            if (generation != m_generation || m_probe != probe) return;
            if (error != QLocalSocket::ConnectionRefusedError && error != QLocalSocket::ServerNotFoundError) {
                failStart(probe->errorString());
                return;
            }
            struct stat current {};
            if (::lstat(encodedPath.constData(), &current) == 0) {
                if (!S_ISSOCK(current.st_mode) || current.st_uid != ::getuid() ||
                    current.st_dev != endpoint.st_dev || current.st_ino != endpoint.st_ino) {
                    failStart(QStringLiteral("IPC endpoint changed during stale listener check"));
                    return;
                }
                if (::unlink(encodedPath.constData()) != 0) {
                    failStart(QString::fromLocal8Bit(std::strerror(errno)));
                    return;
                }
            } else if (errno != ENOENT) {
                failStart(QString::fromLocal8Bit(std::strerror(errno)));
                return;
            }
            finishProbe();
            bind();
        });
    QTimer::singleShot(250, probe, [this, probe, generation] {
        if (generation == m_generation && m_probe == probe)
            failStart(QStringLiteral("IPC listener ownership check timed out"));
    });
    probe->connectToServer(m_path);
}

void LocalIpcServer::bind() {
    if (!m_active || !m_pathLock || !m_pathLock->isLocked()) return;
    if (!m_server.listen(m_path)) {
        failStart(m_server.errorString());
        return;
    }
    if (::chmod(QFile::encodeName(m_path).constData(), S_IRUSR | S_IWUSR) != 0) {
        const auto error = QString::fromLocal8Bit(std::strerror(errno));
        m_server.close();
        failStart(error);
        return;
    }
    setError({});
    emit listeningChanged();
}

void LocalIpcServer::stop() {
    ++m_generation;
    finishProbe();
    const auto wasListening = m_server.isListening();
    m_server.close();
    m_pathLock.reset();
    const auto connections = m_connections;
    for (auto* connection : connections) connection->close();
    if (wasListening) emit listeningChanged();
}

void LocalIpcServer::accept() {
    while (m_server.hasPendingConnections()) {
        auto* socket = m_server.nextPendingConnection();
        if (!socket) continue;
        struct ucred peer {};
        socklen_t size = sizeof(peer);
        if (::getsockopt(socket->socketDescriptor(), SOL_SOCKET, SO_PEERCRED, &peer, &size) != 0 ||
            size != sizeof(peer) || peer.uid != ::getuid()) {
            socket->abort();
            socket->deleteLater();
            emit connectionError(QStringLiteral("IPC peer identity rejected"));
            continue;
        }
        if (m_connections.size() >= MaxConnections) {
            socket->abort();
            socket->deleteLater();
            emit connectionError(QStringLiteral("IPC active connection limit exceeded"));
            continue;
        }
        auto* connection = new LocalIpcConnection(socket, this);
        m_connections.insert(connection);
        emit activeConnectionCountChanged();
        connect(connection, &LocalIpcConnection::lineReceived, this, [this, connection](const QString& line) {
            emit request(connection, line);
        });
        connect(connection, &LocalIpcConnection::transportError, this, &LocalIpcServer::connectionError);
        const auto removed = [this, connection] {
            if (m_connections.remove(connection)) emit activeConnectionCountChanged();
        };
        connect(connection, &LocalIpcConnection::closed, this, removed);
        connect(connection, &QObject::destroyed, this, removed);
    }
}
