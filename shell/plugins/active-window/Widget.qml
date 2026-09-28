import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int maxWidth: Util.option(widgetConfig, "maxWidth", 420)

  // Quickshell learns the focused window from Hyprland's focus *events*. A shell
  // that starts into an already-focused session gets nothing until the user
  // switches windows (refreshToplevels() does not cover it), so fall back to
  // asking hyprctl — only while the event-driven value is still empty.
  readonly property string eventTitle: Hyprland.activeToplevel ? (Hyprland.activeToplevel.title || "") : ""
  property string polledTitle: ""
  readonly property string title: eventTitle !== "" ? eventTitle : polledTitle

  implicitHeight: Style.widgetHeight
  implicitWidth: Math.min(label.implicitWidth, maxWidth)
  visible: title !== ""

  Timer {
    interval: 2000
    repeat: true
    triggeredOnStart: true
    running: root.eventTitle === ""
    onTriggered: poller.running = true
  }

  Process {
    id: poller
    command: ["sh", "-c", "command -v hyprctl >/dev/null 2>&1 && hyprctl -j activewindow 2>/dev/null | jq -r '.title // \"\"'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.polledTitle = String(text).trim()
    }
  }

  Text {
    id: label
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.maxWidth)
    text: root.title
    elide: Text.ElideRight
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }
}
