# Agent 桌面：特性分支使用与测试

修复分支：Cornice `codex/agent-desktop-recovery`，Hyprland `codex/cornice-agent-desktop`。
当前实现只在特性分支。通过一次性登录试运行部署独立快照，不修改系统 Hyprland、
用户的 Cornice 配置或服务；正在使用的会话不会热替换。原生展示验证见
[2026-10-09 验证记录](agent-desktop-native-verification-20261009.md)。

需要注销后试用时，可先准备[一次性登录试运行与自动回退](session-trial.md)。它保留稳定登录入口，
只在显式 arm 后接管下一次 SDDM Hyprland 登录；启动失败或持续健康检查失败会结束试运行；桌面就绪后没有确认倒计时。

## 不影响日常桌面的测试

先构建特性版 Hyprland 与本工作树的 native 组件，再执行：

```sh
make desktop-build
export CORNICE_TEST_HYPRLAND_SOURCE=/path/to/Hyprland
export CORNICE_TEST_HYPRLAND=$CORNICE_TEST_HYPRLAND_SOURCE/build-agent-session/Hyprland
./test/isolated-desktop-test.sh
./test/isolated-desktop-test.sh agent-desktop-verify.py
./test/isolated-desktop-test.sh desktop-switcher-verify.py
./test/isolated-desktop-test.sh human-lock-verify.py
./test/isolated-desktop-test.sh capture-lock-race-verify.py
```

统一入口使用 bubblewrap 隔离进程、网络、设备、运行目录和 HOME，再启动无窗口的
Mutter → Hyprland → Cornice。宿主文件系统只读，只有本次临时目录可写；物理键鼠、
DRM card 设备、宿主 Wayland/X11 socket、systemd 与系统 D-Bus 均不可见。
仅开放 `/dev/dri/renderD128` 供普通 GPU 渲染，不能设置物理屏幕模式；纯软件 Mutter
会公告旧版 dmabuf，目前 Aquamarine 嵌套后端不能使用该组合。
测试不会连接当前合成器，也不会自动安装或启动宿主服务。退出时进程命名空间被清理。

入口打印实际宿主证据目录；sandbox 内 `/tmp/t/` 对应该目录。日志、截图均保留在其中。
可设置 `CORNICE_TEST_SESSION_START=/path/to/agent-session/session-start`，在同一沙箱中
对真实 bootstrap 执行 `--test-bootstrap`，回归带换行的发布指针及 11–13 工作区。

首个套件专门覆盖普通 GTK/Xwayland 客户端先运行，再动态创建和销毁私有输出；检查
普通客户端不收到私有 wl_output、人的 1–10 工作区归属、Agent 输入不改变人的焦点、
实际 Cornice 启动和截图，以及新增 X11 应用仍能显示。
锁屏套件中的 logind 是私有测试服务，不能触发真实休眠；物理合盖、热插拔和 DRM
显示验证仍未覆盖，不能据此认为可以直接接管日常会话。

原生锁屏与 Quickshell 锁屏共用 `shell/Commons/LockContent.qml`，保持 Cornice 的
壁纸、时钟、主题、中文提示和密码框。原生安全表面使用软件渲染，壁纸在 CPU 上模糊，
缓冲按输出缩放绘制；锁屏套件覆盖 3072×1920、2 倍缩放的实际画面。
解锁与原有 Quickshell 一样只调用 PAM 的认证阶段，不重新执行登录账户阶段。
`hyprlock` 等只定义 `auth` 的锁屏服务因此不会落入默认 `account` 拒绝规则；
测试同时覆盖 auth-only 成功和认证失败保持锁定。真实用户密码仍需用户亲自验证。

截图锁屏回归使用真实 Wayland 客户端，在同一连接上依次提交截图 copy 和锁屏请求，
确保截图尚未处理时锁 epoch 已改变。断言旧帧收到 failed 且目标缓冲未被写入，
不依赖再次截图触发渲染；随后恢复原生锁界面并验证锁内、解锁后的新截图。

录制同一隔离环境的真实演示（另需 ffmpeg、Python Pillow 与 Noto CJK 字体）：

```sh
./test/isolated-desktop-test.sh desktop-demo-record.py
```

