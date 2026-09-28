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

  spacing: Style.space(0.5)

  Repeater {
    model: root.entries

    delegate: BarWidgetLoader {
      required property var modelData
      required property int index

      host: root.host
      registry: root.registry
      entry: modelData
      section: root.section
    }
  }
}
