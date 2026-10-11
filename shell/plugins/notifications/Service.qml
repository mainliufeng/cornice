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

  // Quickshell registers org.freedesktop.Notifications when this object is
  // created. At shell start the name may still be held by the previous instance
  // (it is dying), registration then fails and is never retried — the session
  // silently loses every notification from then on. So the server lives behind a
  // Loader that the watchdog below can recreate until we own the name.
  readonly property var server: serverHost.item
  property bool serverRegistered: false
  property int serverGeneration: 0

  Loader {
    id: serverHost
    active: true
    // Recreating is the only way to re-attempt the bus-name registration.
    property int generation: root.serverGeneration
    sourceComponent: Component {
      NotificationServer {
        keepOnReload: true
        // Opt-in on the server side: with this false (the default) Quickshell
        // clears hasInlineReply on every notification, so a client's
        // inline-reply action never produces a reply field — the action arrives,
        // and nothing can be done with it.
        inlineReplySupported: Util.option(widgetConfigFromHost(), "inlineReply", true)
        onNotification: notification => root.receive(notification)
      }
    }
    // A synchronous false→true is coalesced by the engine; unload now, reload
    // on the next tick so the server object is really recreated.
    onGenerationChanged: {
      active = false
      reloadTimer.restart()
    }
    onLoaded: root.serverRegistered = true

    Timer {
      id: reloadTimer
      interval: 50
      repeat: false
      onTriggered: serverHost.active = true
    }
  }

  // Watch who owns the name; take it back when the owner goes away.
  Process {
    id: nameProbe

    // Owner as "<unique name> <pid>", or "unowned".
    command: ["sh", "-c",
      "o=$(busctl --user get-name-owner org.freedesktop.Notifications 2>/dev/null); " +
      "if [ -z \"$o\" ]; then echo unowned; else " +
      "p=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus " +
      "org.freedesktop.DBus GetConnectionUnixProcessID s \"$o\" 2>/dev/null | awk '{print $2}'); " +
      "echo \"$o ${p:-0}\"; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const parts = String(text).trim().split(/\s+/)
        if (parts[0] === "unowned") {
          console.warn("cornice: org.freedesktop.Notifications is unowned; re-registering the notification server")
          root.recreateServer()
          return
        }
        const ownerPid = Number(parts[1] || 0)
        const ours = ownerPid !== 0 && ownerPid === Number(Quickshell.processId)
        root.serverRegistered = ours
        if (!ours)
          console.warn("cornice: another process (" + ownerPid + ") owns org.freedesktop.Notifications")
      }
    }
  }

  function recreateServer() {
    root.serverRegistered = false
    root.serverGeneration = root.serverGeneration + 1
  }

  Timer {
    interval: 10000
    running: root.server === null || !root.serverRegistered
    repeat: true
    onTriggered: nameProbe.running = true
  }

  function senderPidOf(notification) {
    const hints = notification ? notification.hints : null
    if (hints && hints["sender-pid"] !== undefined && hints["sender-pid"] !== null)
      return String(hints["sender-pid"])
    return ""
  }

  // The live object for a notification id, or null when it is already gone.
  function liveNotification(id) {
    const tracked = server ? server.trackedNotifications : null
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
      at: Date.now(),
      // Kept so the history list can still jump to the app after the live
      // notification object is gone.
      desktopEntry: notification.desktopEntry || "",
      senderPid: senderPidOf(notification)
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

  // JSON-safe state shared with desktop UI shells. Functions and live Qt
  // wrappers stay in the daemon; secondary cards refer to notification ids.
  function sessionSnapshot() {
    const live = []
    for (const entry of history) {
      const notification = liveNotification(entry.id)
      if (!notification) continue
      const raw = notification.actions || []
      const actions = Array.isArray(raw.values) ? raw.values : raw
      const descriptors = []
      for (let i = 0; i < actions.length; i++)
        descriptors.push({identifier:actions[i].identifier,text:actions[i].text})
      live.push({id:entry.id,hasInlineReply:notification.hasInlineReply === true,
        inlineReplyPlaceholder:notification.inlineReplyPlaceholder || "",actions:descriptors})
    }
    return {history:history,unread:unread,dnd:dnd,serverReady:server !== null && serverRegistered,live:live}
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
    const token = String(value).toLowerCase()
    if (["true", "1", "on", "false", "0", "off"].indexOf(token) === -1)
      throw new Error("Expected on/off or true/false for do-not-disturb")
    const next = token === "true" || token === "1" || token === "on"
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
    implicitWidth: Math.min(420, (screen ? screen.width : 1280) - Style.space(4))
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
            // Action buttons work in popups too; inline reply stays out because a
            // popup must never take the keyboard.
            notification: root.liveNotification(modelData.id)
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

    function inspect(): string {
      const tracked = root.server ? root.server.trackedNotifications : null
      const list = tracked && tracked.values ? tracked.values : (tracked || [])
      return JSON.stringify({
        inlineReplySupported: root.server ? root.server.inlineReplySupported : null,
        notifications: list.map(item => ({
          id: item.id,
          app: item.appName,
          hasInlineReply: item.hasInlineReply,
          placeholder: item.inlineReplyPlaceholder,
          actions: (item.actions || []).map(action => ({
            identifier: action.identifier,
            text: action.text
          })),
          hints: item.hints ? Object.keys(item.hints) : []
        }))
      })
    }

    function reply(id: string, message: string): string {
      const live = root.liveNotification(Number(id))
      if (!live) return "no-such-notification"
      if (live.hasInlineReply !== true) return "no-inline-reply"
      try {
        live.sendInlineReply(String(message))
      } catch (error) {
        return "failed: " + error
      }
      return "ok"
    }

    function invokeAction(id: string, identifier: string): string {
      const live = root.liveNotification(Number(id))
      if (!live) throw new Error("Notification is no longer available")
      const raw = live.actions || []
      const actions = Array.isArray(raw.values) ? raw.values : raw
      for (let i = 0; i < actions.length; i++) {
        if (actions[i].identifier !== identifier) continue
        actions[i].invoke()
        return "ok"
      }
      throw new Error("Notification action is no longer available")
    }

    function replyNotification(id: string, message: string): string {
      const live = root.liveNotification(Number(id))
      if (!live || live.hasInlineReply !== true) throw new Error("Notification reply is no longer available")
      live.sendInlineReply(String(message))
      return "ok"
    }

    function dismiss(id: string): string {
      if (!root.dismiss(Number(id))) throw new Error("Notification is no longer available")
      return "ok"
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
        serverReady: root.server !== null && root.serverRegistered
      })
    }
  }
}
