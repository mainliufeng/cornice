import QtQuick
import Quickshell.Bluetooth
import qs.Commons

// Bluetooth indicator. Shows connected devices, or nothing when the adapter is
// off (nothing to say). Click opens the device panel.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property bool hideWhenOff: Util.option(widgetConfig, "hideWhenOff", true)
  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []

  readonly property int connectedCount: {
    let count = 0
    for (const device of devices || []) if (device.connected) count++
    return count
  }

  readonly property bool enabled: adapter !== null && adapter.enabled
  readonly property string icon: connectedCount > 0 ? "\uf293" : "\uf294"

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)
  visible: enabled || !hideWhenOff

  Text {
    id: label
    anchors.centerIn: parent
    text: root.icon + (root.connectedCount > 0 ? " " + root.connectedCount : "")
    color: root.connectedCount > 0 ? Color.barForeground : Color.muted
    font.family: Style.iconFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: if (root.host) root.host.toggle("cn.bluetooth", {})
  }
}
