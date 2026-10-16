"""Real Qt singleton window/tray fixture verifies source-scoped Launcher feedback."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys

ROOT = Path(os.environ["CORNICE_TEST_PRODUCT"])
FORK = Path(os.environ["CORNICE_TEST_HYPRLAND_SOURCE"])
assert os.environ.get("CORNICE_TEST_SANDBOX") == "1" and not Path("/dev/input").exists()
os.environ.update(HYPRLAND_TEST_SANDBOX="1", MULTISEAT_TEST_DIR="/tmp/t", MULTISEAT_HYPRLAND=os.environ["CORNICE_TEST_HYPRLAND"])
sys.path.insert(0, str(FORK / "hyprtester/multiseat"))
from runtime import Runtime, wait

runtime = Runtime("shell-routing")
runtime.env.update(CORNICE_PATH=str(ROOT), PATH=str(ROOT / "bin") + ":/usr/bin:/bin")
checks = []


def record(description, evidence):
    checks.append({"description": description, "evidence": evidence})
    (runtime.base / "launcher-routing.json").write_text(json.dumps(checks, indent=2))
    print("PASS", description, flush=True)


def cli(*args):
    result = subprocess.run([str(ROOT / "bin/cornice-desktop"), *map(str, args)], env=runtime.env, capture_output=True, text=True, timeout=10)
    result.check_returncode()
    return json.loads(result.stdout)


def shell(desktop, *args):
    environment = runtime.env.copy()
    if desktop != "main": environment["CORNICE_DESKTOP_NAME"] = desktop
    return subprocess.check_output([str(ROOT / "bin/cornice"), *map(str, args)], env=environment, stderr=subprocess.PIPE, text=True, timeout=6).strip()


def state(desktop):
    return json.loads(shell(desktop, "ipc", "launcher", "debug"))


def command(process, value):
    process.stdin.write(value + "\n"); process.stdin.flush()
    assert select.select([process.stdout], [], [], 4)[0] and process.stdout.readline().strip() == "done", value


try:
    runtime.launch()
    configuration = runtime.base / "config/cornice"; configuration.mkdir()
    (configuration / "config.json").write_text(json.dumps({"agentDesktop": {"enabled": True}, "background": {"enabled": False},
        "weather": {"intervalMinutes": 0}, "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0, "dimAc": 0,
        "dimBattery": 0, "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False}, "desktopApplications":{"rules":{"fixture":{"executables":["cornice-singleton-fixture"],"singleInstance":"Singleton fixture"}}}}))
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"), ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(runtime.base / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    subprocess.run(["cc", "-I" + str(runtime.base), str(FORK / "hyprtester/multiseat/input.c"), str(runtime.base / "virtual-keyboard.c"),
                    str(runtime.base / "virtual-pointer.c"), "-o", str(runtime.base / "input"), *flags], check=True)
    fixture = runtime.base / "cornice-singleton-fixture"
    cpp = runtime.base / "singleton.cpp"
    cpp.write_text(r'''#include <QApplication>
#include <QWidget>
#include <QLabel>
#include <QVBoxLayout>
#include <QCloseEvent>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QLocalServer>
#include <QLocalSocket>
class Window : public QWidget { void closeEvent(QCloseEvent* event) override {hide();event->ignore();} };
int main(int argc,char** argv) {
 QApplication app(argc,argv);app.setApplicationName("cornice-singleton-fixture");app.setQuitOnLastWindowClosed(false);
 const auto path=qEnvironmentVariable("XDG_RUNTIME_DIR")+"/singleton-fixture.sock";
 QLocalSocket peer;peer.connectToServer(path);if(peer.waitForConnected(200)){peer.write("show");peer.waitForBytesWritten();return 0;}
 QLocalServer server;if(!server.listen(path))return 2;
 Window window;window.setWindowTitle("Singleton fixture");window.resize(600,300);
 auto* layout=new QVBoxLayout(&window);layout->addWidget(new QLabel("Single-instance application on desktop 1"));
 QObject::connect(&server,&QLocalServer::newConnection,[&]{auto* socket=server.nextPendingConnection();window.show();window.raise();window.activateWindow();socket->deleteLater();});
 QPixmap pixmap(32,32);pixmap.fill(Qt::blue);QSystemTrayIcon tray{QIcon(pixmap)};tray.setToolTip("Singleton fixture");
 QMenu menu;auto* show=menu.addAction("Show");QObject::connect(show,&QAction::triggered,[&]{window.show();});tray.setContextMenu(&menu);tray.show();
 window.show();return app.exec();}
''')
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "Qt6Widgets", "Qt6Network"], text=True).split()
    subprocess.run(["c++", "-std=c++20", "-fPIC", str(cpp), "-o", str(fixture), *flags], check=True)
    applications = runtime.base / "data/applications"; applications.mkdir()
    (applications/"singleton.desktop").write_text("[Desktop Entry]\nType=Application\nName=Singleton fixture\nExec="+str(fixture)+"\n")
    runtime.start([str(ROOT / "bin/cornice-desktopd")], "desktopd")
    wait(lambda: cli("list"))
    for desktop in ("desktop2",):
        cli("resume", desktop)
    runtime.start([str(ROOT / "bin/cornice-qs"), "-n", "-p", str(ROOT / "shell")], "primary-shell")
    wait(lambda: json.loads(shell("main", "ipc", "desktop", "status"))["available"])
    keyboards = {}
    for desktop in ("main", "desktop2"):
        current = cli("state", desktop)
        process = runtime.start([str(runtime.base / "input"), "Hyprland" if desktop == "main" else desktop,
                                 current["output"]], desktop + "-input", env=runtime.env | {"WAYLAND_DISPLAY": current["display"]},
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert select.select([process.stdout], [], [], 5)[0] and process.stdout.readline().strip() == "ready"
        keyboards[desktop] = process
    def launch(desktop, name, keyboard=None):
        shell(desktop, "launcher")
        wait(lambda: state(desktop)["focused"])
        shell(desktop, "ipc", "launcher", "setQuery", name)
        wait(lambda: state(desktop)["first"] == name)
        command(keyboard or keyboards[desktop], "key 28 1"); command(keyboard or keyboards[desktop], "key 28 0")
    def notice(desktop):
        return json.loads(shell(desktop, "ipc", "tray", "actionNotice"))
    def singleton_window():
        return next((window for window in runtime.ctl("clients", True) if window.get("title") == "Singleton fixture"), None)
    runtime.start([str(fixture)], "singleton-app")
    window = wait(singleton_window, timeout=45)
    primary_before = runtime.ctl("activewindow", True)["address"]
    original_pid = window["pid"]
    launch("desktop2", "Singleton fixture")
    message = wait(lambda: (value if "Singleton fixture" in (value := notice("desktop2"))["detail"] else None))
    assert "桌面 1" in message["detail"] and message["desktop"] == "desktop2", message
    assert notice("main")["detail"] == ""
    assert runtime.ctl("activewindow", True)["address"] == primary_before
    assert singleton_window()["pid"] == original_pid
    cli("capture", "desktop2", str(runtime.base / "singleton-launcher-notice.png"))
    record("single-instance fixture Launcher refusal stays on requesting desktop and preserves primary process/focus", message)
    # Real tray endpoint: no synthetic tray service and no application action is sent.
    item = wait(lambda: next((item for item in json.loads(shell("desktop2", "ipc", "tray", "dump")) if "singleton" in (item["id"]+item["title"]).lower()), None))
    shell("desktop2", "ipc", "tray", "invoke", item["id"], "activate")
    tray_message = wait(lambda: (value if "托盘" in (value := notice("desktop2"))["detail"] else None))
    assert "桌面 1" in tray_message["detail"]
    assert runtime.ctl("activewindow", True)["address"] == primary_before
    cli("capture", "desktop2", str(runtime.base / "singleton-tray-notice.png"))
    record("single-instance fixture tray refusal identifies original desktop without dispatch or focus change", tray_message)
    shell("main", "ipc", "desktop", "observe", "desktop2")
    wait(lambda: json.loads(shell("main", "ipc", "desktopObserver", "status"))["presentation"].get("active"))
    shell("main", "ipc", "desktopObserver", "takeover", "true")
    wait(lambda: json.loads(shell("main", "ipc", "desktopObserver", "status"))["humanControl"])
    launch("desktop2", "Singleton fixture", keyboards["main"])
    takeover_notice = wait(lambda: (value if "Singleton fixture" in (value := notice("desktop2"))["detail"] else None))
    assert "桌面 1" in takeover_notice["detail"]
    subprocess.run(["grim", "-o", "physical", str(runtime.base / "singleton-takeover-notice.png")], env=runtime.env, check=True)
    shell("main", "ipc", "desktopObserver", "takeover", "false")
    wait(lambda: not json.loads(shell("main", "ipc", "desktopObserver", "status"))["humanControl"])
    shell("main", "ipc", "shell", "hide", "cn.desktop-observer")
    wait(lambda: not json.loads(shell("main", "ipc", "desktopObserver", "status"))["open"])
    record("physical takeover Launcher keeps the singleton refusal visible on desktop 2", takeover_notice)
    # Closing the fixture's window hides it; the singleton still owns the process.
    answer = runtime.ctl('dispatch hl.dsp.window.close({window=' + json.dumps("address:"+window["address"]) + '})')
    assert answer == "ok", answer
    wait(lambda: singleton_window() is None)
    launch("desktop2", "Singleton fixture")
    hidden = wait(lambda: (value if "Singleton fixture" in (value := notice("desktop2"))["detail"] else None))
    assert "桌面 1" in hidden["detail"]
    record("single-instance fixture remains detectable with its window hidden in tray", hidden)
    # Same-desktop launch reaches the original instance and reopens its window.
    launch("main", "Singleton fixture")
    assert wait(singleton_window)["pid"] == original_pid
    record("same-desktop Launcher reopens the existing singleton window", {"pid":original_pid})
finally:
    runtime.cleanup()
