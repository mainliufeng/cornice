#pragma once
#include <QObject>
#include <QJsonObject>
#include <QStringList>
#include <memory>

// Session clipboard sharing is product policy. No compositor-specific copy
// commands, history database or input focus are needed for a real paste.
class ClipboardBridge : public QObject {
  public:
    explicit ClipboardBridge(const QString &display, QObject *parent = nullptr);
    ~ClipboardBridge() override;
    void configure(const QStringList &seatNames, const QString &primarySeat,
                   const QString &mode, qint64 maxBytes, const QString &lockScope);
    QJsonObject status() const;
  private:
    struct Impl;
    std::unique_ptr<Impl> m;
};
