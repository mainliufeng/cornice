#include "ScreenshotController.hpp"
#include <QBuffer>
#include <QClipboard>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QMimeData>
#include <QPointer>
#include <QQuickItemGrabResult>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>
#include <cmath>

void ScreenshotController::cancel() { ++m_revision; }

void ScreenshotController::save(QQuickItem* frame, QRectF region, QSize sourceSize, const QString& destination) {
    const auto revision = ++m_revision;
    if (!frame || frame->width() <= 0 || frame->height() <= 0 || sourceSize.isEmpty() || region.isEmpty()) {
        emit failed(QStringLiteral("截图区域无效"));
        return;
    }
    const auto bounds = QRectF(0, 0, frame->width(), frame->height());
    region = region.intersected(bounds);
    if (region.isEmpty()) { emit failed(QStringLiteral("截图区域无效")); return; }
    const auto ratioX = sourceSize.width() / bounds.width();
    const auto ratioY = sourceSize.height() / bounds.height();
    const auto pixels = QRect(QPoint(std::lround(region.left() * ratioX), std::lround(region.top() * ratioY)),
                              QPoint(std::lround(region.right() * ratioX) - 1, std::lround(region.bottom() * ratioY) - 1));
    auto grab = frame->grabToImage();
    if (!grab) { emit failed(QStringLiteral("无法读取截图帧")); return; }
    // Hold the asynchronous grab until ready, without keeping this controller
    // alive. A cancelled/locked/replaced session can never export an old frame.
    QPointer<ScreenshotController> owner(this);
    connect(grab.data(), &QQuickItemGrabResult::ready, this, [owner, grab, revision, pixels, sourceSize, destination] {
        if (!owner || revision != owner->m_revision) return;
        auto image = grab->image();
        if (image.isNull()) { emit owner->failed(QStringLiteral("截图帧为空")); return; }
        if (image.size() != sourceSize) image = image.scaled(sourceSize, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
        image = image.copy(pixels);
        image.setDevicePixelRatio(1);
        QString path = destination;
        if (path.isEmpty()) {
            const auto directory = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) + QStringLiteral("/Screenshots");
            if (!QDir().mkpath(directory)) { emit owner->failed(QStringLiteral("无法创建截图目录")); return; }
            path = directory + QStringLiteral("/Screenshot-") + QUuid::createUuid().toString(QUuid::WithoutBraces) + QStringLiteral(".png");
        }
        if (!QFileInfo(path).isAbsolute()) { emit owner->failed(QStringLiteral("截图路径必须是绝对路径")); return; }
        QByteArray png;
        QBuffer buffer(&png);
        buffer.open(QIODevice::WriteOnly);
        if (!image.save(&buffer, "PNG")) { emit owner->failed(QStringLiteral("无法编码截图")); return; }
        QSaveFile output(path);
        // Private, atomic writes; a failed write leaves an existing image intact.
        if (!output.open(QIODevice::WriteOnly) || !output.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner) ||
            output.write(png) != png.size() || !output.commit()) {
            emit owner->failed(QStringLiteral("无法保存截图")); return;
        }
        auto* mime = new QMimeData;
        mime->setImageData(image);
        mime->setData(QStringLiteral("image/png"), png);
        QGuiApplication::clipboard()->setMimeData(mime);
        emit owner->saved(path);
    }, Qt::SingleShotConnection);
}
