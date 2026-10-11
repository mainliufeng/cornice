#pragma once
#include <QElapsedTimer>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QProcessEnvironment>
#include <QLocalSocket>
#include <QTcpServer>
#include <QTimer>
#include <QWebSocket>
#include <QWebSocketServer>
#include <deque>
#include <functional>
#include <memory>

// Chrome has no listening debug port. Every HTTP discovery, WS command and
// outbound event passes the current seat/binding authorization check.
class BrowserSession : public QObject {
public:
  BrowserSession(QString program, QStringList args, QProcessEnvironment env,
                 QString log, std::function<bool(const QString &)> allowed);
  ~BrowserSession() override;
  QString endpoint(const QString &token) const;
  void revoke();
  bool running() const;
  bool starting() const { return !m_startupComplete; }
  QString startupError() const { return m_startupError; }
  void whenReady(std::function<void(QString)> callback);
  bool matchesLaunchEnvironment(const QJsonObject &requested) const;
  qint64 pid() const { return m_pid; }
  static bool close(const QString &log);

private:
  void receive();
  void finishStartup(QString error = {});
  void send(QJsonObject message, QString token = {});
  void flush();
  void detachTargets();
  bool authorized(const QString &token) const;
  struct Peer {
    QPointer<QWebSocket> socket;
    QString token;
  };
  struct Request {
    QPointer<QWebSocket> socket;
    QJsonValue originalId;
    QString token;
  };
  std::unique_ptr<QLocalSocket> m_runtime;
  QString m_log;
  qint64 m_pid = 0;
  QTcpServer m_http;
  QWebSocketServer m_ws{"Cornice seat CDP", QWebSocketServer::NonSecureMode};
  struct Outgoing {
    QByteArray bytes;
    qsizetype written = 0;
    QString token;
  };
  std::deque<Outgoing> m_outgoing;
  qsizetype m_queuedBytes = 0;
  std::function<bool(const QString &)> m_allowed;
  QList<Peer> m_peers;
  QMap<qint64, Request> m_requests;
  QJsonObject m_version;
  QJsonObject m_launchEnvironment;
  QByteArray m_input;
  QTimer m_watchdog;
  QTimer m_startupRetry;
  QElapsedTimer m_startupTime;
  bool m_startupComplete = false;
  bool m_helperStarted = false;
  bool m_connectRetrying = false;
  QString m_startupError;
  QList<std::function<void(QString)>> m_readyCallbacks;
  qint64 m_nextId = 1;
};
