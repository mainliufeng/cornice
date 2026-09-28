pragma Singleton
import QtQuick
import qs.Commons

// Structural tokens: spacing, sizes, type scale. Sizing decisions live here so
// a theme can change density without touching widget code.
QtObject {
  id: root

  readonly property int barHeight: Theme.metrics.barHeight
  readonly property int fontSize: Theme.metrics.fontSize
  readonly property int radius: Theme.metrics.radius
  readonly property int gap: Theme.metrics.gap
  readonly property int padding: Theme.metrics.padding

  readonly property int smallFontSize: Math.max(9, fontSize - 2)
  readonly property int largeFontSize: fontSize + 2

  // A widget's natural height inside the bar, leaving a little breathing room.
  readonly property int widgetHeight: barHeight - gap

  readonly property string fontFamily: Theme.metrics.fontFamily !== undefined
    ? Theme.metrics.fontFamily
    : "Hack Nerd Font"

  readonly property string iconFamily: Theme.metrics.iconFamily !== undefined
    ? Theme.metrics.iconFamily
    : fontFamily

  function space(multiplier) {
    return Math.round(gap * multiplier)
  }
}
