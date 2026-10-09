"""Exercise real one-shot login, health failures and logout without host access."""
from desktop_harness import *

assert os.environ.get("CORNICE_TEST_SANDBOX") == "1"
TRIAL = ROOT / "bin/cornice-session-trial"
TEST_ENV = None


def trial(*args, succeeds=True):
    result = subprocess.run([str(TRIAL), *map(str, args)], env=TEST_ENV, text=True,
                            capture_output=True, timeout=40)
    assert (result.returncode == 0) == succeeds, (args, result.stdout, result.stderr)
    return result.stdout


def status():
    return json.loads(trial("status"))


def login_session():
    # The real zsh login hook must recognize the SDDM-shaped argv. No executable
    # on the host or fake readiness endpoint is used by the trial itself.
    process = start(["/usr/bin/zsh", "--login", str(SDDM), "/usr/bin/start-hyprland"],
                    "login-" + str(time.monotonic_ns()), TEST_ENV)
    return process


def ready(process):
    def probe():
        current = status().get("current")
        if process.poll() is not None:
            raise AssertionError("Login ended before ready: " + str(current))
        return current if current and current["status"] == "ready" else None
    return wait(probe, 35)


def ended(process, reason=None):
    process.wait(timeout=25)
    assert process.returncode == 0
    result = status()
    assert not result["armed"] and not result["running"]
    assert result["current"]["stableSelected"]
    if reason:
        assert reason in result["current"]["reason"], result
    assert human_state() == BASELINE
    assert SENTINEL.poll() is None
    return result["current"]


