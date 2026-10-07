import QtQuick
import qs.Commons
import qs.Ui
PanelFrame {
  id: root
  edge: "center"
  panelWidth: window.screen ? Math.max(500, window.screen.width - 80) : 1100
  panelHeight: window.screen ? Math.max(400, window.screen.height - Style.barHeight - 80) : 650
  takesKeyboard: true
  dismissOnClickAway: false
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  property string selectedWorkspace: "current"
  readonly property string desktopName: String(payload.name || "")
  onOpened: selectedWorkspace = "current"
  Column {
    anchors.fill: parent; anchors.margins: Style.space(1.5); spacing: Style.space(1)
    Row {
      width: parent.width; spacing: Style.space(1)
      Text { text: root.desktopName + " · " + (root.selectedWorkspace === "current" ? "跟随 · 只读" : "浏览 · 只读"); color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: Style.fontSize; anchors.verticalCenter: parent.verticalCenter }
      PanelButton { label: "跟随 agent"; selected: root.selectedWorkspace === "current"; onClicked: root.selectedWorkspace = "current" }
      PanelButton { label: "返回我的桌面"; onClicked: root.close() }
    }
    Row {
      width: parent.width; spacing: Style.space(0.5)
      Text { text: "浏览已有工作区："; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize; anchors.verticalCenter: parent.verticalCenter }
      Repeater {
        model: root.service ? root.service.workspaces : []
        delegate: PanelButton {
          required property var modelData
          label: String(modelData.name || modelData.id)
          selected: root.selectedWorkspace === label
          onClicked: root.selectedWorkspace = label
        }
      }
    }
    Loader {
      id: frame; width: parent.width; height: parent.height - y
      active: root.isOpen && root.service && root.service.available
      source: active ? "NativeView.qml" : ""
      onLoaded: { item.service = root.service; item.desktop = root.desktopName; item.workspace = root.selectedWorkspace }
    }
    Connections {
      target: root
      function onSelectedWorkspaceChanged() { if (frame.item) frame.item.workspace = root.selectedWorkspace }
      function onDesktopNameChanged() { if (frame.item) frame.item.desktop = root.desktopName }
    }
  }
  Text {
    anchors.centerIn: parent
    visible: !root.service || !root.service.available || frame.status === Loader.Error
    text: frame.status === Loader.Error ? "观察模块不可用，请安装 cornice 原生组件" : "Agent 桌面服务不可用"
    color: Color.urgent; font.family: Style.fontFamily; font.pixelSize: Style.fontSize
  }
  ShellIpc {
    target: "desktopObserver"
    function status(): string { return JSON.stringify({open: root.isOpen, name: root.desktopName, workspace: root.selectedWorkspace, readonly: true, paintedFrames: frame.item ? frame.item.paintedFrames : 0, lastPaintMs: frame.item ? frame.item.lastPaintMs : 0, frame: frame.item ? frame.item.metadata : ({}), error: frame.item ? frame.item.error : ""}) }
    function browse(workspace: string): string { root.selectedWorkspace = workspace; return "ok" }
    function follow(): string { root.selectedWorkspace = "current"; return "ok" }
  }
}
