#pragma once
#include <QFile>
#include <QRegularExpression>
#include <QString>

namespace CorniceApplication {
// Inspect only a verified application's initial desktop identity. Never log or
// return the rest of its environment, and never infer identity from its title.
inline QString desktopForPid(qint64 pid) {
    if (pid <= 0) return {};
    QFile file("/proc/" + QString::number(pid) + "/environ");
    if (!file.open(QIODevice::ReadOnly)) return {};
    QString desktop, instance;
    bool display = false;
    for (const auto &entry : file.read(1024 * 1024).split('\0')) {
        if (entry.startsWith("CORNICE_DESKTOP_NAME=")) desktop = QString::fromUtf8(entry.mid(21));
        if (entry.startsWith("HYPRLAND_INSTANCE_SIGNATURE=")) instance = QString::fromUtf8(entry.mid(28));
        if (entry.startsWith("WAYLAND_DISPLAY=") || entry.startsWith("DISPLAY=")) display = true;
    }
    // A process in another login must not be labelled as this login's desktop 1.
    if (instance != qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE") || !display) return {};
    return desktop.isEmpty() ? QString("main") : desktop;
}
inline QString label(const QString &desktop) {
    if (desktop == "main") return QStringLiteral("桌面 1（人的桌面）");
    const auto match = QRegularExpression("^desktop([0-9]+)$").match(desktop);
    return match.hasMatch() ? QStringLiteral("桌面 ") + match.captured(1) : desktop;
}
}
