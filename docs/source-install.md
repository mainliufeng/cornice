# 源码配套安装

当前安装方式是我们的 Hyprland fork 与 Cornice 源码配套；多 seat 尚未合入 Hyprland 上游。AUR、发行包和新的会话架构不是本轮前置。以下使用现有 CMake、`install.sh` 和 `session-trial`，不创建第二套同时运行的 compositor。

## 来源与版本

- Cornice：`https://github.com/mainliufeng/cornice.git`，默认 ref `main`；本次已验收固定提交 `6ca3a3620fd6ae6d5ddb24daa1b691a64ac7881a`。
- Hyprland：`https://github.com/mainliufeng/Hyprland.git`，精确提交 `b18a6b98136420efc3838bab6bd4a7f7de02fff7`，所在 ref `codex/cornice-agent-desktop`；tree `cf2b0f15c32f1d168563f7c611da36af625c9c1e`。

Cornice ref 会继续前进。安装前记录解析出的完整提交；重现时 checkout 记录的 SHA，而不是重新解析分支。本次验收清单已记录产物 SHA256、完整安装的 Cornice commit/tree 与编译选项；未有通过记录的组合不能写成已验证。

```sh
# 选择空的源码目录；已有 checkout 先检查分支和未提交修改，不覆盖它。
git clone --branch main https://github.com/mainliufeng/cornice.git cornice
cornice_src=$(realpath cornice)
cornice_commit=6ca3a3620fd6ae6d5ddb24daa1b691a64ac7881a
git -C "$cornice_src" checkout --detach "$cornice_commit"

git clone --branch codex/cornice-agent-desktop https://github.com/mainliufeng/Hyprland.git Hyprland
hyprland_src=$(realpath Hyprland)
git -C "$hyprland_src" checkout --detach b18a6b98136420efc3838bab6bd4a7f7de02fff7
git -C "$hyprland_src" submodule update --init --recursive -- subprojects/udis86 subprojects/hyprland-protocols
printf 'Cornice %s\nHyprland %s\n' "$cornice_commit" "$(git -C "$hyprland_src" rev-parse HEAD)"
```

## 依赖

本轮实测环境是 Arch。脚本会检查依赖或由 CMake 给出缺项；它们不会运行 pacman、替换系统包或自动构建整个 Hyprland 生态。

Cornice 运行需要 Quickshell、Qt6 base/declarative/Wayland/WebSockets、Wayland、xkbcommon、PAM、AT-SPI2/GLib、Node ≥20、Python、jq、socat、curl、util-linux、wf-recorder/ffmpeg。源码构建还需要 C/C++20 工具链、CMake ≥3.25、Ninja、pkgconf、npm 和 wayland-scanner。MCP SDK 与 Playwright MCP 按 `native/agent/package-lock.json` 用 `npm ci --omit=dev --ignore-scripts` 安装；这不安装 Chrome。浏览器操作还需要真实 Chrome/Chromium；音频、网络等可选面板依赖见 README。

这份 Hyprland 源码需要 CMake ≥3.30、C++26 工具链、pkgconf、Python ≥3.12、Lua 5.5、Aquamarine ≥0.15.0、Hyprlang ≥0.6.7、Hyprcursor ≥0.1.7、Hyprutils ≥0.14.0、Hyprgraphics ≥0.5.1、hyprwayland-scanner ≥0.3.10、xkbcommon ≥1.11.0、Wayland server ≥1.22.91、wayland-protocols ≥1.49、libinput ≥1.29；以及 OpenGL/EGL/GLES3、glslang、sdbus-c++ ≥2、hyprwire/scanner、readline、tomlplusplus 和 CMake 列出的 Cairo/Pango/Pixman、DRM/GBM、libei、GLib、re2、muparser、lcms2、libcanberra、XCB 库。X11 应用另需 Xwayland。最低版本以固定提交的 CMake 为准；它的 Lua 候选搜索没有严格保证版本，安装前另检查实际 5.5。

Glaze 未在系统提供时由 CMake 获取 v7.2.0，因此初次配置可能联网；udis86 和 hyprland-protocols 的子模块按提交固定。测试用 Mutter、GTK、xeyes、gtest 不属于普通生产安装依赖。

## 构建与安装

沿用源码安装；默认用户 prefix 是 `$HOME/.local`。需要保留当前工作时先保存，检查目标目录中的已有版本和备份。使用新 out-of-tree 构建目录，不借旧对象文件。