入口打印的证据目录内包含 `ad-*/demo.mp4`、`timeline.json` 和 `recording.json`。
视频左侧是人的测试输出实时截图，右侧是 Agent 工具实际返回的授权截图；完整锁屏
或暂停后右侧清空，不展示旧帧。演示使用自动输入、真实应用与测试 PAM，不能当作
模型执行器接入或真实账号认证的证明。脚本同时断言输入效果、焦点隔离与锁屏撤权。

## 构建与隔离测试

原生组件依赖 CMake、Ninja、Qt 6 Core/Gui/Network/Quick/Qml/WebSockets/DBus、PAM、Wayland client、
wayland-scanner、xkbcommon、AT-SPI 2（Arch 的 `at-spi2-core`）与 GLib。测试另需 bubblewrap、Mutter、GTK 3/Pycairo 的 Python GI、Pillow、grim、xmessage 及已构建的 fork。
兼容验证会运行系统 Google Chrome、kitty 和 Qt/Quickshell 客户端。

```bash
make desktop-build
CORNICE_TEST_HYPRLAND_SOURCE=/path/to/Hyprland \
  CORNICE_TEST_HYPRLAND=/path/to/Hyprland/build-agent-session/Hyprland make desktop-verify
CORNICE_TEST_HYPRLAND_SOURCE=/path/to/Hyprland make human-lock-verify
# 同一套验证也可直接测试全新安装后的产物：
CORNICE_TEST_PRODUCT=/tmp/cornice-agent-install/share/cornice \
  CORNICE_TEST_HYPRLAND_SOURCE=/path/to/Hyprland ./test/agent-desktop-verify.sh
```

测试使用独立 runtime、配置、session bus、Mutter 父合成器和指定 fork 二进制。
它不查询当前合成器；物理输入及 DRM card 设备不可访问，只连接私有父合成器。
测试目录里的截图和日志用于核验，输出会报告其绝对路径。

手动调试时，先进入自己创建的嵌套 fork 环境，显式设置 `XDG_RUNTIME_DIR`、
`HYPRLAND_INSTANCE_SIGNATURE` 与 `WAYLAND_DISPLAY`。以下命令不会自动发现其他实例，
也不会在缺少 seat 能力时退回人的默认输入。测试仅使用显式指定的本地构建，不需要安装或迁移日常会话。

## CLI 管理

```bash
cornice desktop serve                              # 前台服务；另一终端执行后续命令
cornice desktop doctor                             # 能力与实例核验
cornice desktop create writer --human-lock-policy continue
cornice desktop create researcher --workspace 11 --virtual-output 1920x1080
cornice desktop resume writer                      # 新帧确认后创建新输入设备
cornice desktop launch writer -- kitty
cornice desktop list
cornice desktop capture writer /tmp/writer.png
cornice desktop observe writer                     # 需要这个实例里的 cornice shell
cornice desktop pause writer
cornice desktop remove researcher                  # 保留共享应用窗口
```

默认每个 seat 创建自己的命名工作区及 1920×1080 headless 输出，用于自己的 WS 尺寸与截图；
`--virtual-output WxH` 可自定义。私有输出不出现在人的屏幕列表、鼠标跨屏或主 seat 焦点导航。
多个 seat 仍可显式选择同一 WS/窗口，布局采用该 WS 的共享尺寸，不能同时有两套窗口排布。
未指定工作区时使用 `name:cornice-agent-<seat>`；合成器初始化私有输出也使用命名
工作区，避免中间状态自动占用人的数字工作区。输出隐私在创建时固定，禁止把已经
公告的公共输出通过旧 `seat private-output` 命令改为私有。
`--output OUTPUT` 保留显式共享输出模式。输出身份消失会撤销原 seat，不能退回人的输出。
创建后默认暂停；`humanLockPolicy` 默认 `pause`，只有显式设置 `continue` 且锁前正在
运行的 seat 能在日常锁屏后继续。管理命令的状态以合成器回复为准。

