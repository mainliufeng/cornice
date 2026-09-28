import QtQuick
import qs.Commons

Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  implicitHeight: Style.widgetHeight
  implicitWidth: Util.option(widgetConfig, "size", 12)
}
