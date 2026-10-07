# Agent 桌面：特性分支使用与测试

实现分支：cornice `codex/agent-desktop`，Hyprland `codex/cornice-agent-desktop`。
两者保持在特性分支，不合 main、不发版。本机物理会话仍运行先前的 `38351820`；
新私有输出、human/full 锁与 CDP 功能已在私有实例验证，须成套安装后注销重登启用。

本机日常会话切换已另行授权：通过 `~/dotfiles/linux/desktop/hyprland/agent-session/`
中的登录入口启动已安装 fork，不覆盖系统包或原 hyprland.conf。SDDM 的原有 Hyprland
登录项保持不变，注销重登后才切换正在运行的合成器。启动先创建 WS10/11/12 的三个
暂停 seat，再启用 Cornice Agent 面板并启动原有应用。配置迁移保留原有主布局、
2 倍缩放、100 个快捷键与启动项。dotfiles 桌面脚本直接使用新版 Lua API；
全局 `hyprctl` 代理和旧命令转换器已删除，正式工具为 `/usr/bin/hyprctl`。
`cornice takeover --undo` 恢复登录 profile 与 Cornice 设置，随后注销重登恢复系统版。
会话切换的最终验收必须读取物理会话的 `hyprctl -j version`、`cornice desktop list`，
并实际验证物理输入和隐藏 seat；嵌套验证不能代表主会话已替换。

本阶段已实现独立 seat 的工具输入、工作区切换、窗口聚焦、截图、管理面板、只读跟随与
只读浏览，以及暂停/恢复的输入门禁。**人的物理输入接管、具体 AI 执行器的任务启动/停止
仍是后续阶段；本机物理会话迁移已完成**；面板没有假任务状态，也没有尚不能工作的接管按钮。
完整目标与分阶段验收见 [设计方案](agent-desktop-design.md)。

## 构建与隔离测试

原生组件依赖 CMake、Ninja、Qt 6 Core/Gui/Network/Quick/Qml/WebSockets/DBus、PAM、Wayland client、
wayland-scanner、xkbcommon。测试另需 Mutter、GTK 3/Pycairo 的 Python GI、grim 及已构建的 fork。
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
它禁用与当前会话同名的物理输入设备，拒绝 DRM 后端；不会调用当前会话的锁屏或切 ws。
测试目录里的截图和日志用于核验，输出会报告其绝对路径。

手动调试时，先进入自己创建的嵌套 fork 环境，显式设置 `XDG_RUNTIME_DIR`、
`HYPRLAND_INSTANCE_SIGNATURE` 与 `WAYLAND_DISPLAY`。以下命令不会自动发现其他实例，
也不会在缺少 seat 能力时退回人的默认输入。本机使用已安装的特性版 fork；其他机器须先安装匹配 fork 并完成会话迁移。

## CLI 管理

```bash
cornice desktop serve                              # 前台服务；另一终端执行后续命令
cornice desktop doctor                             # 能力与实例核验
cornice desktop create writer --workspace 10 --human-lock-policy continue
cornice desktop create researcher --workspace 11 --virtual-output 1920x1080
cornice desktop resume writer                      # 新帧确认后创建新输入设备
cornice desktop launch writer -- kitty
cornice desktop list
cornice desktop capture writer /tmp/writer.png
cornice desktop observe writer                     # 需要这个实例里的 cornice shell
cornice desktop pause writer
cornice desktop remove researcher                  # 保留共享应用窗口
```

默认每个 seat 创建自己的 1920×1080 headless 输出，用于自己的 WS 尺寸与截图；
`--virtual-output WxH` 可自定义。私有输出不出现在人的屏幕列表、鼠标跨屏或主 seat 焦点导航。
多个 seat 仍可选择同一 WS/窗口，布局采用该 WS 的共享尺寸，不能同时有两套窗口排布。
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

## cornice 面板与只读观察

在该实例的 cornice 配置中启用 `agentDesktop.enabled`，并将 `cn.agent-desktop`
加入 bar layout；默认安装关闭此特性。桌面定义可以放在 `agentDesktop.desktops` 中，
已有桌面保持真实当前 ws，配置重载不会把它拉回初始 ws。

```json
{
  "agentDesktop": {"enabled":true,"desktops":[
    {"name":"writer","initialWorkspace":"10","virtualOutput":"1920x1080","humanLockPolicy":"continue"}
  ]},
  "bar":{"layout":{"left":[{"id":"cn.workspaces"},{"id":"cn.agent-desktop"}]}}
}
```

观察器只消费合成器导出的原始 ARGB 帧缓冲，默认 15 fps；不建立 agent 输入设备。
「跟随」读取 agent 当前 ws，「浏览」读取人选的已有 ws；浏览不会修改任何 seat 的实际 ws。
窗口、popup、目标 seat 的 cursor 属于导出画面；物理输出上的 bar/launcher/壁纸不属于
agent 截图。其他 ws 的浏览画面不会绘制 agent 当前 ws 的错误光标。
任意锁屏都阻断人的观察导出并清除观察缓存；焦点抓取被清除时观察器可关闭，解锁后可以重新打开。
再次执行 observe 会打开/保持打开，不会把已有观察器关闭。关闭观察器释放缓冲。服务独立于 UI，UI 关闭不结束 agent 输入。

暂停只阻断桌面写入口，不表示外部 agent 的文件/网络/终端动作已暂停。
暂停、全会话锁和服务崩溃会使旧设备/凭证失效，解锁/重连不会自动恢复写入；
需要人显式 resume，再绑定执行器、重新截图。human 锁保留事先授权的 active/continue
seat，暂停策略或已暂停的 seat 均不自动恢复。这是共享会话控制契约，不是同 UID 沙箱。

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
原生锁界面使用不透明背景和真实 PAM，支持 showUser；旧壁纸/主题/主屏配置未接入。

guard 持有 sleep block/delay 和 lid inhibitor；启用后使用 Cornice 的 suspend/面板入口，
外部直接 `systemctl suspend` 被门禁拦住。唤醒仍锁住且全部 Agent 暂停；认证进程丢失
保留锁并恢复认证，guard 或整个 Cornice 在 human 锁期间丢失会升级全锁、撤销所有 Agent。
详细规定和物理验证边界见 [Session lock 设计](agent-desktop-session-lock-design.md)。

## Agent 浏览器的 CDP

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
调用工具的进程应由现有执行器启动，并将 binding 作为其桌面工具上下文。具体任务
运行、取消及状态同步需下一阶段接对应执行器，不从 seat 状态推断任务正在运行。

单输出 1280×800 的私有嵌套环境中，持续观察的实际绘制约 14.9 fps，
应用绘制时钟到物理输出读取的测量值低于 200 ms。测试直接读取应用画面的彩色
时钟像素，并同时核对 WorkspaceView 实际绘制计数；没有以 RPC 次数代替帧率。
这不是所有 GPU、分辨率、输出变换及真实会话负载下的性能保证。

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
