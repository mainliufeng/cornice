import QtQuick
import qs.Commons

// The notification UI has the same contract on every desktop. Only the
// session owner holds live Notification objects; other desktops use snapshots
// and forward actions to that owner, including actions and inline replies.
Item {
  id: root
  visible: false
  property var host: null
  readonly property var local: !SessionServices.secondary && host ? host.services["cn.notifications"] || null : null
  readonly property var remote: SessionServices.state("cn.notifications")
  readonly property var snapshot: local ? local.sessionSnapshot() : remote.snapshot || ({})
  readonly property bool available: local ? local.serverRegistered : remote.available && snapshot.serverReady === true
  readonly property string error: !available ? (local ? "Notification service is unavailable" : remote.error || "Notification service is unavailable") : ""
  readonly property string operationError: SessionServices.operationError
  readonly property var history: local ? local.history : snapshot.history || []
  readonly property int unread: local ? local.unread : Number(snapshot.unread || 0)
  readonly property bool dnd: local ? local.dnd : snapshot.dnd === true

  function invoke(method, args) {
    if (!available) return false
    if (DesktopSession.readOnly && ["invokeAction", "replyNotification", "dismiss"].indexOf(method) !== -1)
      return false
    return SessionServices.invoke("cn.notifications", "notifications", method, args || [])
  }
  function markRead() { return invoke("markRead") }
  function setDnd(value) { return invoke("setDnd", [value ? "true" : "false"]) }
  function clearHistory() { return invoke("clear") }
  function removeFromHistory(id) { return invoke("remove", [String(id)]) }
  function openCenter() {
    if (host && typeof host.summon === "function") host.summon("cn.notifications", {})
  }
  function liveNotification(id) {
    if (!available) return null
    if (local) return local.liveNotification(id)
    const record = (snapshot.live || []).find(item => Number(item.id) === Number(id))
    if (!record) return null
    const notification = Object.assign({}, record)
    notification.actions = (record.actions || []).map(action => {
      const identifier = action.identifier
      return {identifier:identifier,text:action.text,
        invoke:function() { return root.invoke("invokeAction", [String(id), identifier]) }}
    })
    notification.sendInlineReply = function(message) { return root.invoke("replyNotification", [String(id), String(message)]) }
    notification.dismiss = function() { return root.invoke("dismiss", [String(id)]) }
    return notification
  }
  Component.onCompleted: if (SessionServices.secondary) SessionServices.watch("cn.notifications")
}
