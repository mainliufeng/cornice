# 观察模式下的输入法与语音输入

2026-10-10。特性分支已实现并在隔离合成器中验证；当前实体会话的版本与下次登录候选版本分别记录在 session-trial 状态中，安装候选不等于当前会话已更新。

## 行为约定

| 输入位置 | 未接管 | 已接管 |
| --- | --- | --- |
| 被观察桌面的应用 | 不接受人的鼠标、键盘、输入法提交或语音插入 | 接受输入，绑定被接管 seat |
| Cornice 自有 prompt / 搜索框 | 可以输入中文；支持原生编辑目标的控件可以接收语音 | 同样可以输入，不能落到背后的应用 |
| 第三方 StatusNotifier 托盘图标 | 显示，点击和滚动无效，不弹菜单 | 保持原有行为 |
| Cornice 自有 bar 按钮 | 保持可用，写操作遵守各自权限 | 保持可用 |

没有可编辑控件焦点时，F8 显示拒绝提示，不启动录音，也不回退到隐藏的主桌面应用。录音中切换目标或撤销接管会停止录音，保留识别结果；重新插入需要用户明确操作。

## 已确认根因与修复

1. Cornice 原先继承工具包 Fcitx 模块，候选框的显示绕过多 seat 的原生输入上下文。本地 prompt 能提交文字，却看不到候选框。cornice-qs 现在只为自己的 Wayland 进程选择原生 text-input，不改用户环境或 dotfiles。
2. 主 seat 的输入法 relay 监听全局窗口焦点；呈现切换直接改变 SeatManager 的焦点，漏掉输入法通知。所有 seat 现在监听各自真实的 keyboardFocusChange，窗口与 layer 使用同一生命周期。
3. 真实 Chrome 回归重现了切回主桌面后 `你好zhongwen` 的故障。客户端重新 enable 时未先提交 disable，Hyprland 漏掉重新激活输入法。按照 text-input-v3 的 enable 语义重置全部上下文并重新激活，同时拒绝离开焦点的旧编辑器提交。
4. Qt 的 Wayland 输入法在空 preedit 下仍可能保留光标属性，使 inputMethodComposing 为真。prompt 用实际未确认的 preeditText 阻止提交，中文确认后 Ctrl+Enter 和 Escape 恢复正常。
5. 观察模式原先挡掉 F8，语音目标只支持应用窗口，Hyprvoice 首次映射前又没有显示路由。已增加通用本地编辑目标、真实服务注册及物理快捷键路由。

## 职责与边界

**Hyprland** 提供通用 physical-input-target-v2 / input-shortcut-v2，保留 v1 应用窗口接口。目标区分 application 和 local-editor；后者必须是登记的键盘 overlay，具有真实启用的原生文本控件。返回 surface 身份、上下文 revision 与 token，校验焦点、呈现代次、锁屏及授权；密码、敏感字段和正在组成的文字拒绝插入。客户端没有提供 surrounding text 时明确返回不可读，不伪造上下文。接口不包含 Cornice、F8 或 Hyprvoice 的产品名称。

**Cornice Broker** 通过本地连接的 SO_PEERCRED 登记语音服务 PID，在首次窗口映射前安装显示规则；连接断开后在下一次配置更新（最多约一秒）撤销规则。Hyprvoice overlay 不抢键盘焦点。Broker 为额外桌面配置 F8 等物理快捷键及成对释放，自动化按键不会启动人的麦克风。主桌面的正常快捷键配置保持原样；它也登记本地 overlay 输入授权。

**Hyprvoice** 在录音开始绑定真实应用或本地编辑控件。本地控件使用原生编辑状态与受保护快捷键路径，监听输入目标和上下文变化，不把 layer 伪造成窗口，也不回退到 activewindow。显示拒绝原因与写入授权分开。

## 本轮验证

- 真实 Fcitx + GTK、Cornice Qt launcher/prompt、Chrome：中文 preedit、候选框、Space 提交；反复观察桌面后主桌面 GTK 和 Chrome 均继续输入中文。
- 只读 prompt：物理 Super+A、候选未确认时禁止提交、确认后的 Ctrl+Enter、Escape；提交失败保留中文草稿。被观察应用没有写入。
- 接管：原生候选框和 GTK 中文输入绑定额外 seat，主桌面文字不变。
- 真实生产 Hyprvoice App + 私有 PipeWire：录音 UI 首次映射、无编辑器拒绝提示、本地 prompt 语音插入、目标变化停止录音、保留后明确插入、应用目标精确粘贴。测试音源为零音频、识别响应为测试文本，因此不宣称验证了实体麦克风或识别准确率。
- 桌面切换与锁屏权限另由现有隔离集成套件回归。shell 既有验证和新安装验证作为交付门槛。

截图、实际文字及测试日志随部署 receipt 保存。实体会话必须使用同一批 Hyprland、Cornice 和 Hyprvoice，不能只更新其中一个程序。只在现有特性分支交付，不合 main，不增加 dotfiles 脚本。
