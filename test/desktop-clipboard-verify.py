"""Real Wayland selections and GTK Ctrl+V across managed seats."""
from desktop_harness import *

# These modes are explicit runtime fixtures. Ordinary initialization continues
# to remove every ambient WAYLAND_SOCKET; only this callback passes a new FD
# made inside the private compositor to the actual installed Broker.
inherited_mode = os.getenv("CORNICE_TEST_INHERITED_DISPLAY_MODE", "")
assert inherited_mode in ("", "shared-first", "isolated-first")
policy = BASE / "config/cornice/config.json"
inherited_identity = None
decoy_baseline = None
broker = None


def inherited_broker():
    global inherited_identity, decoy_baseline
    ok("seat create clipboard-decoy human")
    ok("seat workspace clipboard-decoy name:clipboard-decoy-only")
    decoy = ctl("seat state clipboard-decoy", True)
    address = pathlib.Path(decoy["display"])
    if not address.is_absolute():
        address = RT / address
    assert address.is_relative_to(RT), address
    start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"),
           "clipboard-decoy-window", str(BASE / "decoy.txt")], "clipboard-decoy",
          ENV | {"WAYLAND_DISPLAY": decoy["display"]})
    wait(lambda: any(c["title"] == "clipboard-decoy-window" for c in ctl("clients", True)))
    decoy_baseline = {key: decoy.get(key) for key in ("seatId", "workspace", "windowId", "cursor", "display", "generation")}
    # Read back after mapping, so window focus/state changes from launching the
    # synthetic client are outside the operations being checked.
    decoy = ctl("seat state clipboard-decoy", True)
    decoy_baseline = {key: decoy.get(key) for key in decoy_baseline}
    subprocess.run(["wl-copy", "--seat", "clipboard-decoy", "--type", "text/plain;charset=utf-8"],
        input=b"synthetic decoy selection", env=ENV | {"WAYLAND_DISPLAY": decoy["display"]}, check=True, timeout=8)
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(str(address))
        fd = connection.fileno()
        inherited_identity = {"fd": fd, "inode": os.fstat(fd).st_ino, "display": str(address)}
        process = subprocess.Popen([str(PRODUCT / "bin/cornice-desktopd")],
            env=ENV | {"WAYLAND_SOCKET": str(fd)}, pass_fds=(fd,),
            stdout=open(BASE / "desktopd-inherited.log", "w"), stderr=subprocess.STDOUT,
            start_new_session=True)
    PROCESSES.append(process)
    return process


def check_decoy():
    if not inherited_mode:
        return
    actual = ctl("seat state clipboard-decoy", True)
    assert {key: actual.get(key) for key in decoy_baseline} == decoy_baseline
    assert not (BASE / "decoy.txt").exists() or not (BASE / "decoy.txt").read_bytes()
    decoy_selection = subprocess.check_output(["wl-paste", "--seat", "clipboard-decoy", "--no-newline", "--type", "text/plain;charset=utf-8"],
        env=ENV | {"WAYLAND_DISPLAY": actual["display"]}, timeout=5)
    assert decoy_selection == b"synthetic decoy selection"
    # The actual Broker must still own this original unrelated descriptor.
    # A reused fd number/EOF on some unrelated pipe cannot satisfy this check.
    assert os.stat(f"/proc/{broker.pid}/fd/{inherited_identity['fd']}").st_ino == inherited_identity["inode"]
    (BASE / "inherited-fd-identity.json").write_text(json.dumps(inherited_identity, indent=2))


