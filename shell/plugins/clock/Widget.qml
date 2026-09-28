import QtQuick
import Quickshell
import qs.Commons

// SystemClock is a creatable type (not a global singleton): one instance per
// widget, ticking at the precision the format needs.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property string format: Util.option(widgetConfig, "format", "ddd HH:mm")
  readonly property string formatAlt: Util.option(widgetConfig, "formatAlt", "HH:mm:ss")

  property bool showAlt: false

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)

  SystemClock {
    id: clock
    enabled: true
    precision: root.showAlt ? SystemClock.Seconds : SystemClock.Minutes
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: Qt.formatDateTime(clock.date, root.showAlt ? root.formatAlt : root.format)
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.showAlt = !root.showAlt
  }
}
