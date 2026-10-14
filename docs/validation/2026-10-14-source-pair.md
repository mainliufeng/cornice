# 固定源码配对的验收门槛 — 2026-10-14

本轮只允许非图形收尾。当前用户会话、安装前缀、服务、登录选择和 GPU/图形实验保持不动。固定 Hyprland 源码为 `b18a6b98136420efc3838bab6bd4a7f7de02fff7`（tree `cf2b0f15c32f1d168563f7c611da36af625c9c1e`）；Cornice 必须从本记录所在特性候选的提交干净导出，正常默认 `install.sh --copy --prefix PRIVATE_PREFIX`，不能借工作树生成物或旧 node_modules。

## 非图形证据的范围

- 精确 Hyprland 源码的 coverage binary 已通过 680 GTests；无 coverage Production Release 另行构建，二者不是同一产物。生产配置、版本、实际安装清单与 SHA256 在私有验证根的 `hyprland/installed-artifact-identity.json` 保存。实际 cache 字段和示例配置的差异也必须写入，不按文档猜测。
- Cornice 显式命名连接及 full/session 状态归一化的真实私有 socket 单元为 34 PASS / 0 FAIL；独立 clipboard-pump 静默 peer/Qt readiness 单元通过。详见 [命名连接记录](2026-10-14-named-display.md)。
- 默认完整复制安装核对六个 helpers、两组 QML 模块/四个动态库、按 lockfile 安装的 MCP/Playwright 依赖和动态库解析；不执行 compositor、锁屏、seat 或 browser，也不启用服务。安装结果以验证根 `source-pair/installed-manifest.json` 的真实状态为准，缺失或失败不得当 PASS。
- 验证根为 `~/.local/state/cornice/release-validation/20261014/`。这些是本机可复查日志/清单，不是在线服务或生产激活证明。

## 最后一个阻塞门槛：同一无 coverage 生产配对的真实运行

最终接受状态保持 **`accepted=false`**。构建、纯版本输出、动态库与依赖 import 不能替代这一个运行门槛；此前旧 b94 快照的图形 PASS 也不计入此配对。解除图形实验暂停后，仅串行运行以下必要套件，全部使用同一安装产物、同一生产 binary 与匹配的源码/测试 fixture。

| 入口 | 必须证明什么 |
| --- | --- |
| `agent-desktop-verify.py` | 多个真实 seat 的 GTK 输入/点击、capture、workspace 与主桌面焦点/光标隔离 |
| `desktop-clipboard-verify.py` | 已有双向文字/PNG、大小限制与 isolated 策略；另需以下继承 FD 与 full-lock 在途传输证据 |
| `desktop-handoff-verify.py` | 真实 MCP task、capture、QML 接管按钮、人工输入、完成后 Agent 恢复；不能只检查服务 READY |
| `session-ui-cold-update-verify.py` | 真正受监督 runner 的两 UI 更新/回退、native/应用进程保持、次 UI 缺 bar 的恢复 |

共同入口是 `test/isolated-desktop-test.sh SUITE`，设置 `CORNICE_TEST_HYPRLAND_SOURCE` 为固定源码，`CORNICE_TEST_HYPRLAND` 为私有 prefix 的生产 binary，`CORNICE_TEST_PRODUCT` 为同候选 `prefix/share/cornice`，`CORNICE_TEST_ARTIFACT_ROOT` 为已有磁盘私有目录；通过 `test/resource-scope.sh` 串行限额。当前 Aquamarine/Mutter 的真实 DMA-BUF 路径需要已获准的 render-only 节点时，也只能在图形实验恢复后显式传入 `CORNICE_TEST_RENDER_NODE`。不可因现有授权而绕过当前暂停。

cold suite 另设 `CORNICE_TEST_UI_BASELINE`；baseline 必须保留与候选相同的非 Platform native/helper 哈希，只构造该套件所需的旧 shell/Platform fixture。不能直接用早晨旧 release 的 native 产物，不能为了 PASS 换回旧 Hyprland。

### 现有自动覆盖仍缺的两项

1. **实际调用者继承 FD**：harness 默认删除 `WAYLAND_SOCKET`，34 项单元仅证明公共 helper。真实 fixture 应在 private compositor 已建、Broker 启动前配置独立 decoy seat，将其实际连接 FD 经 `pass_fds` 和 `WAYLAND_SOCKET` 仅传给 Broker 的 `Popen`。分别用 shared-first（先 ClipboardBridge）和 isolated-first（先 SeatDriver、再 sharing）验证目标 GTK 内容、双向复制，以及 primary/decoy 的内容、焦点/workspace/cursor 不变。该显式 fixture 尚未实现或运行，不能声称普通套件自动覆盖它。
2. **整会话锁中的在途剪贴板**：已有 clipboard suite 没有此断言。真实 provider 必须先确认自身 secure ack 和 native scope=session；稳态需检查 bridge 各 seat enabled=false、新 offer 不传播、解锁后新 copy 恢复，旧传输不得自动续传。即时取消还需真实 offer.receive/source.send 握手得到 pipe inode，匹配测试 Broker 的对应 fd，在锁发生时验证该端点已关闭；总 pipe 数、晚到的 enabled=false 或 wl-paste stdout EOF都不足以证明。此身份可观测 fixture 尚待补齐并运行。Broker 目前约每秒刷新 clipboard policy，sessionlock 事件没有即时刷新调用，真实在途行为必须验证，不能预先宣称安全或泄漏。

这两项是上述运行门槛的必要测试准备与断言，不是新产品功能。真机 SDDM 重登、合盖/唤醒、外接显示器/物理设备仍未测，作为明确限制记录；本轮不要求打断用户，不自动注销或重启。
