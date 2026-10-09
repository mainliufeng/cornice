import QtQuick
import Cornice.Desktop
import qs.Commons

Item {
  id: root
  property var host: null
  property var plugin: null
  property bool isOpen: false
  property string payloadJson: "{}"
  readonly property var payload: { try { return JSON.parse(payloadJson) } catch (e) { return ({}) } }
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  readonly property string desktopName: String(payload.name || "")
  readonly property var presentationState: presentation.state
  readonly property bool humanControl: presentation.humanControl
  property string selectedWorkspace: "current"
  signal opened()
  signal dismissed()
  function open(json) {
    const next = json || "{}"
    if (next !== payloadJson || !isOpen) selectedWorkspace = "current"
    payloadJson = next; isOpen = true
    if (service) service.selectedDesktop = desktopName
    opened()
  }
  function close() {
    if (!isOpen) return
    isOpen = false
    if (service) service.selectedDesktop = ""
    dismissed()
  }
  function takeControl(enabled) { presentation.takeControl(enabled) }
  function browseWorkspace(workspace) {
    if (humanControl) return "end-takeover-first"
    selectedWorkspace = workspace
    return "ok"
  }
  onServiceChanged: if (service && !DesktopSession.agentShell) service.observer = root
  Component.onCompleted: if (service && !DesktopSession.agentShell) service.observer = root
  DesktopPresentation {
    id: presentation
    active: root.isOpen && root.service && root.service.available
    socketPath: root.service ? root.service.socketPath : ""
    desktop: root.desktopName
    workspace: root.selectedWorkspace
    onReturned: root.close()
  }
  ShellIpc {
    target: "desktopObserver"
    function status(): string {
      return JSON.stringify({open:root.isOpen,native:true,name:root.desktopName,workspace:presentation.state.following ? "current" : presentation.state.workspace || root.selectedWorkspace,
        readonly:!root.humanControl,humanControl:root.humanControl,presentation:presentation.state,error:presentation.error})
    }
    function controls(): string {
      const reply = IpcRegistry.dispatch("bar", "geometry", [])
      if (!reply.ok) return "[]"
      const widgets = JSON.parse(reply.result); const out = []
      for (const widget of widgets) if (widget.id === "cn.agent-desktop") out.push(...widget.controls || [])
      return JSON.stringify(out)
    }
    function takeover(enabled: string): string { root.takeControl(enabled === "true"); return "requested" }
    function browse(workspace: string): string { return root.browseWorkspace(workspace) }
    function follow(): string { if (root.selectedWorkspace === "current") presentation.refreshView(); else root.selectedWorkspace = "current"; return "ok" }
  }
}
