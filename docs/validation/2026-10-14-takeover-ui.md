# 接管提示与界面生命周期验收 — 2026-10-14

修复仍在 `codex/agent-desktop-recovery`，未合 main。点击接管立即收起通知，处理中与等待 Agent 继续时不常驻浮窗；完整说明和“已完成，退出接管”留在桌面菜单。收起提示不取消请求或改变输入授权，新请求可以再次提醒。主界面只显示一份通知，主/次桌面菜单使用相同任务协议。

## 本轮真实验证

| 验证 | 结果与证据 |
| --- | --- |
| 原生接管、实际物理输入、完成退出、远程撤回、历史保存 | 5 PASS，`/tmp/cornice-ui-native-handoff-20261014.log` |
| 长说明、收起、新请求与主/次菜单实际像素 | PASS，`/tmp/cornice-handoff-product-ui-finalowner-20261014.log`；Qt 与 OCR 检查真实图形 |
| 真正旧 Supervisor 首次迁移、显式回退、运行失败恢复/重试、新 Supervisor 次 UI 故障恢复、guards | 8 PASS，exit 0，`/tmp/cornice-ui-cold-legacy-new-supervisor-20261014.log`；`/tmp/cornice-ui-cold-validation-20261014.json` |
| 两席软更新与真正 QML 解析失败回退 | 5 PASS，exit 0，`/tmp/cornice-ui-native-soft-final-20261014.log` |
| 长期 IPC 连接回收 | 160000 请求 / 7488ms；持久连接保留，每批回收到 1 wrapper / 6 QObject，RSS 60752 KiB；`/tmp/cornice-local-ipc-pressure.log` |
| 真实旧/新运输层重载与十次交换 | PASS，`/tmp/cornice-ui-native-reload-fixedfixture-20261014.log` |
| 更新单元、监督健康、预检、CLI/Controller | 17 / 22 / 实际离屏预检 / 8 / 6 组 PASS |
| 完整界面与干净复制安装 | exit 0，all checks passed，`/tmp/cornice-ui-native-headless-20261014.log`、`/tmp/cornice-ui-native-install-final-20261014.log` |

冷迁移严格保持 Supervisor、Hyprland、Broker、GTK 应用 PID/starttime、实际输入文本、窗口位置/尺寸/全屏、每席焦点/cursor/workspace。对应输出必须映射相同新 UI PID 的 bar；62 秒观察不允许反复替换 UI。原生私有 display 的 raw grim 与 seat capture 语义不同，bar 截图不充当应用内容的像素证据；应用输入与像素由接管产品套件证明。

## 实际发现与处理

旧 Quickshell SocketServer 长期保留断开的 Socket wrapper；160k 历史连接下清理需要约 20 秒。第一次真机 soft 更新未完成，旧监督器恢复了主 UI，Hyprland、Broker 与原有应用保留。原图形进程没有匹配的 core/kernel crash 证据，不能把健康超时推断写成已证实的崩溃原因。旧维护记录已用新 PID 和真实旧 UI 读回结束为 `restored-with-replacement`。

新增连接实现属于已有 `Cornice.Platform` Qt 模块，不是新 daemon。逐连接删除、UTF-8/帧/输出/连接数量上限、端点独占与同用户鉴权、真实 SIGKILL stale 恢复均通过。初次迁移或模块变化必须 cold，后续兼容模块可 soft。

负面图形验收发现：次 bar 丢失会被旧监督器错归为 Broker 故障。新监督器只恢复对应 UI，保留独立预算；旧进程无法自动获得新分类。首次迁移串行执行，并预检 QML 语法及真实 IPC 模块，完整运行仍由真实 Wayland 套件证明。旧监督器对任意次 UI 运行故障的恢复限制仍存在，随下次正常登录升级。

安装第一次因天气名称仍显示 Chengdu 而失败。真实 Service 离屏实验没有证明 Process 重启 race；可复现的是两项查询最长 20 秒，而验收仅等约 4 秒。仅将测试等待改为 25 秒绝对 deadline、保存失败诊断，保留必须显示“成都”的断言；没有修改天气生产逻辑。最终干净复制安装通过，不能倒推原失败的唯一原因。

/tmp 后来耗尽；仅清理本轮已结束失败测试的重复 node_modules/可执行副本，保留日志、QML、manifest、截图与最终产物。管理通道一度报告 EAGAIN，随后健康归零且原进程保持；没有 GPU 内核故障告警，原暂时失联原因未被唯一证明。

## 当前交付状态与边界

本轮最新 UI 快照为 `20261014-120642-e99b6622`；完整特性快照 `20261014-120645-31ad1d3d` 已持久选择为下次正常登录版本。当前桌面锁屏，cold 守卫拒绝换锁屏所属的 UI，当前浮窗修复尚待用户解锁后应用。不会绕过锁屏或注销当前会话。

本轮构建的 Platform 库 SHA256 为 `95b76a54b4259c4c4e4690891a79cb49342cc035f211feac36bd942d36f09c7b`，插件为 `41a6ce5a8f5a0115f90bc132132c45c238f95f4c22ba9cb331dbf9760992cc4f`。运行/测试 Hyprland 二进制 SHA256 为 `520694ebee42668e6ffe0e5ae5e1955a05bd4047c7c0db6e723aba3c5e4b9e86`，内嵌修订 b94b2ca；当前 fork 源码 HEAD b18a6b9，不能把它直接称为本轮二进制的构建修订。

默认 `install.sh --copy` 仅构建 Platform；多桌面完整六个 helpers/Agent 依赖仍需要显式 `--desktop`。根 PKGBUILD 默认仍仅构建 Platform。本轮最新提交没有重新验证干净 `--desktop` 安装，也没有将默认安装/发布切到多桌面；此前完整安装证据见 2026-10-11 记录，不能冒充同一最终候选的全安装验证。默认 main 发布与隔离展示全安装 gate 保持 pending。

所有图形使用明确获批的 `/dev/dri/renderD128`，串行 CPU 200% / Memory 3G / Swap 0 / Tasks 1024 / 20min 限额，以及独立输入、显示、PID、网络、总线、HOME。没有安装系统包、修改设备权限或重启当前合成器。原始证据路径在本机；长期复验应按仓库隔离套件重新生成。
