import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// Audio panel: default output and input, plus the list of sinks.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 400
  panelHeight: 380
  takesKeyboard: false

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var sinks: {
    const list = Pipewire.nodes ? Pipewire.nodes.values.slice() : []
    return list.filter(node => node.isSink && !node.isStream)
  }

  PwObjectTracker {
    objects: {
      const all = Pipewire.nodes ? Pipewire.nodes.values.slice() : []
      return all.concat([root.sink, root.source].filter(node => node !== null))
    }
  }

  function setVolume(node, value) {
    if (!node || !node.audio) return
    node.audio.volume = value
  }

  function setDefault(node) {
    Util.exec("wpctl set-default " + node.id)
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(1)

    Text {
      width: parent.width
      text: "Audio"
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      font.bold: true
    }

    // output
    Column {
      width: parent.width
      spacing: Style.space(0.4)

      Row {
        width: parent.width
        spacing: Style.space(0.8)

        Text {
          width: parent.width - muteButton.width - Style.space(0.8)
          text: root.sink ? (root.sink.description || root.sink.nickname || root.sink.name || "output") : "no output"
          color: Color.foreground
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        Rectangle {
          id: muteButton
          width: muteText.implicitWidth + Style.space(1.4)
          height: Style.widgetHeight
          radius: Style.radius
          color: (root.sink && root.sink.audio && root.sink.audio.muted) ? Color.workspaceActive : Color.hover

          Text {
            id: muteText
            anchors.centerIn: parent
            text: (root.sink && root.sink.audio && root.sink.audio.muted) ? "\uf026 muted" : "\uf028"
            color: (root.sink && root.sink.audio && root.sink.audio.muted) ? Color.workspaceActiveText : Color.foreground
            font.family: Style.iconFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Util.exec("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
          }
        }
      }

      Slider {
        width: parent.width
        enabled: !!root.sink && !!root.sink.audio
        value: (root.sink && root.sink.audio) ? Util.clamp(root.sink.audio.volume, 0, 1) : 0
        onMoved: value => root.setVolume(root.sink, value)
      }
    }

    // input
    Column {
      width: parent.width
      spacing: Style.space(0.4)
      visible: !!root.source

      Row {
        width: parent.width
        spacing: Style.space(0.8)

        Text {
          width: parent.width - micMute.width - Style.space(0.8)
          text: root.source ? (root.source.description || root.source.nickname || "input") : ""
          color: Color.foreground
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        Rectangle {
          id: micMute
          width: micMuteText.implicitWidth + Style.space(1.4)
          height: Style.widgetHeight
          radius: Style.radius
          color: (root.source && root.source.audio && root.source.audio.muted) ? Color.workspaceActive : Color.hover

          Text {
            id: micMuteText
            anchors.centerIn: parent
            text: (root.source && root.source.audio && root.source.audio.muted) ? "\uf131 muted" : "\uf130"
            color: (root.source && root.source.audio && root.source.audio.muted) ? Color.workspaceActiveText : Color.foreground
            font.family: Style.iconFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Util.exec("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")
          }
        }
      }

      Slider {
        width: parent.width
        enabled: !!root.source && !!root.source.audio
        value: (root.source && root.source.audio) ? Util.clamp(root.source.audio.volume, 0, 1) : 0
        onMoved: value => root.setVolume(root.source, value)
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Color.surfaceBorder
    }

    ListView {
      id: sinkList

      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(0.4)
      model: root.sinks

      delegate: Rectangle {
        required property var modelData

        width: sinkList.width
        height: Style.widgetHeight + Style.space(0.6)
        radius: Style.radius
        color: modelData === root.sink ? Color.hover : "transparent"

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(0.8)
          anchors.rightMargin: Style.space(0.8)
          spacing: Style.space(0.8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - levelText.width - Style.space(0.8)
            text: (modelData.description || modelData.nickname || modelData.name || "sink") +
              (modelData === root.sink ? "  ·  default" : "")
            color: Color.foreground
            elide: Text.ElideRight
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }

          Text {
            id: levelText
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.audio ? Math.round(Util.clamp(modelData.audio.volume, 0, 1) * 100) + "%" : ""
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setDefault(modelData)
        }
      }
    }
  }
}
