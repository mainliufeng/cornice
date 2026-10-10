# 观察、接管与输入边界

| 场景 | 只读观察 | 接管 |
| --- | --- | --- |
| 被观察应用 | 禁止键盘、鼠标写入、输入法及语音插入 | 原生输入路由到该桌面实际聚焦的应用 |
| Cornice 桌面管理控件 | 可以选桌面、切换观察工作区、管理预览及接管 | 同样可操作 |
| 第三方系统托盘项 | 禁止点击打开应用或执行菜单动作 | 可执行普通托盘动作 |

内置任务输入框、提交快捷键及专属语音/输入法适配已经移除。外部 Harness 管理自己的任务输入，Cornice 不提供任务编辑器。

Cornice 的普通 launcher/search 控件仍保留正常输入法功能。启动 shell 时使用原生 Wayland text-input，不修改用户环境或 dotfiles。观察者返回主桌面或进入接管时，输入法目标必须跟随实际获得键盘输入的 seat；观察到的应用不因管理 UI 交互获得输入。

Hyprvoice 是独立普通应用，原有人的语音快捷键保留。录音及最终插入校验真实应用目标、seat、上下文和权限，不回退到全局 activewindow。Cornice 不再接受语音编辑内置 prompt，也不配置识别模型或启动语音执行器。

真实 GTK、Chrome 和普通 Cornice launcher 的中文输入由 `test/ime-session-verify.py` 覆盖。正常 Hyprvoice 应用目标校验由 `test/voice-seat-verify.py` 与 `test/voice-session-verify.py` 覆盖；其中私有 PipeWire 零音源和合成识别响应只验证应用生命周期与路由，不代表实体麦克风或识别准确率。
