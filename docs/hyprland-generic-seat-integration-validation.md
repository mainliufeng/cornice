# 通用多 seat 对接实现与验证

日期：2026-10-09。Hyprland `codex/cornice-agent-desktop`、Cornice `codex/agent-desktop-recovery`；Hyprvoice 消费端在 `codex/cornice-seat-input` 同步能力名称。没有合并 main、修改 dotfiles 或重启当前 compositor。

## 已拆出的职责

Hyprland 只处理 seat 的原生输入/焦点/工作区、独立原生观察和接管、可撤销控制、上下文与锁定作用域。运行源码和协议不再包含 Cornice 按键、workspace 前缀、启动环境、bar/menu/prompt/语音 namespace 名单和 human/agent 锁策略。

Cornice Broker 保存桌面 workspaceSlots，注册数字键及 Super+A，声明 shell/语音图层 PID 与 namespace 路由，选择锁前允许继续的桌面。内部 HyprlandAdapter 集中处理 compositor 传输与通用 DTO→产品 DTO 翻译；对外 23 个 MCP 工具、skill、Pi 扩展和 Codex 插件保持契约。没有新增常驻 daemon 或逐次输入转发服务。

Hyprvoice 识别 `physical-input-target-v1`，仍用真实触发目标和代次校验，失效后保留识别结果。不能混用旧 Hyprvoice 与新 compositor 然后宣称 F8 的目标路由已兼容。

## 实际接口

`seat capabilities` 按能力握手。新增 `managed-seat-config-v1`、`seat-action-context-v1`；锁/输入能力使用 `lock-scope-v1`、`private-output-v1`、`lock-aware-export-v1`、`physical-input-target-v1`。

| 接口 | 契约 |
| --- | --- |
| `seat configure JSON` | owner、seatName、seatId、callback、bindings、overlays；注册原生 registry 中带 seat/view 作用域的绑定 |
| `seat configuration-renew OWNER` | 5 秒配置 lease，Cornice 每秒续约；reload、过期明确报错并重新注册 |
| `seat configuration-remove OWNER` | 撤销绑定和 overlay 规则，恢复继承配置 |
| `seat ensure-workspace NAME SEAT_ID WORKSPACE` | 显式创建并保留空工作区，不按产品名称猜测；每 seat 上限 128 个保留工作区 |
| `seat validate-context ACTION_ID [OWNER]` | 验证 5 秒 action context；校验实例、seat 生命周期、控制 generation、view 模式/workspace、锁 epoch |
| `seat context-dispatch ACTION_ID DISPATCH` | 异步动作显式绑定触发 seat；只读、过期、撤权或删除重建直接拒绝，绝不退回主桌面 |

managed binding 支持 workspace、move、dismiss 和 notify；只读 move 禁止。继承绑定冲突默认拒绝，显式 overrideInherited 才能覆盖，响应报告冲突列表；两个活跃 controller 的同 seat、同 mode、同键绑定不允许争用。Cornice 把这些覆盖和注册错误显示在桌面状态中。未注册的原生主桌面配置不变。

notify 使用配置的本地 controller socket 单播，带 actionId/owner/seatId/generation/viewOwner/mode。这里只发送管理动作通知，鼠标、键盘、窗口切换和画面仍在 compositor 原生路径。外部脚本获得 `HYPRLAND_ACTION_ID` 和 `HYPRLAND_SEAT_*`；compositor 不注入 `CORNICE_*`。

overlay 规则由实际客户端 PID 和 namespace 匹配，并受配置 lease 限制；localInView 允许主 shell 的管理图层覆盖被观察桌面的同角色图层。只读管理 UI 可以接收自身输入，应用输入仍在 compositor 拒绝。规则不是基于 namespace 的系统权限沙箱；同 UID 的 compositor 管理通道仍是可信控制面。

## Lock scope

旧 `cornice-human-lock-v1` 已删除。新 `hyprland-lock-scope-v1` 是本分支的实验协议，采用配置→activate→secure→unlock 生命周期，显式 allow_seat(name, identity, generation) 和 exclude_output(output)。默认保护所有 seat/output，预授权本身不构成隐式豁免；排除仅限注册的私有 headless 输出。热插拔、身份变化或未知输出继续保护。

Cornice 日常锁选择允许继续集合，实体输入仍锁住；睡眠前升级到标准完整锁并等待 secure。完整 `ext-session-lock-v1` 优先，撤销全部控制/导出；unlock 不自动恢复旧授权。锁客户端或 guardian 死亡升级为孤立完整锁，Cornice 恢复认证界面，不能自动解锁或恢复后台输入。

## 验证记录

真实嵌套 Mutter/Hyprland、GTK/Chrome/Quickshell、Wayland 虚拟输入及原生锁客户端运行在隔离设备/PID/网络/HOME/DBus 的环境里；没有操作当前用户窗口。

- Hyprland GTests：647/647。
- GCC 16 Release `-Werror` 编译通过；清理先前多 seat 数据设备路径中的四处未使用引用，没有关闭警告。
- Hyprland 自有 generic-controller 回归：独立 controller，无 Cornice 进程/库依赖；绑定、单播、只读/后台同时操作、异步撤权、reload/lease 过期、默认全保护锁。
- Cornice shell：321 项通过；installer 与真实 Codex 插件发现/23 MCP 工具通过。
- 真实接管/只读：鼠标、键盘、Fcitx、应用启动、关闭、移动、全屏聚焦、工作区、bar；停止 Broker 后原生输入仍工作。真实 Super+A 在接管和只读 UI 中分别打开正确 prompt。
- Super+J/K 在主桌面和额外桌面的平铺/最大化/全屏三种模式轮转；Super+H/L 改变实际 master 比例并保持另一桌面状态；只读拒绝这些写操作。
- action-routing：既有相对/命名 workspace dispatcher、窗口移动和原生输入目标没有退回主桌面。
- scoped/full lock：真实 Chrome CDP 撤权、未知/热插拔输出、客户端与守护者故障、native PAM UI、睡眠 inhibitor/secure 时序、恢复认证与私有输出失效均通过。睡眠使用隔离的 logind 测试服务，未让真实机器睡眠。
- Hyprvoice：实际编译的 seat probe 和 App；UTF-8 输入、剪贴板、只读/过期目标拒绝、F8 录音停止、结果保留重试、原生 overlay 输入通过。App 测试使用私有 PipeWire 与测试 ASR，未声称测过真人麦克风识别准确率。
- 会话试运行、回退、不可变 manifest、故障退出和原配置保留通过。
- 上游完整 hyprtester 和 fresh install/package：正在完成，最终结果在交付前补录。

本机未安装 Nix，Nix/portal CI 尚未验证。以上通过不等于上游已接受本协议或整个多 seat 补丁；仍需上游 API/安全审查、portal 及应用生态检查和按职责拆分 PR。

## 复现入口

Hyprland 仓库：`hyprtester/multiseat/generic-controller.sh <Hyprland binary>`，或 CMake `seat-controller-check`。

Cornice 仓库：设置 CORNICE_TEST_HYPRLAND_SOURCE 与 CORNICE_TEST_HYPRLAND，运行 `test/isolated-desktop-test.sh desktop-switcher-verify.py`、`human-lock-verify.py`、`layout-shortcuts-verify.py`、`seat-action-routing-verify.py`、`desktop-harness-verify.py`；另外 `test/headless-verify.sh`、`test/install-test.sh`、`test/install-verify.sh --package`。

运行新版必须使用匹配的 Hyprland/Cornice/Hyprvoice 特性构建。此次只交付特性代码与隔离验证；现有运行会话和已选择的登录候选未被改动。
