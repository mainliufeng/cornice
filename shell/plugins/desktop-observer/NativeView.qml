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
  WorkspaceView { id: view; anchors.fill: parent; socketPath: root.service ? root.service.socketPath : ""; desktop: root.desktop; workspace: root.workspace; active: root.visible && root.service && root.service.available }
  Text {
    anchors.top: parent.top; anchors.left: parent.left; anchors.margins: Style.space(1)
    text: view.error !== "" ? view.error : "正在看 WS " + (view.metadata.viewWorkspace || "?") + " · agent 在 WS " + (view.metadata.workspace || "?")
    color: view.error !== "" ? Color.urgent : Color.foreground
    font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize
  }
  // Consume interaction locally. No target input channel exists in this view.
  MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: wheel => wheel.accepted = true }
}
