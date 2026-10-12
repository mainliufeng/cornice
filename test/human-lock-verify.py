"""Real isolated Hyprland integration; never operates on the live session."""
from desktop_harness import *
from cdp_client import Cdp
import urllib.request
import re
from PIL import Image


def provider_secure(process, event_name):
    """The provider's own locked acknowledgement, not another owner's state."""
    path = BASE / event_name
    def acknowledged():
        assert process.poll() is None, (event_name, process.returncode)
        if not path.exists():
            return False
        for line in path.read_text().splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue  # A final line may be in the middle of its write.
            if event.get("event") == "secure" and event.get("secure") is True:
                return True
        return False
    wait(acknowledged, 10)


def secondary_process(args, event_name, log_name, env=None):
    """Real secondary display and inherited FD must not select lock ownership."""
    display = cli("state", "continuing")["display"]
    assert display != ENV["WAYLAND_DISPLAY"], display
    address = pathlib.Path(display)
    if not address.is_absolute():
        address = RT / address
    assert address.is_relative_to(RT), address
    with socket.socket(socket.AF_UNIX) as inherited:
        inherited.connect(str(address))
        child_env = (env or ENV) | {"WAYLAND_DISPLAY": display,
                                   "WAYLAND_SOCKET": str(inherited.fileno()), "WAYLAND_DEBUG": "client"}
        process = subprocess.Popen(args, env=child_env, pass_fds=(inherited.fileno(),),
            stdin=subprocess.PIPE, stdout=open(BASE / event_name, "w"), stderr=open(BASE / log_name, "w"),
            start_new_session=True, text=True)
    PROCESSES.append(process)
    return process


def provider_output_coverage(process, event_name, log_name, scope):
    """Require the provider's own surfaces; secure can initially mean failsafe."""
    provider_secure(process, event_name)
    monitors = {monitor["name"] for monitor in ctl("monitors", True)}
    private = set(ctl("seat private-outputs", True))
    test_outputs = {cli("state", name)["output"] for name in ("continuing", "continuing2", "pausing")}
    assert len(test_outputs) == 3 and test_outputs <= private and private < monitors, (test_outputs, private, monitors)
    expected = monitors if scope == "session" else monitors - private
    state = ctl("seat lock-state", True)
    assert state["secure"] and state["scope"] == scope, state
    protected = state["protectedOutputs"]
    assert {output["name"] for output in protected} == expected, (expected, protected)
    assert len(protected) == len(expected) and all(output["covered"] for output in protected), protected
    protocol = "ext_session_lock" if scope == "session" else "hyprland_lock_scope"

    def presented():
        assert process.poll() is None, (event_name, process.returncode)
        trace = (BASE / log_name).read_text()
        outputs = dict(re.findall(r'wl_output[#@](\d+)\.name\("([^"]+)"\)', trace))
        surfaces = re.findall(protocol + r'_v1[#@]\d+\.get_lock_surface\(new id ' + protocol +
                              r'_surface_v1[#@](\d+), wl_surface[#@](\d+), wl_output[#@](\d+)\)', trace)
        names = [outputs.get(output) for surface, wl_surface, output in surfaces]
        if set(outputs.values()) != monitors or set(names) != expected or len(names) != len(expected):
            return False
        if scope != "session":
            excluded = re.findall(r'hyprland_lock_scope_v1[#@]\d+\.exclude_output\(wl_output[#@](\d+)\)', trace)
            if {outputs.get(output) for output in excluded} != private:
                return False
        for surface, wl_surface, output in surfaces:
            configured = set(re.findall(protocol + r'_surface_v1[#@]' + surface + r'\.configure\((\d+),', trace))
            acknowledged = set(re.findall(protocol + r'_surface_v1[#@]' + surface + r'\.ack_configure\((\d+)\)', trace))
            if not configured.intersection(acknowledged):
                return False
            # A configured surface without a rendered buffer leaves the
            # compositor's black failsafe in place, which is not native lock UI.
            if not re.search(r'wl_surface[#@]' + wl_surface + r'\.attach\(wl_buffer[#@]\d+,', trace):
                return False
            if not re.search(r'wl_surface[#@]' + wl_surface + r'\.commit\(\)', trace):
                return False
        return True

    wait(presented, 10)
    record(scope + " native provider enumerates all outputs and configures/acks/presents every protected output")


