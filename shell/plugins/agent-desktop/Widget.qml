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
  implicitWidth: switches.implicitWidth + manage.width + Style.space(0.5)
  DesktopSwitcher { id: switches; service: root.service }
  Rectangle {
    id: manage; anchors.left: switches.right; anchors.leftMargin: Style.space(0.5)
    height: Style.widgetHeight; width: label.implicitWidth + Style.space(1)
    color: mouse.containsMouse ? Color.hover : "transparent"; radius: Style.radius
    Text { id: label; anchors.centerIn: parent; text: "管理"; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (root.host) root.host.toggle("cn.agent-desktop", {}) }
  }
}
