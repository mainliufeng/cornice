#include "ScreenshotController.hpp"
#include <QBuffer>
#include <QClipboard>
#include <QDir>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QMimeData>
#include <QPointer>
#include <QQuickItemGrabResult>
#include <QStandardPaths>
#include <QTemporaryFile>
#include <QUuid>
#include <QtConcurrent/QtConcurrentRun>
#include <cmath>
#include <cstdio>
#include <unistd.h>

namespace {
// Only ordinary values cross the worker boundary. The last future/result owner
// removes an unpublished staging file even if its controller has been destroyed.
struct StagedFile {
    QString path;
    ~StagedFile() { if (!path.isEmpty()) QFile::remove(path); }
};
struct ExportResult {
    QString path;
    QString error;
    QByteArray png;
    std::shared_ptr<StagedFile> staging;
};

ExportResult prepareExport(QImage image, QRect pixels, QSize sourceSize, QString path,
                           const std::shared_ptr<std::atomic_bool>& cancelled, bool createDirectory) {
    const auto stopped = [&] { return cancelled->load(std::memory_order_relaxed); };
    if (stopped()) return {};
    if (image.size() != sourceSize) image = image.scaled(sourceSize, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    if (stopped()) return {};
    image = image.copy(pixels);
    image.setDevicePixelRatio(1);
    if (image.isNull()) return {{}, QStringLiteral("截图帧为空"), {}, {}};
    QByteArray png;
    QBuffer buffer(&png);
    buffer.open(QIODevice::WriteOnly);
    if (!image.save(&buffer, "PNG")) return {{}, QStringLiteral("无法编码截图"), {}, {}};
    if (stopped()) return {};
    const auto directory = QFileInfo(path).absolutePath();
    if (createDirectory && !QDir().mkpath(directory)) return {{}, QStringLiteral("无法创建截图目录"), {}, {}};
    QTemporaryFile output(directory + QStringLiteral("/.cornice-screenshot-XXXXXX"));
    if (!output.open() || !output.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner) ||
        output.write(png) != png.size() || !output.flush() || ::fsync(output.handle()) != 0)
        return {{}, QStringLiteral("无法保存截图"), {}, {}};
    if (stopped()) return {};
    auto staging = std::make_shared<StagedFile>();
    staging->path = output.fileName();
    output.setAutoRemove(false);
    output.close();
    return {std::move(path), {}, std::move(png), std::move(staging)};
}
}

ScreenshotController::~ScreenshotController() { cancel(); }

void ScreenshotController::cancel() {
    ++m_revision;
    if (m_cancelled) m_cancelled->store(true, std::memory_order_relaxed);
    m_cancelled.reset();
}

void ScreenshotController::save(QQuickItem* frame, QRectF region, QSize sourceSize, const QString& destination) {
    cancel();
    const auto revision = m_revision;
    auto cancelled = std::make_shared<std::atomic_bool>(false);
    m_cancelled = cancelled;
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
    const bool createDirectory = destination.isEmpty();
    QString path = destination;
    if (path.isEmpty())
        path = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) +
            QStringLiteral("/Screenshots/Screenshot-") + QUuid::createUuid().toString(QUuid::WithoutBraces) + QStringLiteral(".png");
    if (!QFileInfo(path).isAbsolute()) { emit failed(QStringLiteral("截图路径必须是绝对路径")); return; }
    auto grab = frame->grabToImage();
    if (!grab) { emit failed(QStringLiteral("无法读取截图帧")); return; }
    // Grab and completion live on the GUI thread. Watcher lifetime belongs to
    // this controller; a destroyed/cancelled/locked/replaced session cannot publish.
    QPointer<ScreenshotController> owner(this);
    connect(grab.data(), &QQuickItemGrabResult::ready, this, [owner, grab, revision, pixels, sourceSize, path, cancelled, createDirectory] {
        if (!owner || revision != owner->m_revision) return;
        const auto image = grab->image();
        if (image.isNull()) { emit owner->failed(QStringLiteral("截图帧为空")); return; }
        auto* watcher = new QFutureWatcher<ExportResult>(owner);
        connect(watcher, &QFutureWatcher<ExportResult>::finished, owner, [owner, watcher, revision, cancelled] {
            watcher->deleteLater();
            if (!owner || revision != owner->m_revision || cancelled->load(std::memory_order_relaxed)) return;
            ExportResult result;
            try { result = watcher->result(); }
            catch (...) { emit owner->failed(QStringLiteral("无法处理截图")); return; }
            if (!result.error.isEmpty()) { emit owner->failed(result.error); return; }
            if (!result.staging) return;
            // Linearization: cancel and commit are ordered by the GUI event
            // loop. All bytes were encoded, written and synced off-thread; one
            // same-directory atomic rename preserves an existing file on failure.
            if (std::rename(QFile::encodeName(result.staging->path).constData(),
                            QFile::encodeName(result.path).constData()) != 0) {
                emit owner->failed(QStringLiteral("无法保存截图"));
                return;
            }
            result.staging->path.clear();
            auto* mime = new QMimeData;
            // Do not advertise every Qt image codec: clipboard bridges request
            // all advertised MIME types, which otherwise encode on the GUI thread.
            mime->setData(QStringLiteral("image/png"), result.png);
            QGuiApplication::clipboard()->setMimeData(mime);
            if (owner && revision == owner->m_revision) emit owner->saved(result.path);
        }, Qt::SingleShotConnection);
        watcher->setFuture(QtConcurrent::run([image, pixels, sourceSize, path, cancelled, createDirectory] {
            try { return prepareExport(image, pixels, sourceSize, path, cancelled, createDirectory); }
            catch (...) { return ExportResult{{}, QStringLiteral("无法处理截图"), {}, {}}; }
        }));
    }, Qt::SingleShotConnection);
}
