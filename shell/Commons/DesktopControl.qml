import QtQuick
import qs.Commons
DesktopMenu {
  id: root
  objectName: "DesktopControl"
  property var service: null
  readonly property string name: DesktopSession.selected
  readonly property var state: DesktopSession.state
  readonly property var observer: service ? service.observer : null
  readonly property var task: service && service.tasks[name] ? service.tasks[name] : ({phase:"idle"})
  readonly property var phases: ({idle:"尚无任务",starting:"启动中",running:"执行中",interrupted:"控制已中断",waiting:"等待恢复",completed:"已完成",cancelled:"已中止",blocked:"受阻",failed:"执行失败",needs_attention:"需要检查"})
  readonly property bool human: observer && observer.humanControl
  icon: human ? "󰥷" : state.agentPaused !== false ? "󰏤" : "󰐊"
  description: service ? service.stateLabel(state) : "Agent"
  entries: name ? [
    {key:"takeover",label:human ? "结束接管" : "接管",enabled:!!observer && !!state.available},
    {key:"run",label:state.agentPaused !== false ? "运行 Agent" : "暂停 Agent",enabled:!human && !!state.available && service && !service.busy},
    {key:"prompt",label:"新任务 · Super+A",enabled:!human && !!state.available},
    {key:"cancel",label:"中止当前任务"},
    {key:"manage",label:"桌面管理"}
  ].concat([{key:"task-status",label:"任务 · " + (phases[task.phase] || task.phase),enabled:false}]) : [{key:"manage",label:"桌面管理"}]
  onChosen: key => {
    if (!service) return
    if (key === "takeover" && observer) observer.takeControl(!human)
    else if (key === "run") service.operate([state.agentPaused !== false ? "resume" : "pause", name])
    else if (key === "prompt") service.prompt(name)
    else if (key === "cancel") service.cancelTask(name)
    else if (key === "manage") service.host.toggle("cn.agent-desktop", {})
  }
}
