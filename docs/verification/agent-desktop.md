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
- cornice：既有 headless、idle/lock 与安装/打包验证；可选原生包构建。
- 全新 `--desktop --copy` 安装后的程序、QML 模块与 RPATH 实际运行上述场景。

命令见 [使用说明](../agent-desktop.md)。每次运行的私有目录包含应用/合成器日志、
observer/manager/browser/Qt 截图及 `observer-performance.json`。验证输出报告绝对路径。

## 尚未验收

物理输入接管、具体执行器的真实任务/取消/状态同步、正式 fork 发版与实际会话切换。
多输出热插拔、所有 scale/transform 组合、所有常用应用及多 seat 输入法矩阵也没有
全部验收。同窗口的应用数据仍共享；Chrome 的单 seat 客户端限制按使用说明处理。

![真实 cornice 只读观察器](agent-desktop-observer.png)

![实际面板按钮暂停/恢复验证后](agent-desktop-manager.png)
