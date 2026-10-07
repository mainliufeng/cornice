import QtQuick
import qs.Commons
Item {
  id: root
  property var host: null
  property var plugin: null
  property var widgetConfig: ({})
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  visible: service && service.enabled
  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)
  Text {
    id: label; anchors.centerIn: parent
    text: "Agent " + (root.service ? root.service.desktops.length : 0)
    color: root.service && root.service.available ? Color.barForeground : Color.urgent
    font.family: Style.fontFamily; font.pixelSize: Style.fontSize
  }
  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (root.host) root.host.toggle("cn.agent-desktop", {}) }
}
