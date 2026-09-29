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

  // Quickshell's networking enums are integers in QML (String() gives "4", not
  // "Full"), so compare against the enum types instead of parsing strings.
  readonly property int connectivity: Networking.connectivity
  readonly property bool online: connectivity === NetworkConnectivity.Full
    || connectivity === NetworkConnectivity.Limited
    || connectivity === NetworkConnectivity.Portal
  readonly property int deviceType: activeDevice ? activeDevice.type : DeviceType.None
  readonly property bool wired: deviceType === DeviceType.Wired

  // Glyphs verified against the bar font: the MDI wifi-strength set renders,
  // while F1EB is the full-strength arc. (FAA8/FAA9 render as empty boxes.)
  readonly property string icon: {
    if (!activeDevice) return "\u{F05E1}"
    if (wired) return "\u{F0200}"
    const signal = strongestSignal()
    if (!online) return "\u{F05E1}"
    if (signal >= 75) return "\u{F0925}"
    if (signal >= 50) return "\u{F0924}"
    if (signal >= 25) return "\u{F0923}"
    return "\u{F0922}"
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
      else if (root.host) root.host.toggle("cn.network", {})
    }
  }

  // Read-only support hook (temporary while the module behaviour is unclear).
  ShellIpc {
    target: "netinfo"

    function dump(): string {
      const devices = Networking.devices ? Networking.devices.values : []
      return JSON.stringify({
        backend: String(Networking.backend),
        connectivity: String(Networking.connectivity),
        canCheck: Networking.canCheckConnectivity,
        wifiEnabled: Networking.wifiEnabled,
        wifiHardwareEnabled: Networking.wifiHardwareEnabled,
        deviceCount: devices.length,
        devices: devices.map(device => ({
          name: String(device.name),
          type: String(device.type),
          state: String(device.state),
          connected: device.connected,
          address: String(device.address),
          networkCount: device.networks ? (device.networks.values ? device.networks.values.length : -1) : -2
        })),
        activeDevice: root.activeDevice ? String(root.activeDevice.name) : null,
        icon: root.icon
      })
    }
  }
}
