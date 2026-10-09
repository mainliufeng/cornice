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

  function configured(id) {
    return ["left", "center", "right"].some(section =>
      Util.option(layout, section, []).some(entry => (typeof entry === "string" ? entry : entry && entry.id) === id))
  }

  // Entries may be a bare id ("cn.clock") or an object with inline options.
  function entriesFor(section) {
    const raw = Util.option(layout, section, [])
    const out = []
    for (const entry of raw) {
      if (typeof entry === "string") out.push({ id: entry })
      else if (entry && entry.id) out.push(entry)
    }
    if (section === "left" && DesktopSession.agentShell && !configured("cn.workspaces")) out.unshift({id:"cn.workspaces"})
    if (section === "left" && DesktopSession.agentShell && !configured("cn.agent-desktop")) out.push({id:"cn.agent-desktop"})
    if (!DesktopSession.agentShell && DesktopSession.service && DesktopSession.service.observer && DesktopSession.service.observer.isOpen)
      return out.filter(entry => entry.id === "cn.workspaces" || entry.id === "cn.agent-desktop")
    return out
  }

  readonly property var leftEntries: entriesFor("left")
  readonly property var centerEntries: entriesFor("center")
  readonly property var rightEntries: entriesFor("right")

  readonly property int surfaceHeight: Style.barHeight

  // Surface/section pairs, used by the geometry IPC target.
  property var geometryParts: []

  function registerGeometry(surface, section) {
    geometryParts = geometryParts.concat([{ surface: surface, section: section }])
  }
  readonly property bool atBottom: position === "bottom"

  function textGeometry(item, surface) {
    const out = []
    if (!item || !item.visible) return out
    if (item.text !== undefined && item.baselineOffset !== undefined && item.font !== undefined) {
      const point = item.mapToItem(surface.contentItem, 0, 0)
      out.push({ text: String(item.text), y: point.y, height: item.height,
        baseline: point.y + item.baselineOffset, pixelSize: item.font.pixelSize })
    }
    for (const child of item.children || []) out.push(...textGeometry(child, surface))
    return out
  }

  Variants {
    model: Quickshell.screens.filter(screen => !DesktopSession.agentShell || screen.name === DesktopSession.output)

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

      WlrLayershell.layer: !DesktopSession.agentShell && DesktopSession.service && DesktopSession.service.observer && DesktopSession.service.observer.isOpen ? WlrLayer.Overlay : WlrLayer.Top
      WlrLayershell.namespace: "cornice-bar"

      // Nothing on the bar takes keyboard focus; it is a status surface.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      DesktopBar {
        anchors.fill: parent
        host: bar.host; registry: bar.registry
        color: "transparent"
        leftEntries: bar.leftEntries; centerEntries: bar.centerEntries; rightEntries: bar.rightEntries
        Component.onCompleted: { for (const section of sections) bar.registerGeometry(surface, section) }
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


  // Where every widget actually is, in bar coordinates — the only reliable way
  // to answer "which icon did I just click?".
  ShellIpc {
    target: "bar"

    function geometry(): string {
      const out = []
      for (const part of bar.geometryParts) {
        if (!part.surface || !part.section) continue
        for (const child of part.section.children) {
          if (!child || child.entry === undefined) continue
          const point = child.mapToItem(part.surface.contentItem, 0, 0)
          out.push({
            id: child.entry.id,
            x: Math.round(point.x),
            y: point.y,
            height: child.height,
            width: Math.round(child.width),
            text: bar.textGeometry(child.item, part.surface),
            controls: child.item && typeof child.item.controls === "function" ? child.item.controls() : [],
            section: part.section.section
          })
        }
      }
      return JSON.stringify(out)
    }
  }
}
