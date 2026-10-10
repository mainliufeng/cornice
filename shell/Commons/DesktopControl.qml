import QtQuick
import qs.Commons
DesktopMenu {
  id: root
  objectName: "DesktopControl"
  property var service: null
  readonly property string name: DesktopSession.selected
  readonly property var state: DesktopSession.state
  readonly property var observer: service ? service.observer : null
  readonly property bool primary: state.primary === true
  readonly property bool human: primary ? state.controlMode === "human" : observer && observer.humanControl
  icon: human ? "󰥷" : state.paused !== false ? "󰏤" : "󰐊"
  description: service ? service.stateLabel(state) : "桌面"
  entries: name ? [
    {key:"state",label:description,enabled:false},
    {key:"permission",label:"允许 Agent 控制 · " + (state.agentAllowed === true ? "开" : "关"),enabled:service && !service.busy && !state.humanLocked},
    {key:"takeover",label:primary && human ? "人工控制" : human ? "结束接管" : "接管",enabled:!!state.available && (primary ? !human : !!observer)},
    {key:"run",label:state.paused !== false ? "恢复 Agent 输入" : "暂停 Agent 输入",enabled:(!human || primary) && state.agentAllowed === true && !!state.available && service && !service.busy},
    {key:"previews",label:"显示浮动预览"},
    {key:"manage",label:"桌面管理"}
  ].filter(item => item.key !== "takeover" || !primary || !human) : [{key:"manage",label:"桌面管理"}]
  onChosen: key => {
    if (!service) return
    if (key === "permission") service.operate(["allow-agent", name, state.agentAllowed === true ? "off" : "on"])
    else if (key === "takeover" && primary) service.operate(["pause", name])
    else if (key === "takeover" && observer) observer.takeControl(!human)
    else if (key === "run") service.operate([state.paused !== false ? "resume" : "pause", name])
    else if (key === "previews") service.restorePreviews()
    else if (key === "manage") service.host.toggle("cn.agent-desktop", {})
  }
}
