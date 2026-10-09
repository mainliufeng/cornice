# Hyprland 通用多 seat 接口与 Cornice 解耦设计

状态：已在独立特性分支实现，2026-10-09；实现契约、验证记录和剩余上游检查见 [交付记录](hyprland-generic-seat-integration-validation.md)。这些接口是本分支新增能力，不表示官方上游已提供。当前会话未替换，未合 main。

## 目标和边界

Hyprland 负责所有桌面都能复用的合成器能力：seat、独立输入和焦点、工作区视图、原生呈现和接管、截图、控制撤销、锁定作用域。Cornice 负责桌面编号、默认权限、工作区编号映射、任务 prompt、模型/harness 接入、bar/menu、语音 UI、认证和睡眠流程。

Hyprland 的运行代码、协议和默认配置不再包含 Cornice 的快捷键、工作区前缀、环境变量、应用图层名单和产品锁屏策略。不运行 Cornice 时，通用能力仍可由其他 shell/controller 使用；不启用新能力时，既有单 seat 配置和输入行为保持原语义。核心代码仍须改，不能把多 seat 路由全部搬成外部脚本。

所有输入、工作区切换和观察画面继续走原生合成器路径。Cornice 只发送控制命令和接收事件，不逐次转发鼠标/键盘，不用截图视频承担桌面观察。

## 现有耦合及替换

| 现有实现 | Hyprland 通用对接点 | Cornice 负责 |
| --- | --- | --- |
| SeatDesktop/SeatPresentation 硬编码 Super+数字、Shift+数字、Super+A | 按 seat/view 作用域的可配置绑定、携带上下文的 action 通知 | 安装数字工作区绑定和 prompt 绑定，可禁用、可改键 |
| `cornice-agent-<seat>-ws-<n>`，并根据此前缀创建观察工作区 | 工作区显式 create/query/select；只读 view 显式选择已有工作区 | slot→workspaceId 映射，创建初始空工作区，解析 UI 数字 |
| Executor 注入 `CORNICE_DESKTOP_*` | 通用稳定 seat 身份、启动上下文和 seat-local exec | 自己启动的 shell 仍可使用 Cornice 环境变量；其他工具按通用上下文接入 |
| `cornice-human-lock-v1` 及 human/agent 产品字段 | 独立的 lock-scope 协议、通用 output/seat 对象和 fail-closed 生命周期 | 日常/全部锁屏选择，PAM 界面，允许继续的桌面集合及睡眠前升级 |
| 按 `cornice-bar/menu/prompt`、`hyprvoice` namespace 特判图层渲染和输入 | 显式 surface 路由规则、view 上的 controller overlay、layer-shell 原有输入区域/交互性 | 声明自己的 bar/menu/prompt/语音 UI 的呈现与输入角色 |
| IPC 中与产品编号/主桌面名字耦合的规则 | primary 标记、稳定对象 ID、控制 lease 和 capability 查询 | “桌面1默认不允许 Agent”、编号、标签和权限开关 |

## 一、统一 Seat、View 和 ActionContext

Seat 是输入对象：包含鼠标、键盘状态、焦点、输入法、当前 workspace。View 是显示对象：指定 output、跟随的 seat 或固定 workspace；观察者浏览不改变被观察 seat。主 seat 同样通过通用对象 ID 暴露，用 `primary` 属性标识；Hyprland 不赋予它“人类桌面”或“禁止 AI”的产品含义。

View 的三种模式：

- follow：显示指定 seat 当前 workspace，只有界面管理动作可执行，输入不进入应用。
- browse：显示指定已有 workspace，仍然只读，不改变任何 seat 的 workspace/focus，不创建工作区。
- control：物理输入直接送给目标 seat 的原生输入管理器；进入时撤销该 seat 的自动化 lease，释放已按住的按键/按钮/修饰键，再交接控制。退出后不自动恢复旧自动化权限。

输入动作共用显式 ActionContext：`seatId`、可选 `viewId`、workspace/window 身份、触发来源、权限模式和相关 generation。按键解析、dispatcher、focus/fullscreen、窗口操作、exec 都使用同一份上下文。同步旧接口可保留一个薄的作用域适配，但异步工作必须复制稳定身份并重新验证，不能把全局临时 seat 指针或“当前选中的桌面”当作目标。

