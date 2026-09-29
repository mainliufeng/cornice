import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Current keyboard layout, straight from the compositor.
//
// Hyprland pushes layout changes on its event socket (`activelayout>>`), so we
// subscribe with socat and only fall back to polling hyprctl when socat is not
// installed. Clicking cycles the layout (useful with `kb_layout = us,cn`).
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property var settings: widgetConfig || ({})
  readonly property string textFormat: Util.option(settings, "format", "{layout}")
  readonly property bool hideWhenSingle: Util.option(settings, "hideWhenSingle", false)

  property string layoutCode: ""
  property string layoutName: ""
  property var configuredLayouts: []
  property string lastAction: ""

  readonly property bool singleLayout: configuredLayouts.length <= 1
  readonly property bool meaningful: !(hideWhenSingle && singleLayout)
  readonly property string label: textFormat
    .replace("{layout}", layoutCode.toUpperCase())
    .replace("{name}", layoutName)

  visible: meaningful
  implicitHeight: Style.widgetHeight
  implicitWidth: meaningful ? labelText.implicitWidth + Style.space(1.2) : 0

  // Empty when the shell was started without the compositor's environment (an
  // agent shell, a broken unit) — the listener is skipped and polling covers it.
  readonly property string socketPath: {
    const runtime = Quickshell.env("XDG_RUNTIME_DIR") || ""
    const signature = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
    if (runtime === "" || signature === "") return ""
    return runtime + "/hypr/" + signature + "/.socket2.sock"
  }

  // ---- initial state + polling fallback ------------------------------------
  Process {
    id: probe
    command: ["hyprctl", "-j", "devices"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const data = JSON.parse(text)
          const keyboards = data.keyboards || []
          // The "main" layout is what the user actually types on; auxiliary
          // devices (power button, extra buttons) carry their own keymaps.
          const meaningful = keyboards.filter(device => {
            const name = String(device.name || "")
            return !/(extra-buttons|video-bus|intel-hid|sleep-button|power-button|button-array)/.test(name)
          })
          const active = meaningful.length > 0 ? meaningful[0] : keyboards[0]
          if (active) {
            root.layoutCode = String(active.layout || "").split(",")[0]
            root.layoutName = String(active.active_keymap || "")
          }
        } catch (error) {
          console.warn("cornice keylayout: could not parse hyprctl devices: " + error)
        }
      }
    }
  }

  Process {
    id: layoutOption
    command: ["hyprctl", "-j", "getoption", "input:kb_layout"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          const data = JSON.parse(text)
          const value = String(data.str || data.int || "")
          root.configuredLayouts = value === "" ? [] : value.split(",")
        } catch (error) {
          root.configuredLayouts = []
        }
      }
    }
  }

  // Event socket: one long-lived socat, parsed as it streams.
  Process {
    id: events
    running: root.socketPath !== ""
    command: ["socat", "-", "UNIX-CONNECT:" + root.socketPath]

    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: root.consume(text)
    }
  }

  // Without socat, fall back to polling (a layout change is rare, so 2s is fine).
  Timer {
    interval: 2000
    repeat: true
    running: !events.running
    onTriggered: probe.running = true
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: layoutOption.running = true
  }

  Component.onCompleted: {
    probe.running = true
    layoutOption.running = true
  }

  // `activelayout>>keyboard,Layout name` — the code itself is not in the event,
  // but the name is, and hyprctl's `layout` field is the short form.
  function consume(chunk) {
    if (!chunk) return
    const lines = chunk.split("\n")
    for (const line of lines) {
      if (line.indexOf("activelayout>>") === 0) {
        const payload = line.slice("activelayout>>".length)
        const comma = payload.indexOf(",")
        const name = comma >= 0 ? payload.slice(comma + 1) : payload
        root.layoutName = name
        // Refresh the short code lazily: the event carries only the name.
        probe.running = true
      }
    }
  }

  function cycle() {
    const command = ["hyprctl", "switchxkblayout", "all", "next"]
    switcher.command = command
    switcher.running = true
  }

  Process {
    id: switcher
    command: ["hyprctl", "switchxkblayout", "all", "next"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.lastAction = String(text).trim()
        probe.running = true
      }
    }
  }

  ShellIpc {
    target: "keylayout"

    function status(): string {
      return JSON.stringify({
        layout: root.layoutCode,
        name: root.layoutName,
        configured: root.configuredLayouts,
        visible: root.meaningful,
        lastAction: root.lastAction
      })
    }

    function next(): string {
      root.cycle()
      return "ok"
    }

    function refresh(): string {
      probe.running = true
      layoutOption.running = true
      return "ok"
    }
  }

  // NB: never name this `text` — it would shadow the StdioCollector's `text`
  // inside the handlers above, and JSON parsing would fail with a TypeError.
  Text {
    id: labelText
    anchors.centerIn: parent
    text: root.label
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: root.cycle()
  }
}
