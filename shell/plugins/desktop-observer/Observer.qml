import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root
  readonly property alias window: window
  property var host: null
  property var plugin: null
  property bool isOpen: false
  property string payloadJson: "{}"
  readonly property var payload: { try { return JSON.parse(payloadJson) } catch (e) { return ({}) } }
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  readonly property string desktopName: String(payload.name || "")
  readonly property var desktopState: service ? service.desktops.find(item => item.name === desktopName) || ({}) : ({})
  readonly property bool humanControl: !!frame.item && frame.item.humanControl
  property string selectedWorkspace: "current"
  signal opened()
  signal dismissed()
  function open(json) {
    const next = !json ? "{}" : json
    const changed = next !== payloadJson || !isOpen
    payloadJson = next
    if (changed) selectedWorkspace = "current"
    isOpen = true
    if (service) service.selectedDesktop = desktopName
    if (changed) fitTimer.restart()
    opened()
  }
  function close() {
    if (!isOpen) return
    isOpen = false
    if (service) service.selectedDesktop = ""
    dismissed()
  }
  function takeControl(enabled) { if (frame.item) frame.item.takeControl(enabled) }
  onServiceChanged: if (service && !DesktopSession.agentShell) service.observer = root
  Component.onCompleted: if (service && !DesktopSession.agentShell) service.observer = root
  function fit() {
    if (!frame.item || !window.screen || humanControl || selectedWorkspace !== "current") return
    const scale = window.screen.devicePixelRatio
    frame.item.fit(Math.round(frame.width * scale), Math.round(frame.height * scale), scale)
  }
  Timer { id: fitTimer; interval: 300; onTriggered: root.fit() }
  PanelWindow {
    id: window
    visible: root.isOpen
    color: Color.background
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    focusable: true
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "cornice-desktop"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    Loader {
      focus: true
      id: frame; anchors { top: parent.top; bottom: parent.bottom; left: parent.left; right: parent.right }
      active: root.isOpen && root.service && root.service.available
      source: active ? "NativeView.qml" : ""
      onLoaded: { item.service = root.service; item.desktop = root.desktopName; item.workspace = root.selectedWorkspace; fitTimer.restart() }
    }
    Connections {
      target: frame.item
      function onReturned() { root.close() }
      function onPromptRequested() { if (root.service) root.service.prompt(root.desktopName) }
    }
    Text {
      anchors.centerIn: parent
      visible: !root.service || !root.service.available || frame.status === Loader.Error
      text: frame.status === Loader.Error ? "桌面模块不可用，请安装 Cornice 原生组件" : "Agent 桌面服务不可用"
      color: Color.urgent; font.family: Style.fontFamily; font.pixelSize: Style.fontSize
    }
  }
  Connections {
    target: root
    function onSelectedWorkspaceChanged() { if (frame.item) frame.item.workspace = root.selectedWorkspace }
    function onDesktopNameChanged() { if (frame.item) frame.item.desktop = root.desktopName }
  }
  ShellIpc {
    target: "desktopObserver"
    function status(): string { return JSON.stringify({open: root.isOpen, fullscreen: true, name: root.desktopName, workspace: root.selectedWorkspace, readonly: !root.humanControl, humanControl: root.humanControl, keyboardReady: !!frame.item && frame.item.keyboardReady, paintedFrames: frame.item ? frame.item.paintedFrames : 0, lastPaintMs: frame.item ? frame.item.lastPaintMs : 0, frame: frame.item ? frame.item.metadata : ({}), error: frame.item ? frame.item.error : ""}) }
    function controls(): string {
      const reply = IpcRegistry.dispatch("bar", "geometry", [])
      if (!reply.ok) return "[]"
      const widgets = JSON.parse(reply.result)
      const out = []
      for (const widget of widgets) if (widget.id === "cn.agent-desktop") out.push(...widget.controls || [])
      return JSON.stringify(out)
    }
    function takeover(enabled: string): string { root.takeControl(enabled === "true"); return "requested" }
    function browse(workspace: string): string { if (root.humanControl) return "end-takeover-first"; root.selectedWorkspace = workspace; return "ok" }
    function follow(): string { root.selectedWorkspace = "current"; return "ok" }
  }
}