**先创建全部 seats，再启动共享 GTK 应用**。运行中的 GTK 3 应用可能不会绑定热新增的
seat；新增后需要重启相关应用。已验证 GTK 3、Google Chrome 154、kitty 0.49.1、
Qt 6.11.2/Quickshell 0.3.1 的隐藏 seat 输入。Chrome 只使用其连接首先绑定的 seat；
fork 在 agent socket 上优先公布目标 seat，因此通过 `desktop launch` 启动的 Chrome
可以操作，但另一 seat 不能保证也向同一个 Chrome 窗口输入。GTK 的同窗口多 seat
操作已单独测试；IME context 的多 seat 兼容仍取决于客户端。
浏览器启动自动使用该 desktop 生命周期的专用 profile；不复用人的日常 profile。
通用应用若通过 DBus/进程单例复用旧窗口，仍需显式使用它自己的新实例参数。
Xwayland 应用可由人的 seat 使用，但当前 Agent seat 不支持向 X11 窗口输入；
切到含 X11 的工作区或光标经过 X11 窗口必须安全忽略，不能使合成器崩溃。

原生快捷键通过 Hyprland 提供的 seat 名称，连接对应桌面的 Cornice shell；面板通过该桌面的 Wayland 连接显示在自己的输出。接管期间，面板启动应用时携带当前 seat 身份与 generation，由 Broker 校验。目标 shell 不存在时直接失败，不会通过配置名找到其他桌面的 shell。

回归测试 `launcher-native-seat-verify.py` 在隔离的真实 Hyprland、Fcitx、Chrome、Konsole 环境中，以物理 seat 按键连续执行工作区切换、Super+R、输入搜索、Ctrl+J 和回车，检查首次按键、窗口归属及主桌面隔离。

## 给 agent 绑定工具

```bash
cornice desktop bind writer /tmp/writer.binding.json
cornice desktop tool /tmp/writer.binding.json desktop.state
cornice desktop tool /tmp/writer.binding.json desktop.windows
cornice desktop tool /tmp/writer.binding.json desktop.capture
cornice desktop tool /tmp/writer.binding.json desktop.workspace '{"workspace":"11"}'
```

binding 文件是权限为 `0600` 的私有凭证，绑定具体实例、seat 生命周期和控制代次。
agent 的工具请求不接受临时指定另一个 seat；省略目标、失联、全会话锁、暂停或生命周期改变
都不能转而操作人的桌面。为同一 desktop 重新 bind 会撤销前一个 binding。

`desktop.capture` 返回 PNG 的 `pngBase64` 和同一帧的 `frameId`、ws、窗口身份、
cursor、尺寸、scale、transform、时间戳。模型/执行器消费图像后，用这一帧身份发送输入：

```json
{"action":"click","x":420,"y":260,"frameId":"本次截图返回的 frameId"}
```

切 ws、尺寸变化、锁 epoch 或焦点身份改变会使旧帧失效；过期帧被拒绝，应重新截图。
这一类可恢复错误不会自动暂停 seat；输入状态无法确认时才暂停并撤销 binding，
需要显式 resume/bind。不会自动重试无法确认的点击。

```bash
cornice desktop tool /tmp/writer.binding.json desktop.input '<上面的 JSON>'
cornice desktop tool /tmp/writer.binding.json desktop.input '{"action":"text","text":"中文也直接送到 agent seat","frameId":"本次 frameId"}'
cornice desktop tool /tmp/writer.binding.json desktop.input '{"action":"chord","keys":["CTRL","a"],"frameId":"本次 frameId"}'
```

其他输入动作：`move`、`scroll`（delta/axis）、`key`（evdev code/pressed）、
`button`（evdev code/pressed）及 `release`。坐标是 **agent 截图的像素坐标**，不是人的
屏幕坐标或预览控件坐标。文字使用 Unicode keysyms，不读写人的剪贴板；这不等同于
所有客户端都支持独立多 seat 输入法。切 ws、聚焦必须使用 `desktop.workspace/focus`，
不能靠人的全局桌面快捷键实现。

直接工具协议使用这个实例的 `desktop.sock`，换行分隔 JSON 请求/回复：

```json
{"id":"唯一请求身份","method":"desktop.input","token":"从 binding 读取的私有凭证","params":{"action":"click","x":420,"y":260,"frameId":"本次 frameId"}}
```

写请求 ID 去重；相同 ID 不允许更换参数。输入无法确认时不自动重试点击。
去重记录到达上限会要求重新同步/bind，不通过淘汰旧记录重新执行旧请求。
CLI 自己生成新 ID；需要重试语义的执行器应直接使用 JSON 协议和自己的稳定请求 ID。
协议处理成功不代表应用业务完成；执行器还应截图/读取状态确认结果。

## Cornice 全屏桌面切换与接管

