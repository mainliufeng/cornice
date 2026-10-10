# 桌面的观察和操作路线

外部 Harness（Codex、Pi 等）→ Cornice MCP → Desktop Broker → 该任务拥有的桌面。Cornice 不含模型执行器或任务输入框；持续执行、压缩上下文和任务历史由 Harness 负责。

## 浏览器

`desktop_browser_connect` 通过 Broker 连接该桌面自己的 Chrome，复用其独立 profile。官方固定版本 `@playwright/mcp` 提供无障碍快照、元素引用和语义点击/填写；先读取新树，再操作。截图用于图表及视觉验证。模型不接收全局 CDP 地址或私有控制 token。

人接管、暂停、锁定、权限变化或生命周期改变会使旧操作授权失效；不能重放不确定动作。Browser 与 native 工具都携带 `desktop_acquire` 返回的任务桌面引用。

## 原生应用

Wayland/Hyprland 提供窗口身份、位置、焦点和 seat；GTK/Qt 等应用通过 AT-SPI 提供控件语义。读取前必须将 AT-SPI 顶层窗口可靠映射到当前授权的实际窗口，不能凭全局焦点或重复标题跨桌面读取。同进程、多窗口或映射歧义应明确拒绝。

Canvas、自绘应用等可能无法提供完整语义树；真实截图仍是这些内容的观察方式。截图在本机转为同尺寸 JPEG85，保留真实 `frameId` 和坐标尺寸，超限明确报错。Pi 扩展仅在发往模型的历史上下文中保留最新桌面图片，已有文字与工具配对保持不变。

## 安装和验证

`install.sh --desktop` 安装锁定的 MCP/Playwright 依赖并构建桌面组件及原生 accessibility helper。原生树构建依赖 `at-spi2-core`；无需 Cornice 模型配置或内置 Pi 线程。Harness 按 [desktop-harness.md](desktop-harness.md) 安装插件。

回归入口为 `test/desktop-acquire-verify.py`、`test/desktop-harness-verify.py`、`test/mcp-transport-verify.mjs`、`test/agent-screenshot-verify.ts` 和相应原生无障碍测试。GTK、Chrome、workspace、接管、IME、锁定和安装测试在隔离会话中运行。

参考：[Playwright MCP](https://github.com/microsoft/playwright-mcp)、[ARIA snapshots](https://playwright.dev/docs/aria-snapshots)、[AT-SPI Accessible](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/class.Accessible.html)、[GTK accessibility](https://docs.gtk.org/gtk4/running.html)、[Qt accessibility](https://doc.qt.io/qt-6/qaccessible.html)。
