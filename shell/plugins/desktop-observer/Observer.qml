import QtQuick
import Quickshell.Hyprland
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
  readonly property var presentationState: presentation.item ? presentation.item.state : ({})
  readonly property bool humanControl: presentation.item ? presentation.item.humanControl : false
  property string selectedWorkspace: "current"
  signal opened()
  signal dismissed()
  function open(json) {
    if (!service || !service.available) return
    const next = json || "{}"
    if (next !== payloadJson || !isOpen) {clearTakeoverIntent();selectedWorkspace = "current"}
    payloadJson = next; isOpen = true
    if (service) service.selectedDesktop = desktopName
    opened()
  }
  function close() {
    clearTakeoverIntent()
    if (!isOpen) return
    isOpen = false
    if (service) service.selectedDesktop = "main"
    dismissed()
  }
  property bool requestedTakeover: false
  property string requestedRequestId: ""
  property string requestedDesktop: ""
  function follow() { if (selectedWorkspace === "current") { if (presentation.item) presentation.item.refreshView() } else selectedWorkspace = "current"; return "ok" }
  function clearTakeoverIntent() {
    requestedTakeover=false;requestedRequestId="";requestedDesktop=""
  }
  function takeControl(enabled, requestId) {
    clearTakeoverIntent()
    if (enabled) {requestedTakeover=true;requestedRequestId=requestId || "";requestedDesktop=desktopName}
    if (presentation.item) {if(enabled && requestId) presentation.item.takeHandoff(requestId);else presentation.item.takeControl(enabled)}
  }
  function confirmTakeover() {
    if (!requestedTakeover || requestedDesktop !== desktopName || !presentation.item) return
    const state=presentation.item.state
    if (state.active === true && state.name === requestedDesktop && state.humanControl === true) clearTakeoverIntent()
  }
  function viewTargetChanged() {
    clearTakeoverIntent()
    if (presentation.item) presentation.item.desktop=desktopName
  }
  function returnedFromView() {
    const takeover=requestedTakeover && requestedDesktop === desktopName
    if (isOpen && service && presentation.item && presentation.item.error) service.reportViewError(desktopName,presentation.item.error,takeover,takeover ? requestedRequestId : "")
    clearTakeoverIntent();close()
  }
  function browseWorkspace(workspace) {
    if (humanControl) return "end-takeover-first"
    selectedWorkspace = workspace
    return "ok"
  }
  onServiceChanged: if (service && !DesktopSession.agentShell) service.observer = root
  Component.onCompleted: if (service && !DesktopSession.agentShell) service.observer = root
  // Ordinary Cornice installs do not include the optional native module.
  // Load this control object only when its real desktop service is available.
  Loader {
    id: presentation
    active: root.isOpen && root.service && root.service.available
    source: active ? "Presentation.qml" : ""
    onLoaded: {
      item.socketPath = root.service.socketPath
      item.desktop = root.desktopName
      item.workspace = root.selectedWorkspace
      item.active = true
    }
    onStatusChanged: if (status === Loader.Error) {
      if (root.service) root.service.reportViewError(root.desktopName,"无法加载桌面控制组件，请检查 Cornice 的原生模块安装。",false)
      root.close()
    }
  }
  Loader {
    id:previews
    active: !DesktopSession.agentShell && !!root.service && root.service.available
    source: active ? "PreviewShelf.qml" : ""
    onLoaded:item.service = root.service
  }
  Loader {
    // Service failure is itself a notice; its UI must outlive availability.
    active:!!root.service && root.service.enabled
    source:active ? "Cooperation.qml" : ""
    onLoaded:item.service=root.service
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.isOpen || !presentation.item) return
      if ((event.name === "seatworkspace" || event.name === "seatpresentation") && event.data.split(",")[0] === root.desktopName)
        presentation.item.refreshStatus()
    }
  }
  Connections {
    target: presentation.item
    function onReturned() { root.returnedFromView() }
    function onStateChanged() { root.confirmTakeover() }
  }
  Connections {
    target: root
    function onSelectedWorkspaceChanged() { if (presentation.item) presentation.item.workspace = root.selectedWorkspace }
    function onDesktopNameChanged() { root.viewTargetChanged() }
    function onServiceChanged() { if (presentation.item) presentation.item.socketPath = root.service ? root.service.socketPath : "" }
  }
  ShellIpc {
    target: "desktopObserver"
    function status(): string {
      return JSON.stringify({open:root.isOpen,native:true,name:root.desktopName,workspace:root.presentationState.following ? "current" : root.presentationState.workspace || root.selectedWorkspace,
        readonly:!root.humanControl,humanControl:root.humanControl,presentation:root.presentationState,error:presentation.item ? presentation.item.error : ""})
    }
    function controls(): string {
      const reply = IpcRegistry.dispatch("bar", "geometry", [])
      if (!reply.ok) return "[]"
      const widgets = JSON.parse(reply.result); const out = []
      for (const widget of widgets) if (widget.id === "cn.agent-desktop") out.push(...widget.controls || [])
      return JSON.stringify(out)
    }
    function actionResult(json: string): string { return root.service ? root.service.acceptActionResult(json) : "service-unavailable" }
    function takeover(enabled: string): string { root.takeControl(enabled === "true"); return "requested" }
    function browse(workspace: string): string { return root.browseWorkspace(workspace) }
    function follow(): string { return root.follow() }
  }
}
