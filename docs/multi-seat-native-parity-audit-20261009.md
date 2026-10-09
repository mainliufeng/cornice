# 多 seat 原生操作审计 · 2026-10-09

本轮补丁位于 Cornice `codex/agent-desktop-recovery` 与 Hyprland
`codex/cornice-agent-desktop`，Hyprland 提交 `c3f3398`。没有合并 main、修改 dotfiles，
没有重启正在使用的合成器。新增测试执行真实 Wayland 协议、GTK 输入和原生展示，
宿主桌面设备、会话 socket、系统总线均隔离。

## 根因与本轮修复

问题不等于已有配置都需要重写。新增 seat 曾在若干调用点直接处理焦点或使用
primary manager，绕过了原生策略。只给某一个 dispatcher 增加 seat 分支不能证明
窗口关闭、应用激活、快捷键转发等其他入口正确。本轮把关闭候选与全屏继承合并成
同一原生流程，应用激活走共享 fullWindowFocus；修改策略前先验证 seat 目标，
其余输入、设备状态和 Workspace 起点明确取当前 seat。

| 实际复现的问题 | 修复与验证 |
| --- | --- |
| Agent 关闭普通窗口选错候选，关闭最大化/全屏窗口后焦点为空 | 布局移除后执行原生候选、focus_on_close 和全屏继承；24 个真人/Agent 对照关闭场景，焦点继承后直接打字，无补救点击 |
| xdg activation 对最大化/全屏窗口漏走原生策略 | 真实 seat serial/token 激活；16 个 focus_on_activate 与 fullscreen policy 对照场景 |
| send_shortcut/send_key_state/pass 向人的键盘发送 | 取当前 seat manager/keymap，保存并恢复该 seat 焦点与修饰键；人使用德语键盘、Agent 使用美式键盘，检查实际 wl_keyboard 收件归属及 GTK 文本 |
| 鼠标快捷键漏发 frame、恢复到错误局部坐标 | Agent 完成按钮批次；按原表面的坐标恢复；GTK 按钮确实触发，跨窗口转发后不移动鼠标仍能点击原按钮 |
| 相对移动窗口与省略 workspace 的跨屏移动取错起点 | 相对解析使用当前 seat Workspace；显式 monitor 和原生绝对语义保留；11 类 named relative selector 与 primary 对照，跨屏移动只移动 Agent WS |
| 已查看的 Workspace 移到另一输出后 seat 仍缓存旧输出 | 订阅 workspace.monitorChanged，更新独立 monitor、鼠标原点、视图 epoch 与事件；不激活人的输出 |
| foreign-toplevel activate 忽略请求中的 wl_seat | 校验请求资源与 client，使用请求 seat；共享的 human/其他 Agent 来源窗口只改变请求 seat 的焦点；暂停、全锁和跨 WS 拒绝均不回退到 primary |
| 拒绝焦点前可能已改变别的 WS 全屏状态、成功焦点未清 urgent | 共享原生焦点入口先验证目标与抓取，允许原生策略解除 fullscreen block；成功聚焦清 urgent；跨 WS 最大化/全屏请求不能提前修改别人的状态 |

`seat-focus-lifecycle-verify.py` 通过 40 个对照场景；
`seat-action-routing-verify.py` 通过 25 项真实输入/工作区检查；
`seat-foreign-activation-verify.py` 验证共享窗口、请求 seat、暂停和全锁。
已有 layout-shortcuts、workspace-response、human-lock 套件也通过。
封存版本通过现有 Magpie + DeepSeek 的四个真实任务：中文输入/点击、原生接管后
等待与精确恢复、接管中的情境取消、重复提交门禁与明确取消；人的原桌面及应用
内容保持不变。模型测试明确要求追加文本不能插入空格，避免将自然语言理解差异
误判为输入路由失败。
Workspace/bar 响应测量属于嵌套环境，不是笔记本物理输出的延迟保证。

旧版复现、修复版 JSON、协议日志和截图保留在本地
`~/.local/state/cornice/session-trial/verification/native-parity-20261009/`。

## 尚未证明全部兼容

这份审计只证明上表入口，不能据此宣称所有 dispatcher 与客户端都兼容。

- **真实未解决边界：后来增加的 seat 与旧 GTK3 应用。** 协议日志确认旧应用只绑定
  初始 wl_seat，没有为后来增加的 agent3 请求 keyboard；原生焦点已属于 agent3，
  输入没有送到应用，也没有回退到人的键盘。foreign 套件单独输出 LIMITATION 并
  保存 late-seat-observation.json。已有部署先创建三个 seat，再启动应用，支持的
  共享窗口输入在该真实顺序下另行验证。这里没有通过重启旧应用伪装成动态支持，
  任意时刻新建 seat 接管旧 GTK3 应用仍需解决客户端协议能力。
- **动态新增空 Agent 不受上述 GTK 边界限制。** 同一真实套件在人和两个 Agent 的
  应用运行期间新增 agent3，默认独立 Workspace 的应用窗口数为 0；随后在它的
  seat 启动新 GTK 应用，实际输入 newseatworks、点击按钮成功，人和原两个 Agent
  的完整状态及已有窗口全屏模式保持不变。实现没有固定两个或三个 seat 的数量
  上限；三个只是当前部署的预创建数量。显式选择已有 Workspace 会共享已有窗口，
  不能把“新建 seat”误解为“复制或清空已有应用”。
- `changeWorkspace(string)` 的 seat 路径仍只处理已有工作区、数字和 name，尚未
  全面接入原生 previous/empty/back-and-forth/相对切换历史。本轮修复的是相对
  **移动窗口**的解析起点，不能把它说成已完成所有相对 Workspace 切换。
- `toggleSpecial` 仍操作 monitor.activeSpecialWorkspace，尚未建模独立 seat 的
  special overlay。此处为代码审计确认的未适配路径，不在已通过的 Agent native
  special 测试中；layout suite 的 special 用例验证的是 primary。
- client 请求 fullscreen(output) 的 monitor/drag 上下文、foreign-toplevel 无 seat
  参数的 close/fullscreen 等请求，以及完整 MRU/弹窗/DnD/自定义 dispatcher
  仍需针对入口补实际协议验证。本轮没有假定它们已通过。
- secondary seat 的 Xwayland 输入边界保持显式拒绝，没有借用人的键盘。

## 模型网关归属

本机调用链是 **Cornice Agent/Pi → Magpie → DeepSeek**。
Cornice 配置的 endpoint 为 `http://127.0.0.1:3425/v1`，模型为
`deepseek/deepseek-flash`；监听进程是 `/usr/bin/magpie`，不是 Cornice 的内部网关。
网关未启动导致的 Connection error 会使任务连接失败并停止实际桌面动作。
当前监听已核实，原失败任务没有自动重放。

session-trial 的下一次登录会导入新会话环境并启动已有 XDG
`app-magpie@autostart.service`，没有新建网关服务或 dotfiles 启动脚本。
当前服务单元 inactive 不必然等于网关停止：本次 Magpie 更新后独立进程仍在监听
3425，故应检查端口和真实任务，不重复启动/杀死它。

## 部署与回退

新补丁封存为下一次 SDDM 登录的独立候选；当前应用与会话继续运行。
真正的 DRM 输出、物理键鼠感受与恢复仍需要下一次登录后验证。
取消待启动候选使用 `cornice session-trial cancel`；试用退出后稳定入口保留。
