import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "services"

// The single long-lived Quickshell instance that hosts the Cornice desktop.
//
// Everything visible is a plugin: the bar, its widgets, and (later) panels,
// overlays and menus. This file only owns the contract between them —
// configuration, theme, plugin discovery and IPC.
ShellRoot {
  id: shell

  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property string home: Quickshell.env("HOME")
  readonly property string version: "0.1.0"

  readonly property string defaultsPath: prefix + "/config/default.json"
  readonly property string userConfigPath: home + "/.config/cornice/config.json"

  // Effective configuration: defaults deep-merged with the user's file. A user
  // file is never required — write only what you want to differ.
  property var defaults: ({})
  property var userConfig: undefined
  property var config: ({ version: 1, theme: "mono", bar: ({}) })
  property string configError: ""

  function parseJson(text, label) {
    if (!text || text.trim() === "") return undefined
    try {
      configError = ""
      return JSON.parse(text)
    } catch (e) {
      configError = label + ": " + e
      console.warn("cornice: " + configError)
      return undefined
    }
  }

  function applyConfig() {
    const merged = Util.deepMerge(defaults, userConfig || ({}))
    config = merged
    Theme.name = Util.option(merged, "theme", "mono")
  }

  readonly property FileView defaultsFile: FileView {
    path: shell.defaultsPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      const parsed = shell.parseJson(text(), "config/default.json")
      if (parsed) shell.defaults = parsed
      shell.applyConfig()
    }
  }

  readonly property FileView userFile: FileView {
    path: shell.userConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      shell.userConfig = shell.parseJson(text(), shell.userConfigPath)
      shell.applyConfig()
    }
    onTextChanged: {
      shell.userConfig = shell.parseJson(text(), shell.userConfigPath)
      shell.applyConfig()
    }
  }

  PluginRegistry {
    id: registry
    host: shell
  }

  // The active bar: the configured `bar.id`, or the built-in bar as fallback.
  readonly property var barPlugin: {
    const wanted = Util.option(config.bar, "id", "cn.bar")
    return registry.byId(wanted) || registry.byId("cn.bar")
  }

  readonly property string barUrl: {
    if (!barPlugin) return ""
    const points = barPlugin.entryPoints || ({})
    const relative = points.bar || ""
    return relative === "" ? "" : Qt.resolvedUrl(barPlugin.dir + "/" + relative)
  }

  Loader {
    id: barLoader

    function rebuild() {
      if (shell.barUrl === "") return
      if (source == shell.barUrl) {
        if (item) item.config = shell.config
        return
      }
      setSource(shell.barUrl, {
        "host": shell,
        "registry": registry,
        "config": shell.config
      })
    }

    Connections {
      target: registry
      function onReadyChanged() { barLoader.rebuild() }
    }

    Connections {
      target: shell
      function onConfigChanged() { barLoader.rebuild() }
    }
  }

  IpcHandler {
    target: "shell"

    function ping(): string {
      return "pong " + shell.version
    }

    function version(): string {
      return shell.version
    }

    function config(): string {
      return JSON.stringify(shell.config)
    }

    function plugins(): string {
      return JSON.stringify(shell.pluginSummary())
    }

    function widgets(): string {
      return JSON.stringify(registry.barWidgets())
    }

    function reloadConfig(): string {
      shell.userFile.reload()
      shell.defaultsFile.reload()
      return "ok"
    }

    function reloadPlugins(): string {
      registry.rescan()
      return "ok"
    }

    function setTheme(themeName: string): string {
      Theme.name = String(themeName)
      return Theme.name
    }

    function theme(): string {
      return Theme.name
    }
  }

  function pluginSummary() {
    const out = []
    for (const plugin of registry.plugins) {
      out.push({
        id: plugin.id,
        name: plugin.name,
        version: plugin.version,
        kinds: plugin.kinds || [],
        origin: plugin.origin,
        dir: plugin.dir
      })
    }
    return out
  }

  Component.onCompleted: {
    defaultsFile.reload()
    userFile.reload()
  }
}
