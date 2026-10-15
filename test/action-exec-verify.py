#!/usr/bin/python3
"""Own temporary IPC, real exec and denial barrier; no process inspection."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="action-exec-") as temporary:
    runtime = Path(temporary)
    instance = "test-instance"
    path = runtime / "hypr" / instance / ".socket.sock"
    path.parent.mkdir(parents=True)
    environment = os.environ | {"XDG_RUNTIME_DIR": str(runtime), "HYPRLAND_INSTANCE_SIGNATURE": instance,
                                 "XDG_ACTIVATION_TOKEN": "synthetic-action-token"}
    observed = []
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(path)); listener.listen(1); listener.settimeout(5)
        def answer(reply):
            connection, _ = listener.accept()
            with connection:
                observed.append(connection.recv(4096).decode())
                connection.sendall(reply)
        thread = threading.Thread(target=answer, args=(b"ok",)); thread.start()
        code = "import json,os;print(json.dumps({'pid':os.getpid(),'token':os.environ.get('XDG_ACTIVATION_TOKEN')}))"
        process = subprocess.Popen([str(ROOT / "bin/cornice-action-exec"), "--", "/usr/bin/python3", "-c", code],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        output, error = process.communicate(timeout=8); thread.join(5)
        value = json.loads(output)
        assert process.returncode == 0 and value == {"pid": process.pid, "token": "synthetic-action-token"}, (output, error)
        assert observed == [f"/seat route-client synthetic-action-token {process.pid}"], observed
        print("PASS exact action and own PID register before exec; PID and standard token survive exec")
        thread = threading.Thread(target=answer, args=(b"stale source",)); thread.start()
        result = subprocess.run([str(ROOT / "bin/cornice-action-exec"), "--", "/usr/bin/printf", "MUST-NOT-EXEC"],
                                env=environment, capture_output=True, text=True, timeout=8)
        thread.join(5)
        assert result.returncode == 1 and not result.stdout and "expired or unavailable" in result.stderr
        print("PASS stale source never starts target and returns a concrete error")
    path.unlink()
    result = subprocess.run([str(ROOT / "bin/cornice-action-exec"), "--", "/usr/bin/printf", "MUST-NOT-EXEC"],
                            env=environment, capture_output=True, text=True, timeout=8)
    assert result.returncode == 1 and not result.stdout
    print("PASS compositor loss has no unscoped fallback")
