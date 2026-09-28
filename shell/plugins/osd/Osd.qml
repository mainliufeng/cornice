import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// On-screen display for volume and brightness.
//
// Two ways in: values pushed over IPC (`cornice osd volume`), and the PipeWire
// sink/source volume changing — which is what volume keys do — so the overlay
// appears without callers having to know about it.
PanelFrame {
  id: root

  edge: "bottom"
  panelWidth: 280
  panelHeight: 54
  takesKeyboard: false

  // { kind, value, label, icon }
  property string kind: "volume"
  property real value: 0
  property string label: ""
  property string icon: "\uf028"
  property bool muted: false
  property bool armed: false

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource

  readonly property real sinkVolume: (sink && sink.audio) ? sink.audio.volume : -1
  readonly property bool sinkMuted: (sink && sink.audio) ? sink.audio.muted : false

  onSinkVolumeChanged: {
    if (!armed || sinkVolume < 0) return
    showVolume()
  }

  onSinkMutedChanged: {
    if (!armed) return
    showVolume()
  }

  // Ignore whatever the session was doing before we started watching.
  Timer {
    interval: 700
    running: true
    onTriggered: root.armed = true
  }

  Timer {
    id: hideTimer
    interval: 1600
    repeat: false
    onTriggered: root.close()
  }

  function showValues(nextKind, nextValue, nextLabel, nextIcon, nextMuted) {
    kind = nextKind
    value = Util.clamp(Number(nextValue) || 0, 0, 1)
    label = nextLabel === undefined || nextLabel === "" ? Math.round(value * 100) + "%" : nextLabel
    if (nextIcon !== undefined && nextIcon !== "") icon = nextIcon
    muted = nextMuted === true
    isOpen = true
    hideTimer.restart()
  }

  function iconForVolume(percent, isMuted) {
    if (isMuted || percent === 0) return "\uf026"
    if (percent < 40) return "\uf027"
    return "\uf028"
  }

  function showVolume() {
    const percent = Math.round(Util.clamp(sinkVolume, 0, 1.5) * 100)
    showValues("volume", Util.clamp(sinkVolume, 0, 1), percent + "%",
      iconForVolume(percent, sinkMuted), sinkMuted)
  }

  function showMicrophone() {
    const node = source
    const volume = (node && node.audio) ? node.audio.volume : 0
    const isMuted = (node && node.audio) ? node.audio.muted : false
    const percent = Math.round(Util.clamp(volume, 0, 1.5) * 100)
    showValues("microphone", Util.clamp(volume, 0, 1), isMuted ? "muted" : percent + "%",
      isMuted ? "\uf131" : "\uf130", isMuted)
  }

  // Brightness has no compositor signal, so read the sysfs backlight.
  readonly property Process brightnessReader: Process {
    command: ["sh", "-c",
      "for d in /sys/class/backlight/*; do [ -r \"$d/brightness\" ] || continue; " +
      "printf '%s %s' \"$(cat $d/brightness)\" \"$(cat $d/max_brightness)\"; break; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const parts = String(text).trim().split(" ")
        if (parts.length !== 2) {
          root.showValues("brightness", root.value, "no backlight", "\uf185", false)
          return
        }
        const current = Number(parts[0])
        const max = Number(parts[1]) || 1
        const fraction = Util.clamp(current / max, 0, 1)
        root.showValues("brightness", fraction, Math.round(fraction * 100) + "%", "\uf185", false)
      }
    }
  }

  function showBrightness() {
    brightnessReader.running = true
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(0.6)

    Row {
      width: parent.width
      height: Style.widgetHeight
      spacing: Style.space(0.8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        color: root.muted ? Color.muted : Color.foreground
        font.family: Style.iconFamily
        font.pixelSize: Style.fontSize + 4
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - (Style.fontSize + 4) - Style.space(0.8) - level.width
        text: root.label
        color: Color.foreground
        horizontalAlignment: Text.AlignRight
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }

      Text {
        id: level
        anchors.verticalCenter: parent.verticalCenter
        text: root.kind
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(0.7)
      radius: Style.radius
      color: Color.hover

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * root.value
        radius: Style.radius
        color: root.muted ? Color.muted : Color.accent

        Behavior on width {
          NumberAnimation { duration: 90 }
        }
      }
    }
  }

  ShellIpc {
    target: "osd"

    function show(kind: string, value: string, label: string): string {
      root.showValues(kind, Number(value), label, "", false)
      return "ok"
    }

    function volume(): string {
      root.showVolume()
      return "ok"
    }

    function microphone(): string {
      root.showMicrophone()
      return "ok"
    }

    function brightness(): string {
      root.showBrightness()
      return "ok"
    }

    function hide(): string {
      root.close()
      return "ok"
    }

    function status(): string {
      return JSON.stringify({ opened: root.isOpen, kind: root.kind, value: root.value })
    }
  }
}
