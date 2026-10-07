# cornice — 装上就能用的 Hyprland shell

> 工作名（AUR 空闲）：**cornice**，建筑檐口——屏幕边缘那条横条。
> 备选：`parapet`、`dockhand`、或你定。

设计稿 **v0.2**，P0 已实现并验证（见 README「Status」与 `test/headless-verify.sh`）。

### P0/P1/P2 实测得到的硬约束（写代码前不知道的）

4. **插件里的 IpcHandler 不会被 Quickshell 的 `qs ipc` 看到**：它只枚举静态声明的树。解决方案是 shell 自己起 Unix socket（`services/IpcServer` + `Commons/IpcRegistry` + `ShellIpc` 包装），CLI 走 socat（约 5ms），omarchy 也是这么做的。
5. **Repeater 不能直接挂在 `ShellRoot` 下**：父级不是 Item 时委托根本不会实例化（现象是"count 正确但实例为 0"）。要包一层 `Item`。
6. **delegate 里写 `registry: registry` 会自引用**（组件自身也有同名属性）→ null。用不同 id（`pluginRegistry`）。
7. **不能 `clone()` 持 QObject 的映射**：会遍历 parent/children 直到栈溢出；用浅拷贝。
8. **`IpcHandler`/`ShellIpc` 的函数参数必须带类型**（`string`），否则注册时报 "cannot be used across IPC"。
9. **`Notification.dismiss()` 不能对保存下来的旧引用调用**（包装对象会失效）；要么按 id 从 `trackedNotifications` 里找活动对象，要么只存 id。
10. **keepLoaded 面板必须 `autoOpen: false`**，否则启动瞬间所有面板同时打开。
11. 面板定位：只锚 `left` 并用 `margins.left = (screenWidth - width) / 2`；同时锚 left+right 会把 surface 拉满全宽。

1. **QML 模块命名空间**：多目录模块必须以 `qs.` 前缀导入（`import qs.Commons`），Quickshell 只把配置根注册成 `qs`。自定义前缀（`cn.Commons`）会报 `module ... is not installed`。
2. **`SystemClock` 是要实例化的类型**，不是全局单例；`SystemClock.date` 直接访问得到 `undefined`，必须 `SystemClock { id: clock; precision: SystemClock.Minutes }`。
3. **Headless 验证需要嵌套合成器**：Hyprland 无 `--headless` 后端；用 `mutter --headless` 当父合成器 + `LIBSEAT_BACKEND=noop AQ_DRM_DEVICES=/dev/null` 强制走 Wayland 后端（否则它会打开真实 DRM 节点），再 `hyprctl output create headless` 生成输出。缺了 noop seat 时 Hyprland 会认为会话处于 inactive 而完全不提交帧。

**原有 shell 范围（已确认）**：先做一个**通用**的 Hyprland shell——装得上、跑得稳、用得住。
agent 桌面扩展在独立特性分支实现和验证，见 [agent 桌面对接设计](docs/agent-desktop-design.md)。
该扩展保存在特性分支；[当前实现与测试](docs/agent-desktop.md) 单独记录，不改变 main 的通用 shell 定位。

---

## 1. 定位

**是什么**：用 Quickshell 写的通用 Hyprland shell，一个常驻进程负责 bar、面板、通知、OSD、launcher（之后 lock）。

**不是什么**：

- 不是 dotfiles 合集（Caelestia / HyprPanel 那种：你 clone 下来自己改配置）；
- 不是发行版（omarchy 那种：ISO 装上，它拥有你的 `~/.config/hypr`）；
- 不是 Material 3 复刻（DMS）；
- v1 之前**不做锁屏**（风险最高，见 §5）。

**现在唯一站得住的差异化**：**非侵入（不写你的 hyprland.conf）+ 装完即用（一条 exec-once）+ 打包干净（可 `pacman -R`）**，并且只用一个进程替掉 waybar + mako + swayosd + 一堆菜单脚本。

**市场现状**（本机核实过 Arch 仓库）：

