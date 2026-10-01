import QtQuick
import qs.Commons

import qs.Ui

// Notification centre: history, do-not-disturb and clear.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: Math.min(560, window.screen ? window.screen.width - Style.space(8) : 560)
  panelHeight: Math.min(680, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 680)
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
    anchors.margins: Style.space(1.5)
    spacing: Style.space(2)

    PanelHeader { width: parent.width; title: I18n.t("notifications.title"); glyph: "\uf0f3" }
    Row {
      spacing: Style.space(1)
      PanelButton { id: dndButton; label: I18n.t(root.dnd ? "notifications.dndOn" : "notifications.dnd"); glyph: "\uf1f6"; filled: true; selected: root.dnd; onClicked: if (root.service) root.service.setDnd(!root.dnd) }
      PanelButton { id: clearButton; label: I18n.t("common.clear"); filled: true; enabled: root.entries.length > 0; onClicked: if (root.service) root.service.clearHistory() }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Color.surfaceBorder
    }

    Text {
      width: parent.width
      visible: root.entries.length === 0
      text: I18n.t("notifications.empty")
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    ListView {
      id: list

      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(1.5)
      model: root.entries

      delegate: Rectangle {
        required property var modelData

        width: list.width
        height: card.implicitHeight + Style.space(3)
        radius: Style.radius
        color: Color.surface

        NotificationCard {
          id: card
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(1.5)
          anchors.rightMargin: Style.space(1.5)
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
  ShellIpc {
    target: "notificationPanel"
    function state(): string {
      const dnd = dndButton.mapToItem(root.window.contentItem, dndButton.width / 2, dndButton.height / 2)
      const clear = clearButton.mapToItem(root.window.contentItem, clearButton.width / 2, clearButton.height / 2)
      return JSON.stringify({ open: root.isOpen, dnd: root.dnd, count: root.entries.length,
        actions: [{ name: "dnd", x: dnd.x, y: dnd.y }, { name: "clear", x: clear.x, y: clear.y }] })
    }
  }
}
