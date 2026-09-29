import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui

// Power panel: battery detail, power profile, and session actions.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 380
  panelHeight: 380
  takesKeyboard: false

  readonly property var device: UPower.displayDevice
  readonly property int percent: device && device.isPresent ? Math.round(device.percentage * 100) : -1

  property string profile: ""
  property var profiles: []

  function refreshProfiles() {
    profileList.running = true
  }

  onOpened: refreshProfiles()

  function timeLabel(seconds) {
    if (!seconds || seconds <= 0) return ""
    const minutes = Math.floor(seconds / 60)
    const hours = Math.floor(minutes / 60)
    return hours > 0 ? hours + "h " + Util.pad2(minutes % 60) + "m" : minutes + "m"
  }

  readonly property Process profileList: Process {
    command: ["sh", "-c", "command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl list | sed -n 's/^\\*\\? *\\([a-z-]*\\):$/\\1/p'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.profiles = String(text).trim().split("\n").filter(line => line !== "")
        profileGet.running = true
      }
    }
  }

  readonly property Process profileGet: Process {
    command: ["sh", "-c", "command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.profile = String(text).trim()
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(1)

    Text {
      width: parent.width
      text: I18n.t("common.power")
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      font.bold: true
    }

    Text {
      width: parent.width
      visible: root.percent < 0
      text: I18n.t("panel.noBattery")
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Column {
      width: parent.width
      spacing: Style.space(0.3)
      visible: root.percent >= 0

      Text {
        width: parent.width
        text: root.percent + "%  ·  " + (root.device ? String(root.device.state).toLowerCase() : "")
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }

      Text {
        width: parent.width
        text: {
          if (!root.device) return ""
          const remaining = root.device.state === UPowerDeviceState.Charging
            ? root.timeLabel(root.device.timeToFull)
            : root.timeLabel(root.device.timeToEmpty)
          const parts = []
          if (remaining !== "") parts.push((root.device.state === UPowerDeviceState.Charging ? "until full " : "remaining ") + remaining)
          if (root.device.changeRate) parts.push(Math.round(root.device.changeRate * 10) / 10 + " W")
          return parts.join("  ·  ")
        }
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }

      Rectangle {
        width: parent.width
        height: Style.space(0.8)
        radius: Style.radius
        color: Color.hover

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * Util.clamp(root.percent / 100, 0, 1)
          radius: Style.radius
          color: root.percent <= 15 ? Color.urgent : Color.accent
        }
      }
    }

    Row {
      spacing: Style.space(0.5)
      visible: root.profiles.length > 0

      Repeater {
        model: root.profiles

        delegate: Rectangle {
          required property var modelData

          width: profileText.implicitWidth + Style.space(1.6)
          height: Style.widgetHeight
          radius: Style.radius
          color: modelData === root.profile ? Color.workspaceActive : Color.hover

          Text {
            id: profileText
            anchors.centerIn: parent
            text: modelData
            color: modelData === root.profile ? Color.workspaceActiveText : Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              Util.exec("powerprofilesctl set " + modelData)
              root.profile = modelData
            }
          }
        }
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Color.surfaceBorder
    }

    Row {
      spacing: Style.space(0.5)

      Repeater {
        model: [
          { label: "Lock", command: "loginctl lock-session" },
          { label: "Suspend", command: "systemctl suspend" },
          { label: "Reboot", command: "systemctl reboot" },
          { label: "Power off", command: "systemctl poweroff" }
        ]

        delegate: Rectangle {
          required property var modelData

          width: actionText.implicitWidth + Style.space(1.6)
          height: Style.widgetHeight
          radius: Style.radius
          color: modelData.label === "Power off" ? Color.urgent : Color.hover

          Text {
            id: actionText
            anchors.centerIn: parent
            text: modelData.label
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Util.exec(modelData.command)
          }
        }
      }
    }
  }
}
