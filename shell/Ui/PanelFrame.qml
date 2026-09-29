import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Base for every summoned surface (panel, overlay, menu).
//
// It is an Item — plugin entry points must be Items — and owns the layer-shell
// window, the placement and the dismissal gestures. A plugin supplies content
// and can hook `onOpened` / `onDismissed`.
Item {
  id: root

  property var host: null
  property var plugin: null

  // Placement, overridable per plugin.
  property string edge: "top"           // top | bottom | center
  property int panelWidth: 360
  property int panelHeight: 400
  property bool takesKeyboard: false
  // Dismiss when the user clicks somewhere else. This needs the same keyboard
  // grab as a keyboard panel, so interactive panels (the OSD) turn it off to
  // stay out of the way.
  property bool dismissOnClickAway: true

  // State driven by the shell.
  property bool isOpen: false
  property string payloadJson: "{}"
  readonly property var payload: parsePayload(payloadJson)

  signal opened()
  signal dismissed()

  default property alias content: contentArea.data

  readonly property alias window: window
  readonly property bool wantsKeyboard: takesKeyboard || dismissOnClickAway

  function parsePayload(json) {
    if (!json || json === "") return ({})
    try {
      return JSON.parse(json)
    } catch (e) {
      console.warn("cornice: bad panel payload: " + json)
      return ({})
    }
  }

  function open(json) {
    payloadJson = (json === undefined || json === "") ? "{}" : json
    isOpen = true
    opened()
  }

  function close() {
    if (!isOpen) return
    isOpen = false
    dismissed()
  }

  PanelWindow {
    id: window

    visible: root.isOpen
    color: "transparent"
    focusable: root.wantsKeyboard
    exclusiveZone: 0
    aboveWindows: true

    anchors.top: root.edge === "top" || root.edge === "center"
    anchors.bottom: root.edge === "bottom"
    // Only the left anchor is set: the surface is placed at margins.left, so a
    // half-screen margin centres it. (Anchoring both sides stretches it.)
    anchors.left: true

    // "center" means centred on the screen, not "just under the bar": layer-shell
    // has no vertical-centre anchor, so the offset is computed from the output.
    margins.top: root.edge === "top" ? Style.barHeight + Style.space(1)
      : root.edge === "center"
        ? Math.max(Style.barHeight + Style.space(1),
            Math.round(((window.screen ? window.screen.height : 1080) - root.panelHeight) / 2))
        : 0
    margins.bottom: root.edge === "bottom" ? Style.space(2) : 0
    margins.left: Math.max(0, Math.round(((window.screen ? window.screen.width : 1280) - root.panelWidth) / 2))

    implicitWidth: root.panelWidth
    implicitHeight: root.panelHeight

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-panel"
    WlrLayershell.keyboardFocus: root.wantsKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Surface {
      anchors.fill: parent
      padding: Style.space(1.4)

      Item {
        id: contentArea
        anchors.fill: parent
        focus: true

        // Escape closes any panel, focused input or not.
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }
      }
    }
  }

  // A keyboard panel takes an exclusive focus grab, which also reports when the
  // user clicks somewhere else — that is the dismissal gesture for a launcher.
  // The grab is what makes click-away dismissal work: Hyprland tells us when it
  // is released, which is exactly when the user clicked elsewhere.
  //
  // It must not arm in the same instant the panel opens, though: the click that
  // opened it (a bar widget) is still in flight, Hyprland reports the grab as
  // immediately cleared, and the panel closes before it is drawn — which looks
  // exactly like "clicking does nothing".
  property bool grabArmed: false

  Timer {
    id: armTimer
    interval: 220
    repeat: false
    onTriggered: root.grabArmed = true
  }

  Connections {
    target: root
    function onOpened() {
      root.grabArmed = false
      armTimer.restart()
    }
    function onDismissed() {
      armTimer.stop()
      root.grabArmed = false
    }
  }

  HyprlandFocusGrab {
    windows: [window]
    active: root.isOpen && root.wantsKeyboard && root.grabArmed
    onCleared: if (root.grabArmed) root.close()
  }
}
