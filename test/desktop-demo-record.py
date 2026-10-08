"""Record actual isolated human/agent output with reproducible assertions.

This is an automated integration demo, not model-driven desktop work. Frames
are captured live; the compositor and clients are real. Test PAM permits the
demo password and cannot authenticate the host session.
"""
from desktop_harness import *
import io
import threading
from PIL import Image, ImageDraw, ImageFont

assert os.getenv("CORNICE_TEST_SANDBOX") == "1"
FONT = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc"
fonts = {size: ImageFont.truetype(FONT, size) for size in (21, 24, 30)}
scene = {"chapter": "真实 GTK 和 X11 应用先启动", "evidence": "随后创建 Agent 私有屏幕，观察已有应用是否存活", "binding": None}
scene_lock = threading.Lock()
stop = threading.Event()
camera_errors = []
timeline = []
begun = None
camera = None
encoder = None

def chapter(title, evidence):
    with scene_lock:
        scene.update(chapter=title, evidence=evidence)
    timeline.append({"seconds": round(time.monotonic() - begun, 2), "title": title, "evidence": evidence})
    (BASE / "timeline.json").write_text(json.dumps(timeline, ensure_ascii=False, indent=2))

def set_binding(binding):
    with scene_lock:
        scene["binding"] = json.loads(binding.read_text()) if binding else None

def camera_loop():
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(4)
    index = 0
    retries = 0
    failed_since = None
    try:
        connection.connect(str(RT / "cornice" / ENV["HYPRLAND_INSTANCE_SIGNATURE"] / "desktop.sock"))
        while not stop.is_set():
            with scene_lock:
                current = dict(scene)
            try:
                shot = subprocess.check_output(["grim", "-t", "ppm", "-o", "human", "-"], env=ENV, timeout=5)
            except subprocess.CalledProcessError:
                # Frames crossing a lock epoch are rejected. Ask for a fresh
                # frame; a hung capture remains a fatal error, not a retry.
                retries += 1
                failed_since = failed_since or time.monotonic()
                if time.monotonic() - failed_since > 3:
                    raise
                stop.wait(.05)
                continue
            failed_since = None
            human = Image.open(io.BytesIO(shot)).convert("RGB").resize((960, 600))
            agent = Image.new("RGB", (960, 600), "#121820")
            message = "Agent 尚未创建 / 暂无授权截图"
            binding = current["binding"]
            if binding:
                connection.sendall((json.dumps({"id": "record-" + str(index), "token": binding["token"],
                                                "method": "desktop.capture", "params": {}}) + "\n").encode())
                response = b""
                while b"\n" not in response:
                    part = connection.recv(65536)
                    if not part:
                        raise RuntimeError("recording connection closed")
                    response += part
                reply = json.loads(response)
                if reply["ok"]:
                    agent = Image.open(io.BytesIO(base64.b64decode(reply["result"]["pngBase64"]))).convert("RGB").resize((960, 600))
                    message = ""
                else:
                    message = "授权截图已停止（暂停、撤销或完整锁屏）"
            if message:
                ImageDraw.Draw(agent).text((45, 260), message, font=fonts[24], fill="#aebac8")
            canvas = Image.new("RGB", (1920, 850), "#111820")
            draw = ImageDraw.Draw(canvas)
            elapsed = time.monotonic() - begun
            draw.text((24, 10), "Cornice / Hyprland · 隔离测试实录 · 自动操作", font=fonts[30], fill="#f1f5f9")
            draw.text((1710, 15), f"{elapsed:05.1f} 秒", font=fonts[24], fill="#94a3b8")
            draw.text((24, 53), current["chapter"], font=fonts[24], fill="#88bfff")
            draw.text((24, 95), "左：人的测试桌面（实际屏幕截图）", font=fonts[24], fill="#f1f5f9")
            draw.text((984, 95), "右：Agent 工作区（实际授权截图）", font=fonts[24], fill="#f1f5f9")
            canvas.paste(human, (0, 130)); canvas.paste(agent, (960, 130))
            draw.text((24, 746), current["evidence"], font=fonts[24], fill="#b8e7c7")
            draw.text((24, 795), "不连接当前桌面；锁屏解锁使用测试 PAM。未验证真实密码、合盖、真实休眠和物理屏幕热插拔。", font=fonts[21], fill="#aab7c7")
            # Maintain wall-clock duration at 8 fps; a delayed capture duplicates
            # its current real frame rather than speeding up the recording.
            goal = max(index + 1, int(elapsed * 8) + 1)
            pixels = canvas.tobytes()
            while index < goal:
                encoder.stdin.write(pixels)
                index += 1
            if index % 32 == 0:
                canvas.save(BASE / "preview.png")
            stop.wait(max(0, begun + index / 8 - time.monotonic()))
    except Exception as error:
        camera_errors.append(str(error))
        stop.set()
    finally:
        connection.close()
        (BASE / "recording.json").write_text(json.dumps({"frames": index, "fps": 8, "wallSeconds": round(time.monotonic() - begun, 2), "rejectedCaptureRetries": retries, "errors": camera_errors}))

