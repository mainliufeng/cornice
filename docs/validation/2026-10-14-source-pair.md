# 固定源码配对的验收门槛 — 2026-10-14

隔离运行验收已获人类明确恢复授权：仅使用合成数据、串行测试和现有 render-only 节点，不再操作当前桌面、服务或登录选择，不合并 main。接管弹窗另有直接人类修复要求，已通过保留旧 native 的 UI 更新单独交付；该 UI backport 不计入这里的固定源码配对验收。固定 Hyprland 源码为 `b18a6b98136420efc3838bab6bd4a7f7de02fff7`（tree `cf2b0f15c32f1d168563f7c611da36af625c9c1e`）；Cornice 必须从本记录所在特性候选的提交干净导出，正常默认 `install.sh --copy --prefix PRIVATE_PREFIX`，不能借工作树生成物或旧 node_modules。

## 非图形证据的范围

- 精确 Hyprland 源码的 coverage binary 已通过 680 GTests；无 coverage Production Release 另行构建，二者不是同一产物。生产配置、版本、实际安装清单与 SHA256 在私有验证根的 `hyprland/installed-artifact-identity.json` 保存。实际 cache 字段和示例配置的差异也必须写入，不按文档猜测。
- Cornice 显式命名连接及 full/session 状态归一化的真实私有 socket 单元为 34 PASS / 0 FAIL；独立 clipboard-pump 静默 peer/Qt readiness 单元通过。详见 [命名连接记录](2026-10-14-named-display.md)。
- 默认完整复制安装核对六个 helpers、两组 QML 模块/四个动态库、按 lockfile 安装的 MCP/Playwright 依赖和动态库解析；不执行 compositor、锁屏、seat 或 browser，也不启用服务。安装结果以验证根 `source-pair/installed-manifest.json` 的真实状态为准，缺失或失败不得当 PASS。
- 验证根为 `~/.local/state/cornice/release-validation/20261014/`。这些是本机可复查日志/清单，不是在线服务或生产激活证明。

## 最后一个阻塞门槛：同一无 coverage 生产配对的真实运行

在全部必要门槛完成前，接受状态必须保持 **`accepted=false`**；最终结果以验证根中绑定同一源码和实际安装产物的 manifest 为准。构建、纯版本输出、动态库与依赖 import 不能替代这一个运行门槛；此前旧 b94 快照的图形 PASS 也不计入此配对。按已恢复的隔离授权，仅串行运行以下必要套件，全部使用同一安装产物、同一生产 binary 与匹配的源码/测试 fixture。

| 入口 | 必须证明什么 |
| --- | --- |
| `agent-desktop-verify.py` | 多个真实 seat 的 GTK 输入/点击、capture、workspace 与主桌面焦点/光标隔离 |
| `desktop-clipboard-verify.py` | 已有双向文字/PNG、大小限制与 isolated 策略；另需以下继承 FD 与 full-lock 在途传输证据 |
| `desktop-handoff-verify.py` | 真实 MCP task、capture、QML 接管/收起按钮、接管路径的合成键盘输入、完成后 Agent 恢复；不能只检查服务 READY |
| `session-ui-cold-update-verify.py` | 真正受监督 runner 的两 UI 更新/回退、native/应用进程保持、次 UI 缺 bar 的恢复 |

共同入口是 `test/isolated-desktop-test.sh SUITE`，设置 `CORNICE_TEST_HYPRLAND_SOURCE` 为固定源码，`CORNICE_TEST_HYPRLAND` 为私有 prefix 的生产 binary，`CORNICE_TEST_PRODUCT` 为同候选 `prefix/share/cornice`，`CORNICE_TEST_ARTIFACT_ROOT` 为已有磁盘私有目录；通过 `test/resource-scope.sh` 串行限额。当前 Aquamarine/Mutter 的真实 DMA-BUF 路径需要已获准的 render-only 节点时，显式传入 `CORNICE_TEST_RENDER_NODE`，不暴露 DRM card、实体输入或用户桌面 socket。GPU/驱动资源仍共享；CPU、内存限额不能宣称 GPU/VRAM 隔离。软件模式已实际失败于 parent 的 DMA-BUF v3/child 要求 v4，不重复长跑。

