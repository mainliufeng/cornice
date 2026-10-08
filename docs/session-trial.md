# 一次性登录试运行与自动回退

用途：注销当前稳定桌面、在下一次 SDDM 的 **Hyprland** 登录中试用特性版；
启动失败、服务持续失联或合成器卡死时，自动结束试运行并回到登录界面。
下一次登录始终使用原来的系统 Hyprland 和 main 上的 Cornice。

## 使用

当前实现放在特性分支，安装系统包、替换当前运行版本和自动注销都不属于准备步骤。
先构建特性组件，再用分支中的 CLI 创建不可变快照：

```sh
make desktop-build
./bin/cornice session-trial prepare \
  --hyprland /home/liufeng/Code/source/Hyprland/build-agent-session/Hyprland \
  --config /home/liufeng/dotfiles/linux/desktop/hyprland/agent-session/hyprland.lua \
  --autostart /home/liufeng/dotfiles/linux/desktop/hyprland/agent-session/hyprland.autostart.json
```

`prepare` 只创建状态目录中的版本快照、Cornice 配置副本与校验清单；不启用登录切换。
源码构建的组件在快照中通过 `patchelf` 设置相对库路径，需要系统已提供该工具。
Hyprland 与 Cornice 的运行依赖仍来自当前系统；这不是静态系统镜像。

需要试用时执行：

```sh
./bin/cornice session-trial arm
# 现在自行保存工作、正常注销；在 SDDM 选择原来的 Hyprland 并登录。
```

默认启动检查期限为 60 秒。桌面就绪后持续执行健康检查，无需确认，也没有确认倒计时。
`--seconds` 仅为旧命令兼容而接受，已不生效；旧 ticket 中的确认期限也会忽略。
登录后的真实通知会提示以下快捷键：

| 动作 | 快捷键或命令 |
| --- | --- |
| 可选：标记本次桌面已人工确认 | Super+Ctrl+Alt+Enter；`session-trial confirm` |
| 有问题，立即结束本次试运行 | Super+Ctrl+Alt+Backspace；`session-trial rollback` |
| 在注销之前取消下次试用 | `session-trial cancel` |
| 查看标记、当前试运行、失败原因 | `session-trial status` |
| 取消并移除登录 snippet，保留用户后续修改 | `session-trial remove-hook` |

命令全称为分支中的 `./bin/cornice session-trial ...`；也可使用已单独安装的
`cornice-session-trial` 入口。它不要求稳定版 Cornice 本身认识这个新子命令。
`confirm` 仅记录人工确认，不影响会话存续或后台健康检查，也不会改变以后登录的默认版本。
回退快捷键在 Hyprland 子映射及锁屏期间也有效；确认快捷键在子映射中有效，锁屏时不可确认。
从 TTY 执行 `rollback` 同样只针对有对应进程身份的试运行，不操作稳定会话。

## 回退为什么不依赖坏桌面

- SDDM 的系统登录项与系统二进制不变。`arm` 在 zsh 的登录 profile 末尾添加有边界的
  snippet，保留备份；只识别 SDDM `wayland-session /usr/bin/start-hyprland`，普通终端/TTY 不切换。
- 启动候选版本**之前**原子消耗一次性标记并落盘。即使进程被 SIGKILL 或断电，后续登录
  也不会重复进入候选版本；没有标记时，snippet 不拦截正常登录。
- 独立 Python 进程监督真实 Hyprland、Cornice 和桌面服务，不运行在 QML 或合成器事件循环里。
  它检查 compositor IPC、配置错误、可见输出、Cornice ping、实际 bar layer 和三个 Agent 桌面。
  就绪后的连续三次健康失败触发回退；单个短暂失败不会立即注销。
  `status` 会记录最近通过检查的时间、连续失败次数和最近失败原因。
- 看门狗退出时子进程设置的父进程死亡信号会结束合成器。正常回退先终止本次创建的进程组，
  卡死时升级为 SIGKILL；不使用 `pkill Hyprland` 或 `loginctl terminate-user`。
- 三个 Agent 使用本次试运行独有的名称，避免旧崩溃遗留的 socket 与下一次试用冲突。
  清理只移除已记录且 inode 未变的本次 seat socket，不删除未知 socket。
- 试运行不覆盖 `.local/bin/cornice`、原 Hyprland 配置、Cornice 配置或旧部署指针。
  旧 bootstrap 被关闭，Cornice 使用配置副本；退出时不需要用旧备份覆盖用户的新修改。
- 仅在新登录开始时停止稳定 Cornice 服务；若仍有另一个 Hyprland 会话则拒绝试运行。
  候选版禁用自动 systemd 环境/target 接管，直接监督 shell。正常退出恢复保存的 user manager
  环境；下一次正常登录重新导入其显示环境并启动稳定服务。

快照和稳定入口的内容校验在 `arm` 及实际启动时分别执行；若版本漂移，消耗试用标记并退出，
需要重新 prepare。诊断保存在 `${XDG_STATE_HOME:-~/.local/state}/cornice/session-trial/runs/`。
登录 snippet 绑定准备时的状态目录，不依赖 SDDM 是否继承终端里的 XDG_STATE_HOME。

## 已验证与边界

在 bubblewrap 设备/进程/网络隔离环境中，使用真实 zsh 登录 profile、真实特性版 Hyprland、
Cornice、原生桌面服务和虚拟键盘执行故障测试。另一个真实合成器保留为对照，要求每次试运行
结束后它的焦点、光标、工作区和进程均未变化。

覆盖：准备不激活、取消后的正常入口、普通 shell 不消耗标记、真实快捷键确认/回退、无确认且越过旧期限仍正常运行、短暂失联恢复、
无确认时 Cornice 崩溃、合成器 SIGSTOP 卡死、合成器崩溃、看门狗 SIGKILL、损坏标记、候选文件变化、
实际日常 Lua 配置启动、错误 Lua 启动、移除 snippet 时保留用户修改。已视觉检查实际通知和 bar。

```sh
CORNICE_TEST_SESSION_CONFIG=/home/liufeng/dotfiles/linux/desktop/hyprland/agent-session/hyprland.lua \
CORNICE_TEST_HYPRLAND_SOURCE=/home/liufeng/Code/source/Hyprland \
./test/isolated-desktop-test.sh session-trial-verify.py
```

旧版已在物理 SDDM 成功登录，且实际触发过确认超时回退；新版取消了该倒计时，
仍需要下一次实机登录验证。真实输入、合盖与休眠等行为还需实机验收。
健康检查不能识别所有“进程正常但体验错误”的问题，因此保留手动回退；整机内核/GPU 死锁导致看门狗也不能运行时，不能保证立即自动注销。