| 项目 | 位置 | 形态 | 我们的空隙 |
| --- | --- | --- | --- |
| waybar + mako + hyprlock | extra | 多进程拼装 | 我们要替代的就是这个 |
| DMS | `extra/dms-shell`（Depends: `quickshell`） | Material 3，有自己的配置 | 审美取向强、绑定 compositor |
| Noctalia | `extra/noctalia` | 原生 C++/Wayland（依赖里无 Qt） | 另一条技术栈，不可定制成 QML |
| Caelestia | AUR | dotfiles 式 | 需要用户接管配置 |
| HyprPanel | `chaotic-aur/ags-hyprpanel-git` | AGS + Astal（GJS） | 另一条技术栈 |
| omarchy shell | 无包（ISO 分发） | 与整个系统共同设计 | 不可单独安装 |

这条空隙**不大但真实**：存在一批"不想被接管、不想改 dotfiles、又想要面板/通知一体化"的用户。够不够撑一个产品？见 §5——**先当成自用工具做，产品化是可加的一步，不是前提**。

---

## 2. 对标 omarchy：它有什么，我们取哪些

实测数字（`omacom/omarchy` branch `quattro` @ `3faafba`）：

| 维度 | Omarchy | 我们 MVP | 我们 v1 | 后续 | 不做 |
| --- | --- | --- | --- | --- | --- |
| bar widget（**21**） | workspaces / active-window / clock / media / audio / microphone / bluetooth / network / battery / tray / indicators / keyboard-layout / weather / monitor / power / tailscale / agents / dropbox / elsewhen / system-update / spacer | workspaces、active-window、clock、audio、mic、battery、network、tray、indicators、media、spacer | bluetooth、weather、power、keyboard-layout | monitor、nightlight、system-update（pacman 版） | dropbox、elsewhen、tailscale |
| panel（**13**） | audio / bluetooth / clock / disk-speedtest / dropbox / elsewhen / monitor / network / power / speedtest / tailscale / weather / wifiqr | clock+calendar | audio、network、bluetooth、power、weather | monitor、image-picker、disk | speedtest、wifiqr、dropbox、elsewhen |
| overlay | clipboard / emojis / image-picker / reminders | — | clipboard（图片预览）、emoji | wallpaper/theme 选择器 | reminders |
| menu | 层级菜单 + 应用库 | — | launcher（应用 + 命令） | 层级菜单 | — |
| service | notifications / battery / idle / media / nightlight / lock / polkit | notifications | battery、mpris | idle、nightlight、polkit | greetd |
| 其他 | 22 套主题、195 条键位、463 个 CLI 命令、39k 行 QML | 2 套内置主题、~10 个 CLI 子命令 | 主题 token、`doctor` | 插件 API、主题生成 | 私有图标字体、uwsm 硬依赖 |

**要借的架构**（这部分 omarchy 做对了）：

1. 单进程 + 插件宿主：扫目录 → 读 `manifest.json` → 注入宿主对象 → 按需加载；
2. `kinds` 六分类：`bar-widget` / `bar` / `panel` / `overlay` / `menu` / `service`；
3. `Commons`（Color/Style/Util/Ipc 单例）+ `Ui`（原子件）分层；
4. **IPC 是 CLI 与 shell 的唯一契约**；
5. 主题是 token 文件，不是散落的硬编码色值。

**不借的**：ISO 分发、接管用户配置、463 命令的耦合面、私有区图标字体作为硬依赖、`OMARCHY_PATH` 的全局假设。

---

## 3. 通用 Hyprland 用户实际要什么（对照现有生态）

