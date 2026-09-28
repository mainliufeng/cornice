import QtQuick
import Quickshell.Networking
import qs.Commons

// Wired/Wi-Fi status. Click opens the network panel.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property bool showName: Util.option(widgetConfig, "showName", false)
  readonly property var devices: Networking.devices ? Networking.devices.values : []

  readonly property var activeDevice: {
    const list = devices || []
    for (const device of list) if (device.connected) return device
    return list.length > 0 ? list[0] : null
  }

  readonly property string connectivity: String(Networking.connectivity)
  readonly property bool online: connectivity === "Connected" || connectivity === "Portal"
  readonly property bool wired: activeDevice !== null && String(activeDevice.type).toLowerCase().indexOf("wired") !== -1

  readonly property string icon: {
    if (!activeDevice) return "\uf00d"
    if (wired) return "\uf0e8"
    const signal = strongestSignal()
    if (!online) return "\uf00d"
    if (signal >= 75) return "\uf1eb"
    if (signal >= 50) return "\ufaa8"
    if (signal >= 25) return "\ufaa9"
    return "\ufaa9"
  }

  function strongestSignal() {
    if (!activeDevice || !activeDevice.networks) return 0
    const list = activeDevice.networks.values || []
    for (const network of list) if (network.connected) return network.signalStrength
    return 0
  }

  readonly property string label: {
    if (!activeDevice) return "offline"
    const name = activeDevice.name || ""
    if (showName) return name
    return wired ? "ethernet" : (name === "" ? "wifi" : "wifi")
  }

  implicitHeight: Style.widgetHeight
  implicitWidth: text.implicitWidth + Style.space(1)

  Text {
    id: text
    anchors.centerIn: parent
    text: root.icon + (root.showName || root.wired ? " " + root.label : "")
    color: root.online ? Color.barForeground : Color.muted
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) Util.exec("nm-connection-editor")
      else if (root.host) root.host.summon("cn.network", {})
    }
  }
}
