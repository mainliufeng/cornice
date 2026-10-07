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
  panelWidth: Math.min(480, window.screen ? window.screen.width - Style.space(8) : 480)
  panelHeight: Math.min(560, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 560)
  takesKeyboard: false

  readonly property var device: UPower.displayDevice
  readonly property int percent: device && device.isPresent ? Math.round(device.percentage * 100) : -1

  property string profile: ""
  property var profiles: []

  function refreshProfiles() {
    profileList.running = true;
  }

  onOpened: refreshProfiles()

  function timeLabel(seconds) {
    if (!seconds || seconds <= 0)
      return "";
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    return hours > 0 ? hours + "h " + Util.pad2(minutes % 60) + "m" : minutes + "m";
  }

  readonly property Process profileList: Process {
    command: ["sh", "-c", "command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl list | sed -n 's/^\\*\\? *\\([a-z-]*\\):$/\\1/p'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.profiles = String(text).trim().split("\n").filter(line => line !== "");
        profileGet.running = true;
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
        title: I18n.t("common.power")
        subtitle: I18n.t("power.subtitle")
        glyph: "\uf240"
      }
      Rectangle {
        width: parent.width
        height: root.percent >= 0 ? Style.space(17) : Style.space(9)
        radius: Style.radius
        color: Color.surface
        Column {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          spacing: Style.space(0.75)
          Row {
            width: parent.width
            spacing: Style.space(1.5)
            Text {
              text: root.percent >= 0 ? root.percent + "%" : "—"
              color: Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize * 2.5
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.percent < 0 ? I18n.t("panel.noBattery") : I18n.t(root.device.state === UPowerDeviceState.Charging ? "power.charging" : root.device.state === UPowerDeviceState.FullyCharged ? "power.full" : "power.battery")
              color: Color.muted
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
          }
          Text {
            width: parent.width
            visible: root.percent >= 0
            text: {
              if (!root.device)
                return "";
              const charging = root.device.state === UPowerDeviceState.Charging;
              const remaining = root.timeLabel(charging ? root.device.timeToFull : root.device.timeToEmpty);
              const parts = [];
              if (remaining !== "")
                parts.push(I18n.t(charging ? "power.untilFull" : "power.remaining") + " " + remaining);
              if (root.device.changeRate)
                parts.push(Math.round(root.device.changeRate * 10) / 10 + " W");
              return parts.join(" · ");
            }
            color: Color.muted
            elide: Text.ElideRight
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }
          Rectangle {
            visible: root.percent >= 0
            width: parent.width
            height: Style.space(1)
            radius: height / 2
            color: Color.hover
            Rectangle {
              width: parent.width * Util.clamp(root.percent / 100, 0, 1)
              height: parent.height
              radius: height / 2
              color: root.percent <= 15 ? Color.urgent : Color.accent
            }
          }
        }
      }
      Column {
        width: parent.width
        spacing: Style.space(1)
        visible: root.profiles.length > 0
        Text {
          text: I18n.t("power.profile")
          color: Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }
        Flow {
          width: parent.width
          spacing: Style.space(1)
          Repeater {
            model: root.profiles
            delegate: PanelButton {
              required property var modelData
              label: I18n.t("power.profile." + modelData)
              filled: true
              selected: modelData === root.profile
              onClicked: {
                Util.exec("powerprofilesctl set " + modelData);
                root.profile = modelData;
              }
            }
          }
        }
      }
      Text {
        text: I18n.t("power.session")
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
      Grid {
        width: parent.width
        columns: 2
        spacing: Style.space(1)
        Repeater {
          model: [
            {
              key: "power.lock",
              glyph: "\uf023",
              command: "loginctl lock-session"
            },
            {
              key: "power.suspend",
              glyph: "\uf186",
              command: "systemctl suspend"
            },
            {
              key: "power.reboot",
              glyph: "\uf021",
              command: "systemctl reboot"
            },
            {
              key: "power.off",
              glyph: "\uf011",
              command: "systemctl poweroff"
            }
          ]
          delegate: PanelButton {
            required property var modelData
            width: (parent.width - parent.spacing) / 2
            implicitHeight: Style.space(6.5)
            label: I18n.t(modelData.key)
            glyph: modelData.glyph
            filled: true
            destructive: modelData.key === "power.off"
            onClicked: {
              if (modelData.key === "power.suspend")
                Quickshell.execDetached([(Quickshell.env("CORNICE_PATH") || "/usr/share/cornice") + "/bin/cornice", "suspend"])
              else Util.exec(modelData.command)
            }
          }
        }
      }
    }
  }
}
