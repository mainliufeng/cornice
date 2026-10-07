# Agent 桌面：特性分支使用与测试

实现分支：cornice `codex/agent-desktop`，Hyprland `codex/cornice-agent-desktop`。
两者保持在特性分支，不合 main、不发版、不替换当前会话。

本阶段已实现独立 seat 的工具输入、工作区切换、窗口聚焦、截图、管理面板、只读跟随与
只读浏览，以及暂停/恢复的输入门禁。**人的物理输入接管、具体 AI 执行器的任务启动/停止
和正式会话迁移仍是后续阶段**；面板没有假任务状态，也没有尚不能工作的接管按钮。
完整目标与分阶段验收见 [设计方案](agent-desktop-design.md)。

## 构建与隔离测试

原生组件依赖 CMake、Ninja、Qt 6 Core/Gui/Network/Quick/Qml、Wayland client、
wayland-scanner、xkbcommon。测试另需 Mutter、GTK 3/Pycairo 的 Python GI、grim 及已构建的 fork。
兼容验证会运行系统 Google Chrome、kitty 和 Qt/Quickshell 客户端。

```bash
make desktop-build
CORNICE_TEST_HYPRLAND_SOURCE=/path/to/Hyprland make desktop-verify
# 同一套验证也可直接测试全新安装后的产物：
CORNICE_TEST_PRODUCT=/tmp/cornice-agent-install/share/cornice \
  CORNICE_TEST_HYPRLAND_SOURCE=/path/to/Hyprland ./test/agent-desktop-verify.sh
```

测试使用独立 runtime、配置、session bus、Mutter 父合成器和指定 fork 二进制。
它禁用与当前会话同名的物理输入设备，拒绝 DRM 后端；不会调用当前会话的锁屏或切 ws。
测试目录里的截图和日志用于核验，输出会报告其绝对路径。

手动调试时，先进入自己创建的嵌套 fork 环境，显式设置 `XDG_RUNTIME_DIR`、
`HYPRLAND_INSTANCE_SIGNATURE` 与 `WAYLAND_DISPLAY`。以下命令不会自动发现其他实例，
也不会在缺少 seat 能力时退回人的默认输入。正式使用须等匹配 fork 发版并完成会话迁移。

## CLI 管理

```bash
cornice desktop serve                              # 前台服务；另一终端执行后续命令
cornice desktop doctor                             # 能力与实例核验
cornice desktop create writer --workspace 10 --output human
cornice desktop create researcher --workspace 11 --output human
cornice desktop resume writer                      # 新帧确认后创建新输入设备
cornice desktop launch writer -- kitty
cornice desktop list
cornice desktop capture writer /tmp/writer.png
cornice desktop observe writer                     # 需要这个实例里的 cornice shell
cornice desktop pause writer
cornice desktop remove researcher                  # 保留共享应用窗口
```

`human` 是测试输出名，真实会话应使用它自己的输出名。多个 seats 可以选择同一输出、
同一 ws 和同一窗口。输出仅提供尺寸/坐标基准，不是 seat 独占的显示器。
创建的桌面默认暂停，管理命令的成功状态以合成器回复为准。

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
agent 的工具请求不接受临时指定另一个 seat；省略目标、失联、锁屏、暂停或生命周期改变
都不能转而操作人的桌面。为同一 desktop 重新 bind 会撤销前一个 binding。

`desktop.capture` 返回 PNG 的 `pngBase64` 和同一帧的 `frameId`、ws、窗口身份、
cursor、尺寸、scale、transform、时间戳。模型/执行器消费图像后，用这一帧身份发送输入：

```json
{"action":"click","x":420,"y":260,"frameId":"本次截图返回的 frameId"}
```

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
    {"name":"writer","initialWorkspace":"10","output":"human"}
  ]},
  "bar":{"layout":{"left":[{"id":"cn.workspaces"},{"id":"cn.agent-desktop"}]}}
}
```

观察器只消费合成器导出的原始 ARGB 帧缓冲，默认 15 fps；不建立 agent 输入设备。
「跟随」读取 agent 当前 ws，「浏览」读取人选的已有 ws；浏览不会修改任何 seat 的实际 ws。
窗口、popup、目标 seat 的 cursor 属于导出画面；物理输出上的 bar/launcher/壁纸不属于
agent 截图。其他 ws 的浏览画面不会绘制 agent 当前 ws 的错误光标。
锁屏阻断导出并清除观察缓存；焦点抓取被清除时观察器可关闭，解锁后可以重新打开。
再次执行 observe 会打开/保持打开，不会把已有观察器关闭。关闭观察器释放缓冲。服务独立于 UI，UI 关闭不结束 agent 输入。

暂停只阻断桌面写入口，不表示外部 agent 的文件/网络/终端动作已暂停。
暂停、锁屏和服务崩溃会使旧设备/凭证失效，解锁/重连不会自动恢复写入；需要人显式
resume，再绑定执行器、重新截图。此机制是共享会话中的控制契约，不是同 UID 安全沙箱。

## 安装与打包

```bash
./install.sh --desktop --copy --prefix /tmp/cornice-agent-install
```

默认 core 包仍为架构无关的 shell；可选平台包在 `packaging/agent-desktop/PKGBUILD`。
原生模块缺失/特性关闭时，普通 cornice shell 不应因为顶层 import 失败而退出。
嵌套 fork 使用 Lua 调度，人的 ws/聚焦/DPMS/重启路径经 `cornice-compositor` 适配；
agent 工具完全绕开这个人的适配器。现有日常 Hyprland 与用户配置保持原样。

## 本轮验收边界

验证的是 CLI/JSON 桌面工具和真实 cornice 界面，未假定任何模型执行器已经接入。
调用工具的进程应由现有执行器启动，并将 binding 作为其桌面工具上下文。具体任务
运行、取消及状态同步需下一阶段接对应执行器，不从 seat 状态推断任务正在运行。

单输出 1280×800 的私有嵌套环境中，持续观察的实际绘制约 14.9 fps，
应用绘制时钟到物理输出读取的测量值低于 200 ms。测试直接读取应用画面的彩色
时钟像素，并同时核对 WorkspaceView 实际绘制计数；没有以 RPC 次数代替帧率。
这不是所有 GPU、分辨率、输出变换及真实会话负载下的性能保证。

真实运行记录、截图、分支范围与后续缺口见 [验证记录](verification/agent-desktop.md)。
