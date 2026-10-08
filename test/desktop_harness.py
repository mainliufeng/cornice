"""cornice CLI + native devices against an isolated real Hyprland fork."""
import base64
import json
import os
import pathlib
import signal
import shlex
import select
import socket
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRODUCT = pathlib.Path(os.getenv("CORNICE_TEST_PRODUCT", ROOT))
FORK = pathlib.Path(os.environ["CORNICE_TEST_HYPRLAND_SOURCE"])
BASE = pathlib.Path(tempfile.mkdtemp(prefix="ad-"))
RT = BASE / "r"
RT.mkdir(mode=0o700)
PROCESSES = []
ENV = os.environ.copy()
for key in ("HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "CORNICE_LAUNCH_LOCKED"):
    ENV.pop(key, None)
ENV.update(XDG_RUNTIME_DIR=str(RT), XDG_CONFIG_HOME=str(BASE / "config"), XDG_CACHE_HOME=str(BASE / "cache"),
           XDG_STATE_HOME=str(BASE / "state"), GDK_BACKEND="wayland", GTK_IM_MODULE="wayland",
           NO_AT_BRIDGE="1", GCOV_PREFIX=str(BASE / "coverage"), CORNICE_PATH=str(PRODUCT), CORNICE_ISOLATED_TEST="1", QML_IMPORT_PATH=str(PRODUCT / "native/qml" if (PRODUCT / "native/qml").exists() else ROOT / "native/build/qml"))
BUS_PID = None
OWNED_PIDS = []
OWNED_BUS_PIDS = []

def wait(callback, timeout=25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            value = callback()
            if value:
                return value
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        time.sleep(.1)
    raise RuntimeError("readiness timeout")

def start(args, name, env=None):
    process = subprocess.Popen(args, env=env or ENV, stdout=open(BASE / (name + ".log"), "w"),
                               stderr=subprocess.STDOUT, start_new_session=True)
    PROCESSES.append(process)
    return process

def ctl(command, as_json=False):
    path = RT / "hypr" / ENV["HYPRLAND_INSTANCE_SIGNATURE"] / ".socket.sock"
    assert path.is_relative_to(RT)
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(4)
        connection.connect(str(path))
        connection.sendall((("j" if as_json else "") + "/" + command).encode())
        chunks = []
        while data := connection.recv(65536):
            chunks.append(data)
    answer = b"".join(chunks).decode().strip()
    return json.loads(answer) if as_json else answer

def ok(command):
    answer = ctl(command)
    assert answer == "ok", (command, answer)

def cli(*args, succeeds=True, env=None):
    result = subprocess.run([str(PRODUCT / "bin/cornice"), "desktop", *map(str, args)], env=env or ENV,
                            text=True, capture_output=True, timeout=10)
    if succeeds:
        assert result.returncode == 0, (args, result.stderr)
        return json.loads(result.stdout)
    assert result.returncode != 0, args
    return result.stderr

def bind(name):
    path = BASE / (name + "-" + str(time.monotonic_ns()) + ".binding")
    cli("bind", name, path)
    assert path.stat().st_mode & 0o077 == 0
    return path

def tool(binding, method, params=None, succeeds=True):
    return cli("tool", binding, "desktop." + method, json.dumps(params or {}), succeeds=succeeds)

def human_state():
    return {"workspace": ctl("activeworkspace", True), "window": ctl("activewindow", True).get("address"),
            "cursor": ctl("cursorpos", True), "output": ctl("monitors", True)[0]["activeWorkspace"]}

def record(name):
    print("PASS", name, flush=True)

def rpc(connection, method, params):
    connection.sendall((json.dumps({"id": str(time.monotonic_ns()), "method": method, "params": params}) + "\n").encode())
    data = b""
    while b"\n" not in data:
        data += connection.recv(65536)
    reply = json.loads(data)
    assert reply["ok"], reply
    return reply["result"]

def shell(*args):
    return subprocess.check_output([str(PRODUCT / "bin/cornice"), *map(str, args)], env=ENV, text=True, timeout=8, stderr=subprocess.PIPE).strip()

def desktop_ready():
    return subprocess.run([str(PRODUCT / "bin/cornice"), "desktop", "list"], env=ENV,
                          capture_output=True, timeout=5).returncode == 0

def displayed_clock(path):
    # Read the application's monotonic clock encoded in its real painted
    # pixels, after compositor export, Qt drawing and output capture.
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(path))
    pixels = pixbuf.get_pixels(); channels = pixbuf.get_n_channels()
    stride, width, height = pixbuf.get_rowstride(), pixbuf.get_width(), pixbuf.get_height()
    for y in range(0, height, 4):
        row = pixels[y * stride:y * stride + width * channels]
        green = row.find(b"\x00\xff\x00")
        while green >= 0 and green % channels:
            green = row.find(b"\x00\xff\x00", green + 1)
        if green < 0:
            continue
        x = green // channels
        def colored(pos):
            offset = pos * channels
            return 0 <= pos < width and row[offset + 2] < 32 and max(row[offset], row[offset + 1]) > 100
        begin = x
        while colored(begin - 1): begin -= 1
        end = x
        while colored(end + 1): end += 1
        length = end - begin + 1
        if length >= 130:
            return sum((1 << bit) for bit in range(32)
                       if row[int(begin + (bit + .5) * length / 32) * channels + 1] >
                          row[int(begin + (bit + .5) * length / 32) * channels])
    raise AssertionError("Application clock pixels absent from actual observer output")


def initialize(xwayland=False):
    global BUS_PID
    assert os.getenv("CORNICE_TEST_SANDBOX") == "1", "Use isolated-desktop-test.sh; never discover the host compositor"
    config = BASE / "hyprland.lua"
    config.write_text('''hl.monitor({output="",mode="1280x800",position="auto",scale=1})
hl.config({animations={enabled=false},xwayland={enabled=XWAYLAND},misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},debug={enable_stdout_logs=true}})
hl.window_rule({name="human-test",match={title="^human-window$"},workspace="1"})
'''.replace("XWAYLAND", "true" if xwayland else "false"))
    bus = subprocess.check_output(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"], env=ENV, text=True).splitlines()
    ENV["DBUS_SESSION_BUS_ADDRESS"] = bus[0]
    BUS_PID = int(bus[1])
    start(["mutter", "--headless", "--wayland", "--no-x11", "--wayland-display=parent", "--virtual-monitor", "1280x800"], "mutter")
    wait(lambda: (RT / "parent").is_socket())
    ENV.update(WAYLAND_DISPLAY="parent", AQ_DRM_DEVICES="/dev/null", LIBSEAT_BACKEND="noop")
    compositor = start([os.environ["CORNICE_TEST_HYPRLAND"], "-c", str(config)], "Hyprland")
    ENV["HYPRLAND_INSTANCE_SIGNATURE"] = wait(lambda: next((p.name for p in (RT / "hypr").glob("*") if (p / ".socket.sock").is_socket()), None))
    wait(lambda: ctl("monitors", True) is not None)
    log = (BASE / "Hyprland.log").read_text(errors="replace")
    assert "drm: Starting backend" not in log and "drm: Registered gpu" not in log
    initial = [m["name"] for m in ctl("monitors", True)]
    ok("output create headless human")
    ok('eval hl.monitor({output="human",mode="1280x800",position="0x0",scale=1})')
    for name in initial:
        ok('eval hl.monitor({output=' + json.dumps(name) + ',disabled=true})')
    wait(lambda: len(ctl("monitors", True)) == 1)
    ENV["WAYLAND_DISPLAY"] = wait(lambda: next((p.name for p in RT.glob("wayland-*") if p.is_socket()), None))
    ok('dispatch hl.dsp.focus({monitor="human"})')
    ok('dispatch hl.dsp.focus({workspace="1"})')
    broker = start([str(PRODUCT / "bin/cornice-desktopd")], "desktopd")
    wait(lambda: (RT / "cornice" / ENV["HYPRLAND_INSTANCE_SIGNATURE"] / "desktop.sock").is_socket())
    assert cli("doctor")["capabilities"]["protocol"] == 1
    return broker

def cleanup():
    for pid in OWNED_PIDS:
        try:
            # Detached browser launchers may exit before the real browser. Only
            # terminate the tested client's process while its private path matches.
            cmdline = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
            if str(BASE).encode() in cmdline:
                os.kill(pid, signal.SIGTERM)
        except (OSError, ProcessLookupError): pass
    for process in reversed(PROCESSES):
        if process.poll() is None:
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
    for process in reversed(PROCESSES):
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL)
    for pid in set(OWNED_BUS_PIDS + ([BUS_PID] if BUS_PID else [])):
        try:
            proc = pathlib.Path('/proc') / str(pid)
            environment = (proc / 'environ').read_bytes().split(b'\0')
            if ('XDG_RUNTIME_DIR=' + str(RT)).encode() in environment and b'dbus-daemon\0' in (proc / 'cmdline').read_bytes():
                os.kill(pid, signal.SIGTERM)
        except (OSError, ProcessLookupError): pass
    print("Private test directory:", BASE, flush=True)