状态栏的桌面组提供桌面选择、真实控制状态和 Harness 身份；可以显示或隐藏浮动预览。
选择另一个桌面打开覆盖输出的原生观察视图，接管是独立的明确动作。当前 UI 合同见
[桌面产品边界](agent-desktop-product.md) 与 DESIGN.md。

默认只看：应用画面由 Hyprland 直接合成到物理输出。Cornice 只管理选择、浏览和控制授权，
没有截图播放窗口、CPU 图像传输或键鼠转发。只读时应用不接收人的输入；Workspace
栏和 Super+数字只改变观察位置，不改变该桌面的当前 Workspace。Cornice 不提供任务编辑框。

点击「接管」撤销旧 Agent 设备、截图凭证和 CDP 权限，再由 Hyprland 把物理键鼠直接
路由到目标 seat。应用快捷键、窗口快捷键、拖动、滚动及该 seat 的原生输入法都在
合成器内处理；窗口操作和启动应用以目标 seat 为上下文，不借用人的焦点和 Workspace。
接管正在浏览的 Workspace 会明确切换 Agent 到该 Workspace，之后跟随 Agent。
Agent seat 对 X11 的原有限制仍在。这轮接管覆盖键盘、鼠标和触摸板移动/双指滚动；
触摸屏、数位板及多指桌面手势尚未路由到目标 seat，观察期间屏蔽这些入口，避免操作隐藏的人类桌面。

「结束接管」释放输入并保持 Agent 暂停；「运行 Agent」才恢复 Agent 写入。只读时 Esc
返回人的桌面，接管时 Ctrl+Alt+Esc 紧急返回并暂停 Agent。切到其他桌面、连接断开、
锁屏、输出关闭或目标消失都会撤销原控制；原生展示另有租期，控制服务退出后也能恢复。

独立虚拟输出适配物理输出的像素和缩放，应用按正确 DPI 渲染。共享输出保留几何，
画面保持宽高比。调整尺寸会使旧截图坐标失效，Agent 工具需要重新截图。
浏览其他 Workspace 不改变任何 seat 的当前 Workspace；接管期间禁止独立浏览。

```sh
cornice desktop observe writer
cornice ipc desktopObserver status
cornice ipc desktopObserver browse 12
cornice ipc desktopObserver follow
```

重复 observe 相同桌面保持打开。UI 关闭保留独立桌面服务；关闭正在接管的 UI 会将
对应 Agent 暂停。`desktop-switcher-verify.py` 使用真实物理 seat 的虚拟键鼠点击实际
状态栏与全屏按钮，验证 2 倍缩放、GTK 输入、Fcitx 拼音、旧凭证撤销、切换及锁屏释放。

## 日常锁屏、全锁与休眠

```bash
cornice desktop lock-policy writer continue  # 只能在未锁屏时设置
cornice lock                                # 日常 human 锁
cornice lock status                         # scope、secure 和认证提供者状态
cornice lock full                           # 原子升级为全会话锁，撤销所有 Agent
cornice lock recover                        # 恢复遗失锁的认证界面
cornice suspend                             # full secure 后由 guard 放行休眠
```

协议与原生模块能力齐全时启用 human 锁；缺失时仍走 Quickshell 标准全会话锁。
日常锁保护人的输入与全部物理/未知输出；continue Agent 可切换共享 WS、输入、启动应用
并截自己的画面，包括和人共用的 WS。人的观察器锁后清空，Agent 不得获取锁 surface。
原生锁界面使用不透明背景和真实 PAM，并复用 Cornice 壁纸、主题、时钟和密码框。

guard 持有 sleep block/delay 和 lid inhibitor；启用后使用 Cornice 的 suspend/面板入口，
外部直接 `systemctl suspend` 被门禁拦住。唤醒仍锁住且全部 Agent 暂停；认证进程丢失
保留锁并恢复认证，guard 或整个 Cornice 在 human 锁期间丢失会升级全锁、撤销所有 Agent。
详细规定和物理验证边界见 [Session lock 设计](agent-desktop-session-lock-design.md)。

## Agent 浏览器的 CDP

外部 Codex、Pi 等 Harness 通过共享 MCP 操作桌面：`desktop_browser_connect` 授权连接后提供 Playwright MCP 元素树及语义操作，浏览器优先读树。依赖安装、截图兜底、原生 AT-SPI 边界及 Codex 对照见 [Agent 的观察路线](agent-observation.md)。