| 需求 | 现在用什么 | 我们怎么做 |
| --- | --- | --- |
| 状态栏 | waybar（配置 226 行 + CSS 299 行的量级） | `PanelWindow` + `WlrLayershell.layer=Top`，三段布局，widget 来自配置 |
| 通知 | mako / dunst | `Quickshell.Services.Notifications` 的 `NotificationServer`（**要抢 `org.freedesktop.Notifications` 名**） |
| 音量/亮度 OSD | swayosd | 自绘 panel，数据来自 `Services.Pipewire` + `brightnessctl`/ddcutil |
| 应用启动器 | wofi / rofi / fuzzel | 解析 `.desktop`（抄 omarchy 的 AppLibrary 思路）+ `IpcHandler` 召唤 |
| 剪贴板 | cliphist + wofi 菜单 | overlay 面板，`Services` 无对应模块 → 用 `wl-paste`/`cliphist` 兜底 |
| 音量/网络/蓝牙面板 | 外部菜单脚本 | panel + `Services.Pipewire` / `Networking` / `Bluetooth` |
| 媒体控制 | playerctl + 脚本 | `Services.Mpris` |
| 电池 | waybar 内置 | `Services.UPower` |
| 系统托盘 | waybar 内置 | `Services.SystemTray` |
| 壁纸（含视频） | hyprpaper / **mpvpaper** | 后期做 layer-shell 背景层（视频壁纸需要单独设计，别急着做） |
| 空闲/锁屏 | hypridle / hyprlock | **先留 hypridle**；锁屏推迟到 v1 之后 |
| 截图/录制 | grim / hyprshot | 不做，只提供键位建议 |

---

## 4. 实现方案

### 4.1 仓库结构

```
cornice/
  shell/
    shell.qml                 # ShellRoot：唯一宿主
    Commons/  qmldir          # module cn.Commons: Color / Style / Util / Ipc / Theme
    Ui/       qmldir          # module cn.Ui: Button / Panel / Dropdown / Toggle / BorderSurface …
    services/                 # PluginRegistry / BarWidgetRegistry / AppLibrary / ConfigLoader
    plugins/
      bar/                    # kind: bar（含 widgets/）
      notifications/          # kind: service
      clock/ audio/ network/ bluetooth/ power/ weather/   # panel + bar-widget
      clipboard/ emojis/      # overlay
      menu/                   # menu + bar-widget
  bin/
    cornice                   # CLI: ping / summon / hide / config / theme / plugin / doctor
    cornice-launch            # 看护式启动，日志进 journal
    cornice-restart
    cornice-doctor            # 依赖 / 冲突 / 环境自检
  config/
    default.json              # 出厂默认（bar 布局、启用插件）
    snippet.hyprland.conf     # 给用户复制的那两行，绝不自动写入
  themes/<name>/{colors.toml,shell.toml}
  test/
  docs/
  packaging/
    PKGBUILD                  # v1 目标
    install.sh                # git clone 路径的安装器
```

### 4.2 运行时与看护

- `hyprland.conf` 只加**一行**：`exec-once = cornice-launch`
- `cornice-launch`：`systemd-cat -t cornice -- quickshell -n -p <prefix>/shell`，带看护重启（1 分钟内超过 5 次就放弃）+ `hyprctl monitors` 探活后重启（这两个手法 omarchy 是对的，直接抄）。
- **没有锁屏之前，任何路径都不会让用户被锁在门外。**

### 4.3 插件宿主（简化版 PluginRegistry）

- manifest：`{schemaVersion, id, name, version, kinds, entryPoints, keepLoaded?}`；
- 扫内置 `<prefix>/shell/plugins` 与用户 `~/.config/cornice/plugins/<id>`；
- 生命周期：`service` 常驻；`panel/overlay/menu` 实现 `open(payload)/close()`；`keepLoaded` 常驻；
- 注入 `host` + `manifest` + registries；
- **v1 不做 facade 沙箱**（omarchy 自己也承认那不是沙箱）：改为文档明说"插件是同进程代码"，安装前提示。
- 热重载：`inotifywait` 只盯用户插件目录。

### 4.4 配置

`~/.config/cornice/config.json`（JSONC），**与 omarchy 相反：做 schema 校验 + 默认值深合并**，用户只写差异：

```jsonc
{
  "version": 1,
  "bar": {
    "position": "top", "transparent": false, "height": 30,
    "layout": {
      "left":   [{ "id": "cn.workspaces" }, { "id": "cn.active-window" }],
      "center": [{ "id": "cn.clock", "format": "HH:mm" }],
      "right":  [{ "id": "cn.network" }, { "id": "cn.audio" }, { "id": "cn.battery" }]
    }
  }
}
```

