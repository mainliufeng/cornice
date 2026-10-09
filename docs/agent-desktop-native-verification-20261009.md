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