def unlock_provider(process, event_name):
    provider_secure(process, event_name)
    process.stdin.write("emergency-unlock\n"); process.stdin.flush()
    wait(lambda: not ctl("seat lock-state", True)["locked"])
    process.wait(timeout=5)
    assert process.returncode == 0, (event_name, process.returncode)


try:
    initialize()
    cli("create", "continuing", "--workspace", "10", "--virtual-output", "1280x800", "--human-lock-policy", "continue")
    cli("create", "continuing2", "--workspace", "12", "--virtual-output", "1280x800", "--human-lock-policy", "continue")
    cli("create", "pausing", "--workspace", "11", "--virtual-output", "1280x800")
    for name in ("continuing", "continuing2", "pausing"):
        cli("resume", name)
        gtk_env = ENV | {"WAYLAND_DISPLAY": cli("state", name)["display"], "WAYLAND_DEBUG": "client"}
        start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"), name + "-window", str(BASE / (name + ".txt"))], name, gtk_env)
    wait(lambda: len(ctl("clients", True)) == 3)
    binding = bind("continuing")
    second = bind("continuing2")
    tool(second, "workspace", {"workspace": "10"})
    target = cli("state", "continuing")["windowId"]
    tool(second, "focus", {"windowId": target})
    frame2 = tool(second, "capture")
    tool(second, "input", {"action": "text", "text": "shared", "frameId": frame2["frameId"]})
    wait(lambda: (BASE / "continuing.txt").read_text() == "shared")
    tool(second, "workspace", {"workspace": "12"})
    record("independent agent seats input into the same real GTK Client")
    browser = tool(binding, "browser")
    cdp = Cdp(browser["cdpUrl"])
    created = cdp.call("Target.createTarget", {"url": "data:text/html,<title>Agent CDP</title><body>ready</body>"})
    session = cdp.call("Target.attachToTarget", {"targetId": created["targetId"], "flatten": True})["sessionId"]
    wait(lambda: cdp.call("Runtime.evaluate", {"expression": "document.title", "returnByValue": True}, session)["result"].get("value") == "Agent CDP")
    # Force multiple pipe writes without replaying the JavaScript command.
    assert cdp.call("Runtime.evaluate", {"expression": "'" + "x" * 128000 + "'.length", "returnByValue": True}, session)["result"]["value"] == 128000
    browser_client = wait(lambda: next((client for client in ctl("clients", True) if client["title"].startswith("Agent CDP")), None))
    browser_pid = browser_client["pid"]
    OWNED_PIDS.append(browser_pid)
    cli("pause", "continuing")
    try:
        cdp.call("Browser.getVersion")
        raise AssertionError("CDP command survived pause")
    except (ConnectionError, OSError): pass
    cdp.close()
    cli("resume", "continuing"); binding = bind("continuing")
    browser = tool(binding, "browser"); cdp = Cdp(browser["cdpUrl"])
    session = cdp.call("Target.attachToTarget", {"targetId": created["targetId"], "flatten": True})["sessionId"]
    record("manual pause revokes live CDP; explicit resume needs a fresh binding")
    tool(binding, "focus", {"windowId": target})
    start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"), "human-window", str(BASE / "human.txt")], "human-app")
    wait(lambda: any(c["title"] == "human-window" for c in ctl("clients", True)))
    ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
    prelock_frame = tool(binding, "capture")
    pam = BASE / "pam"; pam.mkdir()
    # Real lock services can be auth-only. A default account deny reproduced
    # the live failure where the correct password passed auth then was rejected.
    (pam / "permit").write_text("auth required pam_permit.so\n")
    (pam / "other").write_text("auth required pam_deny.so\naccount required pam_deny.so\n")
    (pam / "deny-worker").write_text("auth required pam_deny.so\naccount required pam_permit.so\n")
    for service, expected in (("permit", 0), ("deny-worker", 1)):
        result = subprocess.run([str(PRODUCT / "bin/cornice-human-lock"), "--pam-worker", service, str(pam)],
            input=json.dumps({"password": "test-only"}), env=ENV, text=True, capture_output=True)
        assert result.returncode == expected, (service, result.returncode, result.stderr)
    record("auth-only lock PAM succeeds despite default account denial; rejected authentication still fails")
    appearance = json.loads((PRODUCT / "themes/mono/theme.json").read_text())
    appearance = appearance["colors"] | appearance["metrics"] | {
        "backgroundSource": (PRODUCT / "wallpapers/default.png").as_uri(), "blur": 1, "language": "zh-CN"}
    assert "management-display-v1" in ctl("seat capabilities", True)["features"]
    locker = secondary_process([str(PRODUCT / "bin/cornice-human-lock"), "--appearance", json.dumps(appearance), "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"],
        "lock-events", "lock.log")
    try:
        wait(lambda: ctl("seat lock-state", True)["secure"], 10)
    except RuntimeError:
        print("lock state", ctl("seat lock-state", True), "provider exit", locker.poll(), flush=True)
        subprocess.run(["grim", "-o", "human", str(BASE / "lock-timeout.png")], env=ENV, timeout=4)
        raise
    provider_output_coverage(locker, "lock-events", "lock.log", "scoped")
    assert cli("state", "continuing")["available"] and not cli("state", "continuing")["paused"]
    assert cli("state", "pausing")["paused"]
    assert cdp.call("Runtime.evaluate", {"expression": "document.body.textContent='locked CDP'; document.body.textContent", "returnByValue": True}, session)["result"]["value"] == "locked CDP"
    record("real Chrome uses pipe-backed authorized CDP and continues during human lock")
    assert "stale" in tool(binding, "input", {"action": "text", "text": "BAD", "frameId": prelock_frame["frameId"]}, succeeds=False).lower()
    frame = tool(binding, "capture")
    tool(binding, "input", {"action": "text", "text": "lock-test", "frameId": frame["frameId"]})
    wait(lambda: (BASE / "continuing.txt").read_text() == "sharedlock-test")
    subprocess.run(["grim", "-o", "human", str(BASE / "human-lock.png")], env=ENV, check=True)
    (BASE / "agent-locked.png").write_bytes(base64.b64decode(tool(binding, "capture")["pngBase64"]))
    launched = tool(binding, "launch", {"argv": ["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"), "locked-launch-window", str(BASE / "locked-launch.txt")]})
    started_client = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "locked-launch-window"), None))
    OWNED_PIDS.append(started_client["pid"]); os.kill(started_client["pid"], signal.SIGTERM)
    wait(lambda: not any(c["title"] == "locked-launch-window" for c in ctl("clients", True)))
    tool(binding, "focus", {"windowId": target})
    record("real native human lock secure; continue seat inputs/captures/launch; default seat paused; prelock frame rejected")
    # The same WS may remain owned by the physical output while an agent uses it.
    tool(binding, "workspace", {"workspace": "1"})
    shared_window = next(w["id"] for w in tool(binding, "windows")["windows"] if w["title"] == "human-window")
    tool(binding, "focus", {"windowId": shared_window})
    frame = tool(binding, "capture")
    tool(binding, "input", {"action": "text", "text": "shared-human", "frameId": frame["frameId"]})
    wait(lambda: (BASE / "human.txt").read_text() == "shared-human")
    last_clock = None
    for index in range(8):
        shot = BASE / ("human-continuous-" + str(index) + ".png")
        subprocess.run(["grim", "-o", "human", str(shot)], env=ENV, check=True)
        try: displayed_clock(shot)
        except AssertionError: pass
        else: raise AssertionError("ordinary app clock leaked onto a protected locked output")
        agent_shot = BASE / ("shared-human-agent-" + str(index) + ".png")
        agent_shot.write_bytes(base64.b64decode(tool(binding, "capture")["pngBase64"]))
        clock = displayed_clock(agent_shot)
        if last_clock is not None: assert clock != last_clock
        last_clock = clock
        time.sleep(.06)
    cli("capture", "continuing", BASE / "forbidden.png", succeeds=False)
    assert not (BASE / "forbidden.png").exists()
    # Human DPMS only affects public outputs; private output remains running.
    subprocess.run([str(PRODUCT / "bin/cornice-compositor"), "dpms", "off"], env=ENV, check=True)
    assert next(m for m in ctl("monitors", True) if m["name"] == "human")["dpmsStatus"] is False
    private_names = set(ctl("seat private-outputs", True))
    assert all(m["dpmsStatus"] for m in ctl("monitors", True) if m["name"] in private_names)
    off_frame = tool(binding, "capture")
    tool(binding, "input", {"action": "text", "text": "-off", "frameId": off_frame["frameId"]})
    wait(lambda: (BASE / "human.txt").read_text() == "shared-human-off")
    subprocess.run([str(PRODUCT / "bin/cornice-compositor"), "dpms", "on"], env=ENV, check=True)
    wait(lambda: ctl("seat lock-state", True)["secure"])
    # Unknown new outputs must be protected, and a mode change advances epoch.
    old_epoch = ctl("seat lock-state", True)["lockEpoch"]
    ok("output create headless unknown")
    ok('eval hl.monitor({output="unknown",mode="1024x768",position="auto",scale=1})')
    wait(lambda: any(o["name"] == "unknown" and o["covered"] for o in ctl("seat lock-state", True)["protectedOutputs"]))
    assert ctl("seat lock-state", True)["lockEpoch"] > old_epoch
    ok('eval hl.monitor({output="unknown",mode="1280x800",position="auto",scale=1})')
    wait(lambda: ctl("seat lock-state", True)["secure"])
    ok("output remove unknown")
    wait(lambda: ctl("seat lock-state", True)["secure"])
    tool(binding, "workspace", {"workspace": "10"}); tool(binding, "focus", {"windowId": target})
    record("agent operates human WS under lock; continuous physical frames hide apps; raw export denied; DPMS and unknown-output hotplug stay protected")
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"), ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(BASE / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    subprocess.run(["cc", "-I" + str(BASE), str(FORK / "hyprtester/multiseat/input.c"), str(BASE / "virtual-keyboard.c"), str(BASE / "virtual-pointer.c"), "-o", str(BASE / "human-input"), *flags], check=True)
    human = subprocess.Popen([str(BASE / "human-input"), "Hyprland", "human"], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / "human-input.log", "w"), start_new_session=True, text=True)
    PROCESSES.append(human)
    assert select.select([human.stdout], [], [], 5)[0] and human.stdout.readline().strip() == "ready"
    # No physical keyboard exists in the sandbox. Verify hotplug restored lock
    # focus, then wait for the lock client to bind its new wl_keyboard before
    # injecting input; an injector roundtrip alone cannot synchronize clients.
    wait(lambda: any('wl_keyboard#' in line and '.enter(' in line for line in (BASE / 'lock.log').read_text().splitlines()))
    provider_secure(locker, "lock-events")
    for command in ("motion 640 400", "type secret", "key 28 1", "key 28 0"):
        human.stdin.write(command + "\n"); human.stdin.flush()
        assert select.select([human.stdout], [], [], 5)[0] and human.stdout.readline().strip() == "done"
    wait(lambda: not ctl("seat lock-state", True)["locked"])
    locker.wait(timeout=5); assert locker.returncode == 0
    assert cli("state", "pausing")["paused"]
    record("real lock field accepts primary keyboard and PAM authentication unlocks; paused seat stays paused")
    cli("resume", "pausing")
    first = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--pam-service", "permit", "--pam-directory", str(pam)], env=ENV,
        stdin=subprocess.PIPE, stdout=open(BASE / "upgrade-human-events", "w"), stderr=open(BASE / "upgrade-human.log", "w"), start_new_session=True)
    PROCESSES.append(first); wait(lambda: ctl("seat lock-state", True)["secure"])
    full = secondary_process([str(PRODUCT / "bin/cornice-human-lock"), "--scope", "session", "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"],
        "full-events", "full.log")
    wait(lambda: ctl("seat lock-state", True)["scope"] == "session" and ctl("seat lock-state", True)["secure"])
    provider_secure(full, "full-events")
    provider_output_coverage(full, "full-events", "full.log", "session")
    first.wait(timeout=5); assert first.returncode == 0
    assert all(cli("state", name)["paused"] for name in ("continuing", "continuing2", "pausing"))
    assert "revoked" in tool(binding, "capture", succeeds=False).lower()
    try:
        cdp.call("Browser.getVersion")
        raise AssertionError("CDP command survived full lock")
    except (ConnectionError, OSError): pass
    try:
        urllib.request.urlopen(browser["cdpUrl"] + "/json/version", timeout=3)
        raise AssertionError("CDP discovery survived full lock")
    except urllib.error.HTTPError as error: assert error.code == 403
    cdp.close()
    record("full lock closes CDP and refuses old endpoint credentials")
    # Its real browser/credential checks are complete. Reap this private app
    # before unrelated guardian/UI checks, retaining the shared TasksMax budget.
    os.kill(browser_pid, signal.SIGTERM)
    wait(lambda: not any(client["pid"] == browser_pid for client in ctl("clients", True)))
    subprocess.run(["grim", "-o", "human", str(BASE / "full-lock.png")], env=ENV, check=True)
    unlock_provider(full, "full-events")
    assert all(cli("state", name)["paused"] for name in ("continuing", "continuing2", "pausing"))
    record("human-to-full upgrade is secure and revokes every seat; unlock never restores agents")
    # Failed PAM cannot unlock, and a provider crash retains protection.
    # Exercise the upstream restore policy explicitly in this private instance;
    # changing the production default would hide a real compositor boundary.
    ok('eval hl.config({misc={allow_session_lock_restore=false}})')
    cli("resume", "continuing")
    orphan_binding = bind("continuing")
    tool(orphan_binding, "focus", {"windowId": target})
    (pam / "deny").write_text("auth required pam_deny.so\naccount required pam_permit.so\n")
    deny = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--pam-service", "deny", "--pam-directory", str(pam)], env=ENV | {"WAYLAND_DEBUG": "client"},
        stdin=subprocess.PIPE, stdout=open(BASE / "deny-events", "w"), stderr=open(BASE / "deny.log", "w"), start_new_session=True)
    PROCESSES.append(deny); wait(lambda: ctl("seat lock-state", True)["secure"])
    wait(lambda: any('wl_keyboard#' in line and '.enter(' in line for line in (BASE / 'deny.log').read_text().splitlines()))
    for command in ("type wrong", "key 28 1", "key 28 0"):
        human.stdin.write(command + "\n"); human.stdin.flush()
        assert select.select([human.stdout], [], [], 5)[0] and human.stdout.readline().strip() == "done"
    wait(lambda: 'authentication-failed' in (BASE / "deny-events").read_text())
    assert ctl("seat lock-state", True)["secure"]
    orphan_frame = tool(orphan_binding, "capture")
    agent_before_loss = (BASE / "continuing.txt").read_text()
    human_before_loss = (BASE / "human.txt").read_text()
    os.kill(deny.pid, signal.SIGKILL); deny.wait()
    wait(lambda: ctl("seat lock-state", True)["phase"] == "orphaned")
    orphaned = ctl("seat lock-state", True)
    # secure describes compositor coverage, including a retained failsafe;
    # orphan ownership and input revocation are the invariants after a crash.
    assert orphaned["locked"] and orphaned["scope"] == "session" and orphaned["phase"] == "orphaned" and not orphaned["ownerConnected"], orphaned
    assert cli("state", "continuing")["paused"]
    tool(orphan_binding, "input", {"action": "text", "text": "ORPHANED", "frameId": orphan_frame["frameId"]}, succeeds=False)
    human.stdin.write("type ORPHANED\n"); human.stdin.flush()
    assert select.select([human.stdout], [], [], 5)[0] and human.stdout.readline().strip() == "done"
    time.sleep(.1)
    assert (BASE / "continuing.txt").read_text() == agent_before_loss
    assert (BASE / "human.txt").read_text() == human_before_loss
    refused = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--scope", "session", "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"], env=ENV | {"WAYLAND_DEBUG": "client"},
        stdin=subprocess.PIPE, stdout=open(BASE / "restore-refused-events", "w"), stderr=open(BASE / "restore-refused.log", "w"), start_new_session=True, text=True)
    PROCESSES.append(refused)
    refused.wait(timeout=5)
    assert refused.returncode == 0, refused.returncode
    refused_events = [json.loads(line) for line in (BASE / "restore-refused-events").read_text().splitlines()]
    assert any(event["event"] == "finished" for event in refused_events), refused_events
    assert not any(event.get("secure") is True for event in refused_events), refused_events
    orphaned = ctl("seat lock-state", True)
    assert orphaned["locked"] and orphaned["scope"] == "session" and orphaned["phase"] == "orphaned" and not orphaned["ownerConnected"], orphaned
    assert all(cli("state", name)["paused"] for name in ("continuing", "continuing2", "pausing"))
    record("upstream restore disabled refuses a new native owner; orphaned full protection blocks primary and agent input")
    ok('eval hl.config({misc={allow_session_lock_restore=true}})')
    recovery = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--scope", "session", "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"], env=ENV,
        stdin=subprocess.PIPE, stdout=open(BASE / "recovery-events", "w"), stderr=open(BASE / "recovery.log", "w"), start_new_session=True, text=True)
    PROCESSES.append(recovery); wait(lambda: ctl("seat lock-state", True)["secure"] and ctl("seat lock-state", True)["ownerConnected"])
    unlock_provider(recovery, "recovery-events")
    record("real PAM failure keeps secure lock; enabling upstream restore allows a new native owner to recover")

    # Use a private SYSTEM bus: fake logind performs no physical sleep, but the
    # helper passes real UNIX inhibitor FDs and checks the actual compositor.
    system_bus = subprocess.check_output(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"], env=ENV, text=True).splitlines()
    OWNED_BUS_PIDS.append(int(system_bus[1]))
    guard_env = ENV | {"DBUS_SYSTEM_BUS_ADDRESS": system_bus[0]}
    fixture = subprocess.Popen(["/usr/bin/python3", str(ROOT / "test/logind-fixture.py"), system_bus[0], str(BASE / "logind-events")],
        env=guard_env, stdin=subprocess.PIPE, stdout=open(BASE / "logind-fixture.log", "w"), stderr=subprocess.STDOUT, start_new_session=True, text=True)
    PROCESSES.append(fixture)
    def events(): return [json.loads(line) for line in (BASE / "logind-events").read_text().splitlines()]
    wait(lambda: any(e["event"] == "ready" for e in events()))
    def new_guard(name):
        process = secondary_process([str(PRODUCT / "bin/cornice-session-guard")], name + "-events", name + ".log", guard_env)
        wait(lambda: 'inhibitor-ready' in (BASE / (name + "-events")).read_text())
        # The real guardian must bind the management-only protocol even when
        # launched by a secondary app with its existing Wayland FD inherited.
        wait(lambda: re.search(r'hyprland_lock_scope_manager_v1[#@]\d+\.get_guard\(new id hyprland_lock_guard_v1[#@]\d+\)', (BASE / (name + ".log")).read_text()))
        return process
    guard = new_guard("guardian")
    cli("resume", "continuing")
    lost = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--pam-service", "permit", "--pam-directory", str(pam)], env=ENV,
        stdin=subprocess.PIPE, stdout=open(BASE / "guardian-lock-events", "w"), stderr=open(BASE / "guardian-lock.log", "w"), start_new_session=True)
    PROCESSES.append(lost); wait(lambda: ctl("seat lock-state", True)["secure"])
    provider_secure(lost, "guardian-lock-events")
    assert not cli("state", "continuing")["paused"]
    os.kill(guard.pid, signal.SIGKILL); guard.wait()
    wait(lambda: ctl("seat lock-state", True)["scope"] == "session" and ctl("seat lock-state", True)["secure"])
    assert cli("state", "continuing")["paused"] and ctl("seat lock-state", True)["phase"] == "orphaned"
    lost.wait(timeout=5); assert lost.returncode == 0
    record("guardian death atomically escalates to an orphaned full lock and revokes agent control")
    recovered = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--scope", "session", "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"], env=ENV,
        stdin=subprocess.PIPE, stdout=open(BASE / "guardian-recovery-events", "w"), stderr=open(BASE / "guardian-recovery.log", "w"), start_new_session=True, text=True)
    PROCESSES.append(recovered); wait(lambda: ctl("seat lock-state", True)["ownerConnected"] and ctl("seat lock-state", True)["secure"])
    unlock_provider(recovered, "guardian-recovery-events")
    guard = new_guard("sleep-guard")
    guard.stdin.write("suspend\n"); guard.stdin.flush()
    wait(lambda: 'full-lock-required' in (BASE / "sleep-guard-events").read_text())
    time.sleep(.3); assert not any(e["event"] == "suspend" for e in events())
    sleep_lock = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--scope", "session", "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"], env=ENV,
        stdin=subprocess.PIPE, stdout=open(BASE / "sleep-lock-events", "w"), stderr=open(BASE / "sleep-lock.log", "w"), start_new_session=True, text=True)
    PROCESSES.append(sleep_lock)
    wait(lambda: any(e["event"] == "suspend" for e in events()))
    actual = next(e for e in events() if e["event"] == "suspend")["state"]
    assert actual["scope"] == "session" and actual["secure"]
    wait(lambda: 'sleep-lock-secure' in (BASE / "sleep-guard-events").read_text())
    wait(lambda: len([e for e in events() if e["event"] == "released" and e["mode"] == "delay"]) >= 2)
    fixture.stdin.write('{"event":"resume"}\n'); fixture.stdin.flush()
    wait(lambda: 'resumed' in (BASE / "sleep-guard-events").read_text())
    assert ctl("seat lock-state", True)["locked"] and cli("state", "continuing")["paused"]
    unlock_provider(sleep_lock, "sleep-lock-events")
    # Lid policy shares the same gate; verify event handling without suspending.
    fixture.stdin.write('{"LidClosed":true}\n'); fixture.stdin.flush()
    wait(lambda: (BASE / "sleep-guard-events").read_text().count('full-lock-required') >= 2)
    assert len([e for e in events() if e["event"] == "suspend"]) == 1
    record("real inhibitor FDs delay fake logind until presented full lock; resume stays locked/paused; lid requests full lock")
    os.killpg(guard.pid, signal.SIGTERM); guard.wait()
    # Exercise the actual Cornice service, observer and suspend command. The
    # only system bus here is the owned fixture above; never the host logind.
    fixture.stdin.write('{"LidClosed":false}\n'); fixture.stdin.flush()
    config_dir = BASE / "config/cornice"; config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "config.json").write_text(json.dumps({
        "agentDesktop": {"enabled": True}, "language": "zh-CN", "background": {"dir": str(PRODUCT / "wallpapers")},
        "bar": {"layout": {"left": [{"id": "cn.agent-desktop"}], "center": [], "right": []}},
        "weather": {"intervalMinutes": 0},
        "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0, "dimAc": 0, "dimBattery": 0, "lockScreenOff": 0,
                 "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False},
        "lock": {"pamService": "permit", "pamDirectory": str(pam), "emergencyUnlock": True, "showUser": False}}))
    assert RT.is_relative_to(BASE) and guard_env['DBUS_SYSTEM_BUS_ADDRESS'] == system_bus[0]
    ui_env = guard_env | {"CORNICE_ISOLATED_TEST": "0"}
    cornice_ui = start([str(PRODUCT / "bin/cornice-qs"), "-p", str(PRODUCT / "shell")], "cornice-shell", ui_env)
    wait(lambda: json.loads(shell("ipc", "lock", "status"))["humanLockAvailable"])
    wait(lambda: json.loads(shell("ipc", "idle", "status"))["sleepGuardReady"])
    cli("resume", "continuing"); fresh = bind("continuing")
    shell("desktop", "observe", "continuing")
    wait(lambda: json.loads(shell("ipc", "desktopObserver", "status"))["presentation"].get("active"))
    assert not list((RT / "cornice" / ENV["HYPRLAND_INSTANCE_SIGNATURE"]).glob("frame-*"))
    # Match the physical laptop's mode, entirely inside the isolated compositor.
    ok('eval hl.monitor({output="human",mode="3072x1920",position="0x0",scale=2})')
    wait(lambda: next(m for m in ctl("monitors", True) if m["name"] == "human")["scale"] == 2)
    shell("lock")
    wait(lambda: ctl("seat lock-state", True)["scope"] == "scoped" and ctl("seat lock-state", True)["secure"])
    assert not cli("state", "continuing")["paused"]
    wait(lambda: json.loads(shell("ipc", "desktopObserver", "status"))["presentation"].get("active") is not True)
    def visible_lock():
        shot = BASE / "cornice-native-lock.png"
        subprocess.run(["grim", "-o", "human", str(shot)], env=ENV, check=True)
        with Image.open(shot) as image:
            assert image.size == (3072, 1920), image.size
            # secure means coverage, which initially can be a black failsafe;
            # wait for actual presented Cornice content before accepting the UI.
            return min(high for low, high in image.convert("RGB").getextrema()) > 100
    wait(visible_lock)
    def native_owners():
        owners = []
        for proc in pathlib.Path('/proc').iterdir():
            if not proc.name.isdigit(): continue
            try:
                if str(pam).encode() in (proc / 'cmdline').read_bytes() and b'cornice-human-lock' in (proc / 'cmdline').read_bytes():
                    if ('XDG_RUNTIME_DIR=' + str(RT)).encode() in (proc / 'environ').read_bytes().split(b'\0'): owners.append(int(proc.name))
            except (FileNotFoundError, PermissionError, ProcessLookupError): pass
        return owners
    owners = wait(native_owners); assert len(owners) == 1, owners
    command = pathlib.Path('/proc', str(owners[0]), 'cmdline').read_bytes().split(b'\0')
    native_appearance = json.loads(command[command.index(b'--appearance') + 1])
    assert native_appearance['language'] == 'zh-CN'
    assert native_appearance['backgroundSource'].endswith('/default.png'), native_appearance
    assert native_appearance['fontSize'] == appearance['fontSize']
    assert native_appearance['labels']['password'] == json.loads((PRODUCT / 'i18n/zh-CN.json').read_text())['lock.password']
    # Save the real forwarded theme for review, and reject silent QML fallbacks.
    (BASE / 'native-appearance.json').write_text(json.dumps(native_appearance, ensure_ascii=False, indent=2))
    assert not any(error in (BASE / 'cornice-shell.log').read_text() for error in
                   ('ReferenceError:', 'TypeError:', 'is not a type', 'Cannot assign'))
    record("Cornice native lock reuses shared themed UI, real wallpaper and Chinese labels at laptop 2x scale")
    old_id = ctl("seat lock-state", True)["lockId"]
    os.kill(owners[0], signal.SIGKILL)
    wait(lambda: ctl("seat lock-state", True)["ownerConnected"] and ctl("seat lock-state", True)["lockId"] != old_id)
    wait(lambda: ctl("seat lock-state", True)["secure"])
    assert ctl("seat lock-state", True)["scope"] == "session"
    assert cli("state", "continuing")["paused"]
    tool(fresh, "capture", succeeds=False)
    record("scope owner loss escalates to a full lock, revokes continuing seats, and automatically restores native authentication")
    shell("suspend")
    wait(lambda: len([e for e in events() if e["event"] == "suspend"]) == 2)
    wait(lambda: json.loads(shell("ipc", "lock", "status"))["scope"] == "session" and json.loads(shell("ipc", "lock", "status"))["secure"])
    assert cli("state", "continuing")["paused"]
    assert all(e["state"]["scope"] == "session" and e["state"]["secure"] for e in events() if e["event"] == "suspend")
    fixture.stdin.write('{"event":"resume"}\n'); fixture.stdin.flush()
    wait(lambda: json.loads(shell("ipc", "idle", "status"))["sleepGuardReady"])
    shell("lock", "emergency-unlock"); wait(lambda: not ctl("seat lock-state", True)["locked"])
    assert cli("state", "continuing")["paused"]
    record("actual cornice suspend upgrades human to full lock before fake logind, then resumes locked with all agents paused")
    shell("lock"); wait(lambda: ctl("seat lock-state", True)["secure"])
    os.killpg(cornice_ui.pid, signal.SIGKILL); cornice_ui.wait()
    wait(lambda: ctl("seat lock-state", True)["scope"] == "session" and not ctl("seat lock-state", True)["ownerConnected"])
    restarted_ui = start([str(PRODUCT / "bin/cornice-qs"), "-p", str(PRODUCT / "shell")], "cornice-restarted", ui_env)
    wait(lambda: ctl("seat lock-state", True)["ownerConnected"] and ctl("seat lock-state", True)["secure"])
    assert ctl("seat lock-state", True)["scope"] == "session" and cli("state", "continuing")["paused"]
    shell("lock", "emergency-unlock"); wait(lambda: not ctl("seat lock-state", True)["locked"])
    record("forced Cornice UI/guard death retains full lock; restarting restores authentication without restoring agent control")
    # The high-resolution native appearance proof is complete. Release its
    # extra private render buffers before the independent output-loss scenario,
    # keeping the unchanged 3 GiB test budget instead of raising resource caps.
    ok('eval hl.monitor({output="human",mode="1280x800",position="0x0",scale=1})')
    wait(lambda: next(m for m in ctl("monitors", True) if m["name"] == "human")["scale"] == 1)
    # Removing the seat's original output must retire it even while it views
    # the human workspace. It cannot fall back to human input or move that view.
    cli("create", "lost-output", "--workspace", "40", "--virtual-output", "640x480")
    cli("resume", "lost-output"); lost = bind("lost-output")
    home = cli("state", "lost-output")["output"]
    tool(lost, "workspace", {"workspace": "1"}); tool(lost, "capture")
    before_loss = human_state()
    ok("output remove " + home)
    wait(lambda: ctl("seat state lost-output") == "seat not found")
    assert "seat not found" in cli("state", "lost-output", succeeds=False)
    tool(lost, "capture", succeeds=False)
    after_loss = human_state()
    assert after_loss == before_loss, {"before": before_loss, "after": after_loss}
    record("private home output loss revokes a seat viewing human WS without primary fallback")
    os.killpg(fixture.pid, signal.SIGTERM); fixture.wait()
    os.kill(int(system_bus[1]), signal.SIGTERM)
    print("Artifacts:", BASE, flush=True)
finally:
    cleanup()
