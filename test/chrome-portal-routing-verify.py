"""Private real Chrome singleton -> public FileChooser portal -> GTK backend.

Only fresh profiles, a local page and synthetic file participate. CDP drives
our own managed browser; no file chooser interception or user profile access.
"""
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
FORK = Path(os.environ["CORNICE_TEST_HYPRLAND_SOURCE"])
assert os.environ.get("CORNICE_TEST_SANDBOX") == "1" and not Path("/dev/input").exists()
os.environ.update(HYPRLAND_TEST_SANDBOX="1", MULTISEAT_TEST_DIR="/tmp/t", MULTISEAT_HYPRLAND=os.environ["CORNICE_TEST_HYPRLAND"])
sys.path.insert(0, str(FORK / "hyprtester/multiseat"))
from runtime import Runtime, wait
from cdp_client import Cdp

runtime = Runtime("chrome-portal")
runtime.env.update(CORNICE_PATH=str(ROOT), PATH=str(ROOT / "bin") + ":/usr/bin:/bin", XDG_CURRENT_DESKTOP="KDE",
                   XDG_SESSION_TYPE="wayland", GTK_USE_PORTAL="1")
checks, clients = [], []
events = None
event_buffer = b""
publications = {}
publication_history = []


def record(description, evidence):
    checks.append({"description": description, "evidence": evidence})
    (runtime.base / "chrome-portal.json").write_text(json.dumps(checks, indent=2))
    print("PASS", description, flush=True)


def cli(*args):
    result = subprocess.run([str(ROOT / "bin/cornice-desktop"), *map(str, args)], env=runtime.env, capture_output=True, text=True, timeout=12)
    result.check_returncode()
    return json.loads(result.stdout)


def shell(desktop, *args):
    environment = runtime.env.copy()
    if desktop != "main": environment["CORNICE_DESKTOP_NAME"] = desktop
    return subprocess.check_output([str(ROOT / "bin/cornice"), *map(str, args)], env=environment, stderr=subprocess.PIPE, text=True, timeout=6).strip()


def command(process, value):
    process.stdin.write(value + "\n"); process.stdin.flush()
    assert select.select([process.stdout], [], [], 5)[0] and process.stdout.readline().strip() == "done", value


def key(driver, code):
    command(driver, f"key {code} 1"); command(driver, f"key {code} 0")


def launch(desktop, label, keyboard):
    shell(desktop, "launcher")
    wait(lambda: json.loads(shell(desktop, "ipc", "launcher", "debug"))["focused"])
    shell(desktop, "ipc", "launcher", "setQuery", label)
    wait(lambda: json.loads(shell(desktop, "ipc", "launcher", "debug"))["first"] == label)
    key(keyboard, 28)


def evaluate(cdp, session, expression):
    return cdp.call("Runtime.evaluate", {"expression": expression, "returnByValue": True, "userGesture": True}, session)["result"].get("value")


def owns(name):
    text = subprocess.check_output(["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus",
        "--method", "org.freedesktop.DBus.NameHasOwner", name], env=runtime.env, text=True, timeout=4)
    return "true" in text


def publication(address):
    global event_buffer
    while True:
        try: event_buffer += events.recv(65536)
        except BlockingIOError: break
    lines = event_buffer.split(b"\n")
    event_buffer = lines.pop()
    for line in lines:
        if line.startswith(b"openwindow>>"):
            window, workspace, *_ = line.decode().removeprefix("openwindow>>").split(",")
            publications[window] = workspace
            publication_history.append({"address": window, "workspace": workspace})
        elif line.startswith(b"closewindow>>"):
            publications.pop(line.decode().removeprefix("closewindow>>"), None)
    (runtime.base / "first-publications.json").write_text(json.dumps(publication_history, indent=2))
    return publications.get(address.removeprefix("0x"))


