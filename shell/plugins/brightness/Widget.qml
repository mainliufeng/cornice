import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Backlight control, shaped like the audio widget: one glyph that carries the
// level, a passive tooltip on hover, the wheel to change it, and a left click that
// opens the interactive brightness panel.
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
  readonly property var service: host ? host.services["cn.brightness"] : null
  readonly property int percent: service ? service.percent : -1

  readonly property bool known: percent >= 0
  // One family only (FontAwesome sun), dimmed glyph at the low end.
  // U+F0EB (bulb). Note U+F185 looks like a *sun* in most icon sets but this
  // machine's font (Hack Nerd Font) draws it as a cog — which is how the widget
  // was reported as "the gear one". The bulb is unambiguous here.
  readonly property string glyph: "\uf0eb"
  // Level is carried by opacity instead (same information, no missing glyph).
  readonly property real glyphOpacity: percent < 0 ? 0.45 : (0.45 + 0.55 * (percent / 100))

  implicitHeight: Style.widgetHeight
  implicitWidth: Style.widgetHeight

  Text {
    id: label
    anchors.centerIn: parent
    text: root.glyph
    color: Color.barForeground
    opacity: root.glyphOpacity
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (root.host) root.host.toggle("cn.brightness", {})
    }
  }

  BarTooltip {
    host: root.host
    anchorItem: root
    hovered: hit.containsMouse
    title: I18n.t("bar.widget.brightness") + (root.known ? " " + root.percent + "%" : "")
    detail: root.known ? "" : I18n.t("osd.noBacklight")
  }

  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (!root.service) return
      if (!root.known) {
        root.service.refresh()
        return
      }
      root.service.setPercent(root.percent + (event.angleDelta.y > 0 ? root.step : -root.step))
    }
  }

}
