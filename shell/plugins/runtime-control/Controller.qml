import QtQuick
import Quickshell

// An on-demand controller, with no window or independent IPC target. Loading,
// opening or closing it never reloads the shell; reload-ui calls reload once
// preparation has reached the ordinary PluginInstance host contract.
Item {
  id: root
  property var host: null
  property var plugin: null
  property bool prepared: false
  property bool reloadQueued: false
  property int requestSerial: 0
  visible: false

  function open(payloadJson) {
    let payload
    try { payload = JSON.parse(payloadJson) }
    catch (error) { return "invalid-payload" }
    if (!payload || payload.action !== "prepare") return "unsupported"
    root.prepared = true
    return "ready"
  }

  function close() {
    root.prepared = false
    root.reloadQueued = false
    root.requestSerial += 1
  }

  function status(argument) {
    return root.prepared ? "ready" : "unprepared"
  }

  function reload(argument) {
    if (!root.prepared) return "unprepared"
    if (root.reloadQueued) return "requested"
    root.reloadQueued = true
    const serial = ++root.requestSerial
    // Finish the IPC reply before replacing this QML generation. The supported
    // soft reload keeps the process and attempts to reuse its native windows.
    Qt.callLater(function() {
      if (!root.prepared || !root.reloadQueued || root.requestSerial !== serial) return
      // A failed QML generation keeps this controller alive. Clear the queue
      // before invoking the API so a later explicit repair/rollback can retry.
      root.reloadQueued = false
      if (root.host && typeof root.host.prepareUiReload === "function") root.host.prepareUiReload()
      Quickshell.reload(false)
    })
    return "requested"
  }
}
