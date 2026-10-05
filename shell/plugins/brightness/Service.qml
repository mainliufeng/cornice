import QtQuick
import Quickshell.Io
import qs.Commons

Item {
  id: root
  property var host: null
  property var plugin: null
  property int percent: -1
  property int requested: -1
  property string error: ""
  readonly property bool known: percent >= 0

  function refresh() {
    if (!reader.running && !writer.running && requested < 0) reader.running = true
  }
  function setPercent(value) {
    if (!known) return
    if (!isFinite(Number(value))) return
    requested = Math.max(1, Math.min(100, Math.round(value)))
    percent = requested
    writeDelay.restart()
  }
  function writeNext() {
    if (writer.running || requested < 0) return
    const value = requested
    requested = -1
    writer.command = ["sh", "-c", "if command -v light >/dev/null 2>&1; then light -S " + value
      + "; elif command -v brightnessctl >/dev/null 2>&1; then brightnessctl -c backlight -q set " + value
      + "%; else exit 127; fi"]
    writer.running = true
  }
  Timer { id: writeDelay; interval: 60; onTriggered: root.writeNext() }
  Process {
    id: writer
    command: ["true"]
    onExited: (code, status) => {
      root.error = code === 0 ? "" : I18n.t("brightness.failed")
      if (root.requested >= 0) Qt.callLater(root.writeNext)
      else Qt.callLater(root.refresh)
    }
  }
  Process {
    id: reader
    command: ["sh", "-c", "if command -v light >/dev/null 2>&1; then light -G; else "
      + "for d in /sys/class/backlight/*; do [ -r \"$d/brightness\" ] || continue; "
      + "printf '%s %s' \"$(cat $d/brightness)\" \"$(cat $d/max_brightness)\"; break; done; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (writer.running || root.requested >= 0) return
        const raw = String(text).trim()
        const parts = raw.split(/\s+/)
        const value = raw === "" ? NaN : (parts.length === 2 ? Number(parts[0]) / Number(parts[1]) * 100 : Number(parts[0]))
        root.percent = isFinite(value) && value >= 0 ? Math.max(0, Math.min(100, Math.round(value))) : -1
      }
    }
  }
  Timer { interval: 5000; running: true; repeat: true; onTriggered: root.refresh() }
  Component.onCompleted: refresh()
  ShellIpc {
    target: "brightness"
    function status(): string { return JSON.stringify({percent: root.percent, known: root.known, error: root.error}) }
    function set(value: string): string { root.setPercent(Number(value)); return "ok" }
  }
}