try:
    SENTINEL = initialize(xwayland=True)
    BASELINE = human_state()
    TEST_ENV = ENV.copy()
    TEST_ENV.pop("HYPRLAND_INSTANCE_SIGNATURE")
    TEST_ENV.pop("DISPLAY", None)
    TEST_ENV["WAYLAND_DISPLAY"] = "parent"
    TEST_ENV["XDG_STATE_HOME"] = str(BASE / "trial-state")
    TEST_ENV["ZDOTDIR"] = str(BASE / "zsh")
    profile = pathlib.Path(TEST_ENV["ZDOTDIR"]) / ".zprofile"
    profile.parent.mkdir()
    original = '# User profile is preserved\nexport CORNICE_TEST_PROFILE="original"\n'
    profile.write_text(original)
    settings = BASE / "config/cornice/config.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({"agentDesktop": {"enabled": False}, "bar": {"layout": {"left": [], "right": ["cn.agent-desktop", {"id": "cn.agent-desktop"}]}}, "weather": {"intervalMinutes": 0},
        "background": {"enabled": False}, "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0,
        "dimAc": 0, "dimBattery": 0, "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False}}))
    configuration = BASE / "trial.lua"
    configuration.write_text('''hl.monitor({output="",mode="1280x800",position="auto",scale=1})
hl.config({animations={enabled=false},xwayland={enabled=true},misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0}})
hl.on("hyprland.start", function() hl.exec_cmd("/usr/bin/hyprctl output create headless trial") end)
hl.env("QT_IM_MODULE", "fcitx")
hl.env("GTK_IM_MODULE", "fcitx")
hl.env("CORNICE_TRIAL_ENV_PROBE", "from-lua")
hl.define_submap("trial-test", function() hl.bind("escape", hl.dsp.submap("reset"), {}) end)
hl.bind("SUPER + h", hl.dsp.exec_cmd("~/.config/hypr/scripts/layoutmsg-active.sh mfact -0.025"), {})
hl.bind("SUPER + l", hl.dsp.exec_cmd("~/.config/hypr/scripts/layoutmsg-active.sh mfact +0.025"), {})
hl.bind("SUPER + i", hl.dsp.exec_cmd("~/.config/hypr/scripts/layoutmsg-active.sh addmaster"), {})
hl.bind("SUPER + d", hl.dsp.exec_cmd("~/.config/hypr/scripts/layoutmsg-active.sh removemaster"), {})
hl.bind("SUPER + CTRL + h", hl.dsp.exec_cmd("~/.config/hypr/scripts/layoutmsg-active.sh splitratio -0.025"), {})
hl.bind("SUPER + CTRL + l", hl.dsp.exec_cmd("~/.config/hypr/scripts/layoutmsg-active.sh splitratio +0.025"), {})
hl.bind("SUPER + ALT + h", hl.dsp.exec_cmd("~/.config/hypr/scripts/layoutmsg-active.sh mfact -0.025; true"), {})
hl.bind("SUPER + ALT + l", hl.dsp.exec_cmd("~/.config/hypr/scripts/unrelated.sh mfact +0.025"), {})
''')
    absolute_helper = str(pathlib.Path(ENV["HOME"]) / ".config/hypr/scripts/layoutmsg-active.sh")
    with configuration.open("a") as stream:
        stream.write('hl.bind("SUPER + ALT + i", hl.dsp.exec_cmd(' + json.dumps(absolute_helper + ' mfact exact 0.55') + '), {})\n')
    original_configuration = configuration.read_text()
    SDDM = BASE / "wayland-session"
    sentinel_path = BASE / "normal-login"
    SDDM.write_text('print -r -- "normal stable entry" > ' + shlex.quote(str(sentinel_path)) + '\n')
    chrome_flags = BASE / "config/chrome-flags.conf"
    chrome_flags.write_text("# Stable Xwayland flags\n--force-device-scale-factor=2\n--force-renderer-accessibility=complete\n")
    original_chrome_flags = chrome_flags.read_text()
    classic = BASE / "config/fcitx5/conf/classicui.conf"
    classic.parent.mkdir(parents=True, exist_ok=True)
    classic.write_text('Font="Sans 24"\nVertical Candidate List=False\n')
    original_classic = classic.read_text()
    original_settings = settings.read_bytes()
    prepared = json.loads(trial("prepare", "--hyprland", os.environ["CORNICE_TEST_HYPRLAND"],
                                "--cornice", PRODUCT, "--config", configuration))
    release = pathlib.Path(prepared["prepared"])
    assert not status()["armed"] and settings.read_bytes() == original_settings
    trial_configuration = (release / "hyprland.lua").read_text()
    for message in ("mfact -0.025", "mfact +0.025", "addmaster", "removemaster", "splitratio -0.025", "splitratio +0.025", "mfact exact 0.55"):
        assert 'hl.dsp.layout(' + json.dumps(message) + ')' in trial_configuration, message
    for command in ("~/.config/hypr/scripts/layoutmsg-active.sh mfact -0.025; true", "~/.config/hypr/scripts/unrelated.sh mfact +0.025"):
        assert 'hl.dsp.exec_cmd(' + json.dumps(command) + ')' in trial_configuration, command
    assert configuration.read_text() == original_configuration
    record("prepare converts literal master/dwindle layout shortcuts to native seat-aware Lua without changing source or unrelated shell commands")
    layout = json.loads((release / "config-home/cornice/config.json").read_text())["bar"]["layout"]
    assert layout["left"] == [] and layout["right"] == ["cn.agent-desktop"], layout
    record("prepare preserves an existing right-side Agent control and removes duplicate copies")
    trial_classic = release / "config-home/fcitx5/conf/classicui.conf"
    assert not (release / "config-home/fcitx5").is_symlink()
    assert 'Font="Sans 12"' in trial_classic.read_text()
    assert classic.read_text() == original_classic
    trial_flags = release / "config-home/chrome-flags.conf"
    assert not trial_flags.is_symlink() and "force-device-scale-factor" not in trial_flags.read_text()
    assert "--ozone-platform=wayland" in trial_flags.read_text()
    assert "--force-renderer-accessibility=complete" in trial_flags.read_text()
    assert chrome_flags.read_text() == original_chrome_flags
    assert profile.read_text() == original
    record("prepare snapshots real candidate without arming, modifying config or touching the existing compositor")
    trial("arm", "--seconds", "5", "--startup-seconds", "30")
    assert profile.read_text().startswith(original)
    trial("cancel")
    process = login_session(); process.wait(timeout=5)
    assert sentinel_path.read_text().strip() == "normal stable entry"
    record("cancelled/unarmed SDDM-shaped login falls through to its original entry; user profile retained")
    # Shells in TTY/terminals must not consume a ticket.
    trial("arm", "--seconds", "30", "--startup-seconds", "30")
    result = subprocess.run(["/usr/bin/zsh", "--login", "-c", "true"], env=TEST_ENV)
    assert result.returncode == 0 and status()["armed"]
    record("ordinary login shells cannot consume the one-shot ticket")
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"), ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(BASE / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    subprocess.run(["cc", "-I" + str(BASE), str(FORK / "hyprtester/multiseat/input.c"), str(BASE / "virtual-keyboard.c"),
                    str(BASE / "virtual-pointer.c"), "-o", str(BASE / "human-input"), *flags], check=True)
    process = login_session(); info = ready(process)
    assert not status()["armed"]
    compositor_environment = pathlib.Path('/proc/' + str(info["compositorPid"]) + '/environ').read_bytes().split(b'\0')
    assert b'HYPRLAND_NO_SD_VARS=1' in compositor_environment and b'HYPRLAND_NO_SD_TARGET=1' in compositor_environment
    shell_environment = pathlib.Path('/proc/' + str(info["shellPid"]) + '/environ').read_bytes().split(b'\0')
    assert b'QT_IM_MODULE=fcitx' in shell_environment and b'GTK_IM_MODULE=fcitx' in shell_environment
    assert b'CORNICE_TRIAL_ENV_PROBE=from-lua' in shell_environment
    assert not pathlib.Path(info['run'], 'launch-environment').exists()
    record("supervised Cornice inherits actual Lua IME and application environment; temporary export is removed")
    selected = TEST_ENV | {"HYPRLAND_INSTANCE_SIGNATURE": info["instance"], "WAYLAND_DISPLAY": info["display"]}
    cli_path = release / "cornice/bin/cornice"
    desktops = json.loads(subprocess.check_output([str(cli_path), "desktop", "list"],
        env=selected | {"CORNICE_PATH": str(release / "cornice")}, text=True))["desktops"]
    assert len(desktops) == 4 and desktops[0]["primary"] and desktops[0]["agentAllowed"] is False, desktops
    assert all(d["humanLockPolicy"] == "continue" and d["paused"] for d in desktops if not d["primary"]), desktops
    (BASE / "trial-initial-desktops.json").write_text(json.dumps(desktops, indent=2))
    record("three real deployment seats explicitly allow human-lock continuation but remain initially paused without input grants")
    # Both the human shell and all private shells share this right-side layout.
    socket_prefix = __import__('hashlib').sha256(info["instance"].encode()).hexdigest()[:8]
    for name in ("", "agent1", "agent2", "agent3"):
        socket_name = f"cs-{socket_prefix}-{name}.sock" if name else f"cornice-{os.environ['USER']}.sock"
        target_env = selected | {"CORNICE_PATH": str(release / "cornice"), "CORNICE_SHELL_SOCKET": str(RT / socket_name)}
        geometry = json.loads(subprocess.check_output([str(cli_path), "ipc", "bar", "geometry"], env=target_env, text=True))
        controls = [entry for entry in geometry if entry["id"] == "cn.agent-desktop"]
        assert len(controls) == 1 and controls[0]["section"] == "right", (name, controls)
    record("human and all Agent bars render exactly one configured right-side switch/status control")
    subprocess.run(["grim", str(BASE / "trial-desktop.png")], env=selected, check=True, timeout=5)
    # Inspect actual registered emergency bindings, not just generated config text.
    bindings = json.loads(subprocess.check_output(["/usr/bin/hyprctl", "-j", "binds"], env=selected, text=True))
    (BASE / "trial-bindings.json").write_text(json.dumps(bindings, indent=2))
    assert {b["key"] for b in bindings if b["modmask"] == 76} >= {"BackSpace", "Return"}, bindings
    assert all(b["submap_universal"] for b in bindings if b["modmask"] == 76)
    assert next(b for b in bindings if b["key"] == "BackSpace")["locked"]
    subprocess.run(["/usr/bin/hyprctl", "dispatch", 'hl.dsp.submap("trial-test")'], env=selected, check=True, stdout=subprocess.DEVNULL)
    keyboard = subprocess.Popen([str(BASE / "human-input"), "Hyprland", "trial"], env=selected,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / "trial-input.log", "w"),
                                text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == "ready"
    for event in ("mods 76", "key 28 1", "key 28 0", "mods 0"):
        keyboard.stdin.write(event + "\n"); keyboard.stdin.flush()
        assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == "done"
    wait(lambda: status()["current"]["status"] == "confirmed")
    trial("arm", succeeds=False)
    trial("arm", "--after-current", succeeds=False)
    trial("prepare", "--hyprland", os.environ["CORNICE_TEST_HYPRLAND"], "--cornice", PRODUCT, "--config", configuration)
    trial("arm", "--after-current")
    assert status()["armed"] and status()["running"] and process.poll() is None
    trial("cancel")
    assert not status()["armed"] and status()["running"]
    record("explicit rearm selects only a different future candidate; current trial survives; cancel restores stable next login")
    for event in ("mods 76", "key 14 1"):
        keyboard.stdin.write(event + "\n"); keyboard.stdin.flush()
        assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == "done"
    ended(process, "Manual rollback")
    assert settings.read_bytes() == original_settings
    record("real Hyprland/Cornice/three seats become ready; emergency bindings exist; confirm and rollback end only the trial")
    process = login_session(); process.wait(timeout=5)
    assert process.returncode == 0 and sentinel_path.exists() and not status()["armed"]
    record("after rollback, the next SDDM login uses the unchanged normal entry without a loop")
    trial("arm", "--seconds", "5", "--startup-seconds", "30")
    process = login_session(); ready(process)
    assert status()["current"]["confirmationRequired"] is False
    # The obsolete five-second option must not reintroduce a deadline. Continue
    # exercising the actual compositor after that former deadline has elapsed.
    until = time.monotonic() + 8
    while time.monotonic() < until:
        current = status()
        assert current["running"] and current["current"]["status"] == "ready", current
        assert current["current"]["healthFailures"] == 0, current
        assert human_state() == BASELINE and SENTINEL.poll() is None
        time.sleep(.5)
    trial("rollback"); ended(process, "Manual rollback")
    record("healthy unconfirmed desktop stays running beyond obsolete --seconds deadline; manual rollback remains available")
    trial("arm", "--seconds", "60", "--startup-seconds", "30")
    process = login_session(); info = ready(process)
    # One transient failure must be visible and recover without logging out.
    os.kill(info["shellPid"], signal.SIGSTOP)
    try:
        wait(lambda: status()["current"].get("healthFailures") == 1, 10)
    finally:
        os.kill(info["shellPid"], signal.SIGCONT)
    wait(lambda: status()["current"].get("healthFailures") == 0, 10)
    assert status()["running"] and status()["current"]["status"] == "ready"
    record("transient Cornice unresponsiveness is reported then clears without logout")
    os.kill(info["shellPid"], signal.SIGKILL)
    ended(process, "health failed")
    record("Cornice crash without confirmation is detected and automatically logs out to stable selection")
    trial("arm", "--seconds", "60", "--startup-seconds", "30")
    process = login_session(); info = ready(process)
    os.kill(info["compositorPid"], signal.SIGSTOP)
    ended(process, "health failed")
    assert not pathlib.Path('/proc/' + str(info["compositorPid"])).exists()
    record("SIGSTOP compositor hang is detected externally and killed after bounded graceful shutdown")
    trial("arm", "--seconds", "60", "--startup-seconds", "30")
    process = login_session(); info = ready(process)
    os.kill(info["compositorPid"], signal.SIGKILL)
    ended(process, "Hyprland exited")
    record("compositor crash does not trigger a broken-version restart loop")
    trial("arm", "--seconds", "60", "--startup-seconds", "30")
    process = login_session(); info = ready(process)
    os.kill(process.pid, signal.SIGKILL)
    process.wait(timeout=5)
    wait(lambda: not pathlib.Path('/proc/' + str(info["compositorPid"])).exists() or
         pathlib.Path('/proc/' + str(info["compositorPid"]) + '/stat').read_text().split()[2] == 'Z')
    assert not status()["armed"] and human_state() == BASELINE
    process = login_session(); process.wait(timeout=5)
    assert process.returncode == 0
    record("supervisor SIGKILL kills its compositor; consumed ticket still selects stable on next login")
    # A damaged ticket must be consumed, even if JSON parsing itself fails.
    state = pathlib.Path(TEST_ENV["XDG_STATE_HOME"]) / "cornice/session-trial"
    (state / "pending.json").write_text('{broken')
    process = login_session(); process.wait(timeout=5)
    assert process.returncode == 0 and not status()["armed"]
    record("malformed ticket fails closed without leaving a repeatable bad login")
    latest_release = pathlib.Path(json.loads((pathlib.Path(TEST_ENV["XDG_STATE_HOME"]) / "cornice/session-trial/prepared.json").read_text())["release"])
    (latest_release / "hyprland.lua").write_text('error("damaged candidate")')
    trial("arm", succeeds=False)
    assert not status()["armed"]
    record("changed candidate cannot be armed; immutable manifest detects drift")
    if real_config := os.environ.get("CORNICE_TEST_SESSION_CONFIG"):
        configuration.write_text(pathlib.Path(real_config).read_text() + '\nhl.on("hyprland.start", function() hl.exec_cmd("/usr/bin/hyprctl output create headless trial") end)\n')
        trial("prepare", "--hyprland", os.environ["CORNICE_TEST_HYPRLAND"], "--cornice", PRODUCT, "--config", configuration)
        trial("arm", "--seconds", "60", "--startup-seconds", "30")
        process = login_session(); info = ready(process)
        selected = TEST_ENV | {"HYPRLAND_INSTANCE_SIGNATURE": info["instance"], "WAYLAND_DISPLAY": info["display"]}
        subprocess.run(["grim", str(BASE / "trial-native-config.png")], env=selected, check=True, timeout=5)
        trial("rollback"); ended(process, "Manual rollback")
        record("actual migrated daily Lua config starts the real candidate with bar and three Agent desktops")
    configuration.write_text('error("injected startup failure")\n')
    trial("prepare", "--hyprland", os.environ["CORNICE_TEST_HYPRLAND"], "--cornice", PRODUCT, "--config", configuration)
    trial("arm", "--seconds", "60", "--startup-seconds", "5")
    process = login_session()
    result = ended(process, "startup timeout")
    assert result["status"] == "rolled-back"
    record("bad Lua startup automatically logs out; new preparation updates the managed hook")
    with profile.open("a") as stream:
        stream.write('# Added by user after arming\n')
    trial("remove-hook")
    assert profile.read_text() == original + '# Added by user after arming\n'
    record("removing trial hook restores original profile while preserving later user edits")
finally:
    cleanup()
