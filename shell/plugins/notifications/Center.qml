import QtQuick
import qs.Commons

import qs.Ui
import "." as Notifications

// Notification centre: history, do-not-disturb and clear.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: Math.min(560, window.screen ? window.screen.width - Style.space(8) : 560)
  panelHeight: Math.min(680, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 680)
  takesKeyboard: true

  Notifications.Model { id: notificationModel; host: root.host }
  readonly property var service: notificationModel
  readonly property bool available: service.available
  readonly property var entries: service.history
  readonly property int unread: service.unread
  readonly property bool dnd: service.dnd

  onOpened: if (service && service.markRead) service.markRead()


  Column {
    anchors.fill: parent
    anchors.margins: Style.space(1.5)
    spacing: Style.space(2)

    PanelHeader { width: parent.width; title: I18n.t("notifications.title"); glyph: "\uf0f3" }
    Row {
      spacing: Style.space(1)
      PanelButton { id: dndButton; label: I18n.t(root.dnd ? "notifications.dndOn" : "notifications.dnd"); glyph: "\uf1f6"; filled: true; enabled: root.available; selected: root.dnd; onClicked: if (root.service) root.service.setDnd(!root.dnd) }
      PanelButton { id: clearButton; label: I18n.t("common.clear"); filled: true; enabled: root.available && root.entries.length > 0; onClicked: if (root.service) root.service.clearHistory() }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Color.surfaceBorder
    }

    Text {
      width: parent.width
      visible: !root.available || root.service.operationError !== ""
      text: root.service.error || root.service.operationError
      color: Color.urgent
      wrapMode: Text.Wrap
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    Text {
      width: parent.width
      visible: root.available && root.entries.length === 0
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
      enabled: root.available

      delegate: Rectangle {
        required property var modelData

        width: list.width
        height: card.implicitHeight + Style.space(3)
        radius: Style.radius
        color: Color.surface

        function inspect() { return card.inspect(root.window.contentItem) }

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
      const cards = []
      for (let index = 0; index < list.count; index++) {
        const item = list.itemAtIndex(index)
        if (item && typeof item.inspect === "function") cards.push(item.inspect())
      }
      return JSON.stringify({ cards:cards, open: root.isOpen, available: root.available, error: root.service.error || root.service.operationError,
        dnd: root.dnd, unread: root.unread, count: root.entries.length, entries: root.entries,
        actions: [{ name: "dnd", x: dnd.x, y: dnd.y }, { name: "clear", x: clear.x, y: clear.y }] })
    }
  }
}
