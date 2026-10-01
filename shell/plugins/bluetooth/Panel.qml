import QtQuick
import Quickshell
import Quickshell.Bluetooth
import qs.Commons
import qs.Ui

// Bluetooth panel: adapter power, scan, paired and discovered devices.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: Math.min(520, window.screen ? window.screen.width - Style.space(8) : 520)
  panelHeight: Math.min(640, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 640)
  takesKeyboard: false

  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var devices: {
    const list = Bluetooth.devices ? Bluetooth.devices.values.slice() : [];
    list.sort((a, b) => {
      if (a.connected !== b.connected)
        return a.connected ? -1 : 1;
      if (a.paired !== b.paired)
        return a.paired ? -1 : 1;
      return String(a.name || a.address).localeCompare(String(b.name || b.address));
    });
    return list;
  }

  function deviceSubtitle(device) {
    const parts = [];
    if (device.connected)
      parts.push(I18n.t("common.connected"));
    else if (device.paired)
      parts.push(I18n.t("bluetooth.paired"));
    if (device.batteryAvailable && device.battery > 0)
      parts.push(Math.round(device.battery * 100) + "%");
    if (parts.length === 0)
      parts.push(device.address || "");
    return parts.join("  ·  ");
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
        title: I18n.t("common.bluetooth")
        subtitle: root.adapter ? (root.adapter.name || root.adapter.address || "") : I18n.t("panel.noBluetooth")
        glyph: "\uf293"
      }
      Row {
        spacing: Style.space(1)
        visible: !!root.adapter
        PanelButton {
          label: I18n.t(root.adapter && root.adapter.enabled ? "bluetooth.on" : "bluetooth.off")
          selected: !!root.adapter && root.adapter.enabled
          filled: true
          onClicked: if (root.adapter)
            root.adapter.enabled = !root.adapter.enabled
        }
        PanelButton {
          label: I18n.t(root.adapter && root.adapter.discovering ? "bluetooth.scanning" : "bluetooth.scan")
          glyph: "\uf021"
          filled: true
          selected: !!root.adapter && root.adapter.discovering
          enabled: !!root.adapter && root.adapter.enabled
          onClicked: if (root.adapter)
            root.adapter.discovering = !root.adapter.discovering
        }
      }
      Text {
        text: I18n.t("bluetooth.devices")
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
      Text {
        width: parent.width
        visible: root.devices.length === 0
        text: I18n.t("bluetooth.empty")
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
        model: root.devices
        delegate: Rectangle {
          required property var modelData
          width: list.width
          height: Style.space(10)
          radius: Style.radius
          color: Color.surface
          Text {
            id: icon
            x: Style.space(1.5)
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf293"
            color: modelData.connected ? Color.accent : Color.muted
            font.family: Style.iconFamily
            font.pixelSize: Style.fontSize + 6
          }
          Column {
            x: icon.x + icon.width + Style.space(1.5)
            width: Math.max(0, action.x - x - Style.space(1))
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(0.5)
            Text {
              width: parent.width
              text: modelData.name || modelData.address || I18n.t("common.unknown")
              color: Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize + 2
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
          PanelButton {
            id: action
            anchors.right: parent.right
            anchors.rightMargin: Style.space(1.5)
            anchors.verticalCenter: parent.verticalCenter
            label: I18n.t(modelData.connected ? "common.disconnect" : modelData.paired ? "common.connect" : "bluetooth.pair")
            filled: true
            selected: modelData.connected
            onClicked: {
              if (modelData.connected)
                modelData.connected = false;
              else if (modelData.paired)
                modelData.connected = true;
              else
                modelData.pair();
            }
          }
        }
      }
    }
  }
}
