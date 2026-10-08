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
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-desktop"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    Rectangle {
      id: toolbar; anchors { left: parent.left; right: parent.right; top: parent.top }
      height: Style.space(7.5); color: Color.panel
      DesktopSwitcher { id: switches; anchors.left: parent.left; anchors.leftMargin: Style.space(1); anchors.verticalCenter: parent.verticalCenter; compact: false; service: root.service }
      Row {
        anchors.right: parent.right; anchors.rightMargin: Style.space(1); anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(1)
        Text {
          text: root.humanControl ? "你正在操作 · Ctrl+Alt+Esc 结束" : "只看 · " + (root.service ? root.service.stateLabel(root.desktopState) : "连接中")
          color: root.humanControl ? Color.accent : Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize; anchors.verticalCenter: parent.verticalCenter
        }
        PanelButton {
          id: run; label: root.desktopState.agentPaused !== false ? "运行 Agent" : "暂停 Agent"
          enabled: !!root.service && !root.service.busy && !root.humanControl && !!root.desktopState.available
          onClicked: root.service.operate([root.desktopState.agentPaused !== false ? "resume" : "pause", root.desktopName])
        }
        PanelButton {
          id: takeover; label: root.humanControl ? "结束接管" : "接管"; filled: root.humanControl
          enabled: !!frame.item && !!frame.item.metadata.frameId && root.selectedWorkspace === "current" && !!root.desktopState.available
          onClicked: frame.item.takeControl(!root.humanControl)
        }
      }
    }
    Loader {
      id: frame; anchors { top: toolbar.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }
      active: root.isOpen && root.service && root.service.available
      source: active ? "NativeView.qml" : ""
      onLoaded: { item.service = root.service; item.desktop = root.desktopName; item.workspace = root.selectedWorkspace; fitTimer.restart() }
    }
    Connections {
      target: frame.item
      function onReturned() { root.close() }
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
    function status(): string { return JSON.stringify({open: root.isOpen, fullscreen: true, name: root.desktopName, workspace: root.selectedWorkspace, readonly: !root.humanControl, humanControl: root.humanControl, paintedFrames: frame.item ? frame.item.paintedFrames : 0, lastPaintMs: frame.item ? frame.item.lastPaintMs : 0, frame: frame.item ? frame.item.metadata : ({}), error: frame.item ? frame.item.error : ""}) }
    function controls(): string {
      const rows = switches.controls().map(item => Object.assign({}, item, {x: item.x + switches.x, y: switches.y}))
      for (const [name, item] of [["takeover", takeover], ["run", run]]) {
        const point = item.mapToItem(window.contentItem, 0, 0)
        rows.push({name: name, x: point.x, y: point.y, width: item.width, height: item.height, enabled: item.enabled, label: item.label})
      }
      return JSON.stringify(rows)
    }
    function browse(workspace: string): string { if (root.humanControl) return "end-takeover-first"; root.selectedWorkspace = workspace; return "ok" }
    function follow(): string { root.selectedWorkspace = "current"; return "ok" }
  }
}
