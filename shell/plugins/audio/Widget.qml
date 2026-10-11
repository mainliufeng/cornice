import QtQuick
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

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

  // The icon carries the level; hover details live outside the bar.
  readonly property string icon: {
    if (muted || percent === 0) return "\uf026"
    if (percent < 40) return "\uf027"
    return "\uf028"
  }

  // Quickshell only binds a PipeWire node's parameters (volume, mute) for
  // objects that are tracked — without this every node reports volume 0 and
  // muted false.
  PwObjectTracker {
    objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
  }

  implicitHeight: Style.widgetHeight
  implicitWidth: Style.widgetHeight
  visible: !!sink

  Text {
    id: label
    anchors.centerIn: parent
    text: root.icon
    color: root.muted ? Color.muted : Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    id: hit
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true

    onClicked: mouse => {
      if (mouse.button === Qt.LeftButton && root.host)
        root.host.toggle("cn.audio", {})
      else if (mouse.button === Qt.RightButton)
        Util.execSession("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
      else if (mouse.button === Qt.MiddleButton)
        Util.exec("pavucontrol-qt || pavucontrol")
    }

    onWheel: wheel => {
      // wpctl takes the direction as part of the value: "5%+" raises, "5%-"
      // lowers. Passing a negative number with "+" (which is what this used to
      // do) is parsed as an option, so scrolling down did nothing.
      const direction = wheel.angleDelta.y > 0 ? "+" : "-"
      Util.execSession("wpctl set-volume @DEFAULT_AUDIO_SINK@ " + root.step + "%" + direction)
    }
  }

  BarTooltip {
    host: root.host
    anchorItem: root
    hovered: hit.containsMouse
    title: I18n.t("bar.widget.audio") + " " + root.percent + "%"
    detail: root.muted ? I18n.t("common.muted") : (root.sink ? root.sink.description || root.sink.name : "")
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
