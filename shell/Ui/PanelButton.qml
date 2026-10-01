import QtQuick
import qs.Commons

// A readable, keyboard-operable action for the larger information panels.
Rectangle {
  id: root
  property string label: ""
  property string glyph: ""
  property bool filled: false
  property bool selected: false
  property bool destructive: false
  signal clicked()
  implicitWidth: content.implicitWidth + Style.space(3)
  implicitHeight: Style.space(5.5)
  radius: Style.radius
  color: root.destructive ? Color.urgent : root.selected ? Color.workspaceActive : hit.containsMouse ? Color.hover : filled ? Color.surface : "transparent"
  opacity: enabled ? 1 : 0.45
  border.width: activeFocus ? 1 : 0
  border.color: Color.accent
  activeFocusOnTab: true
  Keys.onReturnPressed: clicked()
  Keys.onSpacePressed: clicked()
  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(0.8)
    Text {
      visible: root.glyph !== ""
      text: root.glyph
      color: root.selected ? Color.workspaceActiveText : Color.foreground
      font.family: Style.iconFamily
      font.pixelSize: Style.fontSize
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      visible: root.label !== ""
      text: root.label
      color: root.selected ? Color.workspaceActiveText : Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      anchors.verticalCenter: parent.verticalCenter
    }
  }
  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
