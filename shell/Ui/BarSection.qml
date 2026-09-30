import QtQuick
import qs.Commons
import qs.Ui

// One horizontal group of bar widgets. The bar uses three of these.
Row {
  id: root

  property var host: null
  property var registry: null
  property var entries: []
  property string section: ""
  // Sections are bounded so a long window title or media string can never run
  // under the centre clock; widgets that support maxWidth elide themselves.
  property real maxWidth: -1

  spacing: Style.space(0.5)
  width: maxWidth > 0 ? Math.min(implicitWidth, maxWidth) : implicitWidth
  // Always clip: the bar also sets an explicit width so sections cannot reach
  // under the centre clock.
  clip: true

  function availableFor(index) {
    if (maxWidth < 0) return -1
    let used = spacing * Math.max(0, entries.length - 1)
    for (let i = 0; i < widgets.count; i++) {
      const widget = widgets.itemAt(i)
      if (i !== index && widget && widget.visible) used += widget.width
    }
    return Math.max(0, maxWidth - used)
  }

  Repeater {
    id: widgets
    model: root.entries

    delegate: BarWidgetLoader {
      required property var modelData
      required property int index

      host: root.host
      registry: root.registry
      entry: modelData
      section: root.section
      availableWidth: root.availableFor(index)
    }
  }
}
