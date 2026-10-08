"""Existing human clients + dynamic private outputs, in the device sandbox."""
from desktop_harness import *

assert os.getenv("CORNICE_TEST_SANDBOX") == "1", "Run with isolated-desktop-test.sh"

def alive(process, name):
    assert process.poll() is None, name + " disconnected/exited"

def registry_ready(process, logfile):
    wait(lambda: "ready" in logfile.read_text() or process.poll() is not None)
    alive(process, "Wayland registry watcher")
    assert "output=human" in logfile.read_text()
    assert "output=cornice-agent-" not in logfile.read_text()

def registry_roundtrip(process, logfile):
    previous = logfile.read_text().count("ready")
    process.stdin.write("roundtrip\n"); process.stdin.flush()
    wait(lambda: logfile.read_text().count("ready") > previous or process.poll() is not None)
    alive(process, "Wayland registry watcher")
    assert "output=cornice-agent-" not in logfile.read_text()

try:
    initialize(xwayland=True)
    assert not pathlib.Path('/dev/input').exists() and not list(pathlib.Path('/dev/dri').glob('card*'))
    assert not pathlib.Path('/run/dbus/system_bus_socket').exists()
    assert not pathlib.Path('/run/user').exists()
    record("device/PID/network sandbox hides physical input, DRM card nodes, desktop sockets and system bus")
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client"], text=True).split()
    subprocess.run(["cc", str(ROOT / "test/output-registry-watch.c"), "-o", str(BASE / "registry-watch"), *flags], check=True)
    log = BASE / "registry.log"
    watcher = subprocess.Popen([str(BASE / "registry-watch")], env=ENV, stdin=subprocess.PIPE,
                              stdout=open(log, "w"), stderr=open(BASE / "registry-errors.log", "w"),
                              start_new_session=True, text=True)
    PROCESSES.append(watcher); registry_ready(watcher, log)
    gtk = start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"), "human-window", str(BASE / "human.txt")], "human-client")
    wait(lambda: any(c["title"] == "human-window" for c in ctl("clients", True)))
    # /tmp is private to this PID/network sandbox, so these cannot be host X11 sockets.
    display = wait(lambda: next((":" + p.name[1:] for p in pathlib.Path('/tmp/.X11-unix').glob('X*') if p.is_socket()), None))
    xenv = ENV | {"DISPLAY": display, "GDK_BACKEND": "x11"}
    xclient = start(["xmessage", "-name", "human-x11", "-buttons", "OK", "Xwayland stays usable"], "human-x11", xenv)
    wait(lambda: any(c.get("xwayland") for c in ctl("clients", True)))
    ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
    baseline = human_state()
    record("real human GTK, bound output watcher and Xwayland client already running before Agent output creation")
    for index in range(3):
        name = "private" + str(index)
        cli("create", name, "--virtual-output", "1280x800")
        registry_roundtrip(watcher, log)
        alive(gtk, "human GTK"); alive(xclient, "human X11")
        assert human_state() == baseline
        # No default numeric workspace may have been allocated to an agent.
        assert all(w["monitor"] == "human" for w in ctl("workspaces", True) if w["name"].isdigit() and 1 <= int(w["name"]) <= 10)
    record("three private outputs neither kill existing clients nor consume human workspaces 1-10")
    late_log = BASE / "late-registry.log"
    late = subprocess.Popen([str(BASE / "registry-watch")], env=ENV, stdin=subprocess.PIPE,
                           stdout=open(late_log, "w"), stderr=open(BASE / "late-errors.log", "w"),
                           start_new_session=True, text=True)
    PROCESSES.append(late); registry_ready(late, late_log)
    state = cli("state", "private0")
    agent_log = BASE / "agent-registry.log"
    agent = subprocess.Popen([str(BASE / "registry-watch")], env=ENV | {"WAYLAND_DISPLAY": state["display"]},
                            stdin=subprocess.PIPE, stdout=open(agent_log, "w"), stderr=open(BASE / "agent-errors.log", "w"),
                            start_new_session=True, text=True)
    PROCESSES.append(agent)
    wait(lambda: "ready" in agent_log.read_text() or agent.poll() is not None)
    alive(agent, "agent registry"); assert "output=cornice-agent-" in agent_log.read_text()
    record("late human clients cannot see private outputs; Agent clients retain output access")
    # Exercise actual shell and launch path after the output topology changes.
    config = BASE / "config/cornice"; config.mkdir(parents=True, exist_ok=True)
    (config / "config.json").write_text(json.dumps({"agentDesktop": {"enabled": True},
        "bar": {"layout": {"left": [{"id": "cn.workspaces"}, {"id": "cn.agent-desktop"}], "center": [], "right": []}},
        "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0, "dimAc": 0, "dimBattery": 0,
                 "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False},
        "background": {"enabled": False}, "weather": {"intervalMinutes": 0}}))
    qs = start([str(PRODUCT / "bin/cornice-qs"), "-p", str(PRODUCT / "shell")], "cornice")
    wait(lambda: json.loads(shell("ipc", "desktop", "status"))["available"])
    assert "pong" in shell("ping")
    for number in range(1, 11):
        ok('dispatch hl.dsp.focus({workspace="' + str(number) + '"})')
        workspace = ctl("activeworkspace", True)
        assert workspace["name"] == str(number) and workspace["monitor"] == "human", workspace
    ok('dispatch hl.dsp.focus({workspace="1"})')
    subprocess.run(["grim", "-o", "human", str(BASE / "human-desktop.png")], env=ENV, check=True)
    record("actual Cornice shell responds and all ten human workspace switches stay on human output")
    cli("resume", "private0")
    cli("launch", "private0", "--", "/usr/bin/python3", ROOT / "test/agent-desktop-client.py", "agent-window", BASE / "agent.txt")
    window = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "agent-window"), None))
    OWNED_PIDS.append(window["pid"])
    baseline = human_state()
    binding = bind("private0")
    frame = tool(binding, "capture")
    tool(binding, "input", {"action": "text", "text": "isolated Agent 中文", "frameId": frame["frameId"]})
    wait(lambda: (BASE / "agent.txt").read_text() == "isolated Agent 中文")
    assert human_state() == baseline
    (BASE / "agent-desktop.png").write_bytes(base64.b64decode(tool(binding, "capture")["pngBase64"]))
    record("real Agent GTK input and frame capture leave human cursor, focus and workspace unchanged")
    private_workspace = cli("state", "private0")["workspace"]
    tool(binding, "workspace", {"workspace": "1"})
    xwindow = next(c for c in ctl("clients", True) if c.get("xwayland"))
    frame = tool(binding, "capture")
    tool(binding, "input", {"action": "move", "x": xwindow["at"][0] + xwindow["size"][0] / 2,
                            "y": xwindow["at"][1] + xwindow["size"][1] / 2, "frameId": frame["frameId"]})
    # The Wayland-only hit tester asserts on X11. The unsupported window
    # must be rejected before reaching it, including during workspace entry.
    alive(xclient, "human X11"); alive(gtk, "human GTK")
    assert human_state() == baseline
    assert "pong" in shell("ping")
    tool(binding, "workspace", {"workspace": private_workspace})
    record("Agent enters a shared workspace and crosses a real X11 window without crashing or moving human focus")
    for index in range(3):
        cli("remove", "private" + str(index))
        registry_roundtrip(watcher, log); registry_roundtrip(late, late_log)
        alive(gtk, "human GTK"); alive(xclient, "human X11"); alive(qs, "Cornice")
    for index in range(3):
        cli("create", "churn", "--virtual-output", "1280x800")
        registry_roundtrip(watcher, log)
        cli("remove", "churn")
        registry_roundtrip(watcher, log)
    # An X11 connection opened after repeated hotplug must still map a window.
    fresh_x = start(["xmessage", "-name", "fresh-x11", "-buttons", "OK", "X11 after hotplug"], "fresh-x11", xenv)
    wait(lambda: len([c for c in ctl("clients", True) if c.get("xwayland")]) == 2)
    alive(fresh_x, "new X11"); alive(xclient, "existing X11")
    assert "global wl_output" not in (BASE / "Hyprland.log").read_text()
    record("repeated private output removal/recreation preserves existing and newly launched X11 applications")
    assert 'privacy must be set at creation' in ctl('seat private-output human')
    registry_roundtrip(watcher, log)
    alive(gtk, 'human GTK'); alive(xclient, 'human X11')
    record('legacy API cannot retroactively hide an already announced public output')
    if bootstrap := os.getenv("CORNICE_TEST_SESSION_START"):
        # Exercise the real login bootstrap's test mode with real built products,
        # a genuine compositor receipt and a newline-terminated pointer. HOME
        # and all sockets are inside the sandbox; no services can be restarted.
        deploy = pathlib.Path(ENV['HOME']) / '.local/share/cornice-agent-desktop'
        release = deploy / 'releases/recovery-test'
        product_link = release / 'cornice/share/cornice'
        product_link.parent.mkdir(parents=True)
        product_link.symlink_to(PRODUCT)
        (release / 'deployment.json').write_text(json.dumps({'hyprlandCommit': ctl('version', True)['commit']}))
        (deploy / 'deployment-path').write_text(str(release) + '\n')
        result = subprocess.run(['/usr/bin/python3', bootstrap, '--test-bootstrap'], env=ENV,
                                text=True, capture_output=True, timeout=40)
        (BASE / 'session-bootstrap.log').write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stderr
        desktops = json.loads(result.stdout)['desktops']
        assert {d['workspace'] for d in desktops} == {'11', '12', '13'}
        assert all(d['paused'] for d in desktops)
        alive(gtk, 'human GTK'); alive(xclient, 'human X11')
        registry_roundtrip(watcher, log)
        record('real bootstrap handles newline-terminated release pointer and creates paused seats on 11-13')
finally:
    cleanup()
