"""Real Shell launcher -> Broker -> exec barrier -> GTK/Qt on H/A/B.

Uses Runtime's tracked process groups and the enclosing private PID namespace;
never imports the legacy harness that scans process cmdlines/environments.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
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
    return json.loads(subprocess.check_output([str(ROOT / "bin/cornice-desktop"), *map(str, args)], env=runtime.env, stderr=subprocess.PIPE, text=True, timeout=10))


def shell(desktop, *args):
    environment = runtime.env.copy()
    if desktop != "main": environment["CORNICE_DESKTOP_NAME"] = desktop
    return subprocess.check_output([str(ROOT / "bin/cornice"), *map(str, args)], env=environment, stderr=subprocess.PIPE, text=True, timeout=6).strip()


def state(desktop):
    return json.loads(shell(desktop, "ipc", "launcher", "debug"))


def client(title):
    return next((window for window in runtime.ctl("clients", True) if window.get("mapped") and window["title"] == title), None)


def command(process, value):
    process.stdin.write(value + "\n"); process.stdin.flush()
    assert select.select([process.stdout], [], [], 4)[0] and process.stdout.readline().strip() == "done", value


try:
    runtime.launch()
    configuration = runtime.base / "config/cornice"; configuration.mkdir()
    (configuration / "config.json").write_text(json.dumps({"agentDesktop": {"enabled": True}, "background": {"enabled": False},
        "weather": {"intervalMinutes": 0}, "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0, "dimAc": 0,
        "dimBattery": 0, "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False}}))
    # Compile a plain Qt widget. No app-specific routing or profile policy.
    qt_source = runtime.base / "qt.cpp"
    qt_source.write_text('''#include <QApplication>
#include <QWidget>
#include <QLineEdit>
#include <QVBoxLayout>
#include <QFile>
int main(int argc,char** argv){QApplication app(argc,argv); if(argc!=3)return 2;
QWidget window; window.setWindowTitle(QString::fromLocal8Bit(argv[1])); window.resize(500,250);
auto* layout=new QVBoxLayout(&window); auto* entry=new QLineEdit; layout->addWidget(entry);
const QString destination=QString::fromLocal8Bit(argv[2]);
QObject::connect(entry,&QLineEdit::textChanged,[destination](const QString& value){QFile file(destination);if(file.open(QIODevice::WriteOnly))file.write(value.toUtf8());});
window.show();entry->setFocus();return app.exec();}''')
    qt_flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "Qt6Widgets"], text=True).split()
    subprocess.run(["c++", "-std=c++20", "-fPIC", str(qt_source), "-o", str(runtime.base / "qt"), *qt_flags], check=True)
    applications = runtime.base / "data/applications"; applications.mkdir()
    for desktop in ("main", "A", "B"):
        for toolkit in ("GTK", "Qt"):
            title = "route-ui-" + desktop + "-" + toolkit
            argv = ["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py")] if toolkit == "GTK" else [str(runtime.base / "qt")]
            argv += [title, str(runtime.base / (title + ".txt"))]
            # All fixture paths are absolute and space-free inside /tmp/t.
            (applications / (title + ".desktop")).write_text("[Desktop Entry]\nType=Application\nName=Route " + desktop + " " + toolkit + "\nExec=" + " ".join(argv) + "\nTerminal=false\n")
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"), ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(runtime.base / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    subprocess.run(["cc", "-I" + str(runtime.base), str(FORK / "hyprtester/multiseat/input.c"), str(runtime.base / "virtual-keyboard.c"),
                    str(runtime.base / "virtual-pointer.c"), "-o", str(runtime.base / "input"), *flags], check=True)
    runtime.start([str(ROOT / "bin/cornice-desktopd")], "desktopd")
    wait(lambda: cli("list"))
    for desktop in ("A", "B"):
        cli("create", desktop, "--workspace", "11" if desktop == "A" else "12", "--virtual-output", "1280x800")
        cli("resume", desktop)
    runtime.start([str(ROOT / "bin/cornice-qs"), "-n", "-p", str(ROOT / "shell")], "primary-shell")
    wait(lambda: json.loads(shell("main", "ipc", "desktop", "status"))["available"])
    keyboards = {}
    for desktop in ("main", "A", "B"):
        current = cli("state", desktop)
        process = runtime.start([str(runtime.base / "input"), "Hyprland" if desktop == "main" else desktop,
                                 current["output"]], desktop + "-input", env=runtime.env | {"WAYLAND_DISPLAY": current["display"]},
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert select.select([process.stdout], [], [], 5)[0] and process.stdout.readline().strip() == "ready"
        keyboards[desktop] = process
    primary_window = None
    for desktop in ("main", "A", "B"):
        for toolkit in ("GTK", "Qt"):
            title = "route-ui-" + desktop + "-" + toolkit
            shell(desktop, "launcher")
            wait(lambda: state(desktop)["focused"])
            shell(desktop, "ipc", "launcher", "setQuery", "Route " + desktop + " " + toolkit)
            wait(lambda: state(desktop)["first"] == "Route " + desktop + " " + toolkit)
            command(keyboards[desktop], "key 28 1"); command(keyboards[desktop], "key 28 0")
            window = wait(lambda: client(title))
            expected = cli("state", desktop)["workspace"].removeprefix("name:")
            assert window["workspace"]["name"] == expected, (window, expected)
            command(keyboards[desktop], "type native" + desktop)
            wait(lambda: (runtime.base / (title + ".txt")).read_text() == "native" + desktop)
            if desktop == "main": primary_window = runtime.ctl("activewindow", True)["address"]
            else: assert runtime.ctl("activewindow", True)["address"] == primary_window
            record(desktop + " real Launcher opens and types into ordinary " + toolkit, window)
finally:
    runtime.cleanup()
