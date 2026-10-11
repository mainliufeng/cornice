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
  readonly property bool human: state.controlMode === "human"
  readonly property var presentation: service ? service.presentationFor(state) : ({})
  readonly property bool browsing: !primary && !human && presentation.active === true && presentation.following === false
  icon: human ? "󰥷" : state.paused !== false ? "󰏤" : "󰐊"
  description: service ? service.stateLabel(state) : "桌面"
  entries: (name ? [
    {key:"current-heading",kind:"section",label:"当前桌面操作",detail:service ? service.desktopLabel(name) + " · " + (primary ? description : service.viewDescription(state)) : name,enabled:false,target:name},
    {key:"permission",icon:"󰒃",scope:"desktop",target:name,label:"允许 Agent 控制",checked:state.agentAllowed === true,detail:primary ? "仅授权 Cornice 桌面工具；所有桌面仍共享系统用户和文件权限。" : "授权此桌面的 Cornice 输入与浏览器控制。",enabled:service && !service.busy && !state.humanLocked},
    {key:"takeover",icon:"󰥷",scope:"desktop",target:name,label:primary && human ? "人工控制" : human ? "结束接管" : "接管" + (service ? " · " + service.desktopLabel(name) : ""),enabled:!!state.available && service && service.available && (primary ? !human : DesktopSession.agentShell || !!observer)},
    {key:"follow",icon:"󰑓",scope:"desktop",target:name,label:"恢复跟随 Agent",detail:"结束自由浏览，显示 Agent 当前工作区。",enabled:!!service && service.available,visible:browsing},
    {key:"run",icon:state.paused !== false ? "󰐊" : "󰏤",scope:"desktop",target:name,label:state.paused !== false ? "恢复 Agent 输入" : "暂停 Agent 输入",detail:"暂停仅撤销桌面输入与浏览器控制；后台应用和 Agent 任务仍可能运行。",enabled:(!human || primary) && state.agentAllowed === true && !!state.available && service && !service.busy}
  ].filter(item => item.visible !== false && (item.key !== "takeover" || !primary || !human)) : []).concat([
    {key:"all-heading",kind:"section",label:"所有桌面",enabled:false},
    {key:"preview-mode",icon:"󰐃",scope:"all",label:"始终显示预览",checked:service && service.alwaysShowPreviews,keepOpen:true,enabled:service && !service.previewModeBusy},
    {key:"previews",icon:"󰍹",scope:"all",label:service && service.allPreviewsVisible ? "隐藏全部浮动预览" : "显示全部浮动预览",enabled:service && service.previewDesktops.length > 0},
    {key:"manage",icon:"󰒓",scope:"all",label:"桌面管理"}
  ])
  onChosen: key => {
    if (!service) return
    if (key === "permission") service.operate(["allow-agent", name, state.agentAllowed === true ? "off" : "on"])
    else if (key === "takeover" && primary) service.operate(["pause", name])
    else if (key === "takeover") service.toggleTakeover(name,!human)
    else if (key === "follow") service.follow()
    else if (key === "run") service.operate([state.paused !== false ? "resume" : "pause", name])
    else if (key === "preview-mode") service.setPreviewMode(!service.alwaysShowPreviews)
    else if (key === "previews") service.togglePreviews()
    else if (key === "manage") service.host.toggle("cn.agent-desktop", {})
  }
}
