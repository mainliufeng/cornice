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
  readonly property bool primary: state.primary === true
  readonly property bool human: primary ? state.controlMode === "human" : observer && observer.humanControl
  readonly property string submissionError: service ? String(service.submissionErrors[name] || "") : ""
  readonly property string taskIssue: service && service.taskError ? service.taskError : submissionError || (["failed","needs_attention","blocked"].includes(task.phase) ? String(task.message || "任务未能执行，请检查任务状态。") : "")
  alert:taskIssue !== ""
  icon: human ? "󰥷" : state.agentPaused !== false ? "󰏤" : "󰐊"
  description: service ? service.stateLabel(state) : "Agent"
  entries: name ? [
    {key:"permission",label:"允许 Agent 控制 · " + (state.agentAllowed === true ? "开" : "关"),enabled:service && !service.busy && !state.humanLocked},
    {key:"takeover",label:primary && human ? "人工控制" : human ? "结束接管" : "接管",enabled:!!state.available && (primary ? !human : !!observer)},
    {key:"run",label:state.agentPaused !== false ? "运行 Agent" : "暂停 Agent",enabled:(!human || primary) && state.agentAllowed === true && !!state.available && service && !service.busy},
    {key:"prompt",label:"新任务 · Super+A",enabled:state.agentAllowed === true && (!human || primary) && !!state.available},
    {key:"cancel",label:"中止当前任务"},
    {key:"manage",label:"桌面管理"}
  ].concat([{key:"task-status",label:service && service.taskError ? "任务 · 状态读取失败" : submissionError ? "任务 · 未能启动" : "任务 · " + (phases[task.phase] || task.phase),detail:taskIssue,alert:taskIssue !== "",enabled:false}]) : [{key:"manage",label:"桌面管理"}]
  onChosen: key => {
    if (!service) return
    if (key === "permission") service.operate(["allow-agent", name, state.agentAllowed === true ? "off" : "on"])
    else if (key === "takeover" && primary) service.operate(["pause", name])
    else if (key === "takeover" && observer) observer.takeControl(!human)
    else if (key === "run") service.operate([state.agentPaused !== false ? "resume" : "pause", name])
    else if (key === "prompt") service.prompt(name)
    else if (key === "cancel") service.cancelTask(name)
    else if (key === "manage") service.host.toggle("cn.agent-desktop", {})
  }
}
