# 观察模式下的托盘、输入法与语音输入

2026-10-09。托盘限制已实现；下述输入架构为待实现设计，不能据此宣称输入法或 Hyprvoice 已修好。

## 行为约定

| 输入位置 | 未接管 | 已接管 |
| --- | --- | --- |
| 被观察桌面的应用 | 不接受人的鼠标、键盘、输入法提交或语音插入 | 接受输入，绑定被接管 seat |
| Cornice 自有 prompt / 搜索框 | 可以输入中文与语音，内容只进入该控件 | 同样可以输入，不能落到背后的应用 |
| 第三方 StatusNotifier 托盘图标 | 显示，所有点击和滚动无效，不弹菜单 | 保持原有行为 |
| Cornice 自有 bar 按钮 | 保持可用，写操作继续遵守各自权限 | 保持可用 |

没有可编辑控件焦点时，F8 给出可见提示，不启动录音、不回退到隐藏的主桌面应用。只读不等于全部 UI 禁用。

## 当前证据与缺口

- 已确认用户正在运行上一轮新版本，而不是忘记重新登录。
- 真正的 Fcitx、Quickshell prompt 和 GTK 在隔离合成器中重现：prompt 有拼音 preedit，Space 可提交中文，但物理输出截图没有候选框。这证明文字提交与候选框显示是两个验收项。
- 同一复现返回主桌面后，GTK 的工具包输入法仍能提交中文；用户所述返回主桌面故障尚未完整复现，不能把所有症状都归为一个已证实根因。
- 对照改用 GTK 原生 Wayland 输入法后，转到 Qt launcher 的中文提交就出现失败，尚未进入观察模式。这是原生协议与工具包输入法混用时的独立覆盖缺口。
- 主 seat 的 InputMethodRelay 监听全局 FocusState 事件；额外 seat 监听自己的 SeatManager.keyboardFocusChange。SeatPresentation.show/clear 直接调用主 SeatManager.setKeyboardFocus，漏掉主 relay 订阅的事件。此代码缺口已确认，其对实际 Chrome/Rime 故障的因果关系仍需协议回归证明。
- 观察模式屏蔽普通配置快捷键；F8 不属于允许的 controller binding。input-target 又直接拒绝整个观察模式，即使本地 prompt 有焦点；已接管时它也拒绝 layer-shell 焦点。Hyprvoice Target 只描述应用窗口，因此无法绑定 Cornice prompt。
- Cornice 目前从已存在的 layer 扫描 Hyprvoice PID 后登记显示路由。语音窗口首次创建或映射前没有登记，会有首帧或拒绝提示不可见的风险。

复现证据：/tmp/cornice-readonly-ime-probe.log 与 /tmp/cornice-agent-test.BoRcmF/ad-h2lywya6/task-pinyin-preedit.png；原生输入路径对照：/tmp/cornice-readonly-native-ime-probe.log。原有完整 ime-session suite 本轮还在只读 Super+A 打开阶段超时，未作为通过证据；诊断副本用明确 IPC 打开 prompt 后观察真实输入与画面。

## 推荐改法

### 1. Hyprland：以实际输入 surface 为准的通用功能

- 每个 seat 的输入法 relay 都订阅该 SeatManager 的真实焦点变化。普通窗口、layer、切换呈现、关闭面板、返回主桌面使用同一条 enter/leave/activate/deactivate 生命周期，避免主 seat 和额外 seat 两套通知逻辑。先验证初始化顺序，不能在主 SeatManager 尚未创建时订阅空指针。
- 呈现切换时正确结束旧输入上下文，归还 grab，向旧目标释放已发送的键和 modifiers；回到主桌面后从物理设备恢复当前状态。不能简单清空全部设备状态，也不能把输入法反馈虚拟键盘再次合并到真实设备。
- 按键按 press 时的目标归属管理 release，包含录音快捷键。目标销毁、接管撤销或锁屏时取消/结束录音，不能丢失 release 后持续录音。
- 候选框继承其输入上下文的真实父 surface 与坐标；应用候选框跟随该 seat 的场景，本地 prompt 候选框留在实体输出。本地与远端候选框不可串到另一个输入框。覆盖原生 input-popup、工具包输入法对应的 UI surface、不同缩放及 WS 切换；不把整个 Fcitx 进程所有窗口无条件显示。
- 增加独立的通用 input-target-v2 能力，目标类型为 application 或获准编辑的 local-layer，返回稳定 surface 身份、seat、焦点 epoch、锁/控制 epoch 和 token。v1 保留应用窗口语义，避免已有调用把 layer 当作 window。
- local-layer 在观察模式下可以是合法输入目标，但被观察应用仍不合法。所有提交/快捷键校验 token、当前焦点和当前授权；不能扩大成任意 layer 或任意窗口输入。
- 这些接口不包含 Cornice、F8、prompt、Hyprvoice 名称；产品提供配置、注册允许的 surface 与 binding。

### 2. Cornice：UI 策略与服务注册

- prompt 作为本地可编辑 UI 登记，并声明真正的文本控件；网络/音量等不需要文本编辑的面板不因此获得语音写入能力。
- Broker 提供本地服务注册入口，通过连接的进程身份登记 overlay PID、实例、角色与生命周期，在映射前安装通用路由规则；连接断开或进程实例变化立即失效。Hyprvoice 的录音 UI、结果 UI、拒绝提示都能原生显示，不依赖发现一个已经可见的窗口。
- 在有本地可编辑目标时，由 Cornice 配置允许的语音快捷键回调；按下/释放成对通知 Hyprvoice。没有目标只显示“请先打开输入框或接管桌面”。不恢复全部主桌面快捷键。
- 第三方托盘只禁用该 widget 的输入区域，并在进入观察模式时关闭已有菜单；不禁用整个 bar。

### 3. Hyprvoice：支持应用与本地 UI 两种真实目标

- Target 增加类型与 surface 身份，使用 v2 能力绑定启动录音时的实际编辑位置。不能伪造一个应用窗口，不能以 activewindow 回退。
- 语音文字通过该目标的受保护原生输入路径插入；Cornice prompt 的控件识别/插入验证与应用验证分别实现，保持当前密码框检查和明确插入结果，不用截图找输入框。
- 显示状态与提交权限分开：没有权限时仍显示原因；窗口出现不能自动授权输入。F8/F9 切换目标、取消、只读、锁屏和销毁都使旧 token 失效，保留识别结果供用户确认。

## 验收与实施顺序

先做真实回归用例，再依次修主/额外 seat 焦点生命周期和候选框、实现通用 layer 输入目标、对接 Cornice 注册及 Hyprvoice。保持现有特性分支，不合 main，不写 dotfiles 脚本。

必须同时验收：主桌面 GTK/Qt/Chrome 中文输入；观察模式 prompt 中文 preedit、候选框和中文提交；观察应用完全无写入；prompt F8 可见并精确插入；接管后应用 F8 与中文正常；切回主桌面、切 WS、Ctrl/Shift/Super 按住期间切换、候选未提交期间切换、overlay 首次映射及销毁、服务重启、锁屏后旧目标不再能插入。每项都检查实际文字和实际窗口画面；文字提交通过不能代替候选框可见。
