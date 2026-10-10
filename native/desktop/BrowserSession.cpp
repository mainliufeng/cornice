#include "BrowserSession.hpp"
#include <QElapsedTimer>
#include <QHostAddress>
#include <QJsonDocument>
#include <QTcpSocket>
#include <QUrl>
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <stdexcept>
#include <unistd.h>

static void failure(const QString &text) {
  throw std::runtime_error(text.toStdString());
}
BrowserSession::BrowserSession(QString program, QStringList args,
                               QProcessEnvironment env, QString log,
                               std::function<bool(const QString &)> allowed)
    : m_allowed(std::move(allowed)) {
  int commands[2], responses[2];
  if (pipe2(commands, O_CLOEXEC))
    failure("Cannot create Chrome pipe");
  if (pipe2(responses, O_CLOEXEC)) {
    close(commands[0]);
    close(commands[1]);
    failure("Cannot create Chrome pipe");
  }
  // Move child handles above fd4 before mapping Chrome's reserved pipe FDs.
  int childRead = fcntl(commands[0], F_DUPFD_CLOEXEC, 10);
  int childWrite = fcntl(responses[1], F_DUPFD_CLOEXEC, 10);
  close(commands[0]);
  close(responses[1]);
  m_write = commands[1];
  m_read = responses[0];
  try {
    if (childRead < 0 || childWrite < 0)
      failure("Cannot map Chrome pipe");
    m_process.setProcessEnvironment(env);
    m_process.setProgram(program);
    args.prepend("--remote-debugging-pipe");
    m_process.setArguments(args);
    m_process.setStandardOutputFile(log, QIODevice::Append);
    m_process.setStandardErrorFile(log, QIODevice::Append);
    m_process.setChildProcessModifier(
        [childRead, childWrite, write = m_write, read = m_read] {
          dup2(childRead, 3);
          dup2(childWrite, 4);
          if (write != 3 && write != 4)
            close(write);
          if (read != 3 && read != 4)
            close(read);
          close(childRead);
          close(childWrite);
        });
    m_process.start();
    if (!m_process.waitForStarted(2000))
      failure("Cannot start managed Chrome");
    close(childRead);
    close(childWrite);
    childRead = childWrite = -1;
    fcntl(m_read, F_SETFL, fcntl(m_read, F_GETFL) | O_NONBLOCK);
    fcntl(m_write, F_SETFL, fcntl(m_write, F_GETFL) | O_NONBLOCK);
    send({{"id", 1}, {"method", "Browser.getVersion"}});
    QElapsedTimer deadline;
    deadline.start();
    while (m_version.isEmpty() && deadline.elapsed() < 4000) {
      pollfd fd{m_read, POLLIN, 0};
      poll(&fd, 1, 100);
      receive();
    }
    if (m_version.isEmpty())
      failure("Managed Chrome did not open its debug pipe; close the old "
              "browser before starting CDP");
    if (!m_http.listen(QHostAddress::LocalHost, 0))
      failure("Cannot start authorized CDP endpoint");
    m_reader =
        std::make_unique<QSocketNotifier>(m_read, QSocketNotifier::Read, this);
    m_writer = std::make_unique<QSocketNotifier>(m_write,
                                                 QSocketNotifier::Write, this);
    m_writer->setEnabled(false);
    connect(m_writer.get(), &QSocketNotifier::activated, this, [this] {
      try {
        flush();
      } catch (...) {
        revoke();
      }
    });
    connect(m_reader.get(), &QSocketNotifier::activated, this,
            [this] { receive(); });
    connect(&m_http, &QTcpServer::newConnection, this, [this] {
      while (auto *socket = m_http.nextPendingConnection()) {
        auto *timeout = new QTimer(socket);
        timeout->setSingleShot(true);
        timeout->start(5000);
        connect(timeout, &QTimer::timeout, socket, &QTcpSocket::abort);
        connect(socket, &QTcpSocket::disconnected, socket,
                &QObject::deleteLater);
        connect(socket, &QTcpSocket::readyRead, this, [this, socket, timeout] {
          const auto bytes = socket->peek(32769);
          if (bytes.size() > 32768) {
            socket->abort();
            return;
          }
          if (!bytes.contains("\r\n\r\n"))
            return;
          const auto parts = bytes.left(bytes.indexOf("\r\n")).split(' ');
          const auto path = parts.size() == 3 && parts[0] == "GET"
                                ? QUrl(QString::fromLatin1(parts[1]))
                                      .path()
                                      .split('/', Qt::SkipEmptyParts)
                                : QStringList{};
          const auto token = path.value(0);
          if (!authorized(token)) {
            socket->readAll();
            socket->write("HTTP/1.1 403 Forbidden\r\nContent-Length: "
                          "0\r\nConnection: close\r\n\r\n");
            socket->disconnectFromHost();
            return;
          }
          timeout->stop();
          disconnect(socket, &QTcpSocket::readyRead, this, nullptr);
          if (path.size() == 4 && path[1] == "devtools" &&
              path[2] == "browser" && path[3] == "cornice") {
            m_ws.handleConnection(socket);
            return;
          }
          socket->readAll();
          if (path.size() != 3 || path[1] != "json" || path[2] != "version") {
            socket->abort();
            return;
          }
          QJsonObject version{
              {"Browser", m_version["product"]},
              {"Protocol-Version", m_version["protocolVersion"]},
              {"User-Agent", m_version["userAgent"]},
              {"V8-Version", m_version["jsVersion"]},
              {"webSocketDebuggerUrl",
               QString("ws://127.0.0.1:%1/%2/devtools/browser/cornice")
                   .arg(m_http.serverPort())
                   .arg(token)}};
          auto body = QJsonDocument(version).toJson(QJsonDocument::Compact);
          socket->write("HTTP/1.1 200 OK\r\nContent-Type: "
                        "application/json\r\nContent-Length: " +
                        QByteArray::number(body.size()) +
                        "\r\nConnection: close\r\n\r\n" + body);
          socket->disconnectFromHost();
        });
      }
    });
    connect(&m_ws, &QWebSocketServer::newConnection, this, [this] {
      while (auto *peer = m_ws.nextPendingConnection()) {
        const auto token =
            peer->requestUrl().path().split('/', Qt::SkipEmptyParts).value(0);
        if (!authorized(token)) {
          peer->close();
          peer->deleteLater();
          continue;
        }
        bool attached = false;
        for (const auto &old : m_peers)
          if (old.socket && authorized(old.token)) attached = true;
        // Revoked peers may still be closing when a replacement connects.
        if (!attached) detachTargets();
        m_peers.append({peer, token});
        connect(peer, &QWebSocket::disconnected, this, [this, peer] {
          m_peers.removeIf(
              [peer](const auto &p) { return !p.socket || p.socket == peer; });
          if (m_peers.isEmpty() && running()) detachTargets();
          peer->deleteLater();
        });
        connect(
            peer, &QWebSocket::textMessageReceived, this,
            [this, peer, token](const QString &text) {
              if (!authorized(token)) {
                peer->close(QWebSocketProtocol::CloseCodePolicyViolated,
                            "seat authorization revoked");
                return;
              }
              QJsonParseError error;
              auto document = QJsonDocument::fromJson(text.toUtf8(), &error);
              auto message = document.object();
              if (error.error != QJsonParseError::NoError ||
                  text.size() > 1024 * 1024 || !message["id"].isDouble() ||
                  !message["method"].isString() || m_requests.size() >= 256) {
                peer->close();
                return;
              }
              const auto id = ++m_nextId;
              m_requests[id] = {peer, message["id"], token};
              message["id"] = id;
              try {
                send(message, token);
              } catch (...) {
                revoke();
              }
            });
      }
    });
    connect(&m_watchdog, &QTimer::timeout, this, [this] {
      try {
        flush();
      } catch (...) {
        revoke();
      }
      const auto peers = m_peers;
      for (const auto &peer : peers)
        if (peer.socket && !authorized(peer.token))
          peer.socket->close(QWebSocketProtocol::CloseCodePolicyViolated,
                             "seat authorization revoked");
    });
    m_watchdog.start(100);
  } catch (...) {
    // The FD values might have been closed already; invalidate after each
    // successful close to avoid closing a newly allocated descriptor.
    m_process.kill();
    m_process.waitForFinished(1000);
    if (childRead >= 0)
      close(childRead);
    if (childWrite >= 0)
      close(childWrite);
    if (m_write >= 0)
      close(m_write);
    if (m_read >= 0)
      close(m_read);
    m_write = m_read = -1;
    throw;
  }
}
BrowserSession::~BrowserSession() {
  revoke();
  m_reader.reset();
  m_writer.reset();
  m_process.kill();
  m_process.waitForFinished(2000);
  if (m_write >= 0)
    close(m_write);
  if (m_read >= 0)
    close(m_read);
}
bool BrowserSession::running() const {
  return m_process.state() == QProcess::Running;
}
bool BrowserSession::authorized(const QString &token) const {
  try {
    return running() && m_allowed(token);
  } catch (...) {
    return false;
  }
}
QString BrowserSession::endpoint(const QString &token) const {
  return QString("http://127.0.0.1:%1/%2").arg(m_http.serverPort()).arg(token);
}
void BrowserSession::revoke() {
  const auto peers = m_peers;
  for (const auto &peer : peers)
    if (peer.socket)
      peer.socket->close(
          QWebSocketProtocol::CloseCodePolicyViolated,
          "seat authorization revoked; in-flight requests unconfirmed");
  m_requests.clear();
}
void BrowserSession::detachTargets() {
  // The Chrome pipe outlives a harness connection. Detach old root sessions
  // so the next CDP client receives existing targets again; keep tabs open.
  try {
    send({{"id", ++m_nextId}, {"method", "Target.setAutoAttach"},
          {"params", QJsonObject{{"autoAttach", false},
                                 {"waitForDebuggerOnStart", false},
                                 {"flatten", true}}}});
  } catch (...) { revoke(); }
}

