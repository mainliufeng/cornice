"""Real isolated Hyprland integration; never operates on the live session."""
from desktop_harness import *

try:
    broker = initialize()
    for index in range(3):
        cli("create", "agent" + str(index + 1), "--workspace", str(10 + index), "--output", "human")
        cli("resume", "agent" + str(index + 1))
    assert len(cli("list")["desktops"]) == 3
    record("three managed agent seats on one output, precreated before GTK clients")
    start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"), "human-window", str(BASE / "human.txt")], "human")
    wait(lambda: len(ctl("clients", True)) == 1)
    for index in range(3):
        name = "agent" + str(index + 1)
        cli("launch", name, "--", "/usr/bin/python3", ROOT / "test/agent-desktop-client.py", name + "-window", BASE / (name + ".txt"))
    wait(lambda: len(ctl("clients", True)) == 4)
    ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
    baseline = human_state()
    binding = bind("agent1")
    # The binding supplies its target even from a shell without compositor env.
    plain = ENV.copy(); plain.pop("HYPRLAND_INSTANCE_SIGNATURE")
    assert cli("tool", binding, "desktop.state", "{}", env=plain)["name"] == "agent1"
    frame = tool(binding, "capture")
    assert frame["workspace"] == "10" and frame["viewWorkspace"] == "10"
    (BASE / "agent.png").write_bytes(base64.b64decode(frame["pngBase64"]))
    text = "Agent 中文输入\nsecond line"
    tool(binding, "input", {"action": "text", "text": text.replace("\n", " "), "frameId": frame["frameId"]})
    wait(lambda: (BASE / "agent1.txt").read_text() == text.replace("\n", " "))
    assert (BASE / "agent1.txt").read_text() == text.replace("\n", " ")
    assert human_state() == baseline
    record("UTF-8 Chinese text reaches hidden agent Client; human focus/workspace/cursor unchanged")
    geometry = json.loads(wait(lambda: (BASE / "agent1.geometry").read_text()))["button"]
    client = next(c for c in ctl("clients", True) if c["title"] == "agent1-window")
    x = client["at"][0] + geometry[0] + geometry[2] / 2
    y = client["at"][1] + geometry[1] + geometry[3] / 2
    frame = tool(binding, "capture")
    tool(binding, "input", {"action": "click", "x": x, "y": y, "frameId": frame["frameId"]})
    wait(lambda: (BASE / "agent1.click").read_text() == "1")
    credential = json.loads(binding.read_text())
    body = json.dumps({"id": "retry-click", "method": "desktop.input", "token": credential["token"],
                       "params": {"action": "click", "x": x, "y": y, "frameId": frame["frameId"]}}).encode() + b"\n"
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5); connection.connect(credential["socket"])
        for retry in range(2):
            connection.sendall(body)
            response = b""
            while b"\n" not in response: response += connection.recv(65536)
            assert json.loads(response)["ok"]
            wait(lambda: (BASE / "agent1.click").read_text() == "2")
    assert (BASE / "agent1.click").read_text() == "2"
    assert human_state() == baseline
    record("real pointer click hits hidden seat Client; repeated RPC ID never doubles a click")
    tool(binding, "workspace", {"workspace": "11"})
    assert tool(binding, "state")["workspace"] == "11" and human_state() == baseline
    error = tool(binding, "input", {"action": "click", "x": 10, "y": 10, "frameId": frame["frameId"]}, succeeds=False)
    assert "stale" in error.lower()
    cli("resume", "agent1"); binding = bind("agent1")
    tool(binding, "workspace", {"workspace": "10"})
    record("seat workspace isolation and stale screenshot rejection")
    frame = tool(binding, "capture")
    original_text = (BASE / "agent1.txt").read_text()
    extra_path = BASE / "focus-race.txt"
    cli("launch", "agent1", "--", "/usr/bin/python3", ROOT / "test/agent-desktop-client.py", "focus-race-window", extra_path)
    extra = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "focus-race-window"), None))
    OWNED_PIDS.append(extra["pid"])
    wait(lambda: cli("state", "agent1")["windowId"] != frame["windowId"])
    assert "stale" in tool(binding, "input", {"action": "text", "text": "WRONG CLIENT", "frameId": frame["frameId"]}, succeeds=False).lower()
    assert not extra_path.exists() and (BASE / "agent1.txt").read_text() == original_text
    os.kill(extra["pid"], signal.SIGTERM)
    wait(lambda: len(ctl("clients", True)) == 4)
    cli("resume", "agent1"); binding = bind("agent1")
    original_window = next(w["id"] for w in tool(binding, "windows")["windows"] if w["title"] == "agent1-window")
    tool(binding, "focus", {"windowId": original_window})
    assert human_state() == baseline
    record("application activation between capture and input cannot redirect text to a different Client")

    before = cli("state", "agent1")
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5); connection.connect(str(RT / "cornice" / ENV["HYPRLAND_INSTANCE_SIGNATURE"] / "desktop.sock"))
        observed = rpc(connection, "frame", {"name": "agent1", "workspace": "11"})
        assert observed["viewWorkspace"] == "11" and observed["workspace"] == "10" and not observed["cursorVisible"]
        pixels = pathlib.Path(observed["buffer"])
        assert pixels.stat().st_size == 1280 * 800 * 4
        assert cli("state", "agent1") == before and human_state() == baseline
    wait(lambda: not pixels.exists())
    record("read-only browse exports SHM frame without changing either seat; disconnect releases buffer")
    # A browsed workspace need not be current for any seat. Its real animated
    # client must still receive frame/FIFO callbacks while an observer reads it.
    agent2_binding = bind("agent2")
    tool(agent2_binding, "workspace", {"workspace": "13"})
    unseen = cli("state", "agent2")
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5); connection.connect(str(RT / "cornice" / ENV["HYPRLAND_INSTANCE_SIGNATURE"] / "desktop.sock"))
        animated = []
        for iteration in range(5):
            observed = rpc(connection, "frame", {"name": "agent1", "workspace": "11"})
            animated.append(pathlib.Path(observed["buffer"]).read_bytes())
            time.sleep(.08)
        assert len(set(animated)) >= 2, "Read-only unselected workspace froze its application frames"
        assert cli("state", "agent2") == unseen and human_state() == baseline
    tool(agent2_binding, "workspace", {"workspace": "11"})
    record("browsing a workspace selected by no seat keeps real animated application frames advancing")

    # Leave a separate legacy virtual device connected across pause/resume.
    # Broker queue tests alone cannot prove compositor revocation.
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"),
                         ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(BASE / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    subprocess.run(["cc", "-I" + str(BASE), str(FORK / "hyprtester/multiseat/input.c"),
                    str(BASE / "virtual-keyboard.c"), str(BASE / "virtual-pointer.c"), "-o", str(BASE / "legacy-input"), *flags], check=True)
    rogue_env = ENV.copy(); rogue_env["WAYLAND_DISPLAY"] = cli("state", "agent2")["display"]
    rogue = subprocess.Popen([str(BASE / "legacy-input"), "agent2", "human"], env=rogue_env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / "legacy-input.log", "w"), text=True, bufsize=1, start_new_session=True)
    PROCESSES.append(rogue)
    assert select.select([rogue.stdout], [], [], 5)[0] and rogue.stdout.readline().strip() == "ready"
    revoked_sources = []
    for command in ("new-pointer", "new-keyboard"):
        source = subprocess.Popen([str(BASE / "legacy-input"), "agent2", "human"], env=rogue_env,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / (command + ".log"), "w"),
                                  text=True, bufsize=1, start_new_session=True)
        PROCESSES.append(source)
        assert select.select([source.stdout], [], [], 5)[0] and source.stdout.readline().strip() == "ready"
        revoked_sources.append((source, command))
    cli("pause", "agent2"); cli("resume", "agent2")
    before = cli("state", "agent2")
    rogue.stdin.write("motion 10 10\n"); rogue.stdin.flush()
    assert select.select([rogue.stdout], [], [], 5)[0] and rogue.stdout.readline().strip() == "done"
    assert cli("state", "agent2") == before
    for source, command in revoked_sources:
        source.stdin.write(command + "\n"); source.stdin.flush()
        assert select.select([source.stdout], [], [], 5)[0] and source.stdout.readline().strip() == "done"
        assert source.poll() is None
        old_text = (BASE / "agent2.txt").read_text() if (BASE / "agent2.txt").exists() else ""
        for event in ("motion 900 700", "type blocked"):
            source.stdin.write(event + "\n"); source.stdin.flush()
            assert select.select([source.stdout], [], [], 5)[0] and source.stdout.readline().strip() == "done"
        assert ((BASE / "agent2.txt").read_text() if (BASE / "agent2.txt").exists() else "") == old_text
        assert "seat input source revoked" not in (BASE / (command + ".log")).read_text()
    assert cli("state", "agent2") == before
    record("old devices remain inert; revoked connections cannot create replacement virtual devices")
    frame = tool(binding, "capture")
    tool(binding, "input", {"action": "key", "code": 42, "pressed": True, "frameId": frame["frameId"]})
    cli("pause", "agent1")
    assert "revoked" in tool(binding, "input", {"action": "text", "text": "bad", "frameId": frame["frameId"]}, succeeds=False)
    assert cli("state", "agent1")["paused"]
    cli("resume", "agent1"); new_binding = bind("agent1")
    assert "revoked" in tool(binding, "state", succeeds=False)
    frame = tool(new_binding, "capture")
    entry_geometry = json.loads((BASE / "agent1.geometry").read_text())["entry"]
    tool(new_binding, "input", {"action": "click", "x": client["at"][0] + entry_geometry[0] + entry_geometry[2] / 2,
                               "y": client["at"][1] + entry_geometry[1] + entry_geometry[3] / 2, "frameId": frame["frameId"]})
    tool(new_binding, "input", {"action": "chord", "keys": ["CTRL", "a"], "frameId": frame["frameId"]})
    tool(new_binding, "input", {"action": "text", "text": "lowercase", "frameId": frame["frameId"]})
    wait(lambda: (BASE / "agent1.txt").read_text() == "lowercase")
    record("pause releases held input, revokes old binding and resumes with fresh devices")
    chrome = pathlib.Path("/opt/google/chrome/google-chrome")
    if chrome.is_file():
        page = BASE / "browser.html"
        page.write_text('<title>agent-browser</title><h1>Agent browser input</h1>'
                        '<input autofocus oninput="document.title=\'typed:\'+this.value">')
        if os.getenv("CORNICE_TEST_WAYLAND_DEBUG"):
            wrapper = BASE / "google-chrome"
            wrapper.write_text("#!/bin/sh\nWAYLAND_DEBUG=client exec " + shlex.quote(str(chrome)) +
                               ' "$@" >' + shlex.quote(str(BASE / "chrome-wayland.log")) + " 2>&1\n")
            wrapper.chmod(0o700)
            chrome = wrapper
        launched = cli("launch", "agent3", "--", chrome, "--ozone-platform=wayland", "--no-first-run",
                       "--no-default-browser-check", "--disable-gpu", "--disable-dev-shm-usage", page.as_uri())
        wait(lambda: any(c["title"].startswith("agent-browser") for c in ctl("clients", True)))
        browser_binding = bind("agent3")
        browser = next(w for w in tool(browser_binding, "windows")["windows"] if w["title"].startswith("agent-browser"))
        tool(browser_binding, "focus", {"windowId": browser["id"]})
        frame = tool(browser_binding, "capture")
        (BASE / "browser-before.png").write_bytes(base64.b64decode(frame["pngBase64"]))
        browser_client = next(c for c in ctl("clients", True) if c["title"].startswith("agent-browser"))
        OWNED_PIDS.append(browser_client["pid"])
        tool(browser_binding, "input", {"action": "click", "x": browser_client["at"][0] + 100,
                                        "y": browser_client["at"][1] + 164, "frameId": frame["frameId"]})
        tool(browser_binding, "input", {"action": "text", "text": "Seat中文", "frameId": frame["frameId"]})
        time.sleep(.5)
        (BASE / "browser-after.png").write_bytes(base64.b64decode(tool(browser_binding, "capture")["pngBase64"]))
        (BASE / "browser-windows.json").write_text(json.dumps(ctl("clients", True), ensure_ascii=False))
        wait(lambda: any(c["title"].startswith("typed:Seat中文") for c in ctl("clients", True)))
        assert human_state() == baseline
        os.kill(browser_client["pid"], signal.SIGTERM)
        wait(lambda: len(ctl("clients", True)) == 4)
        record("actual Chrome receives hidden-seat Unicode input with a dedicated profile")
    kitty = pathlib.Path("/usr/bin/kitty")
    if kitty.is_file():
        destination = BASE / "terminal-result.txt"
        cli("launch", "agent3", "--", kitty, "--title", "agent-terminal", "-o", "linux_display_server=wayland",
            "-o", "confirm_os_window_close=0", "-e", "/usr/bin/bash", "--noprofile", "--norc")
        terminal = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "agent-terminal"), None))
        OWNED_PIDS.append(terminal["pid"])
        terminal_binding = bind("agent3")
        terminal_id = next(w["id"] for w in tool(terminal_binding, "windows")["windows"] if w["title"] == "agent-terminal")
        tool(terminal_binding, "focus", {"windowId": terminal_id})
        frame = tool(terminal_binding, "capture")
        tool(terminal_binding, "input", {"action": "text", "text": "printf '%s' 'terminal 中文' > " + shlex.quote(str(destination)) + "\n",
                                          "frameId": frame["frameId"]})
        wait(lambda: destination.read_text() == "terminal 中文")
        assert human_state() == baseline
        tool(terminal_binding, "input", {"action": "text", "text": "exit\n", "frameId": frame["frameId"]})
        wait(lambda: len(ctl("clients", True)) == 4)
        record("actual kitty executes hidden-seat typed commands including Chinese and Return")
    qt_page = BASE / "qt.qml"
    qt_page.write_text("""import QtQuick
import Quickshell
FloatingWindow {
    id: qtRoot
    visible: true; title: "agent-qt"; width: 600; height: 400
    TextInput { anchors.fill: parent; focus: true; color: "black";
        onTextChanged: { qtRoot.title = "typedQt:" + text }
    }
}
""")
    cli("launch", "agent3", "--", PRODUCT / "bin/cornice-qs", "-p", qt_page)
    qt_client = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "agent-qt"), None))
    OWNED_PIDS.append(qt_client["pid"])
    qt_binding = bind("agent3")
    qt_id = next(w["id"] for w in tool(qt_binding, "windows")["windows"] if w["title"] == "agent-qt")
    tool(qt_binding, "focus", {"windowId": qt_id})
    frame = tool(qt_binding, "capture")
    tool(qt_binding, "input", {"action": "text", "text": "Qt中文", "frameId": frame["frameId"]})
    wait(lambda: any(c["title"] == "typedQt:Qt中文" for c in ctl("clients", True)))
    (BASE / "qt-after.png").write_bytes(base64.b64decode(tool(qt_binding, "capture")["pngBase64"]))
    assert human_state() == baseline
    os.kill(qt_client["pid"], signal.SIGTERM)
    wait(lambda: len(ctl("clients", True)) == 4)
    record("actual Qt/Quickshell TextInput receives hidden-seat Chinese text")
    # Run the actual cornice UI against the same fork and inspect its exported
    # frame, then exercise observer navigation through its public shell IPC.
    cornice_config = BASE / "config/cornice"
    cornice_config.mkdir(parents=True, exist_ok=True)
    (cornice_config / "config.json").write_text(json.dumps({
        "agentDesktop": {"enabled": True},
        "bar": {"layout": {"left": [{"id": "cn.workspaces"}, {"id": "cn.agent-desktop"}], "center": [], "right": []}},
        "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0, "dimAc": 0, "dimBattery": 0,
                 "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False},
        "background": {"enabled": False}, "weather": {"intervalMinutes": 0}}))
    quickshell = start([str(PRODUCT / "bin/cornice-qs"), "-p", str(PRODUCT / "shell")], "cornice")
    wait(lambda: json.loads(shell("ipc", "desktop", "status"))["available"])
    assert len(json.loads(shell("ipc", "desktop", "status"))["desktops"]) == 3
    shell("desktop", "observe", "agent1")
    frame_ui = wait(lambda: json.loads(shell("ipc", "desktopObserver", "status")).get("presentation", {}).get("active"))
    shell("desktop", "observe", "agent1")
    assert json.loads(shell("ipc", "desktopObserver", "status"))["open"], "Observe must be idempotent, not toggle/close"
    assert "different compositor instance" in cli("--instance", "nonexistent-instance", "observe", "agent1", succeeds=False)
    observed_state = cli("state", "agent1")
    shell("ipc", "desktopObserver", "browse", "11")
    wait(lambda: json.loads(shell("ipc", "desktopObserver", "status"))["presentation"].get("workspace") == "11")
    assert cli("state", "agent1") == observed_state
    shell("ipc", "desktopObserver", "follow")
    wait(lambda: json.loads(shell("ipc", "desktopObserver", "status"))["presentation"].get("workspace") == "10")
    time.sleep(.5)
    paint_start = json.loads(shell("ipc", "desktopObserver", "status"))
    samples = []; stamps = []; begun = time.monotonic(); end = begun + 3
    while time.monotonic() < end:
        shot = BASE / "observer-live.ppm"
        subprocess.run(["grim", "-t", "ppm", str(shot)], env=ENV, check=True, timeout=5)
        stamp = displayed_clock(shot)
        samples.append(((int(time.monotonic() * 1000) & 0xffffffff) - stamp) & 0xffffffff)
        stamps.append(stamp)
        time.sleep(.015)
    elapsed = time.monotonic() - begun
    # The clock also advances while its ws is hidden. This measures real output
    # pixels, not a socket acknowledgement or an unchanged screenshot.
    paint_end = json.loads(shell("ipc", "desktopObserver", "status"))
    fps = (paint_end["presentation"]["frames"] - paint_start["presentation"]["frames"]) / elapsed
    metrics = {"nativeSceneDrawsPerSecond": round(fps, 2), "maximumPaintToObservationMs": max(samples),
               "physicalOutputSamples": len(samples), "distinctPixelFrames": len(set(stamps))}
    (BASE / "observer-performance.json").write_text(json.dumps(metrics))
    assert fps >= 30, metrics
    assert max(samples) < 200, metrics
    record("live observer output: " + json.dumps(metrics))
    assert not list((RT / "cornice" / ENV["HYPRLAND_INSTANCE_SIGNATURE"]).glob("frame-*"))
    # Exercise real human-seat interaction while the observer holds keyboard
    # focus. No target device is created by this view.
    human_input = subprocess.Popen([str(BASE / "legacy-input"), "Hyprland", "human"], env=ENV,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / "human-input.log", "w"),
                                   text=True, bufsize=1, start_new_session=True)
    PROCESSES.append(human_input)
    assert select.select([human_input.stdout], [], [], 5)[0] and human_input.stdout.readline().strip() == "ready"
    readonly_before = cli("state", "agent1")
    clients_before = ctl("clients", True)
    text_before = (BASE / "agent1.txt").read_text()
    for event in ("motion 500 500", "button 272 1", "button 272 0", "type READONLY", "key 29 1", "key 17 1", "key 17 0", "key 29 0"):
        human_input.stdin.write(event + "\n"); human_input.stdin.flush()
        assert select.select([human_input.stdout], [], [], 5)[0] and human_input.stdout.readline().strip() == "done"
    assert json.loads(shell("ipc", "desktopObserver", "status"))["open"]
    assert (BASE / "agent1.txt").read_text() == text_before
    assert cli("state", "agent1") == readonly_before
    assert [c["address"] for c in ctl("clients", True)] == [c["address"] for c in clients_before]
    record("human click, text and Ctrl+W in the actual read-only observer do not reach shared applications")
    shell("lock")
    wait(lambda: json.loads(shell("ipc", "lock", "status"))["secure"])
    wait(lambda: json.loads(shell("ipc", "desktopObserver", "status"))["presentation"].get("active") is not True)
    assert cli("state", "agent1")["paused"]
    shell("lock", "emergency-unlock")
    wait(lambda: not json.loads(shell("ipc", "lock", "status"))["locked"])
    assert cli("state", "agent1")["paused"], "Unlock must not restore an agent's write lease"
    # Lock clears focus grabs and may close the overlay. Reopen explicitly;
    # showing a fresh read-only frame must not itself resume agent input.
    shell("desktop", "observe", "agent1")
    try:
        wait(lambda: json.loads(shell("ipc", "desktopObserver", "status"))["presentation"].get("active"))
    except RuntimeError:
        print("Post-unlock diagnostic", shell("ipc", "desktopObserver", "status"), cli("state", "agent1"),
              shell("ipc", "desktop", "status"), ctl("locked", True), flush=True)
        raise
    assert cli("state", "agent1")["paused"]
    cli("resume", "agent1")
    record("real session lock clears native presentation and revokes input; unlock stays paused")
    subprocess.run(["grim", str(BASE / "observer.png")], env=ENV, check=True, timeout=5)
    human_input.stdin.write(f"motion {int(baseline['cursor']['x'])} {int(baseline['cursor']['y'])}\n"); human_input.stdin.flush()
    assert select.select([human_input.stdout], [], [], 5)[0] and human_input.stdout.readline().strip() == "done"
    shell("ipc", "shell", "hide", "cn.desktop-observer")
    wait(lambda: not json.loads(shell("ipc", "desktopObserver", "status"))["open"])
    shell("ipc", "shell", "summon", "cn.agent-desktop", "{}")
    wait(lambda: any(item["namespace"] == "cornice-panel" for item in ctl("layers", True)["human"]["levels"]["3"]))
    wait(lambda: all(d["paused"] == (d["name"] != "agent1") for d in json.loads(shell("ipc", "desktop", "status"))["desktops"]))
    for desired in (True, False):
        control = next(row for row in json.loads(shell("ipc", "desktopPanel", "controls")) if row["name"] == "agent1")
        layers = ctl("layers", True)["human"]["levels"]["3"]
        layer = next(item for item in layers if item["namespace"] == "cornice-panel")
        for event in (f"motion {int(layer['x'] + control['x'] + control['width']/2)} {int(layer['y'] + control['y'] + control['height']/2)}", "button 272 1", "button 272 0"):
            human_input.stdin.write(event + "\n"); human_input.stdin.flush()
            assert select.select([human_input.stdout], [], [], 5)[0] and human_input.stdout.readline().strip() == "done"
        wait(lambda: cli("state", "agent1")["paused"] == desired)
        wait(lambda: not json.loads(shell("ipc", "desktop", "status"))["busy"] and
                     next(d["paused"] for d in json.loads(shell("ipc", "desktop", "status"))["desktops"] if d["name"] == "agent1") == desired)
    record("real human clicks on manager pause/resume buttons change compositor control state")
    subprocess.run(["grim", str(BASE / "manager.png")], env=ENV, check=True, timeout=5)
    shell("ipc", "shell", "hide", "cn.agent-desktop")
    human_input.stdin.write(f"motion {int(baseline['cursor']['x'])} {int(baseline['cursor']['y'])}\n"); human_input.stdin.flush()
    assert select.select([human_input.stdout], [], [], 5)[0] and human_input.stdout.readline().strip() == "done"
    human_input.terminate(); human_input.wait(timeout=5)
    quickshell.terminate(); quickshell.wait(timeout=8)
    assert cli("state", "agent1")["paused"] is False, "UI teardown must not destroy the independent desktop service"
    assert human_state()["workspace"] == baseline["workspace"]
    record("actual cornice observer follows/browses native scenes; UI teardown preserves service")
    # CLI-owned service graceful shutdown and restart leave seats paused.
    broker.terminate(); assert broker.wait(timeout=8) == 0
    assert all(ctl("seat state agent" + str(i + 1), True)["paused"] for i in range(3))
    broker = start([str(PRODUCT / "bin/cornice-desktopd")], "desktopd-restarted")
    wait(desktop_ready)
    assert len(cli("list")["desktops"]) == 3
    assert all(d["paused"] for d in cli("list")["desktops"])
    cli("resume", "agent2")
    broker.kill(); broker.wait(timeout=5)
    wait(lambda: ctl("seat state agent2", True)["paused"])
    record("forced desktop service crash revokes live input devices in compositor")
    broker = start([str(PRODUCT / "bin/cornice-desktopd")], "desktopd-after-crash")
    wait(desktop_ready)
    cli("remove", "agent3")
    assert len(ctl("clients", True)) == 4
    assert human_state() == baseline
    record("service restart stays paused; retirement preserves shared applications and human state")
    # Exercise the human-only Lua adapter separately from seat tools.
    def human_command(*args):
        subprocess.run([str(PRODUCT / "bin/cornice-compositor"), *map(str, args)], env=ENV, check=True, timeout=8)
    human_command("workspace", "2")
    assert ctl("activeworkspace", True)["id"] == 2
    human_command("workspace", "1")
    warp_option = ctl("getoption cursor:no_warps", True)
    original_warp = int(warp_option.get("bool", warp_option.get("int")))
    original_policy = ctl("getoption misc:on_focus_under_fullscreen", True)["int"]
    human_command("focus-window", baseline["window"], original_warp, original_policy)
    restored_warp = ctl("getoption cursor:no_warps", True)
    assert int(restored_warp.get("bool", restored_warp.get("int"))) == original_warp
    assert ctl("getoption misc:on_focus_under_fullscreen", True)["int"] == original_policy
    assert human_state() == baseline
    app = next(c for c in ctl("clients", True) if c["title"] == "agent1-window")
    subprocess.run([str(PRODUCT / "bin/cornice-focus-app"), "--pid", str(app["pid"])], env=ENV, check=True, timeout=8)
    assert ctl("activeworkspace", True)["id"] == 10 and ctl("activewindow", True)["address"] == app["address"]
    assert ctl("cursorpos", True) == baseline["cursor"]
    human_command("workspace", "1")
    human_command("focus-window", baseline["window"], original_warp, original_policy)
    assert human_state() == baseline
    human_command("dpms", "off")
    assert not cli("state", "agent1")["available"]
    human_command("dpms", "on")
    assert cli("state", "agent1")["available"] and cli("state", "agent1")["paused"]
    marker = BASE / "human launch marker"
    human_command("exec", "/usr/bin/touch", marker)
    wait(marker.exists)
    record("human-only Lua adapter switches ws, preserves focus policy, handles DPMS and quoted argv launch")
    print("Artifacts:", BASE, flush=True)
finally:
    cleanup()