栏编辑器以左、中、右三列对应实际栏的位置，拖动可跨列移动或调整顺序，底部单独显示隐藏组件。每行只留一个菜单入口，提供位置选择、上下移动和隐藏操作。跨区移动保留该组件的完整选项，保存时保留 `config.json.previous` 以便回退。

#### 当前工作区窗口切换（owner 已确认）

- 在现有 active-window 栏组件内，工作区数字后常驻显示当前工作区的窗口图标，再显示当前标题；不要求重写用户栏配置。
- 一窗口一图标；焦点高亮，顺序稳定，新窗口追加。悬停只显示应用名与完整标题，单击聚焦该窗口，不跨工作区。
- 点击图标不移动光标；工作区处于最大化或全屏时，将当前显示模式保留到目标窗口，不退出该模式，不永久改动桌面的聚焦设置。
- 按左侧实际剩余空间缩短标题；图标过多时保留可见图标与“+数量”按钮。点击按钮打开可滚动的完整标题列表，悬停不展开。
- showWindows=false 可恢复仅标题显示；不新增关闭、移动、最小化或快捷键操作。

### 4.5 主题

`Color` / `Style` 单例是 token 的**唯一出口**（QML 里禁止硬编码色值）。来源优先级：用户 `~/.config/cornice/theme.toml` → 内置预设（先做 2 套）→ 后期加"跟随壁纸生成（matugen/wallust，可选依赖）"。

### 4.6 不碰用户配置（产品化的核心约束）

- 只提供 `config/snippet.hyprland.conf`（exec-once 一行 + 建议键位）让人自己贴；
- `cornice doctor` 检查：quickshell 版本、Nerd Font（本机已有 Hack Nerd Font；缺失时降级为文字/emoji）、`waybar`/`mako`/`dunst`/`hyprlock`/`swayosd` 是否在跑、`org.freedesktop.Notifications` 的 owner 是谁、Hyprland 版本、配置语法；
- `cornice takeover [bar|notifications]` 是**显式命令**，打印它做了什么，支持 `--undo`。

### 4.7 数据与服务（已核实 Quickshell 0.3.1 里有什么）

本机核实：`extra/quickshell 0.3.1` 提供 12 个顶层模块（`Wayland`/`WindowManager`/`Hyprland`/`I3`/`X11`/`Services`/`Widgets`/`Io`/`Networking`/`Bluetooth`/`DBusMenu`/`_Window`），`Services` 下 8 个（`Notifications`/`Pam`/`Pipewire`/`Polkit`/`Mpris`/`UPower`/`SystemTray`/`Greetd`）。

因此：workspaces/窗口 = `Quickshell.Hyprland`；音频 = `Services.Pipewire`；网络 = `Quickshell.Networking`（NetworkManager）；蓝牙 = `Quickshell.Bluetooth`；电池 = `Services.UPower`；媒体 = `Services.Mpris`；托盘 = `Services.SystemTray`；通知 = `Services.Notifications`。
**缺口**：亮度/剪贴板/壁纸没有现成模块 → 走 `brightnessctl`/`ddcutil`、`cliphist`/`wl-paste`、layer-shell 背景层。

### 4.8 IPC 与 CLI

先只用 Quickshell 原生 `IpcHandler`（`qs ipc`）。**不要一开始就抄 omarchy 的 Unix socket 快路径**——那是为了高频键位调用把 45ms 压到 5ms 的优化，等真成为问题再做。

CLI 契约：`cornice <target> <method> [args...]`，`shell` target 提供 `ping / summon / hide / toggle / reloadConfig / listPlugins / setPluginEnabled`。

### 4.9 测试

- `qmllint` + Qt Quick Test（纯函数与小组件）；
- headless smoke：`WLR_BACKENDS=headless` 起 shell → `cornice shell ping` → 退出（omarchy 的 `test/shell.d/*.sh` 用假 IPC 驱动真 QML，值得抄）；
- 数据 fixture 用你现有的 `waybar-codex.sh` 输出、`nmcli` 输出样本等。

