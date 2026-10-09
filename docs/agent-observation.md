# Agent 的观察和操作路线

2026-10-09。浏览器路径已实现；原生应用元素树仍是后续工作。

## 已实现

Agent prompt → Pi 常驻任务循环 → Cornice 桌面扩展 → Broker 的 seat 授权 CDP → Microsoft Playwright MCP → Agent 自己的 Chrome。

- 浏览器先读取 accessibility snapshot（角色、名称、状态、文字、元素引用），用语义点击、填写、键盘和标签页工具操作。操作后读更新的树，避免复用过期元素。
- `desktop_browser_connect` 只连接 Broker 启动的本 Agent 浏览器，复用该桌面的持久 profile。模型不接收 CDP 地址、授权 token，也不能指定人的浏览器端口。
- 使用官方 `@playwright/mcp` 固定版本 **0.0.83** 与 lockfile；不自建浏览器控制器。只公开 13 个浏览器表单/导航工具；代码执行、evaluate、文件工具和网站动态 WebMCP 不开放。
- 人接管、暂停、全会话锁或 generation/seat 改变后旧工具请求被拒绝。明确恢复后重新连接、读取新树，禁止重放不确定动作。Broker 再逐条验证底层 CDP 命令。
- 原生应用与图表等视觉内容仍可截图：PNG 在本机转为**同尺寸 JPEG85**，保留 frameId/pixelSize。单图上限 12 MiB，超限明确报错，绝不缩放后沿用旧坐标。每次模型请求只保留最新桌面图片，历史文字与工具配对保留。
- 每个 run 有独立 cwd 和 Pi 配置目录；只显式加载 `builtin:mcp` 与 Cornice 扩展。MCP 子进程仅继承自己的 seat grant 和私有目录，不继承模型凭证或宿主环境。Pi 死亡时该子进程也被 Linux 终止；任务结束清理短 socket 目录，Chrome/profile 保留。

依赖安装：`npm ci --prefix native/agent --omit=dev --ignore-scripts`。`install.sh --desktop` 会安装锁定依赖，再构建与复制桌面组件。仅安装基础 shell 不会自动安装 Agent 的模型执行器。Pi、Node（>=20）与浏览器需预先提供。

## 本次 413 的原因

此前提示词要求每步截图，执行器将每一张 PNG 带入后续上下文。失败任务的四张 3072×1920 截图共约 63 MiB base64，超过 DeepSeek 的 **48 MiB 请求体限制**；这不同于 token 上限。相同真实截图 JPEG85 约 1.81 MB，像素尺寸不变。仅增大模型 contextWindow 或重启 Magpie 无法修正该累积问题。

## 原生窗口可以成为树，但不能只改 Hyprland

Wayland/Hyprland 能提供窗口、位置、焦点和 seat，控件语义由应用工具包提供。Linux 的成熟接口是 **AT-SPI2**：GTK、Qt 等可暴露控件树、状态与动作；Canvas/自绘内容可能不完整。无需为各工具包重新造一套识别库。

AT-SPI 默认共享同一用户会话的无障碍总线，独立 Wayland seat 不会自动隔离它。PID 只能定位应用，同一进程可能同时含人的窗口和 Agent 的窗口；标题重复也不能当作可靠身份。当前 `desktop.windows` 尚未提供足够的可靠映射，所以本次没有把全局 AT-SPI 树直接交给 Agent。

正确后续工作：由 Hyprland/Broker 提供可信窗口身份和进程信息；在 Broker 内确定唯一的授权顶层窗口，再有界读取其 AT-SPI 子树与事件。歧义时拒绝。语义写入同样验证 seat、generation、控制权和窗口归属；不使用没有 seat 参数的全局 AT-SPI 键鼠模拟。最高风险验收是同一进程跨人/Agent 桌面、同标题多个窗口，仍不串读、不串写。

## Codex 的做法与持续运行

当前本机 Codex 浏览器插件的 `docs/accessibility.md` 明确把 AX 树作为首选，支持元素操作、树差异、批量动作和持久浏览器会话；截图用于视觉验证或树不可用的情况。不能由此推断 Codex 已公开实现 Linux 的多 seat 原生窗口隔离；官方桌面 computer-use 文档列出 macOS/Windows。

持续运行依靠任务循环、持久会话、控制权检查与上下文整理，不要求持续截图。Cornice 当前已有 Pi 任务循环和任务状态，本次接入持久的结构化浏览器工具并移除历史图片累积。Pi 自身支持 token 上限附近的上下文压缩；它不能替代请求体字节控制。跨进程崩溃/重启自动恢复任务是另一能力，本次未实现，不把保留日志称为自动续跑。

## 证据与参考

- [Microsoft Playwright MCP](https://github.com/microsoft/playwright-mcp)：结构化无障碍快照、CDP 接入、工具与配置。实现采用官方库而非复制 Codex 私有内部代码。
- [Playwright connectOverCDP](https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp)；[ARIA snapshots](https://playwright.dev/docs/aria-snapshots)。CDP 比 Playwright 自身协议的功能保真度较低，当前已验证树、填写和点击。
- [AT-SPI Accessible](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/class.Accessible.html)；[GTK 运行配置](https://docs.gtk.org/gtk4/running.html)；[Qt accessibility](https://doc.qt.io/qt-6/qaccessible.html)。
- [Codex 浏览器](https://developers.openai.com/codex/app/browser)；[Codex computer use](https://learn.chatgpt.com/docs/computer-use)；[OpenAI context compaction](https://developers.openai.com/api/docs/guides/compaction)。OpenAI API 的 compaction 与当前 DeepSeek/Pi 执行器是不同接口。
- [DeepSeek vision limits](https://api-docs.deepseek.com/guides/vision/#limits)。

回归入口：`node test/agent-screenshot-verify.ts`、`node test/agent-browser-tools-verify.ts`、`python3 test/agent-runtime-protocol-verify.py`；真实模型与隔离桌面运行 `test/isolated-desktop-test.sh agent-browser-model-verify.py`（需要真实模型配置与 fork）。
