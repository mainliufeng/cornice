import QtQuick
import qs.Commons

import qs.Ui

// Notification centre: history, do-not-disturb and clear.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 420
  panelHeight: 470
  takesKeyboard: true

  // `services` is replaced wholesale when a service registers, so this binding
  // picks the notifications service up whenever it appears.
  readonly property var service: host ? host.services["cn.notifications"] : null
  readonly property var entries: service ? service.history : []
  readonly property int unread: service ? service.unread : 0
  readonly property bool dnd: service ? service.dnd : false

  onOpened: if (service && service.markRead) service.markRead()


  Column {
    anchors.fill: parent
    spacing: Style.space(1)

    Row {
      width: parent.width
      height: Style.widgetHeight
      spacing: Style.space(0.8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - controls.width - Style.space(1)
        text: "Notifications" + (root.unread > 0 ? "  (" + root.unread + " new)" : "")
        color: Color.foreground
        elide: Text.ElideRight
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
        font.bold: true
      }

      Row {
        id: controls
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(0.6)

        Rectangle {
          width: dndLabel.implicitWidth + Style.space(1.6)
          height: Style.widgetHeight
          radius: Style.radius
          color: root.dnd ? Color.workspaceActive : Color.hover

          Text {
            id: dndLabel
            anchors.centerIn: parent
            text: root.dnd ? "DND on" : "DND"
            color: root.dnd ? Color.workspaceActiveText : Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.service) root.service.setDnd(!root.dnd)
          }
        }

        Rectangle {
          width: clearLabel.implicitWidth + Style.space(1.6)
          height: Style.widgetHeight
          radius: Style.radius
          color: Color.hover

          Text {
            id: clearLabel
            anchors.centerIn: parent
            text: "Clear"
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.service) root.service.clearHistory()
          }
        }
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Color.surfaceBorder
    }

    Text {
      width: parent.width
      visible: root.entries.length === 0
      text: "Nothing yet."
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    ListView {
      id: list

      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(0.6)
      model: root.entries

      delegate: Rectangle {
        required property var modelData

        width: list.width
        height: card.implicitHeight + Style.space(1.6)
        radius: Style.radius
        color: Color.hover

        NotificationCard {
          id: card
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(0.8)
          anchors.rightMargin: Style.space(0.8)
          entry: modelData
          // The live object is what carries actions and inline-reply; the history
          // entry only holds the text we render.
          notification: root.service ? root.service.liveNotification(modelData.id) : null
          // The chip only exists while the panel is open, and closing the panel
          // drops any half-typed reply instead of leaving it holding the keyboard.
          allowReply: root.isOpen
          onDismissed: if (root.service) root.service.removeFromHistory(modelData.id)

          Connections {
            target: root
            function onDismissed() { card.replying = false }
          }
        }
      }
    }
  }
}
