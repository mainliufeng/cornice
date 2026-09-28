import QtQuick
import qs.Commons

// Launcher button for the left end of the bar.
//
// The launcher itself is a menu plugin; this is just the affordance, so the
// bar does not depend on the launcher being the first thing in it.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property string icon: Util.option(widgetConfig, "icon", "\uf009")

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
    onClicked: if (root.host) root.host.toggle("cn.launcher", {})
  }
}
