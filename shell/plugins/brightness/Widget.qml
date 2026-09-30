import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Backlight control, the same shape as the audio widget: a single glyph that
// carries the level, the percentage on hover, and the wheel for changing it.
//
// The backlight is read straight from sysfs (what the OSD does too), so no extra
// tool has to be installed; writing goes through `light`, which the idle plugin
// already uses for dimming.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int step: Math.max(1, Math.round(Util.option(widgetConfig, "step", 5)))
  property int percent: -1
  property bool hovered: false

  readonly property bool known: percent >= 0
  readonly property string glyph: {
    if (percent < 0) return "\u{F0590}"
    if (percent >= 66) return "\uf185" // sun
    if (percent >= 33) return "\uf185"
    return "\uf186"                     // near-dark: the same family, dimmer
  }

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)

  function refresh() {
    reader.running = false
    reader.running = true
  }

  function setPercent(value) {
    const clamped = Math.max(1, Math.min(100, Math.round(value)))
    percent = clamped
    writer.command = ["light", "-S", String(clamped)]
    writer.running = false
    writer.running = true
    // The OSD plugin already knows how to draw the level.
    Util.exec("cornice ipc osd brightness")
  }

  Process {
    id: reader
    command: ["bash", "-c",
      "for d in /sys/class/backlight/*; do [ -r \"$d/brightness\" ] || continue; " +
      "printf '%s %s' \"$(cat $d/brightness)\" \"$(cat $d/max_brightness)\"; break; done"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const parts = String(text).trim().split(/\s+/)
        if (parts.length !== 2) {
          root.percent = -1
          return
        }
        const current = Number(parts[0])
        const maximum = Number(parts[1])
        root.percent = maximum > 0 ? Math.round((current / maximum) * 100) : -1
      }
    }
  }

  // `light` writes the value; its result is not read back, the sysfs read is.
  Process {
    id: writer
    command: ["true"]
    onRunningChanged: if (!running) refresh()
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.hovered && root.known ? root.percent + "%" : root.glyph
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onHoveredChanged: root.hovered = hovered
    onClicked: root.refresh()
  }

  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (!root.known) {
        root.refresh()
        return
      }
      const up = event.angleDelta.y > 0
      root.setPercent(root.percent + (up ? root.step : -root.step))
    }
  }

  Component.onCompleted: refresh()
  onPercentChanged: refreshTimer.restart()

  // Another tool may have changed the backlight (the idle plugin dims it); keep
  // the glyph honest without polling hard.
  Timer {
    id: refreshTimer
    interval: 5000
    repeat: true
    onTriggered: root.refresh()
  }
}