```bash
cornice desktop tool /tmp/writer.binding.json desktop.browser
```

首次请求启动该 seat 的专用 Chrome；返回标准 CDP HTTP discovery endpoint，可连接
`endpoint + /json/version` 返回的 WebSocket。Chrome 内部使用 remote-debugging-pipe，
不开放原始 debug 端口；endpoint 含当前 binding 的秘密，不能当作公开 URL 分享。
每个 discovery、命令、响应、事件都检查 seat 授权；手动暂停、全锁、binding 失效或
服务退出关闭连接。human 锁期间 active/continue 可继续用同一授权；恢复后需新 binding
和新 endpoint。在途已执行脚本不能撤回，不自动重放失败请求。Codex 固定 9222 的插件
不会自动改连这个 endpoint，需要执行器支持传入返回的 CDP 地址。

## 安装与打包

```bash
./install.sh --desktop --copy --prefix /tmp/cornice-agent-install
```

默认 core 包仍为架构无关的 shell；可选平台包在 `packaging/agent-desktop/PKGBUILD`。
原生模块缺失/特性关闭时，普通 cornice shell 不应因为顶层 import 失败而退出。
嵌套 fork 使用 Lua 调度，人的 ws/聚焦/DPMS/重启路径经 `cornice-compositor` 适配；
agent 工具完全绕开这个人的适配器。系统 Hyprland 包与原 hyprland.conf 保留，登录迁移可通过 takeover undo 撤销。

## 本轮验收边界

验证的是 CLI/JSON 桌面工具和真实 cornice 界面，未假定任何模型执行器已经接入。
调用工具的进程由外部 Harness 启动，通过 desktop_acquire 获取桌面引用。具体任务
运行、取消及历史属于 Harness；Cornice 展示真实租期和当前 Harness，不从 seat 存在推断执行结果。

原生展示复用 Hyprland 输出的 damage 和刷新调度。回归读取实际应用画面的时钟像素，
同时核对合成器场景帧数；Cornice 不再计时抓帧。具体结果记入验证记录，
隔离测试结果不能代替物理会话的最终验收。

真实运行记录、截图、分支范围与后续缺口见 [验证记录](verification/agent-desktop.md)。

## 2026-10-07 物理会话补充验收

日常会话已运行 `38351820` 的 Release fork，DRM 输出 eDP-1，3072×1920、scale 2。
已实际测试隐藏 WS 的 GTK 点击/中文输入、kitty 中文命令与 Return、专用 Chrome
中文输入、Qt/Quickshell 中文输入、Agent 切 WS、独立截图、暂停及旧凭证撤销。
Cornice 只读观察的跟随/浏览已在物理屏幕绘制并目视检查，约 14.96 fps。
测试期间人继续操作；按物理输入事件计数区分人主动改变状态，未把整段前后相等作为验收代理。

**尚未通过：agent1 启动的同一个 GTK 窗口，agent2 可见但输入框未收到文字。**
在 GTK_IM_MODULE=fcitx 与 wayland 下均复现，尚未确定根因。因此本轮物理会话
完整验收为失败；独立应用操作路径通过，不能据此承诺任意窗口都可跨 seat 操作。
这里的失败与嵌套环境里主 seat 启动 GTK 的共享窗口通过结果需要分别保留。

证据目录：`~/.local/state/cornice-agent-desktop/physical-20261007-171801/`，
其中 result.json、test.log、agent-gtk.png、agent-browser.png、agent-terminal.png、
agent-qt.png 和 physical-observer.png 为实际执行与绘制结果。测试窗口已清理，
三个 seat 均恢复暂停；没有在物理会话注入人的输入或触发锁屏/DPMS。

## 2026-10-07 新锁分支补充

此前物理 GTK 跨 Agent 窗口失败保留为历史结果。新分支修正 agent socket 上 primary
seat 的发布时序，私有实例已验证两个预创建 Agent 向同一个 Agent 启动的 GTK 输入。
旧 GTK 应用不一定绑定后新增 seat，Chrome 仍不保证同窗口多 seat；物理修复待重登验证。
新锁测试的真实画面、FD、应用效果与失败恢复记录见验证文档；没有拿当前会话锁屏或睡眠试验。

Desktop state, IPC routing and shared daemon ownership are documented in
[desktop context](desktop-context.md).
