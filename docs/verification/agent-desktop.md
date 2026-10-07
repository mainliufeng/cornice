# Agent 桌面对接验证

本轮完整对接证据：`/tmp/ad-e6_6n7ax`；约 **14.94 fps**，最大绘制到观察时间 **124 ms**。
文末界面截图来自 `/tmp/ad-fpovr9l2`。
Hyprland 多 seat 回归证据：`/tmp/hyprland-multiseat.ugPdp5`。

日期：2026-10-07。cornice `codex/agent-desktop`；Hyprland `codex/cornice-agent-desktop`。
没有合并 main、发布或替换宿主的 Hyprland。宿主会话 PID 40893 保持原来的启动时间。

## 真实场景

一个输出，人在 ws1，三个 agent 分别在 ws10/11/12；可以切到相同 ws、共享窗口。
下列能力通过实际客户端结果确认：

- GTK 3 隐藏窗口的点击、组合键、中文输入；人的 ws/focus/cursor 不变。
- 重复写请求身份不会重复点击；切 ws 后拒绝旧截图坐标；旧 binding 被撤销。
- 截图后启动另一个真实 GTK 应用抢走焦点，旧帧文字输入被拒绝；两个应用均未收到错误文字。
- 暂停释放 held Shift，旧虚拟设备保持无效；旧连接创建替代键盘/指针被协议拒绝。
- Google Chrome 154 使用专用 profile，页面实际收到点击与中文文字。
- kitty 0.49.1 在后台执行真实输入的 shell 命令，包含中文与 Return。
- Qt 6.11.2/Quickshell 0.3.1 TextInput 实际收到中文。
- 只读跟随/浏览不改变任何 seat 状态；无人选中的 ws 的真实动画也继续更新。
- 观察器消费原始帧；真人 seat 点击、输入及 Ctrl+W 未传给共享应用。
- 实际 session lock 清空画面和缓冲，解锁保持 agent 暂停；只读重开不恢复写入。
- 人的 Lua ws/窗口聚焦/通知回到应用/DPMS/带空格 argv 启动路径通过实际状态核验。
- UI 退出不终止独立桌面服务；服务正常退出、SIGKILL、重启、seat 删除符合暂停/保留窗口契约。

持续观察测试采样实际物理输出的应用绘制时钟，另读原生 view 的实际 paint 计数。
测试输出记录 fps、最大绘制到观察时间及采样数。读 PNG 的压缩时间不作为帧率计数，
性能采样使用未压缩输出；最终视觉检查仍保存 PNG。

## 回归与安装

- Hyprland：647/647 单元测试通过；multiseat 套件及其原有单 seat 集成回归通过。
- cornice：既有 headless、idle/lock；全新复制安装回归通过，core 包文件与提交一致，
  包产物的 headless 补验通过；可选原生包构建并实际运行完整桌面专项。
- 全新 `--desktop --copy` 安装后的程序、QML 模块与 RPATH 实际运行上述场景。

安装记录：`/tmp/cornice-install-feature-focus-final.log` 的复制安装套件通过；
core 包套件遇到通知点击失败，测试原先只等待图层出现，现改为等待完整卡片尺寸稳定，
并保存实际点击前截图。对包产物重跑后的全部通过记录是
`/tmp/cornice-packaged-headless-final.log`，证据 `/tmp/cn-99kXlM`。
可选原生包运行记录是 `/tmp/cornice-agent-desktop-packaged-final.log`，证据
`/tmp/ad-a0ov62jw`（14.92 fps、最大 135 ms）。
先前一次既有空闲锁屏等待也曾失败（`/tmp/cornice-install-feature-final.log`）；
复跑的复制安装和包安装均通过，尚未确定该次间歇失败的原因。

命令见 [使用说明](../agent-desktop.md)。每次运行的私有目录包含应用/合成器日志、
observer/manager/browser/Qt 截图及 `observer-performance.json`。验证输出报告绝对路径。

## 尚未验收

物理输入接管、具体执行器的真实任务/取消/状态同步与正式 fork 发版。
本机实际会话切换结果与新增失败项见下方物理会话验收。
多输出热插拔、所有 scale/transform 组合、所有常用应用及多 seat 输入法矩阵也没有
全部验收。同窗口的应用数据仍共享；Chrome 的单 seat 客户端限制按使用说明处理。

![真实 cornice 只读观察器](agent-desktop-observer.png)

![实际面板按钮暂停/恢复验证后](agent-desktop-manager.png)

## 2026-10-07 实际物理会话验收

特性版 `38351820` 已通过原 SDDM 登录入口启动；cornice.service 正常运行，
agent1/2/3 均在实际 DRM 输出 eDP-1 上。3072×1920、2 倍缩放保留。
隐藏 Workspace 内的 GTK 点击/中文、kitty 命令、Chrome 中文、Qt 中文、切 ws、
截图、暂停/恢复与旧 binding 撤销通过。只读观察器的跟随/浏览约 14.96 fps，
已检查实际物理输出截图。测试期间有人的真实输入，逐步核对输入事件计数
与 primary 状态，观察到 3 个状态不变检查点和 5 个人主动操作检查点。

完整验收仍未通过：agent1 启动的 GTK 窗口，在 agent2 上可见但输入框不接受
第二 seat 的文字。fcitx/native Wayland IM 两种配置均复现，不能将原因归结为 fcitx。
这与以前主 seat 启动 GTK 的共享窗口通过结果不是同一个场景。

证据：`~/.local/state/cornice-agent-desktop/physical-20261007-171801/result.json`
及同目录实际截图、日志。物理会话已切换与独立应用路径通过，分别记录为真；
完整多 seat 共享窗口验收记录为假，保留此缺口。
