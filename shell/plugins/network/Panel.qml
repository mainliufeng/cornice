import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Commons
import qs.Ui

// Network panel: connection details, Wi-Fi toggle, network list, connect.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: Math.min(520, window.screen ? window.screen.width - Style.space(8) : 520)
  panelHeight: Math.min(640, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 640)
  takesKeyboard: false

  property string selectedSsid: ""
  property bool connecting: false
  property string message: ""

  readonly property var devices: Networking.devices ? Networking.devices.values : []
  readonly property var device: {
    const list = devices || [];
    for (const candidate of list)
      if (candidate.connected)
        return candidate;
    return list.length > 0 ? list[0] : null;
  }

  readonly property bool wifi: device !== null && device.type === DeviceType.Wifi
  readonly property var networks: {
    if (!device || !device.networks)
      return [];
    const list = (device.networks.values || []).slice();
    list.sort((a, b) => b.signalStrength - a.signalStrength);
    return list;
  }

  // Quickshell only lists access points while the device's scanner is on, and it
  // is off by default — which is why the list used to show only the connected
  // network. Keep it on for as long as the panel is open.
  property bool scannerAcquired: false

  function updateScanner(enabled) {
    if (!root.wifi || !root.device) return
    try {
      if (enabled) {
        if (root.device.scannerEnabled !== true) {
          root.device.scannerEnabled = true
          root.scannerAcquired = true
        }
      } else if (root.scannerAcquired) {
        root.device.scannerEnabled = false
        root.scannerAcquired = false
      }
    } catch (e) {
      console.warn("cornice: wifi scanner toggle failed: " + e)
    }
  }

  onOpened: updateScanner(true)
  onDismissed: updateScanner(false)
  onDeviceChanged: if (root.isOpen) updateScanner(true)

  function signalIcon(strength) {
    if (strength >= 75)
      return "\u{F0928}";
    if (strength >= 50)
      return "\u{F0925}";
    if (strength >= 25)
      return "\u{F0922}";
    return "\u{F091F}";
  }

  function pickNetwork(network) {
    message = "";
    if (network.known || network.security === WifiSecurityType.Open || network.security === WifiSecurityType.Owe || network.security === undefined) {
      selectedSsid = "";
      connect(network, "");
      return;
    }
    selectedSsid = network.name;
  }

  function connect(network, psk) {
    connecting = true;
    message = I18n.t("network.connecting") + " " + network.name + "…";
    try {
      if (network.known && !psk)
        network.connect();
      else
        network.connectWithPsk(psk === undefined ? "" : psk);
    } catch (e) {
      message = I18n.t("network.failed") + ": " + e;
    }
    connecting = false;
    selectedSsid = "";
  }

  Flickable {
    id: viewport
    anchors.fill: parent
    anchors.margins: Style.space(1.5)
    contentHeight: panelBody.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Column {
      id: panelBody
      width: viewport.width
      spacing: Style.space(2)
      PanelHeader {
        width: parent.width
        title: I18n.t("common.network")
        subtitle: root.device ? root.device.name : I18n.t("network.noDevice")
        glyph: "\uf1eb"
      }
      Rectangle {
        width: parent.width
        height: Style.space(10)
        radius: Style.radius
        color: Color.surface
        Column {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          spacing: Style.space(0.75)
          Text {
            text: I18n.t(root.device && root.device.connected ? "common.connected" : "network.notConnected")
            color: root.device && root.device.connected ? Color.accent : Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize + 2
            font.bold: true
          }
          Text {
            width: parent.width
            text: root.device && root.device.address ? I18n.t("network.deviceAddress") + " " + root.device.address : I18n.t("network.noAddress")
            color: Color.muted
            elide: Text.ElideRight
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
        }
      }
      Row {
        spacing: Style.space(1)
        visible: root.wifi
        PanelButton {
          label: I18n.t(Networking.wifiEnabled ? "network.wifiOn" : "network.wifiOff")
          filled: true
          selected: Networking.wifiEnabled
          onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
        }
        PanelButton {
          label: I18n.t("network.rescan")
          glyph: "\uf021"
          filled: true
          enabled: !root.connecting
          onClicked: {
            root.updateScanner(true)
            Util.execSession("nmcli device wifi rescan")
          }
        }
      }
      Text {
        width: parent.width
        visible: root.message !== ""
        text: root.message
        color: Color.accent
        wrapMode: Text.Wrap
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
      Text {
        text: I18n.t("network.available")
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
      Text {
        width: parent.width
        visible: root.wifi && Networking.wifiEnabled && root.networks.length <= 1
        text: I18n.t("network.scanning")
        color: Color.muted
        wrapMode: Text.Wrap
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }
      Text {
        width: parent.width
        visible: root.networks.length === 0
        text: I18n.t(root.wifi ? "network.empty" : "network.noWifi")
        color: Color.muted
        wrapMode: Text.Wrap
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
      ListView {
        id: list
        width: parent.width
        height: Math.max(Style.space(12), viewport.height - y)
        clip: true
        spacing: Style.space(1)
        model: root.networks
        delegate: Column {
          required property var modelData
          required property int index
          width: list.width
          spacing: Style.space(0.75)
          Rectangle {
            width: parent.width
            height: Style.space(8)
            radius: Style.radius
            color: hover.containsMouse ? Color.hover : Color.surface
            Text {
              id: signal
              x: Style.space(1.5)
              anchors.verticalCenter: parent.verticalCenter
              text: root.signalIcon(modelData.signalStrength)
              color: modelData.connected ? Color.accent : Color.muted
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize + 4
            }
            Column {
              x: signal.x + signal.width + Style.space(1.5)
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x - Style.space(5)
              spacing: Style.space(0.5)
              Text {
                width: parent.width
                text: modelData.name || I18n.t("network.hidden")
                color: Color.foreground
                elide: Text.ElideRight
                font.family: Style.fontFamily
                font.pixelSize: Style.fontSize + 2
              }
              Text {
                width: parent.width
                text: modelData.connected ? I18n.t("common.connected") : modelData.known ? I18n.t("network.saved") : I18n.t("network.new")
                color: Color.muted
                font.family: Style.fontFamily
                font.pixelSize: Style.smallFontSize
              }
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(1.5)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.connected ? "\uf00c" : modelData.security !== undefined && modelData.security !== WifiSecurityType.Open ? "\uf023" : ""
              color: Color.accent
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize
            }
            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pickNetwork(modelData)
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(1)
            visible: root.selectedSsid === modelData.name
            onVisibleChanged: if (visible) {
              list.positionViewAtIndex(index, ListView.Contain)
              pskField.forceFocus()
            }
            TextField {
              id: pskField
              width: parent.width - connectButton.width - parent.spacing
              echoMode: TextInput.Password
              placeholder: I18n.t("lock.passwordFor") + modelData.name
              onAccepted: root.connect(modelData, pskField.text)
              onCanceled: root.selectedSsid = ""
            }
            PanelButton {
              id: connectButton
              label: I18n.t("common.connect")
              selected: true
              onClicked: root.connect(modelData, pskField.text)
            }
          }
        }
      }
    }
  }
}
