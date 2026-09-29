import QtQuick
import Quickshell.Services.Pipewire
import qs.Commons

Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int step: Util.option(widgetConfig, "step", 5)

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property bool muted: !!sink && !!sink.audio && sink.audio.muted
  readonly property real volume: (sink && sink.audio) ? sink.audio.volume : 0
  readonly property int percent: Math.round(Util.clamp(volume, 0, 1.5) * 100)

  // Same glyph set and order as the waybar config this replaces: percentage
  // first, then the icon (F026 off / F027 low / F028 high).
  readonly property string icon: {
    if (muted || percent === 0) return "\u{F0581}"
    if (percent < 40) return "\uf027"
    return "\uf028"
  }

  readonly property string text: percent + "%"

  // Quickshell only binds a PipeWire node's parameters (volume, mute) for
  // objects that are tracked — without this every node reports volume 0 and
  // muted false.
  PwObjectTracker {
    objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
  }

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)
  visible: !!sink

  Text {
    id: label
    anchors.centerIn: parent
    text: root.text + " " + root.icon
    color: root.muted ? Color.muted : Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor

    onClicked: mouse => {
      if (mouse.button === Qt.LeftButton)
        Util.exec("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
      else if (mouse.button === Qt.RightButton && root.host)
        root.host.toggle("cn.audio", {})
      else if (mouse.button === Qt.MiddleButton)
        Util.exec("pavucontrol-qt || pavucontrol")
    }

    onWheel: wheel => {
      const delta = wheel.angleDelta.y > 0 ? 1 : -1
      Util.exec("wpctl set-volume @DEFAULT_AUDIO_SINK@ " + (delta * root.step) + "%+")
    }
  }

  // Read-only support hook.
  ShellIpc {
    target: "audioinfo"

    function dump(): string {
      const all = Pipewire.nodes ? Pipewire.nodes.values : []
      const sinks = []
      for (const node of all) {
        if (!node.isSink || node.isStream) continue
        sinks.push({
          id: node.id,
          name: String(node.name),
          description: String(node.description),
          volume: node.audio ? node.audio.volume : null,
          muted: node.audio ? node.audio.muted : null,
          ready: node.ready
        })
      }
      return JSON.stringify({
        ready: Pipewire.ready,
        nodeCount: all.length,
        defaultSink: Pipewire.defaultAudioSink
          ? { id: Pipewire.defaultAudioSink.id, name: String(Pipewire.defaultAudioSink.name),
              volume: Pipewire.defaultAudioSink.audio ? Pipewire.defaultAudioSink.audio.volume : null }
          : null,
        preferredSink: Pipewire.preferredDefaultAudioSink
          ? String(Pipewire.preferredDefaultAudioSink.name) : null,
        sinks: sinks
      })
    }
  }
}
