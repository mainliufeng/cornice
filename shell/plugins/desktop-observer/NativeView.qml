import QtQuick
import Cornice.Desktop
import qs.Commons
Item {
  id: root
  property var service: null
  property string desktop: ""
  property string workspace: "current"
  readonly property var metadata: view.metadata
  readonly property var paintedFrames: view.paintedFrames
  readonly property var lastPaintMs: view.lastPaintMs
  readonly property string error: view.error
  readonly property bool humanControl: view.humanControl
  signal returned()
  signal promptRequested()
  function takeControl(enabled) { view.takeControl(enabled) }
  function fit(width, height, scale) { view.fit(width, height, scale) }
  WorkspaceView {
    id: view; anchors.fill: parent; focus: true
    socketPath: root.service ? root.service.socketPath : ""
    desktop: root.desktop; workspace: root.workspace
    active: root.visible && root.service && root.service.available
    Keys.onPressed: event => {
      if ((event.modifiers & Qt.MetaModifier) && event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
        DesktopSession.workspace(event.key === Qt.Key_0 ? 10 : event.key - Qt.Key_0)
        event.accepted = true; return
      }
      if (event.key === Qt.Key_A && (event.modifiers & Qt.MetaModifier)) {
        root.promptRequested(); event.accepted = true; return
      }
      if (event.key === Qt.Key_Escape && !view.humanControl) {
        root.returned(); event.accepted = true
      }
    }
  }
  Rectangle {
    anchors.centerIn: parent; width: message.implicitWidth + Style.space(4); height: message.implicitHeight + Style.space(3)
    visible: view.error !== "" || !view.metadata.frameId
    color: Color.panel; radius: Style.radius
    Text { id: message; anchors.centerIn: parent; text: view.error || "正在连接桌面…"; color: view.error !== "" ? Color.urgent : Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.fontSize }
  }
}