try:
    runtime.launch()
    events = socket.socket(socket.AF_UNIX)
    events.connect(str(runtime.rt / "hypr" / runtime.env["HYPRLAND_INSTANCE_SIGNATURE"] / ".socket2.sock"))
    events.setblocking(False)
    settings = runtime.base / "config/cornice"; settings.mkdir()
    (settings / "config.json").write_text(json.dumps({"agentDesktop": {"enabled": True}, "background": {"enabled": False},
        "weather": {"intervalMinutes": 0}, "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0, "dimAc": 0,
        "dimBattery": 0, "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False}}))
    portal_config = runtime.base / "config/xdg-desktop-portal"; portal_config.mkdir()
    (portal_config / "portals.conf").write_text("[preferred]\ndefault=gtk\norg.freedesktop.impl.portal.FileChooser=gtk\n")
    payload = runtime.base / "portal-payload.txt"; payload.write_text("synthetic Cornice portal payload\n")
    page = runtime.base / "upload.html"
    page.write_text('<title>Cornice synthetic upload</title><input id="upload" type="file" accept=".txt"><p>Private portal routing test</p>')
    url = page.as_uri()
    applications = runtime.base / "data/applications"; applications.mkdir()
    (applications / "cornice-private-chrome.desktop").write_text("[Desktop Entry]\nType=Application\nName=Route Private Chrome\nExec=google-chrome-stable --ozone-platform=wayland --no-first-run --no-default-browser-check --disable-sync --disable-background-networking --disable-component-update " + url + "\nTerminal=false\n")
    broker = runtime.start([str(ROOT / "bin/cornice-desktopd")], "desktopd")
    wait(lambda: cli("list"))
    for desktop in ("A", "B"):
        cli("create", desktop, "--workspace", "11" if desktop == "A" else "12", "--virtual-output", "1280x800")
        cli("resume", desktop)
    # The shared backend intentionally connects on the primary display. Parent,
    # not that connection or process identity, must route each chooser.
    backend = runtime.start(["/usr/lib/xdg-desktop-portal-gtk", "--replace"], "portal-gtk", env=runtime.env | {"WAYLAND_DEBUG": "client"})
    wait(lambda: owns("org.freedesktop.impl.portal.desktop.gtk"))
    runtime.start(["/usr/lib/xdg-desktop-portal", "--replace", "--verbose"], "portal-frontend")
    wait(lambda: owns("org.freedesktop.portal.Desktop"))
    monitor = runtime.start(["dbus-monitor", "--session", "interface='org.freedesktop.portal.FileChooser'",
        "interface='org.freedesktop.impl.portal.FileChooser'", "interface='org.freedesktop.portal.Request'",
        "interface='org.kde.StatusNotifierItem'"], "portal-dbus")
    runtime.start([str(ROOT / "bin/cornice-qs"), "-n", "-p", str(ROOT / "shell")], "primary-shell")
    wait(lambda: json.loads(shell("main", "ipc", "desktop", "status"))["available"])
    # All three seats exist before toolkit and input clients bind their globals.
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"), ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(runtime.base / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    subprocess.run(["cc", "-I" + str(runtime.base), str(FORK / "hyprtester/multiseat/input.c"), str(runtime.base / "virtual-keyboard.c"),
        str(runtime.base / "virtual-pointer.c"), "-o", str(runtime.base / "input"), *flags], check=True)
    keyboards = {}
    for desktop in ("main", "A", "B"):
        state = cli("state", desktop)
        process = runtime.start([str(runtime.base / "input"), "Hyprland" if desktop == "main" else desktop, state["output"]], desktop + "-input",
            env=runtime.env | {"WAYLAND_DISPLAY": state["display"]}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert select.select([process.stdout], [], [], 5)[0] and process.stdout.readline().strip() == "ready"
        keyboards[desktop] = process
    guard = runtime.start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"), "portal-human-guard", str(runtime.base / "human.txt")], "human-guard")
    human = wait(lambda: next((w for w in runtime.ctl("clients", True) if w["title"] == "portal-human-guard"), None))
    runtime.ok('dispatch hl.dsp.focus({window="address:' + human["address"] + '"})')
    guard_address = human["address"]
    for desktop in ("A", "B"):
        launch(desktop, "Route Private Chrome", keyboards[desktop])
        expected = cli("state", desktop)["workspace"].removeprefix("name:")
        binding = runtime.base / (desktop + ".binding"); cli("bind", desktop, binding)
        endpoint = cli("tool", binding, "desktop.browser", "{}")["cdpUrl"]
        cdp = Cdp(endpoint); clients.append(cdp)
        try:
            browser = wait(lambda: next((w for w in runtime.ctl("clients", True) if w.get("mapped") and "Cornice synthetic upload" in w["title"]
                and w["workspace"]["name"] == expected), None), timeout=35)
            target = next(info for info in cdp.call("Target.getTargets")["targetInfos"] if info["url"].startswith(url))
        except (RuntimeError, StopIteration):
            print("Synthetic browser diagnostic", json.dumps({"expected": expected, "windows": runtime.ctl("clients", True), "targets": cdp.call("Target.getTargets")}), flush=True)
            raise
        assert runtime.ctl("activewindow", True)["address"] == guard_address
        assert publication(browser["address"]) == expected
        session = cdp.call("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True})["sessionId"]
        evaluate(cdp, session, "window.routingSentinel='preserved-' + " + json.dumps(desktop))
        before_count = len(cdp.call("Target.getTargets")["targetInfos"])
        launch(desktop, "Route Private Chrome", keyboards[desktop])
        wait(lambda: len(cdp.call("Target.getTargets")["targetInfos"]) > before_count)
        assert evaluate(cdp, session, "window.routingSentinel") == "preserved-" + desktop
        assert any(w["pid"] == browser["pid"] for w in runtime.ctl("clients", True))
        assert runtime.ctl("activewindow", True)["address"] == guard_address
        record(desktop + " real Launcher warm Chrome uses the existing singleton and preserves page memory", {"pid": browser["pid"], "workspace": expected})
        cdp.call("Target.activateTarget", {"targetId": target["targetId"]})
        evaluate(cdp, session, "document.querySelector('#upload').click()")
        chooser = wait(lambda: next((w for w in runtime.ctl("clients", True) if w.get("mapped") and w["pid"] == backend.pid), None), timeout=20)
        assert chooser["workspace"]["name"] == expected, chooser
        assert publication(chooser["address"]) == expected
        assert runtime.ctl("activewindow", True)["address"] == guard_address
        command(keyboards[desktop], "mods 4"); key(keyboards[desktop], 38); command(keyboards[desktop], "mods 0")
        command(keyboards[desktop], "type " + str(payload)); key(keyboards[desktop], 28)
        try:
            wait(lambda: evaluate(cdp, session, "document.querySelector('#upload').files.length") == 1, timeout=5)
        except RuntimeError:
            assert any(w["address"] == chooser["address"] and w.get("mapped") for w in runtime.ctl("clients", True))
            key(keyboards[desktop], 28)
            wait(lambda: evaluate(cdp, session, "document.querySelector('#upload').files.length") == 1, timeout=10)
        assert evaluate(cdp, session, "document.querySelector('#upload').files[0].name") == payload.name
        wait(lambda: not any(w["address"] == chooser["address"] and w.get("mapped") for w in runtime.ctl("clients", True)))
        assert runtime.ctl("activewindow", True)["address"] == guard_address
        record(desktop + " Chrome -> public portal -> shared GTK chooser -> file Response -> Chrome DOM", {"browserPid": browser["pid"], "chooserPid": backend.pid,
            "chooserWorkspace": chooser["workspace"], "selected": payload.name, "humanFocusUnchanged": runtime.ctl("activewindow", True)["address"] == guard_address})
    bus_log = (runtime.base / "portal-dbus.log").read_text()
    assert "interface=org.freedesktop.portal.FileChooser; member=OpenFile" in bus_log
    assert "interface=org.freedesktop.impl.portal.FileChooser; member=OpenFile" in bus_log
    assert "member=Response" in bus_log and "wayland:" in bus_log and payload.name in bus_log
    record("unmodified portal frontend/backend D-Bus calls include exported Wayland parent and selected synthetic URI", {"openCalls": bus_log.count("member=OpenFile"), "responses": bus_log.count("member=Response")})
    trace = (runtime.base / "portal-gtk.stderr").read_text().splitlines()
    parent_timing = []
    for index, line in enumerate(trace):
        match = re.search(r"zxdg_imported_v2#\d+\.set_parent_of\(wl_surface#(\d+)\)", line)
        if not match: continue
        surface = match[1]
        attached = next(i for i in range(index + 1, len(trace)) if f"wl_surface#{surface}.attach(wl_buffer#" in trace[i])
        # A preceding initial empty commit is not a mapped frame. The actual
        # installed backend announces the foreign parent before attaching pixels.
        parent_timing.append({"surface": surface, "parentLine": index + 1, "firstBufferLine": attached + 1})
    assert len(parent_timing) == 2
    record("both real chooser foreign parents precede first pixel buffer and first openwindow publication has the requested workspace", parent_timing)
    # A new launch token must also be accepted when the independent browser
    # runtime is reattached after Broker replacement. Old CDP grants are revoked.
    launch_log = runtime.rt / "cornice" / runtime.env["HYPRLAND_INSTANCE_SIGNATURE"] / "B-launch.log"
    previous_submissions = launch_log.read_text().count("Opening in existing browser session.")
    broker.terminate(); broker.wait(timeout=8)
    assert broker.returncode == 0
    for client in clients: client.close()
    clients.clear()
    broker = runtime.start([str(ROOT / "bin/cornice-desktopd")], "desktopd-recovered")
    wait(lambda: cli("list"))
    cli("resume", "B")
    wait(lambda: json.loads(shell("B", "ipc", "desktop", "status"))["available"])
    keyboards["B"].terminate(); keyboards["B"].wait(timeout=5)
    recovered = cli("state", "B")
    keyboards["B"] = runtime.start([str(runtime.base / "input"), "B", recovered["output"]], "B-input-recovered",
        env=runtime.env | {"WAYLAND_DISPLAY": recovered["display"]}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert select.select([keyboards["B"].stdout], [], [], 5)[0] and keyboards["B"].stdout.readline().strip() == "ready"
    launch("B", "Route Private Chrome", keyboards["B"])
    wait(lambda: launch_log.read_text().count("Opening in existing browser session.") > previous_submissions)
    binding = runtime.base / "B-recovered.binding"; cli("bind", "B", binding)
    cdp = Cdp(cli("tool", binding, "desktop.browser", "{}")["cdpUrl"]); clients.append(cdp)
    assert any(info["targetId"] == target["targetId"] for info in cdp.call("Target.getTargets")["targetInfos"])
    session = cdp.call("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True})["sessionId"]
    assert evaluate(cdp, session, "window.routingSentinel") == "preserved-B"
    assert any(w["pid"] == browser["pid"] for w in runtime.ctl("clients", True))
    record("new Launcher token after Broker replacement reattaches the same real Chrome process and page memory", {"pid": browser["pid"]})
    # Actual installed tray producer, not just a synthetic no-token service.
    runtime.start(["fcitx5", "-D", "--disable=cloudpinyin,vinput,xcb"], "fcitx")
    item = wait(lambda: next((item for item in json.loads(shell("B", "ipc", "tray", "dump")) if "fcitx" in item["id"].lower()), None), timeout=20)
    shell("B", "ipc", "tray", "invoke", item["id"], "activate")
    error = wait(lambda: shell("B", "ipc", "tray", "actionError"), timeout=10)
    assert "UnknownMethod" in error and "per-action activation tokens" in error
    record("installed Fcitx tray activation capability result", {"id": item["id"], "error": error})
finally:
    if events: events.close()
    for client in clients:
        try: client.close()
        except OSError: pass
    runtime.cleanup()
