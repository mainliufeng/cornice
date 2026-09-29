import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons

// Now-playing in the bar. Left click opens the control panel, middle click
// plays/pauses, scroll skips — the panel is where the detail lives.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int maxWidth: Util.option(widgetConfig, "maxWidth", 200)

  // Prefer the shared service (it also drives the panel); fall back to MPRIS
  // directly while the service is still loading.
  readonly property var service: host ? host.services["cn.media"] : null
  readonly property var players: Mpris.players ? Mpris.players.values : []

  readonly property var player: service
    ? service.player
    : (function () {
        const list = players || []
        for (const candidate of list) if (candidate.isPlaying) return candidate
        return list.length > 0 ? list[0] : null
      })()

  readonly property string title: service ? service.title : (player ? (player.trackTitle || "") : "")
  readonly property string artist: service ? service.artist : (player ? (player.trackArtist || "") : "")
  readonly property bool playing: service ? service.playing : (player ? player.isPlaying === true : false)
  readonly property string icon: playing ? "\uf04b" : "\uf04c"

  implicitHeight: Style.widgetHeight
  implicitWidth: Math.min(label.implicitWidth, maxWidth)
  visible: title !== ""

  function text() {
    const format = Util.option(widgetConfig, "format", "{icon} {title}")
    return format.replace("{icon}", icon)
      .replace("{title}", title)
      .replace("{artist}", artist)
  }

  Text {
    id: label
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.maxWidth)
    text: root.text()
    elide: Text.ElideRight
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor

    onClicked: mouse => {
      if (!root.player) return
      if (mouse.button === Qt.MiddleButton) {
        if (root.service) root.service.playPause()
        else if (root.player.canTogglePlaying) root.player.togglePlaying()
      } else if (root.host) {
        root.host.toggle("cn.media", {})
      }
    }

    onWheel: wheel => {
      if (!root.player) return
      if (wheel.angleDelta.y > 0) {
        if (root.service) root.service.previous()
        else if (root.player.canGoPrevious) root.player.previous()
      } else {
        if (root.service) root.service.next()
        else if (root.player.canGoNext) root.player.next()
      }
    }
  }
}
