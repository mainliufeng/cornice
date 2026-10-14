"""Check the actual runner boundary without starting any graphical process."""
import json
import os
from pathlib import Path
import stat

assert os.environ.get("CORNICE_TEST_SANDBOX") == "1"
for name in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
             "HYPRLAND_INSTANCE_SIGNATURE", "CORNICE_MCP_BINDING", "NODE_OPTIONS", "LD_PRELOAD"):
    assert name not in os.environ, name
assert not Path("/dev/dri").exists() and not Path("/dev/input").exists()
assert not Path("/run/user").exists()
assert Path("/home").exists() and Path("/root").exists()
assert not Path("/home/liufeng/.config").exists()
assert not Path("/home/liufeng/.codex").exists()
sentinel = os.environ.get("CORNICE_TEST_ISOLATION_SENTINEL")
assert sentinel and not Path(sentinel).exists(), "host socket sentinel visible"
foreign = []
for name in os.listdir("/proc/self/fd"):
    if int(name) <= 2:
        continue
    try:
        target = os.readlink("/proc/self/fd/" + name)
    except FileNotFoundError:
        continue
    foreign.append({"fd": name, "target": target})
assert not foreign, foreign
assert os.statvfs("/").f_flag & os.ST_RDONLY
source = Path(__file__).resolve().parent.parent
assert os.statvfs(source).f_flag & os.ST_RDONLY
product = Path(os.environ["CORNICE_TEST_PRODUCT"])
assert os.statvfs(product).f_flag & os.ST_RDONLY
probe = Path("/tmp/t/allowed-write-probe")
probe.write_text("synthetic fixture only"); probe.unlink()
print("PASS actual sandbox: private HOME/run/tmp/dev, no inherited FD or ambient client environment; source/product read-only", flush=True)
print(json.dumps({"physicalDevices": False, "testEnvironmentNames": sorted(os.environ),
                  "writableHostTarget": "/tmp/t (this test artifact directory only)",
                  "resourceManager": "outer host systemd user scope remains outside this boundary"}), flush=True)
