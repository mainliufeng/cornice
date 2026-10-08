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

## 视频复验与追加修复

录制时发现此前套件未覆盖的路径：Agent 从私有输出切到包含 X11 窗口的人的
工作区，重定位后的指针命中 X11，随后调用只接受 Wayland 窗口的 surface 查询，
触发 `Cannot call windowSurfaceAt on an X11 window!` 断言。已在查询前过滤 X11；
新增回归明确将 Agent 光标移动到真实 X11 窗口内部，核对应用存活和人的状态不变。
这保证安全忽略，不新增 Agent 对 X11 的输入支持。

连续录屏还发现跨锁 epoch 的待处理截图被移出队列，但协议仍持有 frame，客户端
收不到失败通知而等待。现在明确通知失败，不输出作废帧；客户端可以重新截图。
中间实现曾误用 weak-to-unique 的 `lock()`，隔离测试立即触发断言，已改为该对象
现有的 weak 访问方式；失败构建未安装。最终 Hyprland 修复提交为 `51fd1a9`。

追加修复后重新执行的套件与录制均正常退出：

| 场景 | 结果 | 宿主证据 |
| --- | --- | --- |
| 恢复回归，含 X11 命中及真实 bootstrap | 10 项 PASS | `/tmp/cornice-agent-test.1qsoPg/ad-oufhiani/` |
| 桌面、observer 与应用回归 | 20 项 PASS | `/tmp/cornice-agent-test.5gROvD/ad-bgyqb8mt/` |
| 原生锁屏及生命周期回归 | 15 项 PASS | `/tmp/cornice-agent-test.53KHqi/ad-h21sf7hy/` |
| 实际演示录制 | 7 项断言 PASS，56.125 秒，449 帧，8 fps，无录制错误 | `/tmp/cornice-agent-test.5KUDZX/ad-ee6rfyxp/` |

视频：`/home/liufeng/Videos/cornice-agent-desktop-2026-10-08.mp4`。
可保留证据在同目录的 `cornice-agent-desktop-2026-10-08-evidence/`，含三个套件的
完整 PASS 日志、演示日志、章节时间与录制统计。视频实际解码完成无错误，已目视
检查编码后共享窗口、人锁继续运行及全锁撤权画面。

这是脚本驱动的真实嵌套会话，使用真实工具输入和 PAM worker，但 PAM 配置为
测试 permit。没有把模型执行器集成或真实账号密码认证作为已通过项。

## 验证边界

本次证明上述问题在隔离嵌套会话中已修复。未执行物理合盖、真实休眠、DRM 热插拔
或日常登录接管；这些尚不能视为通过。测试结果不构成切换当前桌面的授权。
运行中的 GTK 3 不一定绑定后新增 seat，Chrome 不保证同窗口多 seat 输入，Agent
尚不支持 X11 输入。客户端边界详见 [使用说明](agent-desktop.md)。
