import QtQuick
import qs.Commons

// Menu button for the right end of the bar.
//
// The point of this button is that every cornice surface stays reachable with
// the mouse alone: no keybinding is required to open the clipboard, the emoji
// picker, the bar layout, the theme or the lock screen.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property string icon: Util.option(widgetConfig, "icon", "\uf0c9")

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1.2)

  property bool hovered: false

  Rectangle {
    anchors.fill: parent
    anchors.margins: Math.round(Style.gap * 0.25)
    radius: Style.radius
    color: root.hovered ? Color.hover : "transparent"
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.icon
    color: Color.barForeground
    font.family: Style.iconFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true
    onEntered: root.hovered = true
    onExited: root.hovered = false
    onClicked: if (root.host) root.host.toggle("cn.menu", {})
  }
}
