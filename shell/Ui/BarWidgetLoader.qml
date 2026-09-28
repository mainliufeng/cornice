import QtQuick
import qs.Commons

// Loads a plugin's bar widget and injects the host contract:
//   host          — the ShellRoot (config, registries, lifecycle)
//   plugin        — the widget's manifest
//   widgetConfig  — this entry's inline options from config.json
//   section       — "left" | "center" | "right"
Loader {
  id: root

  property var host: null
  property var registry: null
  property var entry: ({})
  property string section: ""

  readonly property var plugin: (registry && entry && entry.id) ? registry.byId(entry.id) : null

  readonly property string widgetUrl: {
    if (!plugin) return ""
    const points = plugin.entryPoints || ({})
    const relative = points.barWidget || points.bar || ""
    if (relative === "") return ""
    return Qt.resolvedUrl(plugin.dir + "/" + relative)
  }

  function rebuild() {
    if (widgetUrl === "") {
      setSource("")
      return
    }
    if (source == widgetUrl) {
      if (item) {
        item.host = host
        item.widgetConfig = entry
      }
      return
    }
    setSource(widgetUrl, {
      "host": host,
      "plugin": plugin,
      "widgetConfig": entry
    })
  }

  Component.onCompleted: rebuild()
  onWidgetUrlChanged: rebuild()
  onStatusChanged: if (status === Loader.Error) console.warn("cornice: bar widget failed to load: " + widgetUrl)
  onLoaded: if (item && item.hasOwnProperty("section")) item.section = root.section
}