观察模式的应用输入与窗口写操作在 compositor 入口拒绝；不能仅靠 Cornice 隐藏按钮。观察模式允许的管理事件单独授权，不给它一般 `exec` 或窗口操作权限。只读 workspace 切换只作用于 View。

## 二、快捷键与工作区

复用现有 Lua/keybind/dispatcher，不另建按键解释器。新增通用作用域：seat、view、mode。旧绑定没有这些选项时，在可控制的桌面上按既有配置执行，并绑定本次真实输入的目标；只读 View 不执行有副作用的普通绑定。

Cornice 通过自己的可撤销配置模块注册绑定：主桌面普通工作区绑定保留；额外桌面的数字键映射到该桌面 slot；只读观察数字键映射到 View 切换；Super+A 通知 Cornice 打开 prompt。冲突必须显式报告，不能 silently 覆盖用户绑定，也不能改用户原文件。卸载 Cornice 模块即撤掉这些产品绑定。

对于 prompt 等外部动作，优先复用并扩展现有 global-shortcuts/action 机制。现有协议事件只有按下/松开及时间，没有 seat/view 上下文；新增版本或独立的通用 context 扩展携带 `seatId/viewId/actionId/mode`，保证事件与该次输入原子关联。旧客户端继续接收原有格式；新对象按版本协商。通知发给绑定的 controller 客户端，不用所有 shell 监听一个无归属的 `seatshortcut,prompt` 广播后猜目标。

Cornice 保存 `{desktopId: {slot: workspaceId}}`。现有工作区原样导入，不改名、不重编号、不迁移窗口。默认仍可创建同样名称，但名称只存在于 Cornice。Agent 直接指定 ws11 时绕过 slot 映射；多个 seat 可引用同一 workspace。新 agent 的初始空 workspace 由 Cornice 先创建再关联，不能依赖 Hyprland 识别前缀。只读观察一个不存在的 slot 返回空/不可用，创建需要明确的管理动作。

## 三、应用启动与外部命令

Hyprland seat-local exec 保留通用路由：正确的 `WAYLAND_DISPLAY`、工作区启动规则；额外 seat 当前不能承诺 X11，因此明确处理 `DISPLAY`，不增加一个假兼容路径。启动上下文可提供 `HYPRLAND_SEAT_ID` 和已有实例标识；不再由 compositor 注入 `CORNICE_*`。

涉及异步快捷键脚本时，提供短期 `HYPRLAND_ACTION_ID`：compositor 保存触发时的 seat/view、来源、模式和代次。脚本提交动作时显式引用该 context，并验证对象仍存在、模式和 generation 未变；过期或接管后拒绝，绝不退回 primary。它不是永久授权，也不能靠继承环境中的旧 generation 获权。稳定 seat ID 用于定位；实时控制状态用于授权。

Broker 自己启动 Cornice shell 时仍可注入 `CORNICE_DESKTOP_*`，这是 Cornice 内部协议，不要求别的应用依赖它。`cornice-cycle-focus`、launcher、语音 UI 使用通用启动/action 上下文并查询当前状态；F8 打开语音时固定该次目标，识别结果回写前再验证代次，失效则保留文本并提示目标失效，不能输入到新的焦点或主桌面。

## 四、shell 图层与观察/接管

删除 SeatPresentation 中按具体 namespace 特判的名单，以及只允许 Cornice prompt 获取键盘的逻辑。普通 layer surface 先按连接所属 seat 和 layer-shell 的 output、层级、input region、keyboard interactivity 处理。

通用 surface 路由声明区分：seat-local（所属桌面 shell）与 controller-overlay（物理观察者的管理 UI）。controller-overlay 绑定一个具体 View，输入仅进入该 UI；即使 View 是只读，管理菜单和 prompt 的文本框也可以工作，但不能借此把输入转给被观察应用。bar 可以不接受键盘，prompt 使用正常键盘交互性；IME 跟随真正拥有输入框的 seat。

