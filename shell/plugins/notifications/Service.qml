import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Wayland
import qs.Commons

import qs.Ui

// Notification daemon.
//
// Owns org.freedesktop.Notifications, keeps a bounded history, and shows popups
// on the top right. History and do-not-disturb are read by the indicators widget
// and the notification centre panel through the host's service registry.
Item {
  id: root

  property var host: null
  property var plugin: null

  // [{ key, id, entry }] — never the live Notification object: Quickshell
  // invalidates that wrapper once the client drops it, and calling a method on
  // the stale object throws instead of dismissing.
  property var popups: []
  // [{ id, appName, appIcon, summary, body, urgency, at }], newest first
  property var history: []
  property bool dnd: false
  property int unread: 0

  readonly property int historyLimit: Util.option(widgetConfigFromHost(), "historyLimit", 50)
  readonly property int defaultTimeout: Util.option(widgetConfigFromHost(), "timeout", 6000)
  readonly property int maxPopups: Util.option(widgetConfigFromHost(), "maxPopups", 4)

  function widgetConfigFromHost() {
    const config = host && host.config ? host.config : ({})
    return config.notifications || ({})
  }

  readonly property NotificationServer server: NotificationServer {
    keepOnReload: true
    onNotification: notification => root.receive(notification)
  }

  // The live object for a notification id, or null when it is already gone.
  function liveNotification(id) {
    const tracked = server.trackedNotifications
    if (!tracked) return null
    const list = tracked.values ? tracked.values : tracked
    for (const candidate of list) if (candidate && candidate.id === id) return candidate
    return null
  }

  function dismiss(id) {
    const live = liveNotification(id)
    if (!live) return false
    try {
      live.dismiss()
      return true
    } catch (e) {
      console.warn("cornice: could not dismiss notification " + id + ": " + e)
      return false
    }
  }

  function receive(notification) {
    // Tracking keeps the notification alive in the server after the client
    // withdraws it, which is what lets the centre dismiss it later.
    try {
      notification.tracked = true
    } catch (e) {
      console.warn("cornice: notification tracking unavailable: " + e)
    }

    const entry = {
      id: notification.id,
      appName: notification.appName || "",
      appIcon: notification.appIcon || "",
      summary: notification.summary || "",
      body: notification.body || "",
      urgency: notification.urgency,
      at: Date.now()
    }

    history = [entry].concat(history).slice(0, historyLimit)
    unread = unread + 1

    // Do-not-disturb still records the notification; it just does not pop up.
    if (dnd) {
      dismiss(notification.id)
      return
    }

    const next = [{ key: String(notification.id) + "-" + Date.now(), id: notification.id, entry: entry }]
      .concat(popups)

    // Never let a burst of notifications cover the screen.
    while (next.length > maxPopups) {
      const dropped = next.pop()
      if (dropped) dismiss(dropped.id)
    }

    popups = next
    armExpiry(notification)
  }

  function armExpiry(notification) {
    const timeout = notification.expireTimeout > 0 ? notification.expireTimeout : defaultTimeout
    expiry.interval = timeout
    expiry.notificationId = notification.id
    expiry.restart()
  }

  function dropPopup(key, shouldDismiss) {
    const next = []
    for (const popup of popups) {
      if (popup.key === key) {
        if (shouldDismiss) root.dismiss(popup.id)
        continue
      }
      next.push(popup)
    }
    popups = next
  }

  function dropByNotificationId(id, shouldDismiss) {
    const next = []
    for (const popup of popups) {
      if (popup.id === id) {
        if (shouldDismiss) root.dismiss(id)
        continue
      }
      next.push(popup)
    }
    popups = next
  }

  function openCenter() {
    if (host && typeof host.summon === "function") host.summon("cn.notifications", {})
  }

  function historyJson() {
    return JSON.stringify(history)
  }

  function clearHistory() {
    history = []
    unread = 0
  }

  function markRead() {
    unread = 0
  }

  function removeFromHistory(id) {
    history = history.filter(entry => entry.id !== id)
    return "ok"
  }

  function setDnd(value) {
    const next = (value === true || value === "true" || value === 1 || value === "1")
    dnd = next
    if (dnd) {
      for (const popup of popups) root.dismiss(popup.id)
      popups = []
    }
    return dnd ? "true" : "false"
  }

  Timer {
    id: expiry
    repeat: false
    property int notificationId: -1
    onTriggered: root.dropByNotificationId(notificationId, false)
  }

  // Popup stack. Not focusable: a notification must never steal the keyboard.
  PanelWindow {
    id: popupWindow

    visible: root.popups.length > 0
    color: "transparent"
    focusable: false
    exclusiveZone: 0
    aboveWindows: true
    implicitWidth: 360
    implicitHeight: column.implicitHeight

    anchors.top: true
    anchors.right: true
    margins.top: Style.barHeight + Style.space(1)
    margins.right: Style.space(1.5)

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-notification-popups"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Column {
      id: column

      anchors.top: parent.top
      anchors.right: parent.right
      width: parent.width
      spacing: Style.space(0.8)

      Repeater {
        model: root.popups

        delegate: Surface {
          required property var modelData

          width: column.width
          height: card.implicitHeight + padding * 2

          NotificationCard {
            id: card
            entry: modelData.entry
            width: parent.width
            onDismissed: root.dropPopup(modelData.key, true)
          }
        }
      }
    }
  }

  ShellIpc {
    target: "notifications"

    function count(): string {
      return String(root.unread)
    }

    function dnd(): string {
      return root.dnd ? "true" : "false"
    }

    function setDnd(value: string): string {
      return root.setDnd(value)
    }

    function toggleDnd(): string {
      return root.setDnd(!root.dnd)
    }

    function history(): string {
      return root.historyJson()
    }

    function clear(): string {
      root.clearHistory()
      return "ok"
    }

    function markRead(): string {
      root.markRead()
      return "ok"
    }

    function remove(id: string): string {
      return root.removeFromHistory(parseInt(id, 10))
    }

    function open(): string {
      root.openCenter()
      return "ok"
    }

    function dismissAll(): string {
      for (const popup of root.popups) root.dismiss(popup.id)
      root.popups = []
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        dnd: root.dnd,
        unread: root.unread,
        popups: root.popups.length,
        history: root.history.length,
        serverReady: root.server !== null
      })
    }
  }
}
