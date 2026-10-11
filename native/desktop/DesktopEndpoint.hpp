#pragma once
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QString>
#include <stdexcept>
#include <sys/un.h>

namespace CorniceEndpoint {
inline void validateSocketPath(const QString &path) {
    const auto bytes = QFile::encodeName(path);
    constexpr auto limit = sizeof(sockaddr_un::sun_path) - 1;
    if (bytes.size() > static_cast<qsizetype>(limit) || bytes.contains('\0'))
        throw std::runtime_error(QString("Local socket path exceeds %1 encoded bytes (%2); shorten XDG_RUNTIME_DIR")
                                 .arg(limit).arg(bytes.size()).toStdString());
}
inline QString desktopSocketPath(const QString &runtime, const QString &instance) {
    if (instance == "." || instance == ".." || !QRegularExpression("^[A-Za-z0-9_.-]{1,128}$").match(instance).hasMatch())
        throw std::runtime_error("Explicit compositor instance required");
    if (runtime.isEmpty() || !QDir::isAbsolutePath(runtime) || !QFileInfo(runtime).isDir())
        throw std::runtime_error("Existing absolute XDG_RUNTIME_DIR required");
    const auto identity = QCryptographicHash::hash(instance.toUtf8(), QCryptographicHash::Sha256).toHex().left(32);
    const auto path = QDir::cleanPath(runtime) + "/cornice/ipc-" + QString::fromLatin1(identity) + "/desktop.sock";
    validateSocketPath(path);
    return path;
}
}
