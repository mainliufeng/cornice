# 原生 Agent 桌面验证 · 2026-10-09

Cornice：`codex/agent-desktop-recovery`；Hyprland：`codex/cornice-agent-desktop`。
均保持特性分支，不合并 main，不修改 dotfiles。

## 实现与使用

点击状态栏的桌面选择入口，选择 Agent，默认只读；点击状态按钮中的「接管」后，
物理键鼠直接进入该 Agent seat。窗口和 Workspace 由 Hyprland 原生合成到物理输出。
Cornice 只维护控制授权、桌面选择和状态，不传输画面或转发人的键鼠。

只读时 Workspace 栏及 Super+数字独立浏览；接管时进入当前浏览的 Workspace。
结束接管、返回人的桌面、断线或锁屏均撤销接管，Agent 保持暂停。
只读 Esc 返回；接管 Ctrl+Alt+Esc 紧急返回；点击「运行 Agent」才恢复自动操作。

已删除 QML/Qt 截图观看组件及 `human.input` 转发。机器截图工具仍用于 Agent 自己的
观察和操作校验，不参与人的桌面显示。接管不再等待截图编码和帧确认。

## 真实隔离环境验证

统一入口为 `test/isolated-desktop-test.sh`，在 bubblewrap 私有环境中运行真实
Mutter、特性版 Hyprland、Cornice、GTK、Chrome、kitty、Qt 与 Fcitx。
宿主物理键鼠、系统总线、DRM card 和当前会话 socket 均不可访问。

| 套件 | 验证内容 | 宿主证据目录 |
| --- | --- | --- |
| `desktop-switcher-verify.py` | 真实状态栏点击、只读禁止输入、原生键鼠/拼音、窗口拖动/全屏/启动/关闭、seat 内切换/移动 Workspace、独立浏览后接管、Chrome 滚轮、紧急返回、3072×1920/2×/120 Hz 模式、锁屏及租期/断线/进程崩溃恢复 | `/tmp/cornice-agent-test.8pYZIF/ad-cfw_t3lp` |
| `agent-desktop-verify.py` | GTK 同窗多 seat、旧设备撤权、Chrome/kitty/Qt 中文输入、真实输出像素连续更新、只读输入隔离、管理按钮、锁屏、服务恢复 | `/tmp/cornice-agent-test.gZqbgA/ad-0o9vr079` |
| `ime-session-verify.py` | 人的输入法、Agent 输入法、三 seat 暂停/恢复、任务输入及 Chrome DPI | `/tmp/cornice-agent-test.lSRQTl/ad-nc1pnwvu` |
| `human-lock-verify.py` | 日常锁继续策略、全锁撤权、PAM 拒绝、锁恢复、DPMS/热插拔、休眠门禁、真实锁界面与 2× 缩放 | `/tmp/cornice-agent-test.3DRdzg/ad-ygv_pmmf` |
| `capture-lock-race-verify.py` | 锁前排队截图失败且目标缓冲未写入；锁内及解锁后新截图正常 | `/tmp/cornice-agent-test.4luSuI/ad-pzv375_l` |
| 恢复套件 | 人的 GTK/X11 窗口与输出增删恢复 | `/tmp/cornice-agent-test.zD6JCa/ad-c9m66ht4` |

另执行 `make check`、headless verify、原生组件构建、Hyprland 构建及改动文件格式检查。
安装产物另运行 `install-verify` 与相同原生切换套件；部署快照由 session-trial 校验清单封存。

性能文件中的 `nativeSceneDrawsPerSecond` 是合成场景绘制次数，**不是物理扫描输出帧率**。
本次隔离原生切换套件记录约 62 次场景绘制/秒、最大绘制到截图年龄 59 ms；
3072×1920 模式打开并接管耗时约 51 ms，真实 GTK 输入成功，截图包含应用内容。
像素时钟用于验证应用绘制到截图的实际新鲜度；嵌套输出的 120 Hz 模式不代表已经在
笔记本 DRM 输出测得 120 FPS。隔离环境测试不能替代重新登录后的真机观感、物理
合盖、外接显示器或真实账户 PAM 验证。

## 当前边界与部署

- 本轮原生接管覆盖键盘、鼠标、触摸板移动和双指滚动。触摸屏、数位板、多指桌面
  手势暂未路由，观察/接管时屏蔽，防止影响隐藏的人类桌面。
- Agent seat 仍不支持向 Xwayland 窗口输入；Chrome 等只使用单 seat 的应用需通过
  对应 Agent 启动。跨应用的 D-Bus 单例行为需应用自己的新实例参数。
- 常用窗口动作已实测；相对鼠标锁定、游戏及所有自定义全局 dispatcher 尚未全面覆盖。
- 本地部署使用新的独立 session-trial 快照，只选定下一次登录。正在运行的旧 Hyprland
  和应用保持原样；需要注销并重新登录才能验证真实物理输出。
- 回退：`cornice session-trial cancel` 取消待启动版本；试用会话退出后原稳定入口保留。

## 接管卡顿及 Launcher 修复（同日追加）

真机反馈为接管后鼠标、打字都卡，Agent Launcher 的 Chrome 无窗口。
发现并修复的路径：

- Agent Workspace 未成为 monitor 的 activeWorkspace，窗口及子表面的 commit 被
  当作隐藏工作区跳过损伤提交。现在正在原生显示的 Workspace 正常触发重绘，
  包括弹窗；不改变人的 activeWorkspace。
