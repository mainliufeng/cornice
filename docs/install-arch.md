# 原版 Hyprland 上安装 Cornice

适用于已有原版 Hyprland 的 Arch Linux x86_64。`cornice-git` 是本地 Arch 候选包，提供日常 Shell、状态栏、应用启动器、通知和面板。包内包含 `Cornice.Platform` Qt/QML 模块；Agent 独立桌面、只读观察、接管和绑定桌面的浏览器需要配套 fork 与完整 Cornice runtime。

## 安装与首次启动

在已正常更新的 Arch 上，用交付的包校验值和文件名执行：

```sh
sha256sum -c SHA256SUMS
sudo pacman -U ./cornice-git-VERSION-x86_64.pkg.tar.zst
/usr/bin/cornice help
```

已有 `base-devel` 和 Git 时，也可在固定提交的干净源码检出里构建。`makepkg` 会通过 pacman 安装缺失的构建依赖：

```sh
makepkg --syncdeps
package=$(makepkg --packagelist)
sudo pacman -U "$package"
```

pacman 将项目文件放在 `/usr/share/cornice`、`/usr/share/doc/cornice` 和 `/usr/share/licenses/cornice-git`，命令链接在 `/usr/bin`。安装本身没有登录 hook、自启动、用户服务和 compositor 配置操作。该包与同名的旧 `cornice-git` 走正常升级流程。若 pacman 提议删除另一个 `cornice` 包或报告文件冲突，先取消这次操作，保留现有安装。请勿使用 `--overwrite`。

首次启动适合在干净的 Hyprland 测试会话进行。从会话内的终端执行 `/usr/bin/cornice launch`，再在另一个终端执行 `/usr/bin/cornice ping` 和 `/usr/bin/cornice launcher`。会话已有 Waybar、通知进程或认证代理时，用 `/usr/bin/cornice doctor` 先检查冲突。启动会尝试注册通知和认证服务、写入 Cornice 健康报告及会话 IPC 状态，并使用测试用户的 Cornice 配置。已有用户配置的 `notifications.takeover` 若为 `true`，启动器会尝试停止竞争的通知进程。

其他功能按需安装相应可选依赖。`hyprlock` 提供默认 PAM 服务，`wf-recorder` 和 `ffmpeg` 提供录屏后端与验证。音量面板使用 WirePlumber，字体图标可用 `ttf-nerd-fonts-symbols`。

## 停止与回退

从同一 Hyprland 会话执行：

```sh
/usr/bin/cornice stop
sudo pacman -R cornice-git
```

普通停止要求会话已解锁。卸载保留 `~/.config/cornice` 与 `~/.local/state/cornice`。如果显式应用过 `cornice takeover --apply`，先执行 `cornice takeover --undo` 恢复其备份的设置。如果升级前保留了旧 Arch 包，可用 `pacman -U` 安装旧包回退。

## 隔离试用 fork

配套测试已有记录的组合是 Cornice `6ca3a3620fd6ae6d5ddb24daa1b691a64ac7881a` 和 Hyprland fork `b18a6b98136420efc3838bab6bd4a7f7de02fff7`。当前 Cornice 包的验证与该配对的验证各自对应自己的版本。见[配套源码的依赖与验收记录](source-install.md)。

试用方案是在一次性 VM 或项目的私有嵌套测试会话里构建并运行这组配对。将配套安装文档中的 `prefix` 设为测试环境专用版本目录，例如 `$HOME/.local/opt/cornice-fork/b18a6b9-6ca3a36`。以该目录的 `bin/Hyprland`、`bin/cornice` 绝对路径启动测试。单独的 HOME 和 XDG config/state/data/runtime、Wayland socket、D-Bus 以及私有进程环境隔离用户配置与运行状态。在测试环境内检查 `hyprctl -j seat capabilities` 和 `cornice desktop list` 后，再验收观察、输入授予与接管。已完成的测试按版本记录，回退时退出测试会话并销毁其环境或切到先前版本目录。

如果给这套方案加启动器或分包，使用独立命令名如 `cornice-fork-session`，只在测试环境可见。文件留在版本目录，不注册默认登录入口、systemd 服务或 `hyprland` 的 `provides`、`replaces`、`conflicts`。现有 `session-trial select` 会配置未来的登录选择，适合另行安排的登录迁移。

同一 fork 会话中的 Agent 桌面共享 Linux 用户权限。一次性环境的隔离边界来自 VM 或测试沙箱。

## 与 Dux 的 Arch 安装路径对比

Dux 的基础 Arch 入口是 `pacman -S dux-shell`，从 `extra` 安装 Shell，另配官方 compositor。`duxinstall` 还可安装 compositor、工具、可选 AUR 包及下发桌面配置。Cornice 本地包采用相同的基本分工，从发行版获取 Quickshell 和原版 Hyprland，由 pacman 安装 Shell 文件，首次启动和桌面迁移由用户分别选择。 [Dux 安装文档](https://duxlabs.dev/docs/dms/installation/) · [Dux 安装器](https://duxlabs.dev/docs/duxinstall) · [Arch `dux-shell`](https://archlinux.org/packages/extra/x86_64/dux-shell/)

## Debian 可行性

Debian 13 的 trixie-backports 已有 Hyprland `0.55.2+ds-1~bpo13+1` 和 Quickshell `0.3.0-1~bpo13+1`，Qt 基线是 6.8.2。Sid 则提供 Hyprland 0.57.2 和 Quickshell 0.3.2，其 amd64 Quickshell 绑定 Qt 6.11.2 私有 ABI。以 Debian 13 amd64 加 backports 为候选目标时，需要在该环境重编 `Cornice.Platform`，通过 `dpkg-shlibdeps` 生成本机依赖，检查 Quickshell 模块与 Qt Quick 功能，再跑同样的安装、渲染、退出和卸载验收。Arch ELF 产物使用的 Qt、glibc 和 libstdc++ ABI 需按目标发行版核对。 [Debian Hyprland](https://packages.debian.org/trixie-backports/hyprland) · [Debian Quickshell](https://packages.debian.org/trixie-backports/quickshell) · [Trixie Qt](https://packages.debian.org/trixie/qt6-base-dev) · [Sid Quickshell](https://packages.debian.org/sid/quickshell)

原版 `.deb` 的工作量集中在一个原生 QML 模块、Debian 依赖映射与一套桌面验收。fork `.deb` 还需为特定 Debian suite 固定 Hyprland/Aquamarine/C++ ABI，并维护原生桌面助手和安全更新。Debian 的构建与会话验收仍待完成。
