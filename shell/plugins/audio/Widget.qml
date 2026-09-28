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

  readonly property string icon: {
    if (muted || percent === 0) return "\uf026"
    if (percent < 40) return "\uf027"
    return "\uf028"
  }

  readonly property string text: muted ? "muted" : (percent + "%")

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)
  visible: !!sink

  Text {
    id: label
    anchors.centerIn: parent
    text: root.icon + " " + root.text
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
      else if (mouse.button === Qt.MiddleButton)
        Util.exec("pavucontrol-qt || pavucontrol")
    }

    onWheel: wheel => {
      const delta = wheel.angleDelta.y > 0 ? 1 : -1
      Util.exec("wpctl set-volume @DEFAULT_AUDIO_SINK@ " + (delta * root.step) + "%+")
    }
  }
}
