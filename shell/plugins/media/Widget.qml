import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons

// Now-playing. Hidden unless a player is actually playing something.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int maxWidth: Util.option(widgetConfig, "maxWidth", 260)

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: {
    const list = players || []
    for (const candidate of list) if (candidate.isPlaying) return candidate
    return list.length > 0 ? list[0] : null
  }

  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string icon: (player && player.isPlaying) ? "\uf04b" : "\uf04c"

  implicitHeight: Style.widgetHeight
  implicitWidth: Math.min(label.implicitWidth, maxWidth)
  visible: !!player && title !== ""

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
      if (!root.player || !root.player.canTogglePlaying) return
      if (mouse.button === Qt.MiddleButton && root.player.canGoNext) root.player.next()
      else root.player.togglePlaying()
    }

    onWheel: wheel => {
      if (!root.player) return
      if (wheel.angleDelta.y > 0 && root.player.canGoPrevious) root.player.previous()
      else if (wheel.angleDelta.y < 0 && root.player.canGoNext) root.player.next()
    }
  }
}