def dwell(seconds):
    assert not stop.wait(seconds), camera_errors

def human_command(command):
    human_input.stdin.write(command + "\n"); human_input.stdin.flush()
    assert select.select([human_input.stdout], [], [], 5)[0] and human_input.stdout.readline().strip() == "done"

def agent_text(binding, text, expected, path):
    for char in text:
        frame = tool(binding, "capture")
        tool(binding, "input", {"action": "text", "text": char, "frameId": frame["frameId"]})
        dwell(.15)
    wait(lambda: path.read_text() == expected)

def launch_human(title, filename):
    process = start(["/usr/bin/python3", str(ROOT / "test/agent-desktop-client.py"), title, str(BASE / filename)], title)
    wait(lambda: any(c["title"] == title for c in ctl("clients", True)))
    return process

def native_lock(scope):
    args = [str(PRODUCT / "bin/cornice-human-lock"), "--pam-service", "permit", "--pam-directory", str(BASE / "pam")]
    if scope == "session":
        args += ["--scope", "session"]
    process = subprocess.Popen(args, env=ENV | {"WAYLAND_DEBUG": "client"}, stdin=subprocess.PIPE,
                               stdout=open(BASE / (scope + "-lock-events.log"), "w"),
                               stderr=open(BASE / (scope + "-lock.log"), "w"), start_new_session=True, text=True)
    PROCESSES.append(process)
    wait(lambda: ctl("seat lock-state", True)["secure"])
    return process

def unlock(scope):
    # Synchronize with the actual lock client's wl_keyboard binding, then send
    # the password through real primary-seat input and the PAM worker.
    wait(lambda: any('wl_keyboard#' in line and '.enter(' in line for line in (BASE / (scope + '-lock.log')).read_text().splitlines()))
    human_command("type demo")
    human_command("key 28 1"); human_command("key 28 0")
    wait(lambda: not ctl("seat lock-state", True)["locked"])

