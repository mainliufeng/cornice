# 显式 Wayland 连接验收 — 2026-10-14

修复在 `codex/agent-desktop-recovery`。`wl_display_connect(name)` 仍优先消费进程继承的 `WAYLAND_SOCKET`，因此显式传入 seat display 名称不足以保证输入驱动和剪贴板连接到所选桌面。将管理连接已有的显式 UNIX socket / `F_DUPFD_CLOEXEC` / `wl_display_connect_to_fd` 路径抽为同一连接入口，并由 SeatDriver、ClipboardBridge 复用。失败保持错误，不退回其他 seat，不修改进程环境或消费继承 descriptor。

没有 instance、上游未知 seat API、无 management-display capability 时，管理连接仍使用原来的普通 Wayland fallback。新的显式入口只用于已有绑定名称的连接；它不改变应用启动协议或 seat/输入授权。

## 已有真实单元证据

2026-10-14 15:48（北京时间），管理显示/锁状态/连接选择单元在私有 UNIX socket 和实际 libwayland 上验证。只有 compositor IPC 回复使用 test double；没有运行 compositor、图形/GPU、当前会话或系统服务。

- 基线：31 PASS / 3 FAIL。测试专用 shim 使用 SeatDriver/ClipboardBridge 修复前的 `wl_display_connect(name)`；相对、绝对名称均错误选择继承 descriptor，缺失目标也未保持失败。
- 修复：34 PASS / 0 FAIL，退出码 0。相对与绝对目标都连接指定 socket；继承 descriptor 仍有效、环境不变；缺失目标抛错且不消费继承连接。现有 31 项兼容、坏 IPC、管理连接和 full/session 锁归一化检查也通过。
- 原始日志：`~/.local/state/cornice/release-validation/20261014/named-display/{before.log,after.log}`；编译/执行日志：`source-pair/named-display-verification.log`（同 release-validation 根）。测试在 bwrap 合成 `/dev`、私有 `/run` 与 `/tmp` 中执行，清空 GUI/DBus 环境。

独立 `test/clipboard-pump-unit-verify.sh` 也已补齐 HyprlandAdapter 链接源，真实静默 Wayland peer / 过期 Qt readiness 单元在无设备 bwrap 中编译并通过（exit 0），日志 `source-pair/clipboard-pump.log`。这避免新增调用造成独立测试 unresolved symbol；不代表真实 compositor 上的剪贴板已验收。

可复验入口是 `native/desktop/CMakeLists.txt` 的 `cornice-management-display-unit` target；其执行仍需私有运行目录和无宿主 Wayland/socket/DBus 环境。本轮后续从此提交的干净导出完成默认完整复制安装，才能证明全部调用者实际编译与安装依赖完整；安装结果另记同候选产物清单。

## 尚未完成的运行门槛

单元测试及动态库解析不替代真实双 seat 运行。固定 Hyprland `b18a6b98136420efc3838bab6bd4a7f7de02fff7` 的无 coverage 生产产物与同一 Cornice 安装需在隔离 compositor 上完成原生输入/焦点/工作区与截图、剪贴板整会话锁、MCP task 与接管 UI 的必要验收。当前图形验证暂停，最终配对保持 `accepted=false`；此前 b94 的 PASS 不计为新配对的运行通过。实际用户重登、合盖/唤醒及外接设备仍未测。
