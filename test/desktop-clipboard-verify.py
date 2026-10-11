"""Real Wayland selections and GTK Ctrl+V across managed seats."""
from desktop_harness import *

try:
    initialize()
    cli("create", "clipboard-test", "--workspace", "11", "--virtual-output", "1280x800")
    cli("resume", "clipboard-test")
    binding = bind("clipboard-test")
    cli("launch", "clipboard-test", "--", "/usr/bin/python3", ROOT / "test/agent-desktop-client.py", "clipboard-target", BASE / "pasted.txt")
    window = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "clipboard-target"), None))
    window_id = next(w["id"] for w in tool(binding, "windows")["windows"] if w["title"] == "clipboard-target")
    tool(binding, "focus", {"windowId": window_id})
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
    png = base64.b64decode(tool(binding, "capture")["pngBase64"])
    copy("clipboard-test", png, "image/png")
    wait(lambda: paste("Hyprland", "image/png") == png)
    record("actual PNG MIME payload survives cross-seat transfer byte-for-byte")
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