void BrowserSession::send(QJsonObject message, QString token) {
  auto data = QJsonDocument(message).toJson(QJsonDocument::Compact);
  data.append('\0');
  if (m_queuedBytes + data.size() > 8 * 1024 * 1024)
    failure("CDP write queue full; command not sent");
  m_queuedBytes += data.size();
  m_outgoing.push_back({std::move(data), 0, std::move(token)});
  flush();
}
void BrowserSession::flush() {
  while (!m_outgoing.empty()) {
    auto &next = m_outgoing.front();
    if (!next.token.isEmpty() && !authorized(next.token)) {
      if (next.written) {
        m_process.kill();
        failure("CDP authorization changed during pipe write; browser stopped");
      }
      m_queuedBytes -= next.bytes.size();
      m_outgoing.pop_front();
      continue;
    }
    const auto count = write(m_write, next.bytes.constData() + next.written,
                             next.bytes.size() - next.written);
    if (count < 0 && errno == EINTR)
      continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (m_writer)
        m_writer->setEnabled(true);
      return;
    }
    if (count <= 0) {
      m_process.kill();
      failure("Chrome pipe failed; in-flight commands unconfirmed");
    }
    // Continue writing only the unsent suffix. Never resend a CDP command.
    next.written += count;
    if (next.written == next.bytes.size()) {
      m_queuedBytes -= next.bytes.size();
      m_outgoing.pop_front();
    }
  }
  if (m_writer)
    m_writer->setEnabled(false);
}
void BrowserSession::receive() {
  char buffer[65536];
  ssize_t count;
  while ((count = read(m_read, buffer, sizeof(buffer))) > 0)
    m_input.append(buffer, count);
  if (count == 0) {
    if (m_reader)
      m_reader->setEnabled(false);
    revoke();
    return;
  }
  if (m_input.size() > 64 * 1024 * 1024) {
    revoke();
    m_input.clear();
    return;
  }
  while (m_input.contains('\0')) {
    auto message =
        QJsonDocument::fromJson(m_input.left(m_input.indexOf('\0'))).object();
    m_input.remove(0, m_input.indexOf('\0') + 1);
    const auto id = message["id"].toInteger();
    if (id == 1) {
      m_version = message["result"].toObject();
      continue;
    }
    if (id) {
      if (!m_requests.contains(id))
        continue;
      const auto request = m_requests.take(id);
      if (!request.socket || !authorized(request.token))
        continue;
      message["id"] = request.originalId;
      request.socket->sendTextMessage(QString::fromUtf8(
          QJsonDocument(message).toJson(QJsonDocument::Compact)));
    } else {
      const auto peers = m_peers;
      for (const auto &peer : peers)
        if (peer.socket && authorized(peer.token))
          peer.socket->sendTextMessage(QString::fromUtf8(
              QJsonDocument(message).toJson(QJsonDocument::Compact)));
    }
  }
}
