#pragma once
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSocketNotifier>
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
  qint64 pid() const { return m_process.processId(); }

private:
  void receive();
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
  QProcess m_process;
  QTcpServer m_http;
  QWebSocketServer m_ws{"Cornice seat CDP", QWebSocketServer::NonSecureMode};
  std::unique_ptr<QSocketNotifier> m_reader, m_writer;
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
  QByteArray m_input;
  QTimer m_watchdog;
  int m_write = -1, m_read = -1;
  qint64 m_nextId = 1;
};
