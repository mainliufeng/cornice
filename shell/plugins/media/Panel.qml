import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Media control panel: cover, title/artist/album, progress (click to seek),
// transport, volume, and a player picker when several players are running.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 420
  panelHeight: 320
  takesKeyboard: false

  readonly property var service: host ? host.services["cn.media"] : null
  readonly property var players: service ? (service.players || []) : []

  // Re-evaluate whenever the service ticks or the track changes.
  readonly property var player: service ? service.player : null
  readonly property string title: service ? service.title : ""
  readonly property string artist: service ? service.artist : ""
  readonly property string album: service ? service.album : ""
  readonly property string artUrl: service ? service.artUrl : ""
  readonly property bool playing: service ? service.playing : false
  readonly property real progress: service ? service.progress : 0
  readonly property string positionLabel: service ? service.positionLabel : "0:00"
  readonly property string lengthLabel: service ? service.lengthLabel : "0:00"
  readonly property real volume: (player && player.volume !== undefined) ? player.volume : 0
  readonly property int tick: service ? service.positionTick : 0

  onOpened: if (service) service.positionTick = service.positionTick + 1

  function playPause() { if (service) service.playPause() }
  function next() { if (service) service.next() }
  function previous() { if (service) service.previous() }

  Column {
    anchors.fill: parent
    spacing: Style.space(1)

    // ---- header: cover + text ---------------------------------------------
    Row {
      width: parent.width
      height: Math.round(Style.space(9))
      spacing: Style.space(1)

      Rectangle {
        width: height
        height: parent.height
        radius: Style.radius
        color: Color.hover
        clip: true

        Image {
          anchors.fill: parent
          visible: root.artUrl !== ""
          source: root.artUrl === "" ? "" : root.artUrl
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }

        Text {
          anchors.centerIn: parent
          visible: root.artUrl === ""
          text: "\uf001"
          color: Color.muted
          font.family: Style.iconFamily
          font.pixelSize: Style.fontSize * 2.4
        }
      }

      Column {
        width: parent.width - parent.height - Style.space(1)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(0.3)

        Text {
          width: parent.width
          text: root.title !== "" ? root.title : "Nothing playing"
          color: Color.foreground
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
          font.bold: true
        }

        Text {
          width: parent.width
          visible: root.artist !== ""
          text: root.artist
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.75)
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        Text {
          width: parent.width
          visible: root.album !== ""
          text: root.album
          color: Color.muted
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }
      }
    }

    // ---- progress ----------------------------------------------------------
    Column {
      width: parent.width
      spacing: Style.space(0.3)
      visible: root.player !== null

      Item {
        width: parent.width
        height: Style.space(1.4)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Math.max(3, Style.space(0.5))
          radius: Style.radius
          color: Color.hover
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.round(parent.width * root.progress)
          height: Math.max(3, Style.space(0.5))
          radius: Style.radius
          color: Color.accent
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: mouse => {
            if (root.service && root.player && root.player.canSeek)
              root.service.seekTo(mouse.x / width)
          }
        }
      }

      Row {
        width: parent.width

        Text {
          width: parent.width / 2
          text: root.positionLabel
          color: Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        Text {
          width: parent.width / 2
          text: root.lengthLabel
          color: Color.muted
          horizontalAlignment: Text.AlignRight
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }
      }
    }

    // ---- transport ---------------------------------------------------------
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(1.2)
      visible: root.player !== null

      Repeater {
        model: [
          { glyph: "\uf048", enabled: root.player ? root.player.canGoPrevious === true : false, action: "previous" },
          { glyph: root.playing ? "\uf04c" : "\uf04b", enabled: root.player ? root.player.canTogglePlaying === true : false, action: "playPause" },
          { glyph: "\uf051", enabled: root.player ? root.player.canGoNext === true : false, action: "next" }
        ]

        delegate: Rectangle {
          required property var modelData

          width: Math.round(Style.space(3.4))
          height: Math.round(Style.space(3.4))
          radius: Style.radius
          color: modelData.action === "playPause" ? Color.workspaceActive : Color.hover
          opacity: modelData.enabled ? 1 : 0.4

          Text {
            anchors.centerIn: parent
            text: modelData.glyph
            color: modelData.action === "playPause" ? Color.workspaceActiveText : Color.foreground
            font.family: Style.iconFamily
            font.pixelSize: Style.fontSize * 1.2
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            enabled: modelData.enabled
            onClicked: {
              if (!root.service) return
              if (modelData.action === "playPause") root.playPause()
              else if (modelData.action === "next") root.next()
              else root.previous()
            }
          }
        }
      }
    }

    // ---- volume ------------------------------------------------------------
    Row {
      width: parent.width
      spacing: Style.space(0.8)
      visible: root.player !== null

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "\uf028"
        color: Color.muted
        font.family: Style.iconFamily
        font.pixelSize: Style.smallFontSize
      }

      Slider {
        width: parent.width - Style.space(3)
        value: root.volume
        onMoved: value => { if (root.service) root.service.setVolume(value) }
      }
    }

    // ---- player picker (only when there is a choice) -----------------------
    Row {
      width: parent.width
      spacing: Style.space(0.5)
      visible: root.players.length > 1

      Repeater {
        model: root.players

        delegate: Rectangle {
          required property var modelData
          required property int index

          width: playerLabel.implicitWidth + Style.space(1.6)
          height: Style.widgetHeight
          radius: Style.radius
          color: modelData === root.player ? Color.hover : "transparent"

          Text {
            id: playerLabel
            anchors.centerIn: parent
            text: String(modelData.identity || modelData.dbusName || "player")
            color: modelData === root.player ? Color.foreground : Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.service) root.service.selectPlayer(modelData)
          }
        }
      }
    }
  }
}