```sh
prefix="$HOME/.local"
hyprland_build="$hyprland_src/build-source-release"
cmake -S "$hyprland_src" -B "$hyprland_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  -DWITH_TESTS=OFF -DWITH_MULTISEAT_TESTS=OFF \
  -DCMAKE_CXX_SCAN_FOR_MODULES=OFF -DPython3_EXECUTABLE=/usr/bin/python3 \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR:PATH=lib \
  '-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib'
cmake --build "$hyprland_build" -j2
cmake --install "$hyprland_build"
export PATH="$prefix/bin:$PATH"
"$cornice_src/install.sh" --copy --prefix "$prefix"
```

Hyprland 的 CMake 安装其实际目标（包括 Hyprland、hyprctl、hyprpm 和资源/文档）到该 prefix；不修改 `/usr/bin/Hyprland` 或系统包数据库，但会覆盖 prefix 中同名文件。Cornice 安装到 `prefix/share/cornice`，CLI 放在 `prefix/bin`。默认完整构建六个 native helpers、`Cornice.Platform`/`Cornice.Desktop` 两组 QML 模块和锁定 npm 依赖；`--desktop` 保留为相同功能的别名。

Cornice 的复制安装使用独立构建根和原子版本树；成功前检查真实动态库与 npm import。失败恢复原复制安装。`install.sh` 不构建或安装 Hyprland。未传 `--service` / `--takeover` 时保持关闭，不启用 systemd 服务、修改登录选择或重启当前桌面。未加 `--copy` 时是开发软链安装，后续源码修改会影响该安装；正式复现建议用这里的复制路径。

## 启用与回退

安装文件不等于运行版本已切换。继续使用现在的受监督登录入口，由用户保存工作后自行正常注销和重新登录；不要由 Agent 自动注销、重启或替换运行中的 compositor。

```sh
"$prefix/bin/cornice" session-trial prepare \
  --hyprland "$prefix/bin/Hyprland" \
  --config "$prefix/share/cornice/config/hyprland.lua"
# 检查准备结果，决定下次登录后再执行下面的选择：
"$prefix/bin/cornice" session-trial select
"$prefix/bin/cornice" session-trial status
```

`prepare` 只封存候选；现有用户 Lua 配置也可显式传入 `--config`，不会原地改它。仓库配置是正常单 compositor 配置，Broker 首次没有持久桌面定义时创建主桌面和 `desktop2`；已有桌面定义保留。主桌面默认不允许 Agent；副桌面需要 harness acquire/resume 后才有输入。受监督入口为副桌面配置日常锁屏继续策略，整会话锁和睡眠仍暂停全部输入。

`select` 会备份并写入现有 SDDM Hyprland 登录 hook，改变下次登录；它不是安装的自动步骤。详见 [session-trial](session-trial.md) 的支持条件、状态与故障回退。取消未来选择用 `session-trial cancel`，移除 hook 用 `session-trial remove-hook`；`session-trial rollback` 会结束受管理会话，因此只在已保存工作、明确需要退出时执行。Cornice 复制安装可用 `install.sh --rollback --prefix "$prefix"` 恢复前一代；手工 Hyprland prefix 安装不具备这个原子回滚，恢复安装前保留的文件或使用既有系统入口。

## 风险和验收边界

- 当前系统 Hyprland 包与运行中的快照是不同身份，不能凭 `pacman -Q` 判断当前 compositor。必须读实际 `/proc/PID/exe`、嵌入修订和哈希。
- `WITH_TESTS=ON` 会给 Hyprland 增加 coverage。测试 binary 的通过记录不能直接当作无 coverage 生产 binary 的验收；两者必须分开标注。
- 两桌面共用 Linux 用户，并非安全容器；应用单实例和不同浏览器 profile、旧 GTK 客户端的动态 seat、输入法与第三方网站登录均有独立约束。应用启动策略在 Cornice 配置中，不靠 Hyprland 产品专用逻辑。
- 所有验证在隔离输入/显示/总线/HOME 和资源限制下进行；没有真实 SDDM 重登、合盖或物理设备验证的项目必须标未测。生产源码配套安装、真实双桌面/剪贴板/接管与 MCP 的最终同候选结果，以新验收记录为准；仅语法、构建或文件存在不能宣称走通。
