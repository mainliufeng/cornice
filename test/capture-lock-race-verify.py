"""Keep a real screencopy pending across a lock epoch, without timing races."""
from desktop_harness import *

assert os.getenv("CORNICE_TEST_SANDBOX") == "1", "Run with isolated-desktop-test.sh"

try:
    initialize()
    sources = [(FORK / "protocols/wlr-screencopy-unstable-v1.xml", "screencopy"),
               (pathlib.Path("/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml"), "session-lock")]
    for source, name in sources:
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(source), str(BASE / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client"], text=True).split()
    subprocess.run(["cc", "-I" + str(BASE), str(ROOT / "test/capture-lock-race.c"),
                    str(BASE / "screencopy.c"), str(BASE / "session-lock.c"), "-o", str(BASE / "capture-lock-race"), *flags], check=True)
    log = BASE / "pending-capture.log"
    capture = start([str(BASE / "capture-lock-race")], "pending-capture", ENV | {"WAYLAND_DEBUG": "client"})
    wait(lambda: capture.poll() is not None, timeout=5)
    assert capture.returncode == 0, log.read_text()
    assert "failed received; destination untouched" in log.read_text()
    wait(lambda: ctl("seat lock-state", True)["phase"] == "orphaned")
    pam = BASE / "pam"; pam.mkdir()
    (pam / "permit").write_text("auth required pam_permit.so\naccount required pam_permit.so\n")
    locker = subprocess.Popen([str(PRODUCT / "bin/cornice-human-lock"), "--scope", "session",
                               "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"],
                              env=ENV, stdin=subprocess.PIPE, stdout=open(BASE / "lock-events.log", "w"),
                              stderr=open(BASE / "lock.log", "w"), start_new_session=True, text=True)
    PROCESSES.append(locker)
    # The orphaned fallback may itself be secure. Wait for the NEW provider's
    # presented lock surface, not that previous compositor-wide state.
    wait(lambda: any(json.loads(line).get("event") == "secure"
                     for line in (BASE / "lock-events.log").read_text().splitlines()))
    wait(lambda: ctl("seat lock-state", True)["secure"])
    subprocess.run(["grim", "-o", "human", str(BASE / "fresh-lock.png")], env=ENV, check=True, timeout=5)
    assert (BASE / "fresh-lock.png").stat().st_size > 0
    locker.stdin.write("emergency-unlock\n"); locker.stdin.flush()
    wait(lambda: not ctl("seat lock-state", True)["locked"])
    subprocess.run(["grim", "-o", "human", str(BASE / "fresh-unlocked.png")], env=ENV, check=True, timeout=5)
    record("pending pre-lock screencopy gets failed, not stale pixels or a hang; fresh locked and unlocked captures complete")
finally:
    cleanup()
