# Agent Desktop 修复与隔离验证（2026-10-08）

## 交付范围

修复保留在 Cornice `codex/agent-desktop-recovery` 与 Hyprland
`codex/cornice-agent-desktop`，不合入 main、不安装、不修改当前登录配置或重启日常服务。

- wl_output 的 monitor 身份在公告前初始化，过滤器不再依赖公告之后才更新的输出表。
- 已公告的公共输出不能再通过旧接口改成私有，避免再次产生公告/绑定权限不一致。
- 私有输出缺省使用命名工作区；Cornice 管理器、配置 bootstrap 和服务也不再默认占用数字 10。
  显式选择共享工作区仍受支持，显式 monitor workspace 配置保持生效。
- 锁屏后首次接入人的键盘时，在键盘能力更新后恢复锁屏焦点。
- 测试入口统一进入 bubblewrap，再运行无窗口 Mutter → Hyprland → Cornice。
  物理输入、DRM card、宿主桌面套接字、系统总线不可见；真实 HOME 只读。
  只开放 GPU render 节点，测试临时目录以外的宿主文件不可写。

## 实际验证

所有下列测试使用真实构建的合成器、Cornice、GTK、Xwayland、Chrome、kitty 与 Qt 客户端。
只有休眠门禁使用私有 logind 测试替身，不会让真实电脑休眠。

| 场景 | 结果 | 宿主证据 |
| --- | --- | --- |
| 故障发布版：普通 GTK/X11 已启动后创建 Agent 输出 | 复现 GTK 协议错误及 compositor 响应超时 | `/tmp/cornice-agent-test.rjP4BL/ad-1hsgby0d/` |
| 修复版新增回归 | 9 项 PASS，含动态输出、公共/私有公告、工作区 1–10、输入隔离、真实 bootstrap 换行指针 | `/tmp/cornice-agent-test.hOrOwg/ad-yfyb785x/` |
| 既有桌面与 observer 回归 | 20 项 PASS，含 Chrome/kitty/Qt 中文输入、过期帧拒绝、锁屏、服务崩溃和恢复 | `/tmp/cornice-agent-test.8bWMe2/ad-_9s1fx6q/` |
| 人/完整锁与生命周期回归 | 15 项 PASS，含键盘热接入解锁、PAM 拒绝、锁屏进程死亡、guard 死亡、输出丢失、私有休眠总线 | `/tmp/cornice-agent-test.3af3ru/ad-9m7yt2tc/` |

执行方式在 [Agent Desktop 测试说明](agent-desktop.md) 中。
恢复回归额外传入 `CORNICE_TEST_SESSION_START`，指向 dotfiles 中已包含 `.strip()`
修复的真实 `agent-session/session-start`，只执行其 `--test-bootstrap` 路径。
测试中的部署指针带真实换行，发布 receipt 使用正在测试的 compositor commit；组件
链接到本次真实构建，不替代为 mock。它成功创建 11/12/13 上的三个暂停 seat。

已视觉检查真实 Cornice 面板、人的 GTK/X11 桌面、Agent 输入截图及原生锁屏截图。
测试结束后嵌套进程均退出；日常 Hyprland 与 Cornice 仍是测试前的同一进程。
保留原有非本任务文件，没有将其纳入提交。

## 验证边界

本次证明上述问题在隔离嵌套会话中已修复。未执行物理合盖、真实休眠、DRM 热插拔
或日常登录接管；这些尚不能视为通过。测试结果不构成切换当前桌面的授权。
