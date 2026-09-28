import QtQuick
import Quickshell
import Quickshell.Bluetooth
import qs.Commons
import qs.Ui

// Bluetooth panel: adapter power, scan, paired and discovered devices.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 400
  panelHeight: 460
  takesKeyboard: false

  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var devices: {
    const list = Bluetooth.devices ? Bluetooth.devices.values.slice() : []
    list.sort((a, b) => {
      if (a.connected !== b.connected) return a.connected ? -1 : 1
      if (a.paired !== b.paired) return a.paired ? -1 : 1
      return String(a.name || a.address).localeCompare(String(b.name || b.address))
    })
    return list
  }

  function deviceSubtitle(device) {
    const parts = []
    if (device.connected) parts.push("connected")
    else if (device.paired) parts.push("paired")
    if (device.batteryAvailable && device.battery > 0) parts.push(Math.round(device.battery * 100) + "%")
    if (parts.length === 0) parts.push(device.address || "")
    return parts.join("  ·  ")
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(0.8)

    Text {
      width: parent.width
      text: "Bluetooth"
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      font.bold: true
    }

    Text {
      width: parent.width
      visible: !root.adapter
      text: "no bluetooth adapter"
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Row {
      spacing: Style.space(0.6)
      visible: root.adapter !== null

      Rectangle {
        width: powerLabel.implicitWidth + Style.space(1.6)
        height: Style.widgetHeight
        radius: Style.radius
        color: root.adapter && root.adapter.enabled ? Color.workspaceActive : Color.hover

        Text {
          id: powerLabel
          anchors.centerIn: parent
          text: root.adapter && root.adapter.enabled ? "Bluetooth on" : "Bluetooth off"
          color: root.adapter && root.adapter.enabled ? Color.workspaceActiveText : Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.adapter) root.adapter.enabled = !root.adapter.enabled
        }
      }

      Rectangle {
        width: scanLabel.implicitWidth + Style.space(1.6)
        height: Style.widgetHeight
        radius: Style.radius
        color: root.adapter && root.adapter.discovering ? Color.workspaceActive : Color.hover

        Text {
          id: scanLabel
          anchors.centerIn: parent
          text: root.adapter && root.adapter.discovering ? "Scanning…" : "Scan"
          color: root.adapter && root.adapter.discovering ? Color.workspaceActiveText : Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (root.adapter) root.adapter.discovering = !root.adapter.discovering
        }
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Color.surfaceBorder
      visible: root.adapter !== null
    }

    ListView {
      id: list

      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(0.4)
      model: root.devices

      delegate: Rectangle {
        required property var modelData

        width: list.width
        height: Style.widgetHeight + Style.space(1)
        radius: Style.radius
        color: modelData.connected ? Color.hover : "transparent"

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(0.8)
          anchors.rightMargin: Style.space(0.8)
          spacing: Style.space(0.8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.icon && modelData.icon !== "" ? "\uf293" : "\uf294"
            color: modelData.connected ? Color.accent : Color.foreground
            font.family: Style.iconFamily
            font.pixelSize: Style.fontSize
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - action.width - Style.space(2)

            Text {
              width: parent.width
              text: modelData.name || modelData.address || "unknown"
              color: Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              width: parent.width
              text: root.deviceSubtitle(modelData)
              color: Color.muted
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.smallFontSize
            }
          }

          Rectangle {
            id: action
            anchors.verticalCenter: parent.verticalCenter
            width: actionText.implicitWidth + Style.space(1.4)
            height: Style.widgetHeight
            radius: Style.radius
            color: modelData.connected ? Color.hover : Color.workspaceActive

            Text {
              id: actionText
              anchors.centerIn: parent
              text: modelData.connected ? "Disconnect" : (modelData.paired ? "Connect" : "Pair")
              color: modelData.connected ? Color.foreground : Color.workspaceActiveText
              font.family: Style.fontFamily
              font.pixelSize: Style.smallFontSize
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (modelData.connected) modelData.connected = false
                else if (modelData.paired) modelData.connected = true
                else modelData.pair()
              }
            }
          }
        }
      }
    }
  }
}
