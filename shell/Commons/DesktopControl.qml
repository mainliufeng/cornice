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
  entries: (name ? [
    {key:"current-heading",kind:"section",label:"当前桌面操作",detail:service ? service.desktopLabel(name) + " · " + (primary ? description : human ? "人工接管" : "只读观察") : name,enabled:false,target:name},
    {key:"permission",scope:"desktop",target:name,label:"允许 Agent 控制 · " + (state.agentAllowed === true ? "开" : "关"),enabled:service && !service.busy && !state.humanLocked},
    {key:"takeover",scope:"desktop",target:name,label:primary && human ? "人工控制" : human ? "结束接管" : "接管" + (service ? " · " + service.desktopLabel(name) : ""),enabled:!!state.available && (primary ? !human : !!observer)},
    {key:"run",scope:"desktop",target:name,label:state.paused !== false ? "恢复 Agent 输入" : "暂停 Agent 输入",enabled:(!human || primary) && state.agentAllowed === true && !!state.available && service && !service.busy}
  ].filter(item => item.key !== "takeover" || !primary || !human) : []).concat([
    {key:"all-heading",kind:"section",label:"所有桌面",enabled:false},
    {key:"previews",scope:"all",label:service && service.allPreviewsVisible ? "隐藏全部浮动预览" : "显示全部浮动预览",enabled:service && service.previewDesktops.length > 0},
    {key:"manage",scope:"all",label:"桌面管理"}
  ])
  onChosen: key => {
    if (!service) return
    if (key === "permission") service.operate(["allow-agent", name, state.agentAllowed === true ? "off" : "on"])
    else if (key === "takeover" && primary) service.operate(["pause", name])
    else if (key === "takeover" && observer) observer.takeControl(!human)
    else if (key === "run") service.operate([state.paused !== false ? "resume" : "pause", name])
    else if (key === "previews") service.togglePreviews()
    else if (key === "manage") service.host.toggle("cn.agent-desktop", {})
  }
}