try:
    initialize(xwayland=True)
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"), ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(BASE / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    subprocess.run(["cc", "-I" + str(BASE), str(FORK / "hyprtester/multiseat/input.c"), str(BASE / "virtual-keyboard.c"), str(BASE / "virtual-pointer.c"), "-o", str(BASE / "human-input"), *flags], check=True)
    human_input = subprocess.Popen([str(BASE / "human-input"), "Hyprland", "human"], env=ENV, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=open(BASE / "human-input.log", "w"), start_new_session=True, text=True)
    PROCESSES.append(human_input)
    assert select.select([human_input.stdout], [], [], 5)[0] and human_input.stdout.readline().strip() == "ready"
    human_app = launch_human("human-window", "human.txt")
    display = next(":" + p.name[1:] for p in pathlib.Path('/tmp/.X11-unix').glob('X*') if p.is_socket())
    x11 = start(["xmessage", "-name", "Xwayland-test", "-buttons", "OK", "X11 already running - must survive private output hotplug"], "x11", ENV | {"DISPLAY": display})
    wait(lambda: len(ctl("clients", True)) == 2)
    config = BASE / "config/cornice"; config.mkdir(parents=True, exist_ok=True)
    (config / "config.json").write_text(json.dumps({"agentDesktop": {"enabled": True},
        "bar": {"layout": {"left": [{"id": "cn.workspaces"}, {"id": "cn.agent-desktop"}], "center": [], "right": []}},
        "idle": {"lock": 0, "screenOffAc": 0, "screenOffBattery": 0, "dimAc": 0, "dimBattery": 0,
                 "lockOnSleep": False, "lockOnLockSignal": False, "lockOnLidClose": False}, "background": {"enabled": False}, "weather": {"intervalMinutes": 0}}))
    start([str(PRODUCT / "bin/cornice-qs"), "-p", str(PRODUCT / "shell")], "cornice")
    wait(lambda: json.loads(shell("ipc", "desktop", "status"))["available"])
    (BASE / "pam").mkdir(); (BASE / "pam/permit").write_text("auth required pam_permit.so\naccount required pam_permit.so\n")
    encoder = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "warning", "-y", "-f", "rawvideo", "-pixel_format", "rgb24",
                                "-video_size", "1920x850", "-framerate", "8", "-i", "pipe:0", "-an", "-c:v", "libx264",
                                "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p", "-threads", "2", "-movflags", "+faststart", str(BASE / "demo.mp4")],
                               env=ENV, stdin=subprocess.PIPE, stderr=open(BASE / "ffmpeg.log", "w"))
    begun = time.monotonic(); camera = threading.Thread(target=camera_loop); camera.start()
    chapter("01 · 原有 GTK / X11 应用先运行", "左侧已有两个真实应用；随后动态创建 Agent 屏幕，检查旧故障是否再出现。")
    dwell(5)
    cli("create", "writer", "--virtual-output", "1280x800", "--human-lock-policy", "continue")
    cli("create", "pausing", "--virtual-output", "1280x800")
    cli("resume", "writer"); cli("resume", "pausing")
    cli("launch", "writer", "--", "/usr/bin/python3", ROOT / "test/agent-desktop-client.py", "agent-window", BASE / "agent.txt")
    agent_window = wait(lambda: next((c for c in ctl("clients", True) if c["title"] == "agent-window"), None))
    OWNED_PIDS.append(agent_window["pid"])
    binding = bind("writer"); set_binding(binding)
    assert human_app.poll() is None and x11.poll() is None
    chapter("02 · 动态创建私有屏幕，已有应用仍存活", "Agent 使用独立命名工作区；人的 GTK / X11 没有退出或丢失。")
    dwell(4)
    ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
    human_command("motion 180 180")
    # Independent human and agent devices really run concurrently in one compositor.
    def human_typing():
        try:
            for char in "Human keeps typing.":
                human_command("type " + char); dwell(.14)
        except Exception as error:
            camera_errors.append("human input: " + str(error))
    chapter("03 · 人与 Agent 同时输入", "左侧由人的 seat 输入，右侧由真实 Agent 工具输入；光标、焦点和工作区分离。")
    human_thread = threading.Thread(target=human_typing); human_thread.start()
    agent_text(binding, "Agent 正在独立工作。", "Agent 正在独立工作。", BASE / "agent.txt")
    human_thread.join(); assert not camera_errors, camera_errors
    wait(lambda: (BASE / "human.txt").read_text() == "Human keeps typing.")
    baseline = human_state()
    agent_text(binding, "互不抢焦点。", "Agent 正在独立工作。互不抢焦点。", BASE / "agent.txt")
    assert human_state() == baseline
    record("concurrent real human/agent input; agent typing preserves human focus/cursor/workspace")
    dwell(3)
    chapter("04 · 暂停 / 恢复 Agent", "暂停会撤销旧授权；恢复后必须重新绑定，不能继续使用旧控制凭据。")
    cli("pause", "writer")
    assert "revoked" in tool(binding, "input", {"action": "text", "text": "BAD", "frameId": "old"}, succeeds=False).lower()
    dwell(3)
    cli("resume", "writer"); binding = bind("writer"); set_binding(binding)
    agent_text(binding, "已恢复。", "Agent 正在独立工作。互不抢焦点。已恢复。", BASE / "agent.txt")
    record("pause revokes old credentials; fresh binding resumes actual input")
    dwell(2)
    chapter("05 · 共同操作一个真实 GTK 窗口", "共享应用在 seats 创建后启动；内容会同步，输入焦点仍各自独立。")
    shared_app = launch_human("shared-window", "shared.txt")
    ok('dispatch hl.dsp.focus({window="title:^shared-window$"})')
    human_command("type Human:")
    wait(lambda: (BASE / "shared.txt").read_text() == "Human:")
    private_workspace = cli("state", "writer")["workspace"]
    tool(binding, "workspace", {"workspace": "1"})
    shared_id = next(w["id"] for w in tool(binding, "windows")["windows"] if w["title"] == "shared-window")
    tool(binding, "focus", {"windowId": shared_id})
    baseline = human_state()
    agent_text(binding, "Agent协助完成。", "Human:Agent协助完成。", BASE / "shared.txt")
    assert human_state() == baseline
    record("two seats operate one real GTK client without changing human focus")
    dwell(4)
    tool(binding, "workspace", {"workspace": private_workspace})
    tool(binding, "focus", {"windowId": next(w["id"] for w in tool(binding, "windows")["windows"] if w["title"] == "agent-window")})
    chapter("06 · 反复创建、删除私有屏幕", "模拟动态输出生命周期；人的现有应用和 Xwayland 必须保持可用。")
    for index in range(3):
        cli("create", "temporary", "--virtual-output", "1280x800"); dwell(.6)
        cli("remove", "temporary"); dwell(.6)
        assert human_app.poll() is None and shared_app.poll() is None and x11.poll() is None
    record("three private output hotplug cycles preserve existing GTK and Xwayland clients")
    dwell(2)
    chapter("07 · 人的日常锁屏：获准 Agent 继续", "真实原生锁屏已覆盖人的画面；writer 预先获准继续，默认策略的 seat 则暂停。")
    native_lock("human")
    assert not cli("state", "writer")["paused"] and cli("state", "pausing")["paused"]
    agent_text(binding, "锁屏中继续。", "Agent 正在独立工作。互不抢焦点。已恢复。锁屏中继续。", BASE / "agent.txt")
    record("native human lock covers actual human output; preauthorized writer continues; default seat pauses")
    dwell(5)
    chapter("08 · 测试 PAM 解锁（不验证真实密码）", "通过人的虚拟键盘输入测试密码，走真实锁屏输入和 PAM worker 流程。")
    unlock("human"); dwell(3)
    chapter("09 · 完整锁屏：全部 Agent 被撤销", "右侧授权截图也必须停止；完整锁屏后不允许 Agent 控制或读取画面。")
    native_lock("session")
    assert cli("state", "writer")["paused"] and cli("state", "pausing")["paused"]
    assert "revoked" in tool(binding, "capture", succeeds=False).lower()
    record("full native session lock revokes every agent, including capture credentials")
    dwell(5)
    unlock("session")
    assert cli("state", "writer")["paused"]
    chapter("10 · 解锁后保持暂停，不自动恢复 Agent", "本次演示断言全部通过；物理合盖、真实休眠和热插拔尚未验证。")
    record("full-lock unlock leaves agents paused; no implicit restoration of control")
    dwell(5)
finally:
    stop.set()
    if camera:
        camera.join(timeout=12)
        assert not camera.is_alive(), "capture thread did not finish"
    if encoder:
        encoder.stdin.close()
        assert encoder.wait(timeout=30) == 0, (BASE / "ffmpeg.log").read_text()
    cleanup()
    assert not camera_errors, camera_errors
    print("Recording:", BASE / "demo.mp4", flush=True)
