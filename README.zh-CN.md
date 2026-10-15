# Cornice

[English](README.md) · **中文**

基于 [Quickshell](https://quickshell.org) 的 **Hyprland shell**，让人和 AI Agent
各有自己的桌面。日常 Shell 把状态栏、面板、通知、启动器、锁屏、空闲管理与
polkit 认证收进统一界面。任务、模型和对话由 Codex、Pi 等外部执行器管理；
Cornice 提供分配给它的桌面及观察、控制工具。

[![Pi 在自己的 Chrome 桌面中真实调研 Cornice](docs/media/cornice-pi-real-browser-v4.png)](docs/media/cornice-pi-real-browser-v4.mp4)

[观看 Pi 真实浏览器调研](docs/media/cornice-pi-real-browser-v4.mp4)。启动脚本自动提交提示词，搜索、点击、页面阅读和带来源的原始答复均由 Pi 1.1.0 的模型实际执行。Google 返回验证/429 页面后，Pi 正常使用 DuckDuckGo 搜索一次，再阅读真实 GitHub 仓库与 README；没有绕过验证。

*57.901 秒，**1.5 倍速**；从同一次 94.643 秒原片按原顺序截取。临时标识、内部端点和验证页信息已实框遮挡，Pi 原答保留不改。工作目录、会话与 Chrome profile 均为全新演示实例。Cornice `6ca3a36` + Hyprland fork `b18a6b9`。摄像采用操作员权限的输出采集，与 Pi 任务的 MCP capture 分开；两侧保留各自的采样时间。*

原答中“Agent 方式是只读观察”的主语有歧义：默认只读的是人对 Agent 桌面的观察窗；显式接管后，人的输入进入该桌面并暂停 Agent 控制。本段只展示真实浏览器调研，没有验证进程架构、个人官网或下文的接管与锁屏功能；下文能力说明依据独立的工程验收。

## 你的桌面，和 Agent 的桌面

- **各自工作。** 任务获取副桌面，Agent 的点击和输入使用该桌面的控制上下文，
  你可以继续在自己的桌面工作。
- **先看，再接管。** 原生观察视图只读；明确接管后，人的输入进入目标桌面，
  Agent 的控制暂停。
- **需要时请人帮忙。** Agent 可以发出带标题和具体说明的协作请求。你接管、
  完成操作并退出接管；任务明确恢复并获得新授权后继续工作。
- **决定日常锁屏后的行为。** 提前授权、锁前正在运行且配置为 `continue` 的任务，
  可以在仅锁人桌面的日常锁中继续。全会话锁会撤销 Agent 控制；两种锁模式有区别。

已验收源码配对为 Cornice `6ca3a36` 与我们的 Hyprland fork `b18a6b9`：干净默认
复制安装及七组真实隔离运行套件（63 项断言）通过。真实 SDDM 注销重登、物理合盖/
睡眠/唤醒、显示器热插拔与物理输入设备仍未测。各桌面共用同一个 Linux 用户、
文件权限及 GPU/驱动资源，不构成安全容器。Agent 暂不支持向 Xwayland 输入；
应用单实例及多 seat 支持仍有兼容限制。

详见[桌面使用](docs/agent-desktop.md)、[执行器对接](docs/desktop-harness.md)及
[产品边界](docs/agent-desktop-product.md)。上方主片展示全新演示环境中的真实 Pi 调研，
下方保留日常 Shell 的历史图片。

---

## 功能

![日常 Shell](docs/screenshots/desktop.png)

*日常 Shell 历史截图。*

| | |
| --- | --- |
| ![状态栏](docs/screenshots/bar.png) | ![天气面板](docs/screenshots/panel-weather.png) |
| **状态栏** — 工作区、当前窗口、媒体、时钟、指示器、托盘、网络、蓝牙、音频、电量、键盘布局、天气、电源 | **天气** — open-meteo 实时天气与预报（无需 API key）；定位顺序为城市 → 经纬度 → 时区 → IP |
| ![启动器](docs/screenshots/launcher.png) | ![通知中心](docs/screenshots/panel-notifications.png) |
| **启动器** — 桌面条目、实时过滤，`>` 前缀进入命令行模式 | **通知** — 自己持有 `org.freedesktop.Notifications`：弹窗、历史、免打扰、动作按钮、内联回复 |
| ![媒体面板](docs/screenshots/panel-media.png) | ![音频面板](docs/screenshots/panel-audio.png) |
| **媒体** — 封面、进度、播放控制、音量、多播放器切换 | **音频** — 输出/麦克风音量、设备列表 |
| ![OSD](docs/screenshots/osd.png) | ![emoji](docs/screenshots/emoji.png) |
| **OSD** — 音量/麦克风/亮度，跟随硬件按键 | **emoji 选择器** — 可搜索，回车即复制 |
| ![锁屏](docs/screenshots/lock.png) | |
| **锁屏** — 走 PAM，背景用壁纸；账号名默认显示、可关掉 | |

其余功能（不配截图）：

- **菜单** — 栏上一个按钮，用鼠标打开所有东西：应用、剪贴板、表情、通知、栏布局编辑器、主题与壁纸、免打扰、锁屏、电源。它的存在就是为了让任何入口都不依赖记快捷键
- **面板** — 时钟/日历、网络（WiFi 列表与连接）、蓝牙（扫描/配对/连接）、电源（电量、性能模式、会话操作）
- **剪贴板** — 基于 cliphist 的历史：打字过滤、回车复制、图片预览
- **锁屏** — 走 PAM 的 Wayland session lock；锁定时拒绝普通停止和重启，PAM 不可用则拒绝锁屏，并文档化"锁客户端死掉"时的 TTY 应急路径
- **Idle** — dim / 灭屏 / 锁屏，AC 与电池分别配置；睡眠前、`loginctl lock-session`、**合盖**都会锁屏
- **polkit 代理** — 认证对话框就在 shell 里
- **壁纸** — 静态背景层，支持按工作区覆盖；检测到 mpvpaper/hyprpaper/swaybg/swww/wbg 时自动让位
- **主题** — 14 套内置配色（`mono`、`dawn`、Catppuccin Mocha/Latte、Gruvbox Dark/Light、Nord、Tokyo Night、Rosé Pine 与 Rosé Pine Dawn、Everforest Dark、Dracula、Kanagawa、One Dark）；在栏菜单里选，或用 `cornice theme <名称>` 运行时切换
- **IPC** — shell 自带 socket，插件各自持有 target，所有面板都能脚本化

## 依赖

- 独立桌面使用支持 Cornice 的 Hyprland fork，详见[源码配套安装](docs/source-install.md)
- Qt 6 base/declarative（核心图片保存与剪贴板模块），源码构建还需 CMake/Ninja；安装前自行准备系统依赖，源码安装脚本只检查，不调用系统包管理器
- Quickshell —— `sudo pacman -S quickshell`（Arch `extra`）
- `jq`（或 `python3`，用于读插件清单）、`glib2`（监听 logind）、`curl`（天气）、`socat`（CLI 与运行时插件通信）
- 一款 Nerd Font 用于状态栏字形 —— `ttf-nerd-fonts-symbols`
- 可选（按功能）：`grim`（`cornice verify` 截图）、`wpctl`/WirePlumber（音频）、`bluez`（蓝牙）、`brightnessctl`（亮度 OSD）、`cliphist`（剪贴板历史）、`light`（idle dim）、`NetworkManager`（网络面板）

原生截图：`cornice screenshot` 选区，`cornice screenshot screen` 截当前屏幕。保存到系统图片目录的 `Screenshots` 并复制到剪贴板；Esc/右键取消，不打开其他应用。[模块设计](docs/screenshot.md)。

## 安装

多桌面现已在默认 `main` 分支，配合我们的 Hyprland fork 使用。按[源码配套安装](docs/source-install.md)获取准确 ref、依赖、启用和回退步骤，不以上游合并或 AUR 包为前置；默认安装会构建完整 native 桌面及锁定 MCP/browser 依赖。

```bash
git clone --branch main https://github.com/mainliufeng/cornice.git ~/Code/self/cornice
cd ~/Code/self/cornice
./install.sh                 # 软链 CLI 到 ~/.local/bin，顺便体检依赖
```

上面的命令只安装 Cornice，不构建 Hyprland，也不会切换正在运行的合成器。
按配套文档构建 fork 并选择未来登录版本；保存工作后，由你自行正常注销重登。
准备安装文件与切换运行会话是不同步骤。

`./install.sh` 默认安装到用户目录，不会改动合成器配置：

```bash
./install.sh --copy              # 装成自包含的一份到 ~/.local/share/cornice
./install.sh --prefix /usr/local # 换个前缀
./install.sh --takeover          # 顺便从 mako/hypridle/waybar 接管
./install.sh --uninstall         # 只删二进制（配置与状态保留）
make install                     # 等价于 ./install.sh
```

已验证的安装入口是上面的配套源码文档。本次多桌面配对未验收 Arch 整包构建或
AUR 发布；历史打包说明保留在 [docs/aur.md](docs/aur.md)。

在兼容的 Hyprland 会话中运行日常 Shell 时，systemd 用户服务会在它退出后自动恢复：

```bash
./install.sh --service       # 安装并启用 cornice.service（Restart=always）
systemctl --user status cornice
```

`--service` 会先检查依赖并安装全部辅助命令，再启用服务。服务启动路径跟随
`--prefix`；已有用户服务文件会先备份为同目录下的 `cornice.service.backup.*`。
撤回时，将安装输出中提示的备份复制回 `cornice.service`，然后运行
`systemctl --user daemon-reload`。

或者自己在 `~/.config/hypr/hyprland.conf` 加一行：

```conf
exec-once = cornice-launch
```


可选的键位片段在 [`config/snippet.hyprland.conf`](config/snippet.hyprland.conf)，
自己挑着贴。Cornice 不会改你的合成器配置、`~/.config/hypr/*` 或任何系统包。
显式使用 `--service` 时，会按上文安装并备份用户服务文件；
`cornice takeover --apply` 会备份后修改桌面启动配置，并支持
`cornice takeover --undo` 撤回。

### 保留的单桌面旧版

旧 Shell 保留在 [`legacy/single-desktop`](https://github.com/mainliufeng/cornice/tree/legacy/single-desktop)，
可独立安装：

```bash
git clone --branch legacy/single-desktop --single-branch https://github.com/mainliufeng/cornice.git "$HOME/Code/self/cornice-single-desktop"
cd "$HOME/Code/self/cornice-single-desktop"
./install.sh --copy --prefix "$HOME/.local/opt/cornice-single-desktop"
"$HOME/.local/opt/cornice-single-desktop/bin/cornice" help
```

使用该版本的完整 CLI 路径。独立 prefix 分开安装文件，用户配置、状态及
`cornice.service` 仍可能共享。启用 `--service` 会选择共享服务，是另行安排的 Shell 迁移。

## 从旧组件接管

```bash
cornice takeover            # 只出计划：会改什么、为什么
cornice takeover --apply    # 注释掉那些行、停掉对应的 systemd 用户单元
cornice takeover --undo     # 恢复最近一次备份
```

它会找出 cornice 所替代组件的 `exec-once` 行与 systemd 用户单元
（mako/dunst/swaync、hypridle、waybar、polkit 代理），用标记注释掉（**不删除**），
把所有改动过的文件备份到 `~/.local/state/cornice/takeover/<时间戳>/`，
并且不碰 cornice 会协作的东西（cliphist、hyprsunset、mpvpaper/hyprpaper/swaybg）。
之后 `hyprctl reload` 即可。

## 命令

```bash
# 生命周期
cornice start | stop | restart | status | logs | health
cornice launch                       # 前台运行，带看门狗

# 观察运行中的 shell
cornice ping | version | plugins | widgets | targets | socket | path
cornice config | theme [list|toggle|<name>] | reload | reload-plugins
cornice ipc <target> <method> [args] # 原始 IPC，例如 cornice ipc idle status

# 也可以脚本化配置（面板调用的就是这些命令）
cornice bar list | show <id> | hide <id> | move <id> up|down|left|center|right
cornice weather place use <名字> [--city 城市 | --lat 纬度 --lon 经度] | clear
cornice clock zone use <名字> <时区> | clear
cornice language [list|<语言>]

# 绑键用的
cornice launcher | clipboard | emojis | notifications | dnd [on|off]
cornice panel <plugin-id> [json]     # 开关任意面板
cornice osd volume | microphone | brightness | hide
cornice lock [status|try <密码>|emergency-unlock]
cornice background [status|set <路径>|next|prev|clear|reload]

# 机器相关
cornice doctor                       # 依赖、合成器、冲突
cornice verify                       # 检查你正在看的这个 shell
cornice takeover [--apply|--undo]
cornice test [--quick|installer|takeover|headless|lock|install|live]
cornice session-env                  # 输出合成器环境变量（TTY / 过期 shell 用）
```

## 天气地区与时区（各只有一个）

天气只有一个地区、时钟只有一个时区，而且都是**从列表里选**，不用手输：天气面板和
时钟面板各有一个搜索框，输入即筛选真实结果（城市检索；时钟复用同一份检索，因为每个
城市结果都带时区），点一行即设定。

```json
{
  "weather": { "place": { "name": "北京", "latitude": 39.9075, "longitude": 116.39723 } },
  "clock":   { "zone":  { "name": "東京", "timezone": "Asia/Tokyo" } }
}
```

名字来自搜索结果，而搜索是**按当前语言**发出的 —— 所以同一个地方，英文界面下是
`Beijing`，中文界面下是 `北京`。状态栏把它显示在数值前面：天气 `☁ 北京 20°`，
时钟 `東京 00:03`（没配时区时，时钟组件显示本地时间）。

```bash
cornice weather place use "北京" --lat 39.9075 --lon 116.39723   # 也可 --city 北京
cornice weather place clear
cornice clock zone use "東京" Asia/Tokyo
cornice clock zone clear
cornice clock zones            # 列出系统里所有可用时区
```

老配置继续可用：`weather.locations` 或 `clock.worldClocks` 列表会被读取其第一条。
写入有保护：写前备份、解析失败回滚、顶层键变少回滚；并且 CLI 是唯一写入者（面板调用
的就是这些命令，所以点出来的结果和脚本改出来的结果不会不一致）。


## 配置

`~/.config/cornice/config.json` 会深合并到 [`config/default.json`](config/default.json)
之上，所以只写与默认不同的部分即可。数组是替换，对象是合并；
`cornice config` 打印合并后的结果。

| 键 | 默认 | 含义 |
| --- | --- | --- |
| `theme` | `"mono"` | `themes/` 下的任意名称，如 `nord`、`gruvbox-dark`、`catppuccin-latte` |
| `background.enabled` | `true` | 是否绘制壁纸层 |
| `background.dir` | `~/Pictures/wallpapers` | 扫描图片的目录 |
| `background.mode` | `"fill"` | `fill` / `fit` / `stretch` / `center` / `tile` |
| `background.perWorkspace` | `{}` | 按工作区覆盖，如 `{"2": "/path/to.png"}` |
| `background.force` | `false` | 即使 mpvpaper/hyprpaper 在跑也要接管 |
| `notifications.takeover` | `true` | 通知总线名空出来时自动抢回 |
| `notifications.inlineReply` | `true` | 向客户端声明支持内联回复 |
| `weather.city` | `""` | 城市名（走地理编码，优先级最高） |
| `weather.latitude`/`longitude` | `null` | 直接给经纬度 |
| `weather.autoLocate` | `true` | 无 city/经纬度时：先时区、再 IP |
| `weather.useTimezone` | `true` | 时区优先于 IP（开了代理也不会定位到出口节点） |
| `weather.unit` | `"metric"` | `metric` 或 `imperial` |
| `weather.intervalMinutes` | `15` | 刷新间隔 |
| `idle.dimAc` / `dimBattery` | `60` / `0` | 多少秒后 dim 背光 |
| `idle.screenOffAc` / `screenOffBattery` | `120` / `300` | 多少秒后灭屏 |
| `idle.lock` | `300` | 多少秒后锁屏 |
| `idle.lockWarning` | `5` | 自动锁屏前渐暗提示的秒数，鼠标或键盘操作可取消；`0` 关闭提示，手动锁屏／合盖／休眠不延迟 |
| `idle.respectInhibitors` | `false` | 是否也尊重应用的 idle inhibitor |
| `idle.lockOnSleep` | `true` | 睡眠前锁屏 |
| `idle.lockOnLockSignal` | `true` | 收到 `loginctl lock-session` 时锁屏 |
| `idle.lockOnLidClose` | `true` | 合盖锁屏（接了外接屏时跳过） |
| `idle.lockScreenOff` | `10` | 锁屏后多少秒灭屏；锁屏界面有输入会重新计时，`0` 关闭；手动 idle inhibit 不会让已锁屏一直亮 |
| `lock.showUser` | `true` | 锁屏是否显示账号名 |
| `lock.background` | `"wallpaper"` | `wallpaper` / `screenshot` / `none` |
| `lock.blur` / `lock.scrim` | `1.0` / `1.0` | 锁屏背景的模糊与压暗强度 |

`cornice ipc idle inhibit 3600` 可以让 idle 链暂停一小时（下大文件、演示、跑测试），
`cornice ipc idle release` 提前结束。


## 插件

一个插件就是一个带 `manifest.json` 的目录加若干 QML 文件；内置的在
`shell/plugins/`，你自己的放 `~/.config/cornice/plugins/<id>/`。入口点会收到
`host`（shell 本体：`config`、`services`、`summon`、`toggle`）与 `plugin`（清单）；
状态栏 widget 还会收到 `widgetConfig`。

**完整指南：[docs/plugin-api.md](docs/plugin-api.md)** —— 类型、service 模式、
`PanelFrame`、`ShellIpc`、主题规则，以及那些已经踩过的坑。

## 资源占用

用 `./test/benchmark.sh --compare` 在 3072x1920 会话实测（PSS，12 秒窗口，23 个
插件全部加载）：

| 组合 | 内存 | 空闲 CPU |
| --- | --- | --- |
| cornice | ~200 MiB | ~0.1% |
| waybar + mako + hypridle | ~46 MiB | ~0.2% |

cornice 这个进程更大，原因值得直说：它跑的是 Qt Quick 运行时，而且比那三个守护
进程多干了不少活（锁屏、polkit 代理、启动器、剪贴板历史、emoji、通知中心与七个
面板、天气、媒体控制）。同样方法做的归因：

| 组成 | 代价 |
| --- | --- |
| 裸 Quickshell + 1 个 layer surface | 62 MiB |
| 每个额外 layer surface | ~5.5 MiB，且只在可见时 |
| 壁纸层 | ~15 MiB |
| 所有状态栏 widget 合计 | ~1 MiB |
| 其余 | 插件 QML 树、服务单例（PipeWire/BlueZ/NetworkManager/MPRIS/托盘）与字体缓存 |

所以地板是运行时本身，不是泄漏也不是某个插件：我试过把音频/媒体面板改成惰性
加载，实测零收益（隐藏的 surface 不占内存），于是保留"点开即现"。
`./test/benchmark.sh` 可复现这些数字，`--json` 便于脚本消费。

## 测试

```bash
cornice test                 # 全部套件（几分钟）
cornice test --quick         # 只跑快的
./test/install-verify.sh --package   # 全新安装是否真的能用？
```

| 套件 | 覆盖内容 |
| --- | --- |
| `test/headless-verify.sh` | 私有合成器（headless mutter → 嵌套 Hyprland）：启动、全部插件、全部 widget、全部面板、通过 D-Bus 送达通知、内联回复、用本地假 API 测天气、logind 信号、实际绘制 |
| `test/lock-verify.sh` | 私有合成器：锁屏、锁屏时拒绝重启、应急解锁、真实 PAM 栈 + 错密码、logind 锁信号、合盖锁屏 |
| `test/takeover-test.sh` | 沙盒：takeover 的计划/应用/幂等/备份/撤销，含假 systemctl |
| `test/install-verify.sh` | 导出**被跟踪的**树并安装，再对安装后的树跑 headless 套件 —— "全新安装"门禁 |
| `cornice verify` | 你正在看的这个会话 |

headless 套件还需要 `pipewire`、`wpctl` 和 `pw-metadata`。它会启动一个仅含虚拟输出、
不接硬件的私有 PipeWire 服务，检查顶部和底部状态栏的提示延迟、布局稳定、静音与滚轮操作。

插件加载失败、面板打开是空的、takeover 注释错行、全新安装缺文件 —— 这些都会让
套件失败。它们之所以存在，是因为每一种都真的发生过。

## 设计说明

[DESIGN.md](DESIGN.md) 记录了架构决策、与 omarchy/Caelestia 的对比，以及刻意
不做的部分。

[Agent 桌面对接设计](docs/agent-desktop-design.md) 记录多 seat 管理、只读观察、
控制权交接与配套 Hyprland fork 的设计；[桌面使用](docs/agent-desktop.md)及
[执行器对接](docs/desktop-harness.md)说明已实现的桌面与协作工具。
真实登录切换及回退步骤见[源码配套安装](docs/source-install.md)与
[会话选择和恢复](docs/session-trial.md)，真实重登与物理设备的未测边界见上文。

## 许可

MIT —— 见 [LICENSE](LICENSE)。`wallpapers/` 里自带的那张壁纸是本项目生成的
（见 [wallpapers/CREDITS.md](wallpapers/CREDITS.md)）；cornice 不自带任何照片。
