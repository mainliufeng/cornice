import QtQuick
import Quickshell.Services.UPower
import qs.Commons

Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property var device: UPower.displayDevice
  readonly property bool present: !!device && device.isPresent
  readonly property real fraction: present ? device.percentage : 0
  readonly property int percent: Math.round(fraction * 100)

  readonly property bool charging: present && device.state === UPowerDeviceState.Charging
  readonly property bool full: present && (device.state === UPowerDeviceState.FullyCharged
    || device.state === UPowerDeviceState.PendingCharge || percent >= 100)
  readonly property bool critical: present && percent <= 10

  // waybar's set: F240 full … F244 empty, F0E7 charging, F1E6 plugged.
  readonly property string icon: {
    if (charging) return "\uf0e7"
    if (full) return "\uf1e6"
    if (percent >= 90) return "\uf240"
    if (percent >= 70) return "\uf241"
    if (percent >= 50) return "\uf242"
    if (percent >= 25) return "\uf243"
    return "\uf244"
  }

  readonly property string remaining: {
    if (!present || !device.timeToEmpty || device.timeToEmpty <= 0) return ""
    const minutes = Math.floor(device.timeToEmpty / 60)
    const hours = Math.floor(minutes / 60)
    return hours > 0 ? hours + "h" + Util.pad2(minutes % 60) : minutes + "m"
  }

  readonly property bool showRemaining: Util.option(widgetConfig, "showTimeRemaining", false)

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)
  visible: present

  Text {
    id: label
    anchors.centerIn: parent
    text: root.percent + "% " + root.icon + (
      root.showRemaining && root.remaining !== "" ? "  " + root.remaining : "")
    color: root.critical && !root.charging ? Color.urgent : Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: if (root.host) root.host.toggle("cn.power", {})
  }
}
