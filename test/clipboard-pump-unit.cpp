// Exercise Qt socket readiness after a silent Wayland peer, without graphics.
#include "ClipboardBridge.hpp"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QEvent>
#include <QLocalServer>
#include <QSocketNotifier>
#include <QTemporaryDir>
#include <QTimer>
#include <cstdio>

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QTemporaryDir directory("/tmp/cornice-clipboard-pump-XXXXXX");
    QLocalServer peer;
    const auto socket = directory.path() + "/wayland-private";
    if (!directory.isValid() || !peer.listen(socket)) return 2;
    ClipboardBridge bridge(socket);
    bridge.configure({"unit"}, "unit", "shared", 1024, "none");
    const auto notifiers = bridge.findChildren<QSocketNotifier *>();
    auto *read = [&]() -> QSocketNotifier * {
        for (auto *notifier : notifiers)
            if (notifier->type() == QSocketNotifier::Read) return notifier;
        return nullptr;
    }();
    if (!read) return 3;
    // A readiness hint can already have been consumed. A compositor which
    // does not reply must never trap the Broker's Qt loop in a socket read.
    QElapsedTimer elapsed; elapsed.start();
    QEvent stale(QEvent::SockAct);
    QCoreApplication::sendEvent(read, &stale);
    if (elapsed.elapsed() > 250) return 4;
    bool timerFired = false;
    QTimer::singleShot(0, &app, [&] { timerFired = true; app.quit(); });
    QTimer::singleShot(500, &app, &QCoreApplication::quit);
    app.exec();
    if (!timerFired) return 5;
    std::puts("PASS: silent real Wayland connection and stale Qt readiness cannot block the Broker event loop");
}