try:
    if inherited_mode:
        policy.parent.mkdir(parents=True, exist_ok=True)
        policy.write_text(json.dumps({"agentDesktop": {"clipboard": {"mode":
            "isolated" if inherited_mode == "isolated-first" else "shared"}}}))
    broker = initialize(broker_launcher=inherited_broker if inherited_mode else None)
    cli("create", "clipboard-test", "--workspace", "11", "--virtual-output", "1280x800")
    cli("resume", "clipboard-test")
    binding = bind("clipboard-test")
    cli("launch", "clipboard-test", "--", "/usr/bin/python3", ROOT / "test/agent-desktop-client.py", "clipboard-target", BASE / "pasted.txt")
    window = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "clipboard-target"), None))
    window_id = next(w["id"] for w in tool(binding, "windows")["windows"] if w["title"] == "clipboard-target")
    tool(binding, "focus", {"windowId": window_id})
    if inherited_mode:
        start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"),
               "human-window", str(BASE / "main.txt")], "human")
        wait(lambda: any(c["title"] == "human-window" for c in ctl("clients", True)))
        ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
        baseline = human_state()
        frame = tool(binding, "capture")
        tool(binding, "input", {"action": "text", "text": "选定桌面", "frameId": frame["frameId"]})
        wait(lambda: (BASE / "pasted.txt").read_text() == "选定桌面")
        assert human_state() == baseline
        assert not (BASE / "main.txt").exists() or not (BASE / "main.txt").read_bytes()
        check_decoy()
        record(inherited_mode + ": actual SeatDriver targets the selected GTK app and preserves primary/decoy state and inherited FD")
        frame = tool(binding, "capture")
        tool(binding, "input", {"action": "chord", "keys": ["CTRL", "a"], "frameId": frame["frameId"]})
        if inherited_mode == "isolated-first":
            isolated = cli("doctor")["clipboard"]
            assert isolated["mode"] == "isolated" and not isolated["connected"]
            for seat, payload in (("Hyprland", b"synthetic isolated primary before"),
                                  ("clipboard-test", b"synthetic isolated secondary before")):
                subprocess.run(["wl-copy", "--seat", seat, "--type", "text/plain;charset=utf-8"],
                    input=payload, env=ENV, check=True, timeout=8)
                wait(lambda seat=seat,payload=payload: subprocess.check_output(
                    ["wl-paste", "--seat", seat, "--no-newline", "--type", "text/plain;charset=utf-8"],
                    env=ENV, timeout=5) == payload)
            subprocess.run(["wl-copy", "--seat", "Hyprland", "--type", "text/plain;charset=utf-8"],
                input=b"synthetic isolated primary", env=ENV, check=True, timeout=8)
            wait(lambda: subprocess.check_output(["wl-paste", "--seat", "Hyprland", "--no-newline", "--type", "text/plain;charset=utf-8"],
                env=ENV, timeout=5) == b"synthetic isolated primary")
            deadline = time.monotonic() + 1.2
            while time.monotonic() < deadline:
                target_selection = subprocess.check_output(["wl-paste", "--seat", "clipboard-test", "--no-newline", "--type", "text/plain;charset=utf-8"],
                    env=ENV, timeout=5)
                assert target_selection == b"synthetic isolated secondary before"
                time.sleep(.1)
            check_decoy()
            record("isolated-first: sharing remains disconnected and a known primary selection is not transferred")
            policy.write_text(json.dumps({"agentDesktop": {"clipboard": {"mode": "shared"}}}))
    wait(lambda: cli("doctor")["clipboard"]["connected"])
    def copy(seat, payload, mime="text/plain;charset=utf-8"):
        subprocess.run(["wl-copy", "--seat", seat, "--type", mime], input=payload, env=ENV, check=True, timeout=8)
    def paste(seat, mime="text/plain;charset=utf-8"):
        return subprocess.check_output(["wl-paste", "--seat", seat, "--no-newline", "--type", mime], env=ENV, timeout=5, stderr=subprocess.DEVNULL)
    message = "主桌面复制 → 第二桌面粘贴".encode()
    copy("Hyprland", message)
    wait(lambda: paste("clipboard-test") == message)
    frame = tool(binding, "capture")
    tool(binding, "input", {"action":"chord", "keys":["CTRL","v"], "frameId":frame["frameId"]})
    wait(lambda: (BASE / "pasted.txt").read_bytes() == message)
    record("main copy reaches real hidden-desktop GTK Ctrl+V without workspace switching")
    frame = tool(binding, "capture")
    tool(binding, "input", {"action":"chord", "keys":["CTRL","a"], "frameId":frame["frameId"]})
    reverse = "第二桌面复制 → 主桌面粘贴"
    tool(binding, "input", {"action":"text", "text":reverse, "frameId":frame["frameId"]})
    tool(binding, "input", {"action":"chord", "keys":["CTRL","a"], "frameId":frame["frameId"]})
    tool(binding, "input", {"action":"chord", "keys":["CTRL","c"], "frameId":frame["frameId"]})
    wait(lambda: paste("Hyprland") == reverse.encode())
    record("native GTK copy on secondary seat updates the main seat selection")
    if inherited_mode:
        assert human_state() == baseline
        assert not (BASE / "main.txt").exists() or not (BASE / "main.txt").read_bytes()
        check_decoy()
        record(inherited_mode + ": actual ClipboardBridge transfers both directions without using the decoy connection")
    png = base64.b64decode(tool(binding, "capture")["pngBase64"])
    copy("clipboard-test", png, "image/png")
    wait(lambda: paste("Hyprland", "image/png") == png)
    record("actual PNG MIME payload survives cross-seat transfer byte-for-byte")
    from clipboard_lock_runtime import verify_full_lock
    verify_full_lock(broker, "clipboard-test")
    # Clearing selections must converge rather than trigger an endless echo.
    subprocess.run(["wl-copy", "--seat", "clipboard-test", "--clear"], env=ENV, check=True, timeout=5)
    time.sleep(.3)
    assert cli("doctor")["clipboard"]["connected"]
    copy("Hyprland", b"after clear")
    wait(lambda: paste("clipboard-test") == b"after clear")
    record("selection clear converges and a subsequent copy still propagates")
    config = BASE / "config/cornice"; config.mkdir(parents=True, exist_ok=True)
    policy = config / "config.json"
    policy.write_text(json.dumps({"agentDesktop":{"clipboard":{"mode":"shared","maxBytes":1024}}}))
    time.sleep(1.2)
    copy("Hyprland", b"x" * 2048)
    wait(lambda: "limit" in cli("doctor")["clipboard"]["error"])
    assert paste("clipboard-test") == b"after clear"
    record("oversized data reports a bounded transfer error and keeps the recipient selection")
    policy.write_text(json.dumps({"agentDesktop":{"clipboard":{"mode":"isolated"}}}))
    wait(lambda: cli("doctor")["clipboard"]["mode"] == "isolated")
    copy("Hyprland", b"private primary selection")
    result = subprocess.run(["wl-paste","--seat","clipboard-test","--no-newline"], env=ENV, capture_output=True, timeout=5)
    assert result.stdout != b"private primary selection"
    record("configured isolated mode never synchronizes a new primary selection")
except Exception:
    try:
        (BASE / "clipboard-failure.json").write_text(json.dumps(cli("doctor"),ensure_ascii=False,indent=2))
    except Exception:
        pass
    raise
finally:
    cleanup()
