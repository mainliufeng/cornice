#pragma once
#include <QByteArray>
#include <QJsonObject>
#include <QString>

struct wl_display;

// Compositor transport and generic controller API. Product policy stays in Broker.
class HyprlandAdapter {
  public:
    explicit HyprlandAdapter(QString instance);
    QByteArray command(const QString &command, bool json = false) const;
    // Caller owns the returned Wayland connection. Capability/query errors throw.
    wl_display *connectManagementDisplay() const;
    QJsonObject configure(const QJsonObject &configuration) const;
    void renew(const QString &owner) const;
    void remove(const QString &owner) const;
    void ensureWorkspace(const QString &name, const QString &identity, const QString &workspace) const;
  private:
    QString m_instance;
};