Cornice 在自己的配置模块或 Broker 中声明这些规则，Hyprland 不知道这些图层属于哪个产品。跨 seat/controller 的绑定需要已授权的管理连接；namespace 只是规则匹配属性，不能作为权限证明。实际对象检查使用客户端身份、稳定 surface/seat/view ID；窗口销毁、surface 重建或连接断开时撤销。Quickshell 图层可由 Cornice 的配置规则声明，native 语音/锁屏窗口可用通用 surface 元数据扩展，不要求给每个 QML 层单独增加一个常驻桥接服务。

原生 hit-test 先处理授权 controller overlay，再处理被显示 seat 的 shell 和窗口。只读不进入后者的输入路径；接管直接进入目标 seat。完整重绘和 frame pacing 继续由 Hyprland output/render loop 决定，不经 Broker 轮询截图。

## 五、锁屏解耦

保留标准 `ext-session-lock-v1` 的完整会话语义。新设计提出独立的 Hyprland `lock-scope` 扩展，表示“锁定指定输入 seat 和输出展示范围”，不冒充标准 session lock，也不是将现有 Cornice 协议简单改名。

通用协议提供配置→activate→secure→unlock 的生命周期；锁定范围由稳定 seat/output ID 显式表达。只有可信锁控制器可以建立 scope，协议 namespace 或应用名称不构成授权。默认保护所有输出；排除输出必须显式注册，且限于允许后台运行的 headless/私有输出，不能靠名称前缀豁免实体显示器。新接入/身份变化/角色未知的输出默认保护；锁定时不能扩大豁免或新发控制权限。

Cornice 将日常锁映射为：锁住当前物理输入通路，保护所有实体与未知输出，只让锁前已授权的后台桌面继续输入和导出其允许的内容。主桌面的自动化 lease 撤销；其他桌面的继续运行选项由 Cornice 配置，compositor 验证允许集合。即使锁前正接管 agent，锁后实体输入也不能继续控制它，后台运行使用独立 seat。

通用 compositor 负责保护帧确已 present 后才发 secure、撤销旧 frame/export、输入隔离和守护对象。锁客户端/守护者死亡必须保持保护并升级为孤立全会话锁，不能自动解锁。全会话锁优先于所有局部 scope，撤销所有输入/导出 lease；安全恢复由新授权的锁控制器接手。

认证 UI、PAM、用户对“日常锁/全部锁”的选择以及 logind 睡眠协调都在 Cornice。睡眠前 Cornice 升级为标准完整锁，等待对应 epoch 的 secure 和全会话撤权确认，再释放睡眠阻止器；超时不按成功处理。唤醒后维持全锁直到认证解锁，不自动恢复旧输入设备/权限。这些仍必须在隔离会话验证。

后台桌面可以访问共享应用数据；局部锁保护实体输入和显示，不提供数据沙箱或隔离 Linux 用户权限。

## 六、最小接口集合与适配层

保留已有 seat control/act/snapshot/presentation 功能，整理成六组通用能力；下列为逻辑操作，不是已实现命令语法：

| 接口组 | 主要操作和契约 |
| --- | --- |
| seat | create/remove/query；稳定生命周期身份、primary 标记、display、input/focus/workspace 状态 |
| action | 显式 seat/context 的 dispatch/exec；绑定作用域、context 事件；不认识 prompt 或 slot |
| workspace | create/query/select；传入真正 workspace 身份，不解释产品名称或数字 slot |
| view | create/follow/browse/control/destroy；不改变目标 seat 的只读浏览；原生呈现与输入交接 |
| surface | 声明所属 seat、controller overlay/view 路由；基于对象与管理授权，不固定应用名单 |
| control/lock | revocable lease、状态代次、capture/export grant、lock scope 和守护生命周期 |

IPC 使用有版本和能力位的结构化请求/响应，返回稳定错误码；Wayland 对象按版本协商。管理客户端显式绑定实例，事件包含对象 ID、相关 generation 和状态序号，重连先取快照再处理增量。未知能力或旧凭证直接失败，不 fallback 到主桌面。

Cornice 新增一个内部 HyprlandAdapter，集中翻译上述接口和产品状态；Broker、bar、launcher、lock service 不各自拼 compositor 私有产品命令。对外 MCP、skill、Pi 扩展和 Codex plugin 的现有桌面操作契约不变，通过 Broker 继续接入；没有新的用户级 daemon。

