import QtQuick
import Quickshell.Hyprland
import qs.Commons

Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int maxWidth: Util.option(widgetConfig, "maxWidth", 420)
  readonly property string title: Hyprland.activeToplevel ? (Hyprland.activeToplevel.title || "") : ""

  implicitHeight: Style.widgetHeight
  implicitWidth: Math.min(label.implicitWidth, maxWidth)
  visible: title !== ""

  Text {
    id: label
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.maxWidth)
    text: root.title
    elide: Text.ElideRight
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }
}
