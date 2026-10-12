#include "../../native/platform/ScreenshotController.hpp"
#include <QClipboard>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QImage>
#include <QMimeData>
#include <QPainter>
#include <QProcess>
#include <QQuickPaintedItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTimer>
#include <QtTest>
#include <sys/stat.h>

class Frame : public QQuickPaintedItem {
public:
    explicit Frame(QQuickItem* parent) : QQuickPaintedItem(parent), pixels(4096, 4096, QImage::Format_RGB32) {
        quint32 seed = 1;
        for (int y = 0; y < pixels.height(); ++y) {
            auto* row = reinterpret_cast<quint32*>(pixels.scanLine(y));
            for (int x = 0; x < pixels.width(); ++x) {
                seed = seed * 1664525u + 1013904223u;
                row[x] = 0xff000000u | (seed >> 8);
            }
        }
        setSize(QSizeF(1024, 1024));
    }
    void paint(QPainter* painter) override { painter->drawImage(boundingRect(), pixels); }
    QImage pixels;
};

class ScreenshotTest : public QObject {
    Q_OBJECT
    QTemporaryDir directory;
    QQuickWindow window;
    QProcess keyboard;
    void keySerial() {
        for (const auto& command : {QByteArray("key 30 1\n"), QByteArray("key 30 0\n")}) {
            QCOMPARE(keyboard.write(command), command.size());
            QTRY_VERIFY_WITH_TIMEOUT(keyboard.canReadLine(), 5000);
            QCOMPARE(keyboard.readLine().trimmed(), QByteArray("done"));
        }
        QTest::qWait(20);
    }
    Frame* frame = nullptr;
    QByteArray read(const QString& path) {
        QFile file(path); if (!file.open(QIODevice::ReadOnly)) return {}; return file.readAll();
    }
    int mode(const QString& path) { struct stat info{}; return ::stat(QFile::encodeName(path).constData(), &info) == 0 ? info.st_mode & 0777 : -1; }
    bool noStaging() { return QDir(directory.path()).entryList({".cornice-screenshot-*"}, QDir::Files | QDir::Hidden).isEmpty(); }
    void write(const QString& path, const QByteArray& bytes) { QFile file(path); QVERIFY(file.open(QIODevice::WriteOnly)); QCOMPARE(file.write(bytes), bytes.size()); }
private slots:
    void initTestCase() {
        QVERIFY(directory.isValid());
        window.setTitle("screenshot-controller-producer");
        window.resize(1024, 1024);
        frame = new Frame(window.contentItem());
        window.show();
        QVERIFY(QTest::qWaitForWindowExposed(&window));
        QTest::qWait(100);
        if (QGuiApplication::platformName() == "wayland") {
            keyboard.start(qEnvironmentVariable("CORNICE_TEST_PHYSICAL_INPUT"), {"Hyprland", "human"});
            QVERIFY(keyboard.waitForStarted(5000));
            QTRY_VERIFY_WITH_TIMEOUT(keyboard.canReadLine(), 5000);
            QCOMPARE(keyboard.readLine().trimmed(), QByteArray("ready"));
        }
    }
    void cleanupTestCase() {
        if (keyboard.state() != QProcess::NotRunning) {
            keyboard.closeWriteChannel();
            QTRY_COMPARE_WITH_TIMEOUT(keyboard.state(), QProcess::NotRunning, 5000);
        }
    }
    void init() {
        window.requestActivate();
        QTRY_COMPARE_WITH_TIMEOUT(QGuiApplication::focusWindow(), &window, 5000);
        // Wayland clipboard publication requires an actual input serial, not
        // only local Qt focus/cache. Use the existing isolated physical fixture.
        if (QGuiApplication::platformName() == "wayland") keySerial();
    }
    void pngExportKeepsEventLoopResponsive() {
        ScreenshotController controller;
        QSignalSpy saved(&controller, &ScreenshotController::saved), failed(&controller, &ScreenshotController::failed);
        const QString path = directory.filePath("full.png");
        QElapsedTimer elapsed; elapsed.start();
        qint64 previous = 0, maxGap = 0; int ticks = 0;
        QTimer heartbeat; heartbeat.setInterval(5);
        connect(&heartbeat, &QTimer::timeout, this, [&] { const auto now = elapsed.elapsed(); maxGap = qMax(maxGap, now - previous); previous = now; ++ticks; });
        heartbeat.start();
        controller.save(frame, QRectF(0, 0, 1024, 1024), QSize(4096, 4096), path);
        QTRY_COMPARE_WITH_TIMEOUT(saved.count(), 1, 30000);
        heartbeat.stop();
        QCOMPARE(failed.count(), 0);
        QVERIFY2(ticks >= 10, "PNG preparation must allow GUI timers to run");
        QVERIFY2(maxGap < 250, qPrintable(QString("GUI heartbeat delayed %1ms").arg(maxGap)));
        const auto bytes = read(path); QVERIFY(!bytes.isEmpty());
        QCOMPARE(QImage::fromData(bytes).size(), QSize(4096, 4096));
        QCOMPARE(mode(path), 0600);
        QCOMPARE(QGuiApplication::clipboard()->mimeData()->formats(), QStringList{"image/png"});
        QCOMPARE(QGuiApplication::clipboard()->mimeData()->data("image/png"), bytes);
        QVERIFY(noStaging());
        qInfo() << "Actual asynchronous PNG export" << elapsed.elapsed() << "ms, heartbeat max gap" << maxGap << "ms, ticks" << ticks;

    }
    void cropAndAtomicReplace() {
        ScreenshotController controller; QSignalSpy saved(&controller, &ScreenshotController::saved);
        const QString path = directory.filePath("replace.png"); write(path, "existing image");
        controller.save(frame, QRectF(12, 14, 100, 60), QSize(2048, 2048), path);
        QTRY_COMPARE_WITH_TIMEOUT(saved.count(), 1, 10000);
        QCOMPARE(QImage::fromData(read(path)).size(), QSize(200, 120));
        QCOMPARE(mode(path), 0600);
        QVERIFY(noStaging());
        if (QGuiApplication::platformName() == "wayland") {
            QProcess consumer;
            consumer.start(QCoreApplication::applicationFilePath(), {"--clipboard-consumer", path});
            QTRY_COMPARE_WITH_TIMEOUT(consumer.state(), QProcess::NotRunning, 15000);
            QCOMPARE(consumer.exitStatus(), QProcess::NormalExit);
            const auto error = consumer.readAllStandardError();
            const auto output = consumer.readAllStandardOutput();
            qInfo().noquote() << "External consumer exit" << consumer.exitCode() << error << output;
            QVERIFY2(consumer.exitCode() == 0, error.constData());
            QVERIFY(output.contains("external Qt PNG clipboard PASS"));
            qInfo().noquote() << output.trimmed();
        }
    }
    void cancelledExportCannotReplaceFileOrClipboard() {
        ScreenshotController controller; QSignalSpy saved(&controller, &ScreenshotController::saved), failed(&controller, &ScreenshotController::failed);
        const QString path = directory.filePath("cancel.png"); write(path, "retain cancellation sentinel");
        QGuiApplication::clipboard()->setText("retain clipboard sentinel");
        QTRY_COMPARE_WITH_TIMEOUT(QGuiApplication::clipboard()->text(), QString("retain clipboard sentinel"), 5000);
        controller.save(frame, QRectF(0, 0, 1024, 1024), QSize(4096, 4096), path);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.findChildren<QFutureWatcherBase*>().isEmpty(), 5000);
        controller.cancel();
        QTRY_VERIFY_WITH_TIMEOUT(controller.findChildren<QFutureWatcherBase*>().isEmpty(), 30000);
        QCOMPARE(saved.count(), 0); QCOMPARE(failed.count(), 0);
        QCOMPARE(read(path), QByteArray("retain cancellation sentinel"));
        QCOMPARE(QGuiApplication::clipboard()->text(), QString("retain clipboard sentinel"));
        QVERIFY(noStaging());
    }
    void replacementRejectsOldFrame() {
        ScreenshotController controller; QSignalSpy saved(&controller, &ScreenshotController::saved);
        const QString old = directory.filePath("old.png"), current = directory.filePath("current.png");
        write(old, "retain replaced sentinel");
        controller.save(frame, QRectF(0, 0, 1024, 1024), QSize(4096, 4096), old);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.findChildren<QFutureWatcherBase*>().isEmpty(), 5000);
        controller.save(frame, QRectF(0, 0, 30, 20), QSize(1024, 1024), current);
        QTRY_COMPARE_WITH_TIMEOUT(saved.count(), 1, 30000);
        QTRY_VERIFY_WITH_TIMEOUT(controller.findChildren<QFutureWatcherBase*>().isEmpty(), 30000);
        QCOMPARE(saved.first().first().toString(), current);
        QCOMPARE(read(old), QByteArray("retain replaced sentinel"));
        QCOMPARE(QImage::fromData(read(current)).size(), QSize(30, 20));
        QCOMPARE(QGuiApplication::clipboard()->mimeData()->data("image/png"), read(current));
        QVERIFY(noStaging());
    }
    void destructionCannotPublish() {
        const QString path = directory.filePath("destroyed.png"); write(path, "retain destruction sentinel");
        QGuiApplication::clipboard()->setText("retain destruction clipboard");
        QTRY_COMPARE_WITH_TIMEOUT(QGuiApplication::clipboard()->text(), QString("retain destruction clipboard"), 5000);
        auto* controller = new ScreenshotController;
        controller->save(frame, QRectF(0, 0, 1024, 1024), QSize(4096, 4096), path);
        QTRY_VERIFY_WITH_TIMEOUT(!controller->findChildren<QFutureWatcherBase*>().isEmpty(), 5000);
        delete controller;
        QTest::qWait(1500);
        QCOMPARE(read(path), QByteArray("retain destruction sentinel"));
        QCOMPARE(QGuiApplication::clipboard()->text(), QString("retain destruction clipboard"));
        QTRY_VERIFY_WITH_TIMEOUT(noStaging(), 10000);
    }
    void failedSavePreservesDestinationAndClipboard() {
        ScreenshotController controller; QSignalSpy saved(&controller, &ScreenshotController::saved), failed(&controller, &ScreenshotController::failed);
        const QString parent = directory.filePath("existing-file"); write(parent, "retain existing bytes");
        QGuiApplication::clipboard()->setText("retain failed clipboard");
        QTRY_COMPARE_WITH_TIMEOUT(QGuiApplication::clipboard()->text(), QString("retain failed clipboard"), 5000);
        controller.save(frame, QRectF(0, 0, 30, 20), QSize(1024, 1024), parent + "/cannot-save.png");
        QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 1, 10000);
        QCOMPARE(saved.count(), 0); QCOMPARE(read(parent), QByteArray("retain existing bytes"));
        QCOMPARE(QGuiApplication::clipboard()->text(), QString("retain failed clipboard"));
        QVERIFY(noStaging());
        controller.save(frame, QRectF(0, 0, 30, 20), QSize(1024, 1024), "relative.png");
        QCOMPARE(failed.count(), 2);
        QCOMPARE(saved.count(), 0);
        const QString missing = directory.filePath("missing-directory");
        controller.save(frame, QRectF(0, 0, 30, 20), QSize(1024, 1024), missing + "/explicit.png");
        QTRY_COMPARE_WITH_TIMEOUT(failed.count(), 3, 10000);
        QVERIFY(!QDir(missing).exists());
        QCOMPARE(QGuiApplication::clipboard()->text(), QString("retain failed clipboard"));
    }
};