“桌面1默认 Agent 权限关闭、其他桌面按设置开启”属于 Broker。Hyprland 对所有受管理输入采用同一 lease 规则：未授予就不能通过该受管理通道输入；物理输入保持原生。它不基于桌面编号识别 Agent。普通同 UID 的 shell/Wayland 管理权限边界保持明确，不宣称新的系统安全沙箱。

## 七、迁移和验收

按依赖分四阶段，每阶段两库都留在现有 feature 分支：

1. 统一 context、补通用绑定/action 事件和 workspace 显式操作；Cornice 注册产品绑定及 slot 映射；删除硬编码按键和前缀判断。立即验证全屏聚焦、既有自定义键、只读浏览和 prompt。
2. 改通用 exec/action 上下文，迁移 focus 脚本、launcher、F8/语音回写；删除 Executor 中 `CORNICE_*` 注入。验证每个桌面的原生应用启动、中文输入及接管期间异步动作失效。
3. 改通用 surface/view 路由，Cornice 声明 overlay 规则；删除 compositor namespace 白名单。验证 bar/menu/prompt/语音 UI，另用不同名称的测试 shell 验证通用性，保持观察与接管 frame pacing。
4. 两库同时迁移 lock-scope；删除旧 Cornice 专用协议及字段，完成断开、崩溃、热插拔、睡眠升级、capture/CDP 撤权的隔离验证。最终打包为匹配的新会话候选，用户现有会话不被重启。

不长期维护两套产品协议和兼容脚本；新版本通过能力握手，协议不匹配明确要求使用匹配的候选版本。已有工作区/窗口/桌面编号和可撤销配置保留；原生标准协议和未启用扩展的用户行为继续兼容。

验收必须同时满足：

- 卸载 Cornice 后，Hyprland 仍能由一个最小通用 controller 创建多 seat、输入、截图、观察、接管和 scoped lock；无任何产品按键/产品工作区自动出现。
- 源码静态检查：运行路径无 `cornice-*`/`CORNICE_*`/`hyprvoice` 特判，无数字 slot/主桌面禁 AI 的硬编码策略。
- 自定义 Super+A/数字键配置不会被 core 抢占；注册冲突可见，Cornice 模块移除后恢复原语义。
- 同 workspace 与不同 workspace 均能工作；只读浏览不改 agent 当前 ws，不能启动/关闭/修改应用；显式接管后原生点击、输入、快捷键和 IME 正常。
- stale seat/action/view/lease/frame 或异步语音回写在删除重建、切换接管、锁屏后被拒绝；不误操作主桌面，不自动重新授权。
- 锁客户端/守护者故障、未知输出/热插拔、睡眠前完整锁均 fail closed；普通日常锁下已授权后台任务仍可继续。
- 最新提交的完整上游 GTests/hyprtester、Clang-format、GCC 严格构建以及可运行的 Nix/portal CI；Cornice 现有 verify、installer 与真实模型/MCP/原生桌面回归均通过。设计不等于这些检查已执行。

## 依据

现场核对的 Hyprland 特性提交：`054534629b3c6bb3bbcfd949aafb70529dcc98c5`；Cornice 特性提交：`c19113e2fd84f1a4814a7011ae0dadcfaa6cc551`。

- `SeatDesktop.cpp`、`SeatPresentation.cpp`：按键、workspace 前缀及产品 namespace 特判。
- `Executor.cpp`：产品环境变量注入；`GlobalShortcuts.cpp/.hpp` 及协议 XML：已有 global-shortcuts 事件缺少 seat/view context。
- Cornice `Broker.cpp`、`DesktopSession.qml`、agent desktop service、lock service、native lock/session：现有对接和需迁移消费方。
- [Hyprland 官方 global-shortcuts 协议](https://github.com/hyprwm/hyprland-protocols/blob/main/protocols/hyprland-global-shortcuts-v1.xml)。
- 标准 session lock 语义核对本机官方 `wayland-protocols` XML；[对应源协议](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/staging/ext-session-lock/ext-session-lock-v1.xml)。