cold suite 另设 `CORNICE_TEST_UI_BASELINE`；baseline 必须保留与候选相同的非 Platform native/helper 哈希，只构造该套件所需的旧 shell/Platform fixture。不能直接用早晨旧 release 的 native 产物，不能为了 PASS 换回旧 Hyprland。

### 必须保留的两组真实断言

1. **实际调用者继承 FD**：harness 默认删除 `WAYLAND_SOCKET`，34 项单元仅证明公共 helper。真实 fixture 应在 private compositor 已建、Broker 启动前配置独立 decoy seat，将其实际连接 FD 经 `pass_fds` 和 `WAYLAND_SOCKET` 仅传给 Broker 的 `Popen`。分别用 shared-first（先 ClipboardBridge）和 isolated-first（先 SeatDriver、再 sharing）验证目标 GTK 内容、双向复制，以及 primary/decoy 的内容、焦点/workspace/cursor 不变。显式 fixture 已实现；必须分别执行两种模式，普通初始化仍清除所有继承 FD，不得把普通套件代替这两个调用顺序。
2. **整会话锁中的在途剪贴板**：clipboard suite 已接入真实受控协议客户端和 provider 断言。真实 provider 必须先确认自身 secure ack 和 native scope=session；稳态需检查 bridge 各 seat enabled=false、新 offer 不传播、解锁后新 copy 恢复，旧传输不得自动续传。即时取消还需真实 offer.receive/source.send 握手得到 pipe inode，匹配测试 Broker 的对应 fd，在锁发生时验证该端点已关闭；总 pipe 数、晚到的 enabled=false 或 wl-paste stdout EOF都不足以证明。首次实际配对测试保留了失败：secure 观察后两条已确认在途的端点仍开放，端点保守年龄约 0.33 秒，远早于自然传输超时。Broker 已改为在真实 locked 事件立即读取实际 scope、更新桥，失败销毁旧桥；周期检查仍覆盖未发送该事件的 force-lock 和解锁恢复。不得将 scoped/human 日常锁当作 full。修复的工作候选 shared-first 已通过，但仍不是最终干净安装接受。

这两项是上述运行门槛的必要测试准备与断言，不是新产品功能。真机 SDDM 重登、合盖/唤醒、外接显示器/物理设备仍未测，作为明确限制记录；本轮不要求打断用户，不自动注销或重启。

## 运行证据的时序与来源

受控客户端不发明 pipe 创建时间：记录 pre-Popen 的保守下界、首次真实 endpoint 观察、最后在途确认和各端首次关闭时间。取消等待使用创建下界开始的绝对 2.8 秒期限，考虑 [Qt 官方文档](https://doc.qt.io/qt-6/qtimer.html#accuracy-and-timer-resolution) 中生产 QTimer 的 CoarseTimer 可提前 5%，保证比最早 3.8 秒自然超时至少早一秒；不能重设成 secure ack 后的宽限。provider 与 Broker 为独立进程，secure 首次观察和取消后状态分别记录，不能把等待结束的 false 写成 secure 时已经关闭。

writer 必须先证明真实非零 payload 充满接收管道且余量尚未传完；关闭后只读到该 payload 的非零精确短前缀和 EOF。reader 对端保持开启并验证 EPIPE。锁中 offer 先等真实 wl_display_sync 回调（仅证明 server processed，不声称 accepted），解锁时保持协议 source 存活直到策略恢复和足够真实事件轮次。所有 producer/receiver 的 endpoint ID 基线都必须不变，不能以 transfers 计数未增加代替无旧数据请求；最后只有新 copy 恢复。

cold suite 的外层截止需覆盖多个真实 62 秒稳定窗口和故障恢复；建议 900 秒，仍在既有 20 分钟资源 scope 内。旧 native UI backport 的一次外层 300 秒超时及 7 个已观察断言须保留，不能记为整套 PASS。最终 cold baseline 使用候选相同的全部非 Platform native/helpers，只有必要的旧 UI/Platform/真实 legacy runner fixture不同。
