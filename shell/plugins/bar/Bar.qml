import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Built-in bar. One layer-shell surface per screen, three sections each.
Item {
  id: bar

  property var host: null
  property var registry: null
  property var config: ({})

  readonly property var barConfig: Util.option(config, "bar", ({}))
  readonly property string position: Util.option(barConfig, "position", "top")
  readonly property bool transparent: Util.option(barConfig, "transparent", false)
  readonly property var layout: Util.option(barConfig, "layout", ({}))

  // Entries may be a bare id ("cn.clock") or an object with inline options.
  function entriesFor(section) {
    const raw = Util.option(layout, section, [])
    const out = []
    for (const entry of raw) {
      if (typeof entry === "string") out.push({ id: entry })
      else if (entry && entry.id) out.push(entry)
    }
    return out
  }

  readonly property var leftEntries: entriesFor("left")
  readonly property var centerEntries: entriesFor("center")
  readonly property var rightEntries: entriesFor("right")

  readonly property int surfaceHeight: Style.barHeight
  readonly property bool atBottom: position === "bottom"

  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: surface

      required property var modelData

      screen: modelData
      implicitHeight: bar.surfaceHeight
      exclusiveZone: bar.surfaceHeight
      color: bar.transparent ? "transparent" : Color.barBackground
      visible: true

      anchors {
        top: !bar.atBottom
        bottom: bar.atBottom
        left: true
        right: true
      }

      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.namespace: "cornice-bar"

      // Nothing on the bar takes keyboard focus; it is a status surface.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      BarSection {
        anchors.left: parent.left
        anchors.leftMargin: Style.padding
        anchors.verticalCenter: parent.verticalCenter
        host: bar.host
        registry: bar.registry
        entries: bar.leftEntries
        section: "left"
      }

      BarSection {
        anchors.centerIn: parent
        host: bar.host
        registry: bar.registry
        entries: bar.centerEntries
        section: "center"
      }

      BarSection {
        anchors.right: parent.right
        anchors.rightMargin: Style.padding
        anchors.verticalCenter: parent.verticalCenter
        host: bar.host
        registry: bar.registry
        entries: bar.rightEntries
        section: "right"
      }

      // Diagnostics beat a silently empty bar.
      Text {
        anchors.centerIn: parent
        visible: bar.registry !== null && bar.registry.ready && bar.registry.plugins.length === 0
        text: "cornice: no plugins found (CORNICE_PATH=" + Quickshell.env("CORNICE_PATH") + ")"
        color: Color.urgent
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
    }
  }

}
