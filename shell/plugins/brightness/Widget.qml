import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Backlight control, shaped like the audio widget: one glyph that carries the
// level, the percentage on hover, the wheel to change it, and a left click that
// just shows the brightness OSD (so clicking always does something visible).
//
// Reading goes through `light -G` (the same tool the idle plugin uses to dim),
// falling back to sysfs. Never render a placeholder glyph when the value is not
// known yet: a widget that shows "?" cannot be told apart from the rest, which is
// exactly how it was reported ("the gear one does not respond").
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int step: Math.max(1, Math.round(Util.option(widgetConfig, "step", 5)))
  property int percent: -1
  property bool hovered: false
  property bool busy: false

  readonly property bool known: percent >= 0
  // One family only (FontAwesome sun), dimmed glyph at the low end.
  readonly property string glyph: (percent >= 0 && percent < 33) ? "\uf186" : "\uf185"

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)

  function parse(text) {
    const value = Number(String(text).trim().split(/\s+/)[0])
    if (!isNaN(value) && value >= 0) return Math.round(value)
    const parts = String(text).trim().split(/\s+/)
    if (parts.length === 2) {
      const maximum = Number(parts[1])
      if (maximum > 0) return Math.round((Number(parts[0]) / maximum) * 100)
    }
    return -1
  }

  function refresh() {
    if (busy) return
    busy = true
    reader.command = ["bash", "-c",
      "if command -v light >/dev/null 2>&1; then light -G; else " +
      "for d in /sys/class/backlight/*; do [ -r \"$d/brightness\" ] || continue; " +
      "printf '%s %s' \"$(cat $d/brightness)\" \"$(cat $d/max_brightness)\"; break; done; fi"]
    reader.running = false
    reader.running = true
  }

  function setPercent(value) {
    const clamped = Math.max(1, Math.min(100, Math.round(value)))
    percent = clamped
    writer.command = ["light", "-S", String(clamped)]
    writer.running = false
    writer.running = true
    Util.exec("cornice ipc osd brightness")
  }

  Process {
    id: reader
    command: ["true"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const value = root.parse(text)
        if (value !== root.percent) console.log("cornice brightness: " + (value >= 0 ? value + "%" : "unavailable"))
        root.percent = value
        root.busy = false
      }
    }
  }

  Process {
    id: writer
    command: ["true"]
    onRunningChanged: if (!running) root.refresh()
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.hovered && root.known ? root.percent + "%" : root.glyph
    color: Color.barForeground
    opacity: root.known ? 1 : 0.5
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onHoveredChanged: root.hovered = hovered
    onClicked: {
      root.refresh()
      // Always give feedback, even before the value is known.
      Util.exec("cornice ipc osd brightness")
    }
  }

  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (!root.known) {
        root.refresh()
        return
      }
      root.setPercent(root.percent + (event.angleDelta.y > 0 ? root.step : -root.step))
    }
  }

  Component.onCompleted: refresh()

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }
}
