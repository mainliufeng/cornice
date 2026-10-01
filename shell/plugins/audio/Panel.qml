import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// Audio panel: default output and input, plus the list of sinks.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: Math.min(520, window.screen ? window.screen.width - Style.space(8) : 520)
  panelHeight: Math.min(660, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 660)
  takesKeyboard: false

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var sinks: {
    const list = Pipewire.nodes ? Pipewire.nodes.values.slice() : [];
    return list.filter(node => node.isSink && !node.isStream);
  }

  PwObjectTracker {
    objects: {
      const all = Pipewire.nodes ? Pipewire.nodes.values.slice() : [];
      return all.concat([root.sink, root.source].filter(node => node !== null));
    }
  }

  function setVolume(node, value) {
    if (!node || !node.audio)
      return;
    node.audio.volume = value;
  }

  function setDefault(node) {
    Util.exec("wpctl set-default " + node.id);
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
        title: I18n.t("common.audio")
        subtitle: I18n.t("audio.subtitle")
        glyph: "\uf028"
      }
      Repeater {
        model: [
          {
            node: root.sink,
            label: I18n.t("audio.output"),
            glyph: "\uf028",
            target: "@DEFAULT_AUDIO_SINK@"
          },
          {
            node: root.source,
            label: I18n.t("audio.input"),
            glyph: "\uf130",
            target: "@DEFAULT_AUDIO_SOURCE@"
          }
        ]
        delegate: Rectangle {
          required property var modelData
          width: parent.width
          height: Style.space(19.5)
          visible: modelData.target === "@DEFAULT_AUDIO_SINK@" || !!modelData.node
          color: Color.surface
          radius: Style.radius
          Column {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            spacing: Style.space(0.5)
            Item {
              width: parent.width
              height: Style.space(5.5)
              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: Color.foreground
                font.family: Style.fontFamily
                font.pixelSize: Style.fontSize + 2
                font.bold: true
              }
              PanelButton {
                anchors.right: parent.right
                glyph: modelData.node && modelData.node.audio && modelData.node.audio.muted ? "\uf026" : modelData.glyph
                label: modelData.node && modelData.node.audio && modelData.node.audio.muted ? I18n.t("common.muted") : ""
                selected: !!modelData.node && !!modelData.node.audio && modelData.node.audio.muted
                enabled: !!modelData.node && !!modelData.node.audio
                onClicked: Util.exec("wpctl set-mute " + modelData.target + " toggle")
              }
            }
            Text {
              width: parent.width
              text: modelData.node ? (modelData.node.description || modelData.node.nickname || modelData.node.name) : I18n.t("audio.noOutput")
              color: Color.muted
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
            Row {
              width: parent.width
              spacing: Style.space(1.5)
              Slider {
                width: parent.width - volumeLabel.width - parent.spacing
                enabled: !!modelData.node && !!modelData.node.audio
                value: modelData.node && modelData.node.audio ? Util.clamp(modelData.node.audio.volume, 0, 1) : 0
                onMoved: value => root.setVolume(modelData.node, value)
              }
              Text {
                id: volumeLabel
                width: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: modelData.node && modelData.node.audio ? Math.round(modelData.node.audio.volume * 100) + "%" : "—"
                color: Color.foreground
                font.family: Style.fontFamily
                font.pixelSize: Style.fontSize + 2
              }
            }
          }
        }
      }
      Text {
        text: I18n.t("audio.devices")
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
      ListView {
        id: sinkList
        width: parent.width
        height: Math.max(Style.space(12), viewport.height - y)
        clip: true
        spacing: Style.space(0.75)
        model: root.sinks
        delegate: Rectangle {
          required property var modelData
          width: sinkList.width
          height: Style.space(7)
          radius: Style.radius
          color: hover.containsMouse ? Color.hover : modelData === root.sink ? Color.surface : "transparent"
          Text {
            x: Style.space(1.5)
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(7)
            text: modelData.description || modelData.nickname || modelData.name
            color: Color.foreground
            elide: Text.ElideRight
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(1.5)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData === root.sink ? "\uf00c" : ""
            color: Color.accent
            font.family: Style.iconFamily
            font.pixelSize: Style.fontSize + 2
          }
          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setDefault(modelData)
          }
        }
      }
    }
  }
}
