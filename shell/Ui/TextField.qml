import QtQuick
import qs.Commons

// Focused text input for panels and the launcher. Emits accepted()/canceled()
// so callers do not have to know about Qt's key handling.
FocusScope {
  id: root

  property alias text: input.text
  property string placeholder: ""
  property bool selectAllOnFocus: true

  signal accepted()
  signal shiftAccepted()
  signal canceled()
  signal moved(int delta)

  implicitHeight: Style.widgetHeight + Style.space(1)
  implicitWidth: 240

  function forceFocus() {
    input.forceActiveFocus()
    if (selectAllOnFocus) input.selectAll()
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.radius
    color: Color.hover
    border.width: input.activeFocus ? 1 : 0
    border.color: Color.accent
  }

  Text {
    anchors.fill: parent
    anchors.leftMargin: Style.space(1.2)
    anchors.rightMargin: Style.space(1.2)
    visible: input.text === ""
    text: root.placeholder
    color: Color.muted
    verticalAlignment: Text.AlignVCenter
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  TextInput {
    id: input

    anchors.fill: parent
    anchors.leftMargin: Style.space(1.2)
    anchors.rightMargin: Style.space(1.2)
    verticalAlignment: TextInput.AlignVCenter
    color: Color.foreground
    selectionColor: Color.accent
    selectedTextColor: Color.background
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
    clip: true

    Keys.onPressed: event => {
      if (event.key === Qt.Key_Escape) {
        root.canceled()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (event.modifiers & Qt.ShiftModifier) root.shiftAccepted()
        else root.accepted()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        root.moved(1)
        event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        root.moved(-1)
        event.accepted = true
      }
    }
  }
}
