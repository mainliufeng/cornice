import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Passive, source-output feedback survives the Launcher closing. No focus,
// input grab or shared notification service is needed to explain a refusal.
Item {
  id: root
  property var host: null
  readonly property var barWindow: root.QsWindow.window
  readonly property var lock: host && host.services ? host.services["cn.lock"] : null
  readonly property bool atBottom: host && host.config.bar && host.config.bar.position === "bottom"
  readonly property bool showing: !!barWindow && !(lock && lock.locked)
    && !DesktopSession.state.humanLocked
    && ActionFeedback.visibleFor(DesktopSession.selected, barWindow.screen ? barWindow.screen.name : "")
  readonly property string message: ActionFeedback.detail === "Tray service does not accept per-action activation tokens: org.freedesktop.DBus.Error.UnknownMethod"
    ? I18n.t("actions.trayUnsupported") : ActionFeedback.detail
  PanelWindow {
    visible: root.showing
    screen: root.barWindow ? root.barWindow.screen : null
    color: "transparent"
    focusable: false
    exclusiveZone: 0
    aboveWindows: true
    anchors.top: !root.atBottom
    anchors.bottom: root.atBottom
    margins.top: root.atBottom ? 0 : Style.barHeight + Style.space(0.75)
    margins.bottom: root.atBottom ? Style.barHeight + Style.space(0.75) : 0
    implicitWidth: Math.max(1, Math.min(480, (screen ? screen.width : 1280) - Style.padding * 2))
    implicitHeight: Math.ceil(content.implicitHeight) + Style.space(3)
    mask: Region {}
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-action-notice"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    Surface {
      anchors.fill: parent
      Column {
        id: content
        width: parent.width
        spacing: Style.space(0.5)
        Text {
          width: parent.width
          text: I18n.t("actions.failed")
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
          font.bold: true
        }
        Text {
          width: parent.width
          text: root.message
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          maximumLineCount: 8
          elide: Text.ElideRight
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }
      }
    }
  }
}
