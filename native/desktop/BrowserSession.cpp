#include "BrowserSession.hpp"
#include "ApplicationScope.hpp"
#include "DesktopEndpoint.hpp"
#include <QElapsedTimer>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QJsonArray>
#include <QThread>
#include <QHostAddress>
#include <QJsonDocument>
#include <QTcpSocket>
#include <QUrl>
#include <QUuid>
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
  m_log = log;
  m_startupNonce = QUuid::createUuid().toString(QUuid::WithoutBraces);
  try {
    QJsonObject requestedEnvironment;
    const auto requestedBytes = env.value("CORNICE_BROWSER_REQUESTED_ENV").toUtf8();
    if (!requestedBytes.isEmpty()) {
      QJsonParseError error;
      const auto requested = QJsonDocument::fromJson(requestedBytes, &error);
      if (error.error != QJsonParseError::NoError || !requested.isObject())
        failure("Invalid managed browser launch environment metadata");
      requestedEnvironment = requested.object();
      for (auto it = requestedEnvironment.begin(); it != requestedEnvironment.end(); ++it)
        if (it.key().isEmpty() || it.key().contains('=') || it.key().contains(QChar(0)) ||
            !it.value().isString() || it.value().toString().contains(QChar(0)))
          failure("Invalid managed browser launch environment metadata");
    }
    m_runtime = std::make_unique<QLocalSocket>();
    const auto path = qEnvironmentVariable("XDG_RUNTIME_DIR") + "/cb-" + QString::fromLatin1(QCryptographicHash::hash(log.toUtf8(), QCryptographicHash::Sha256).toHex().left(32)) + ".sock";
    CorniceEndpoint::validateSocketPath(path);
    m_startupRetry.setInterval(100);
    connect(&m_startupRetry, &QTimer::timeout, this, [this, path] {
      if (m_startupComplete) return;
      if (m_startupTime.elapsed() >= 10000) {
        finishStartup("Browser runtime startup timed out; see " + m_log + ".runtime");
        return;
      }
      if (m_runtime->state() == QLocalSocket::UnconnectedState)
        m_runtime->connectToServer(path);
    });
    connect(m_runtime.get(), &QLocalSocket::connected, this, [this, env, requestedEnvironment] {
      auto attach = QJsonDocument(QJsonObject{{"op", "attach"}, {"policy", env.value("CORNICE_BROWSER_POLICY")},
          {"requestedEnvironment", requestedEnvironment}}).toJson(QJsonDocument::Compact);
      attach.append('\0');
      if (m_runtime->write(attach) != attach.size()) {
        finishStartup("Cannot attach browser runtime");
        return;
      }
      m_runtime->flush();
    });
    connect(m_runtime.get(), &QLocalSocket::errorOccurred, this, [this, path, program, args, env, log](QLocalSocket::LocalSocketError) {
      if (m_startupComplete) { revoke(); return; }
      m_connectRetrying = true;
      m_runtime->abort();
      m_connectRetrying = false;
      if (m_startupComplete || m_helperStarted) return;
      m_helperStarted = true;
      auto helperEnvironment = env; helperEnvironment.insert("CORNICE_BROWSER_STARTUP_NONCE",m_startupNonce);
      m_helperJob = new ApplicationScope({QCoreApplication::applicationDirPath() + "/cornice-browser-runtime",{},log + ".runtime",
          {path,program,QString::fromUtf8(QJsonDocument(QJsonArray::fromStringList(args)).toJson(QJsonDocument::Compact)),log,env.value("CORNICE_BROWSER_POLICY")},helperEnvironment},this);
      m_helperJob->setSubmissionCheck([this] {
        if (m_startupComplete) return QString("Browser startup ended during application preparation");
        return m_startupSubmissionCheck ? m_startupSubmissionCheck() : QString("Browser startup authorization context missing");
      });
      m_helperJob->whenStarted([this](ApplicationScopeResult result) {
        m_startupLaunchSubmitted = m_helperJob && m_helperJob->submitted();
        if (!result.error.isEmpty() && !m_startupComplete) finishStartup(result.error);
        if (m_helperJob) { m_helperJob->deleteLater(); m_helperJob = nullptr; }
      });
    });
    connect(m_runtime.get(), &QLocalSocket::readyRead, this, [this] { receive(); });
    connect(m_runtime.get(), &QLocalSocket::disconnected, this, [this] {
      if (!m_startupComplete && !m_connectRetrying)
        finishStartup("Browser runtime disconnected during startup; see " + m_log + ".runtime");
      else if (m_startupComplete) revoke();
    });
    connect(m_runtime.get(), &QLocalSocket::bytesWritten, this, [this] { try { flush(); } catch (...) { revoke(); } });
    if (!m_http.listen(QHostAddress::LocalHost, 0))
      failure("Cannot start authorized CDP endpoint");
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
                  !message["method"].isString() || message.contains("op") ||
                  (message.contains("params") && !message["params"].isObject()) ||
                  (message.contains("sessionId") && !message["sessionId"].isString()) ||
                  m_requests.size() >= 256) {
                peer->close();
                return;
              }
              const auto id = ++m_nextId;
              m_requests[id] = {peer, message["id"], token};
              // CDP and private runtime control share a transport, not an
              // envelope. Never forward private control or arbitrary metadata.
              QJsonObject command{{"id",id},{"method",message["method"]}};
              for (const auto &key : {"params","sessionId"})
                if (message.contains(key)) command[key] = message[key];
              try {
                send(command, token);
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
    m_startupTime.start();
    m_startupRetry.start();
    m_runtime->connectToServer(path);
  } catch (...) { if (m_runtime) m_runtime->abort(); throw; }
}
BrowserSession::~BrowserSession() {
  m_watchdog.stop();
  m_startupRetry.stop();
  m_readyCallbacks.clear();
  if (m_helperJob) { delete m_helperJob; m_helperJob = nullptr; }
  QObject::disconnect(&m_ws, nullptr, this, nullptr);
  QObject::disconnect(&m_http, nullptr, this, nullptr);
  for (auto *socket : m_http.findChildren<QTcpSocket *>()) {
    QObject::disconnect(socket, nullptr, this, nullptr);
    socket->abort();
  }
  m_http.close();
  for (const auto &peer : m_peers) if (peer.socket) QObject::disconnect(peer.socket, nullptr, this, nullptr);
  if (m_runtime) QObject::disconnect(m_runtime.get(), nullptr, this, nullptr);
  revoke();
  if (m_runtime) m_runtime->abort();
}
bool BrowserSession::running() const {
  return m_startupComplete && m_startupError.isEmpty() && m_pid > 0 &&
         m_runtime && m_runtime->state() == QLocalSocket::ConnectedState;
}
bool BrowserSession::matchesLaunchEnvironment(const QJsonObject &requested) const {
  if (!running()) return false;
  for (auto it = requested.begin(); it != requested.end(); ++it)
    if (!it.value().isString() || !m_launchEnvironment.contains(it.key()) ||
        m_launchEnvironment.value(it.key()) != it.value()) return false;
  return true;
}
bool BrowserSession::setStartupSubmissionCheck(std::function<QString()> check) {
  if (!starting() || m_startupSubmissionCheck) return false;
  m_startupSubmissionCheck = std::move(check); return true;
}
void BrowserSession::cancelUnregisteredStartup(const QString &reason) {
  if (starting() && !m_startupSubmissionCheck && !launchSubmitted()) finishStartup(reason+"; no helper was submitted");
}
bool BrowserSession::launchSubmitted() const {
  return m_startupLaunchSubmitted || (m_helperJob && m_helperJob->submitted());
}
void BrowserSession::whenReady(std::function<void(QString)> callback) {
  if (m_startupComplete) {
    const auto error = m_startupError;
    QTimer::singleShot(0, this, [callback = std::move(callback), error] { callback(error); });
  } else {
    if (m_readyCallbacks.size() >= 64) failure("Browser startup waiter limit reached");
    m_readyCallbacks.append(std::move(callback));
  }
}
void BrowserSession::finishStartup(QString error) {
  if (m_startupComplete) return;
  m_startupComplete = true;
  m_startupError = std::move(error);
  m_startupRetry.stop();
  if (!m_startupError.isEmpty()) {
    if (m_helperJob) m_helperJob->cancel("Browser startup ended before its helper acknowledgement");
    m_runtime->abort();
  }
  const auto callbacks = std::move(m_readyCallbacks);
  for (const auto &callback : callbacks) {
    const auto result = m_startupError;
    QTimer::singleShot(0, this, [callback, result] { callback(result); });
  }
}
bool BrowserSession::close(const QString &log) {
  QLocalSocket socket;
  const auto path = qEnvironmentVariable("XDG_RUNTIME_DIR") + "/cb-" + QString::fromLatin1(QCryptographicHash::hash(log.toUtf8(), QCryptographicHash::Sha256).toHex().left(32)) + ".sock";
  socket.connectToServer(path);
  if (!socket.waitForConnected(500)) return true; // No live runtime to close.
  QByteArray message("{\"op\":\"shutdown\"}"); message.append('\0');
  socket.write(message); socket.flush();
  if (!socket.waitForReadyRead(3000)) return false;
  return QJsonDocument::fromJson(socket.readAll().split('\0').first()).object()["ok"].toBool();
}
bool BrowserSession::authorized(const QString &token) const {
  try {
    return running() && m_allowed(token);
  } catch (...) {
    return false;
  }
}
QString BrowserSession::endpoint(const QString &token) const {
  if (!running()) failure(m_startupError.isEmpty() ? "Browser runtime startup is pending" : m_startupError);
  return QString("http://127.0.0.1:%1/%2").arg(m_http.serverPort()).arg(token);
}
void BrowserSession::revoke() {
  if (m_helperJob && starting()) m_helperJob->cancel("Desktop control revoked during browser startup");
  if (starting()) finishStartup("Desktop control revoked during browser startup");
  const auto peers = m_peers;
  for (const auto &peer : peers)
    if (peer.socket)
      peer.socket->close(
          QWebSocketProtocol::CloseCodePolicyViolated,
          "seat authorization revoked; in-flight requests unconfirmed");
  m_requests.clear();
  // Revoke queued control as well as client sockets. Frames accepted by the
  // helper are submitted and may have an unconfirmed outcome; never replay.
  const bool incomplete = !m_outgoing.empty() && m_outgoing.front().written;
  m_outgoing.clear();
  m_queuedBytes = 0;
  if (!running()) return;
  if (incomplete) {
    // Closing this transport drops its incomplete local frame at the helper,
    // which independently owns Chrome and preserves all application state.
    m_runtime->abort();
    return;
  }
  try { send({{"op", "detach"}}); }
  catch (...) { m_runtime->abort(); }
}
void BrowserSession::detachTargets() {
  // The Chrome pipe outlives a harness connection. Detach old root sessions
  // so the next CDP client receives existing targets again; keep tabs open.
  try {
    send({{"op", "detach"}});
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
        m_runtime->abort();
        failure("CDP authorization changed during transport write; submitted command unconfirmed");
      }
      m_queuedBytes -= next.bytes.size();
      m_outgoing.pop_front();
      continue;
    }
    if (!running()) failure("Browser runtime connection closed");
    if (m_runtime->bytesToWrite() + next.bytes.size() > 8 * 1024 * 1024) failure("Browser runtime queue full");
    const auto count = m_runtime->write(next.bytes.constData() + next.written, next.bytes.size() - next.written);
    if (count < 0 && errno == EINTR)
      continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      return;
    }
    if (count <= 0) {
      m_runtime->abort();
      failure("Browser runtime transport failed; in-flight commands unconfirmed");
    }
    // Continue writing only the unsent suffix. Never resend a CDP command.
    next.written += count;
    if (next.written == next.bytes.size()) {
      m_queuedBytes -= next.bytes.size();
      m_outgoing.pop_front();
    }
  }
}
void BrowserSession::receive() {
  m_input.append(m_runtime->readAll());
  if (!m_startupComplete) {
    if (m_input.size() > 1024 * 1024) {
      finishStartup("Browser runtime greeting is too large");
      return;
    }
    if (!m_input.contains('\0')) return;
    const auto separator = m_input.indexOf('\0');
    const auto greeting = QJsonDocument::fromJson(m_input.left(separator)).object();
    m_input.remove(0, separator + 1);
    if (!greeting["ok"].toBool() || greeting["pid"].toInteger() <= 0) {
      finishStartup(greeting["error"].toString("Cannot attach browser runtime"));
      return;
    }
    if (!greeting["launchEnvironment"].isObject()) {
      finishStartup("Browser runtime did not provide its launch environment");
      return;
    }
    const auto launchEnvironment = greeting["launchEnvironment"].toObject();
    for (auto it = launchEnvironment.begin(); it != launchEnvironment.end(); ++it)
      if (!it.value().isString() || it.value().toString().contains(QChar(0))) {
        finishStartup("Invalid browser runtime launch environment");
        return;
      }
    // Private runtime metadata remains in memory and is never included in the
    // public HTTP discovery object or forwarded as a CDP event.
    m_initialArgumentsSubmitted = greeting["startupNonce"].toString() == m_startupNonce;
    m_launchEnvironment = launchEnvironment;
    m_pid = greeting["pid"].toInteger();
    m_version = greeting["version"].toObject();
    finishStartup();
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
    // Only a startup handshake may contain private runtime metadata. A
    // subsequent greeting or malformed non-CDP frame revokes public peers.
    if (message.contains("op") || message.contains("ok") || message.contains("launchEnvironment") || message.contains("startupNonce") ||
        (!message["id"].isDouble() && !message["method"].isString())) {
      revoke(); m_input.clear(); return;
    }
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
