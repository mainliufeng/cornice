import QtQuick
import Quickshell
import qs.Commons

// Hosts one plugin entry point.
//
// Full plugins are loaded only when they are needed: `service` entries at
// startup, `panel`/`overlay`/`menu` entries when summoned. The entry point
// (an Item) receives the shell contract and, for summonable kinds, the
// `open(payloadJson)` / `close()` lifecycle the shell drives.
Item {
  id: root

  property var host: null
  property var registry: null
  property string pluginId: ""
  property string entry: "panel"
  property var payload: ({})
  // Summoned instances open as soon as they load; kept-loaded ones must not
  // (mounting the OSD or a panel at startup would flash every panel on screen).
  property bool autoOpen: true

  readonly property var plugin: (registry && pluginId !== "") ? registry.byId(pluginId) : null

  readonly property string url: {
    if (!plugin) return ""
    const points = plugin.entryPoints || ({})
    const relative = points[entry] || ""
    return relative === "" ? "" : Qt.resolvedUrl(plugin.dir + "/" + relative)
  }

  readonly property var item: loader.item
  readonly property bool loaded: loader.status === Loader.Ready

  // No anchors on the root: Repeater delegates are parented to the Repeater,
  // whose parent is the ShellRoot — a window object, not an Item. Anchoring to
  // it makes the whole delegate fail to instantiate.
  implicitWidth: 0
  implicitHeight: 0

  function rebuild() {
    if (url === "") return
    if (loader.source == url) return
    loader.setSource(url, {
      "host": host,
      "plugin": plugin
    })
  }

  function open(payloadJson) {
    if (item && typeof item.open === "function") {
      item.open(JSON.stringify(payloadJson === undefined ? ({}) : payloadJson))
      return "ok"
    }
    return "unsupported"
  }

  function close() {
    if (item && typeof item.close === "function") {
      item.close()
      return "ok"
    }
    return "unsupported"
  }

  function call(method, argument) {
    if (!item) return "not-loaded"
    if (typeof item[method] !== "function") return "unknown"
    const result = item[method](argument)
    return result === undefined ? "ok" : result
  }

  Loader {
    id: loader
    anchors.fill: parent
    asynchronous: false

    onLoaded: {
      if (!item) return
      if (root.host) {
        if (root.entry === "service" && typeof root.host.registerService === "function")
          root.host.registerService(root.pluginId, item)
        else if (typeof root.host.registerInstance === "function")
          root.host.registerInstance(root.pluginId, root)
      }
      // A payload that arrived before the plugin finished loading still has to
      // reach it, otherwise a summoned panel would open empty.
      if (root.autoOpen && root.entry !== "service" && item.open !== undefined)
        root.open(root.payload)
    }

    onStatusChanged: {
      if (status === Loader.Error)
        console.warn("cornice: plugin failed to load: " + root.pluginId + " (" + root.url + ")")
    }
  }

  Connections {
    target: registry
    function onPluginsChanged() { rebuild() }
    function onReadyChanged() { rebuild() }
  }

  onUrlChanged: rebuild()
  onPayloadChanged: if (autoOpen && entry !== "service") open(payload)

  Component.onCompleted: rebuild()

  Component.onDestruction: {
    if (entry !== "service" && host && typeof host.unregisterInstance === "function")
      host.unregisterInstance(pluginId)
  }
}
