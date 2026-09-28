import QtQuick
import qs.Commons

// Notification count and do-not-disturb.
//
// Reads the notifications service straight out of the host's service registry
// (first-party plugins share those objects; the same trust model as any
// dotfile).
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property var notifications: host ? host.services["cn.notifications"] : null
  readonly property bool dnd: notifications ? notifications.dnd : false
  readonly property int unread: notifications ? notifications.unread : 0
  readonly property bool hideWhenZero: Util.option(widgetConfig, "hideWhenZero", true)

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)
  visible: !(hideWhenZero && unread === 0 && !dnd)

  Text {
    id: label
    anchors.centerIn: parent
    text: {
      if (dnd && unread === 0) return "\uf1f6"
      if (unread === 0) return "\uf0f3"
      return "\uf0f3 " + unread
    }
    color: dnd ? Color.muted : (unread > 0 ? Color.accent : Color.barForeground)
    font.family: Style.iconFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (!root.notifications) return
      if (mouse.button === Qt.MiddleButton) root.notifications.setDnd(!root.dnd)
      else root.notifications.openCenter()
    }
  }
}
