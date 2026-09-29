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
  panelWidth: 400
  panelHeight: 460
  takesKeyboard: false

  property string selectedSsid: ""
  property bool connecting: false
  property string message: ""

  readonly property var devices: Networking.devices ? Networking.devices.values : []
  readonly property var device: {
    const list = devices || []
    for (const candidate of list) if (candidate.connected) return candidate
    return list.length > 0 ? list[0] : null
  }

  readonly property bool wifi: device !== null && String(device.type).toLowerCase().indexOf("wired") === -1 &&
    String(device.type).toLowerCase().indexOf("wifi") !== -1
  readonly property var networks: {
    if (!device || !device.networks) return []
    const list = (device.networks.values || []).slice()
    list.sort((a, b) => b.signalStrength - a.signalStrength)
    return list
  }

  function signalIcon(strength) {
    if (strength >= 75) return "\uf1eb"
    if (strength >= 50) return "\ufaa8"
    return "\ufaa9"
  }

  function pickNetwork(network) {
    message = ""
    if (network.known || network.security === "None" || network.security === "" || network.security === undefined) {
      selectedSsid = ""
      connect(network, "")
      return
    }
    selectedSsid = network.name
  }

  function connect(network, psk) {
    connecting = true
    message = "connecting to " + network.name + "…"
    try {
      network.connectWithPsk(psk === undefined ? "" : psk)
    } catch (e) {
      message = "connect failed: " + e
    }
    connecting = false
    selectedSsid = ""
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(0.8)

    Text {
      width: parent.width
      text: I18n.t("common.network")
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      font.bold: true
    }

    Text {
      width: parent.width
      text: {
        if (!root.device) return "no network device"
        const parts = [root.device.name || ""]
        if (root.device.address) parts.push("ip " + root.device.address)
        parts.push(String(Networking.connectivity).toLowerCase())
        return parts.join("  ·  ")
      }
      color: Color.muted
      elide: Text.ElideRight
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Row {
      spacing: Style.space(0.6)
      visible: root.wifi

      Rectangle {
        width: wifiLabel.implicitWidth + Style.space(1.6)
        height: Style.widgetHeight
        radius: Style.radius
        color: Networking.wifiEnabled ? Color.workspaceActive : Color.hover

        Text {
          id: wifiLabel
          anchors.centerIn: parent
          text: Networking.wifiEnabled ? "Wi-Fi on" : "Wi-Fi off"
          color: Networking.wifiEnabled ? Color.workspaceActiveText : Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
        }
      }

      Rectangle {
        width: rescanLabel.implicitWidth + Style.space(1.6)
        height: Style.widgetHeight
        radius: Style.radius
        color: Color.hover

        Text {
          id: rescanLabel
          anchors.centerIn: parent
          text: root.connecting ? "…" : "Rescan"
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: Util.exec("nmcli device wifi rescan")
        }
      }
    }

    Text {
      width: parent.width
      visible: root.message !== ""
      text: root.message
      color: Color.accent
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Color.surfaceBorder
    }

    ListView {
      id: list

      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(0.4)
      model: root.networks

      delegate: Column {
        required property var modelData

        width: list.width
        spacing: Style.space(0.4)

        Rectangle {
          width: parent.width
          height: Style.widgetHeight + Style.space(0.6)
          radius: Style.radius
          color: modelData.connected ? Color.hover : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(0.8)
            anchors.rightMargin: Style.space(0.8)
            spacing: Style.space(0.8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.signalIcon(modelData.signalStrength)
              color: modelData.connected ? Color.accent : Color.foreground
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(6)
              text: (modelData.name || "hidden") +
                (modelData.security && modelData.security !== "None" ? "  \uf023" : "") +
                (modelData.known ? "  ·  saved" : "")
              color: Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pickNetwork(modelData)
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(0.6)
          visible: root.selectedSsid === modelData.name

          TextField {
            id: pskField
            width: parent.width - connectButton.width - Style.space(0.6)
            placeholder: I18n.t("lock.passwordFor") + modelData.name
            onAccepted: root.connect(modelData, pskField.text)
            onCanceled: root.selectedSsid = ""
          }

          Rectangle {
            id: connectButton
            width: connectText.implicitWidth + Style.space(1.6)
            height: Style.widgetHeight
            radius: Style.radius
            color: Color.workspaceActive

            Text {
              id: connectText
              anchors.centerIn: parent
              text: I18n.t("common.connect")
              color: Color.workspaceActiveText
              font.family: Style.fontFamily
              font.pixelSize: Style.smallFontSize
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.connect(modelData, pskField.text)
            }
          }
        }
      }
    }
  }
}
