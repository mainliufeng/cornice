import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons

// Shared MPRIS state and actions, so the bar widget and the panel agree on which
// player is "the" player and both can drive it.
Item {
  id: root

  property var host: null
  property var plugin: null

  readonly property var players: Mpris.players ? Mpris.players.values : []

  // An explicitly picked player (from the panel) wins; otherwise prefer whatever
  // is playing, then the first player that has a track.
  property var selected: null

  readonly property var player: {
    if (selected && players.indexOf(selected) !== -1) return selected
    const list = players || []
    for (const candidate of list) if (candidate.isPlaying) return candidate
    for (const candidate of list) if ((candidate.trackTitle || "") !== "") return candidate
    return list.length > 0 ? list[0] : null
  }

  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string album: player ? (player.trackAlbum || "") : ""
  readonly property string artUrl: player ? (player.trackArtUrl || "") : ""
  readonly property bool playing: player ? player.isPlaying === true : false
  readonly property real position: player ? Number(player.position || 0) : 0
  readonly property real length: player ? Number(player.length || 0) : 0
  readonly property bool hasPlayer: player !== null && title !== ""

  // MPRIS position is in microseconds.
  readonly property string positionLabel: formatTime(position)
  readonly property string lengthLabel: formatTime(length)
  readonly property real progress: length > 0 ? Util.clamp(position / length, 0, 1) : 0

  function formatTime(microseconds) {
    const total = Math.max(0, Math.floor(Number(microseconds || 0) / 1000000))
    const minutes = Math.floor(total / 60)
    const seconds = total % 60
    return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
  }

  function playPause() {
    if (player && player.canTogglePlaying) player.togglePlaying()
  }

  function next() {
    if (player && player.canGoNext) player.next()
  }

  function previous() {
    if (player && player.canGoPrevious) player.previous()
  }

  function seekTo(fraction) {
    if (!player || !player.canSeek || length <= 0) return
    player.position = Util.clamp(fraction, 0, 1) * length
  }

  function setVolume(value) {
    if (!player) return
    player.volume = Util.clamp(value, 0, 1)
  }

  function selectPlayer(candidate) {
    selected = candidate
  }

  // Players can be slow to update position; the panel polls this.
  property int positionTick: 0

  Timer {
    interval: 1000
    running: root.hasPlayer && root.playing
    repeat: true
    onTriggered: root.positionTick = root.positionTick + 1
  }

  ShellIpc {
    target: "media"

    function status(): string {
      return JSON.stringify({
        player: root.player ? String(root.player.identity || "unknown") : "",
        title: root.title,
        artist: root.artist,
        album: root.album,
        playing: root.playing,
        position: root.position,
        length: root.length,
        progress: root.progress,
        artUrl: root.artUrl,
        canSeek: root.player ? root.player.canSeek === true : false,
        canGoNext: root.player ? root.player.canGoNext === true : false,
        canGoPrevious: root.player ? root.player.canGoPrevious === true : false,
        players: (root.players || []).map(candidate => String(candidate.identity || candidate.dbusName || "player"))
      })
    }

    function playPause(): string {
      root.playPause()
      return "ok"
    }

    function next(): string {
      root.next()
      return "ok"
    }

    function previous(): string {
      root.previous()
      return "ok"
    }

    function seek(fraction: string): string {
      root.seekTo(Number(fraction))
      return "ok"
    }

    function volume(value: string): string {
      root.setVolume(Number(value))
      return "ok"
    }

    function select(index: string): string {
      const list = root.players || []
      const i = Number(index)
      if (i < 0 || i >= list.length) return "unknown-player"
      root.selectPlayer(list[i])
      return "ok"
    }
  }
}