- 应用的 `wp_presentation` 反馈原来按几何所属虚拟输出排队。现在由实际绘制输出
  排队；虚拟输出的重复绘制、直接扫描和空闲回调不能抢走反馈。FIFO 等待随实际
  输出呈现释放，离开观察后恢复普通输出规则。
- Launcher 对 Agent Chrome/Chromium 使用该 seat 的独立 profile 并启用 Wayland，
  避免复用人的浏览器单例；Firefox 同样隔离 profile。CLI 的 Firefox profile 与
  Chrome 分开，CLI Chromium 启动补齐 Wayland 参数。

新增 `presentation-pacing-verify.py` 使用真实 Wayland 窗口、`wp_presentation`
与 FIFO，不用截图绘制次数代替呈现。相同测试运行当前旧快照时，第一阶段在 12 秒
内无法完成；修复后普通和 FIFO 阶段均收到 100 次真实呈现反馈，输出均为人正在
观看的 `human`，同一窗口退出观察后继续在私有输出完成，总计 600 帧。

3072×1920、2×、120 Hz 配置的隔离输出测试：8 次键盘输入到呈现反馈约
10.8–15.5 ms，8 次鼠标输入约 9.6–16.2 ms；普通/FIFO 呈现反馈 P95 分别约
5.8/6.0 ms。测试输出的 refreshNs 为 0；这些是嵌套输出的事件延迟，不能解释为
笔记本 DRM 扫描帧率或物理设备到屏幕发光的延迟。

新增 `agent-launcher-verify.py` 在人的 Chrome 已启动时，通过真正的 Agent
Launcher 搜索及主 seat 回车启动 Chrome，检查独立 profile、Agent Workspace、
原生 Wayland、人的 workspace/focus 不变，并等待窗口内容实际绘制完整。
最终原生切换回归、headless verify 和 `make check` 通过。证据封存在
`~/.local/state/cornice/session-trial/verification/input-launcher-20261009`。

本次更改继续留在两库特性分支；本地新快照供下一次登录使用。当前会话不强制退出。
是否已生效以新会话中的 Hyprland 版本及快照路径为准，真机观感仍需新会话验证。


## 工作区同步与 F8 语音路由（同日追加）

这轮真机反馈是 Agent 工作区和 bar 切换慢，以及 F8 需输入正在接管的 Agent 应用。

工作区切换此前只改 seat 的当前工作区，没有通知原生观察端与 Agent shell；
主 bar 等 500 ms、Agent shell 等 1000 ms 定时查询。现在 Hyprland 发布
`seatworkspace` / `seatpresentation`，Cornice 立即读取真实状态，请求处理中发生的
更新合并排队。定时器仅保留心跳和断线兜底。切换同时补齐输出损伤，不激活人的
workspace，也不改变只读独立浏览的 Agent 当前 workspace。

新增 `workspace-response-verify.py`，使用实际主 seat Super+数字及真实 shell IPC，
核对观察状态、两套 shell 状态和两套 bar 控件。旧封存快照同步耗时 840–972 ms，
修改后 22–40 ms；只读浏览旧版 182–491 ms，修改后 11–19 ms。
请求处理中连续切换后的收敛为 13 ms。数值为嵌套隔离环境的状态同步耗时，
不代表物理输入到屏幕发光的延迟；bar 原有颜色动画仍与人的桌面相同。

Hyprvoice 的常驻服务以前只查询主 seat `activewindow`，并用主 seat 剪贴板及
快捷键。现在通过 `human-input-target-v1` 查询人当前实际操作的 seat 与应用，
以焦点令牌校验后向对应 seat 发快捷键；每个 seat 保留独立剪贴板 owner。
只读、锁屏或 Launcher/任务面板焦点不会回落到隐藏应用。焦点、workspace 或接管
变化会撤销旧目标；普通听写的明确确认允许重新绑定原 seat、原窗口的当前光标，
原有密码、选区和最终粘贴检查保留。Hyprvoice 悬浮层也由原生显示和命中测试处理。

`voice-seat-verify.py` 使用长驻生产 Desktop、真实主 seat F8、GTK、Agent Launcher
和 Wayland 剪贴板验证人 → Agent 1 → Agent 2 → 人的输入路由、剪贴板保留、只读及
过期拒绝、明确重试。固定文本只代表测试中的识别结果，不替代生产 ASR。
完整 App 的录音状态、F8 释放被模式切换吞掉后的停止与结果保留，以及真实语音
悬浮层，由 `voice-session-verify.py` 另行验证；其零音源和识别器为隔离测试替身。
完整 App 测试还发现：主 seat 的语音浮层关闭后会恢复隐藏的人类应用焦点，导致
下一次 F8 被拒绝。现在原生显示期间浮层关闭或放弃键盘焦点时保留 Agent 输入路径，
退出观察才恢复人的应用。恢复接管后的结果按钮只刷新可用性，不更新旧目标令牌或
自动提交；实际点击“输入”后重新核验并提交一次。隔离测试中，只读切换和任务面板
抢占时停止并保留结果分别约 220 / 131 ms；后续 F8 与原生浮层“结束录音”按钮均通过。
这些测试不声称已测真实麦克风、ASR 准确率或新版本的物理按键观感。

Hyprvoice 使用独立 `codex/cornice-seat-input` 分支；Cornice 与 Hyprland 延续原特性
分支。无 main 合并，无 dotfiles 改动。当前使用中的会话不重启；下一次登录使用新
封存快照和已备份安装的 Hyprvoice，待启动版本可用 `cornice session-trial cancel`
撤销，旧语音二进制备份记录在本地交付证据中。