int main(int argc, char** argv) {
    QGuiApplication app(argc, argv);
    if (app.arguments().contains("--clipboard-consumer")) {
        const auto path = app.arguments().last();
        QFile file(path); if (!file.open(QIODevice::ReadOnly)) return 2;
        const auto expected = QImage::fromData(file.readAll());
        QQuickWindow window; window.setTitle("screenshot-clipboard-consumer"); window.resize(160, 100); window.show();
        QTimer read; read.setInterval(20);
        QStringList lastFormats;
        QObject::connect(&read, &QTimer::timeout, &app, [&] {
            const auto* mime = app.clipboard()->mimeData();
            if (mime->formats() != lastFormats) {
                lastFormats = mime->formats();
                fprintf(stderr, "external clipboard formats=%s focus=%s hasImage=%d\n", qPrintable(lastFormats.join(",")), app.focusWindow() ? qPrintable(app.focusWindow()->title()) : "none", mime->hasImage());
                fflush(stderr);
            }
            if (!mime->hasImage()) return;
            const auto actual = app.clipboard()->image();
            if (actual.isNull()) return;
            if (actual != expected) { qCritical("external Qt PNG clipboard mismatch"); app.exit(3); return; }
            puts("external Qt PNG clipboard PASS"); app.exit(0);
        });
        read.start(); QTimer::singleShot(12000, &app, [&] { fprintf(stderr, "external Qt PNG clipboard timeout: formats=%s focus=%s\n", qPrintable(app.clipboard()->mimeData()->formats().join(",")), app.focusWindow() ? qPrintable(app.focusWindow()->title()) : "none"); fflush(stderr); app.exit(4); });
        return app.exec();
    }
    ScreenshotTest test; return QTest::qExec(&test, argc, argv);
}
#include "main.moc"