### 4.10 阶段与验收

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| **P0** 骨架（1–2 天） | 仓库、`shell.qml`、Commons/Ui 最小集、bar 画出来（workspaces + clock + battery）、`cornice launch/restart/ping` | 与 waybar 并存可切换，无崩溃，**没有写用户任何配置** |
| **P1** bar 可用（3–5 天） | active-window、audio、network、tray、indicators、配置深合并、doctor、2 套主题 | 关掉 waybar 用一整天不出问题 |
| **P2** 一体化（1 周） | notifications 服务、clock/audio/network/bluetooth/power 面板、OSD | 关掉 mako + swayosd，一天不用碰命令行 |
| **P3** 产品化（1–2 周） | launcher、clipboard overlay、`install.sh`/PKGBUILD、首次运行向导、docs、冲突处理 | **在一台干净的 Hyprland 上按文档装完能用** |
| **P4** 可选 | 锁屏、polkit、壁纸（含视频）、插件 API 文档、agent 类插件 | — |

---

## 5. 「装完就能用」要过的六关

| # | 关卡 | 方案 | 难度 |
| --- | --- | --- | --- |
| 1 | 不碰用户 dotfiles | snippet + doctor + 显式 `takeover --undo` | 中（设计问题） |
| 2 | 字体/图标无硬依赖 | 只用 Nerd Font 通用字形，缺失降级 | 低但易翻车 |
| 3 | 冲突检测 | 通知总线只能一个 owner；session lock 只能一个持有者；waybar/mako/dunst/swayosd 是否在跑 | 中 |
| 4 | 首次运行向导 | bar 位置、主题、启用哪些 widget、探测已有工具 | 中 |
| 5 | 升级模型 | 锁最低 quickshell 版本（在 extra 0.3.1 上开发）；AUR + git 自更新两条路；上游 API 变动自己消化（omarchy 用 `migrations/` 扛） | 中，长期 |
| 6 | 支持成本 | `cornice doctor --dump` 一键诊断、docs、issue 模板 | 中 |

**三个真实技术风险**（提前认账）：

1. **quickshell 0.x**：API 会变（omarchy 的 migrations 里有两条就是在处理 `quickshell` ↔ `quickshell-git` 的切换）。对策：锁最低版本 + 只用一个进程 + 保持 QML 里对 API 的接触面小。
2. **锁屏**：Wayland session lock 一旦做错（PAM 未就绪就上锁），用户会被困在 failsafe 后面。对策：P4 才做，且在此之前 shell 完全不碰 lock。
3. **通知总线**：`org.freedesktop.Notifications` 同时只能有一个 owner，抢占会影响现有 mako 用户。对策：显式 takeover + 检测 + 明确报错。

**许可**：我们 MIT；Quickshell 是 LGPL-3.0 的独立进程，不构成链接问题；若 vendored omarchy 的 QML（MIT），保留声明。图标只用 Nerd Font 与系统字体，不自带私有字体（避免字体授权与安装问题）。

---

## 6. 待拍板（4 件事）

1. **名字**：`cornice`（AUR 空闲，GitHub 也空）/ `parapet` / `dockhand` / 你定。目录暂用 `~/Code/self/cornice`。
2. **定位**：个人自用工具，还是对外产品？——只影响 P3（安装器/向导/文档）要不要做；**P0–P2 两种定位完全一样**，可以先开工再决定。
3. **视觉方向**：这决定"为什么不直接用 DMS"。需要一个明确取向，候选：极简零圆角高信息密度（omarchy 风）/ 跟随终端主题（跟你现在的 `palette.sh`、终端配色联动）/ Material 3 式（那就和 DMS 撞了）。
4. **第一个停止点**：P1（替换 waybar 就停）还是 P2（连通知和 OSD 一起替换）？

我的建议：1 用 `cornice`；2 先按"自用工具"做，P2 之后再决定是否产品化；3 先做**极简零圆角**一套 + 主题可换；4 直接做到 **P2**——只替换 bar 的话，收益不足以证明这个投入。
