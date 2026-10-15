#!/usr/bin/env python3
"""Native tray policy and exact menu destination on private buses, no desktop."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "native/platform-build/cornice-desktop-action-verify"
INTERLEAVING = ROOT / "native/platform-build/cornice-tray-interleaving-verify"
if not BINARY.is_file() or not INTERLEAVING.is_file():
    raise SystemExit("Build cornice-desktop-action-verify and cornice-tray-interleaving-verify from native/platform first")
with tempfile.TemporaryDirectory(prefix="cornice-tray-policy-") as directory:
    temporary = Path(directory)
    runtime = temporary / "runtime"
    runtime.mkdir(mode=0o700)
    # No inherited compositor sockets, app profiles, credentials or session bus.
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(temporary), "XDG_RUNTIME_DIR": str(runtime)}
    for command in ([str(BINARY)], [str(INTERLEAVING)], [str(INTERLEAVING), "--deferred"],
                    ["/usr/bin/python3", str(ROOT / "test/tray-exact-owner-verify.py")]):
        subprocess.run(["dbus-run-session", "--", *command], env=environment, check=True, timeout=35)
