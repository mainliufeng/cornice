pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Single source of theme tokens.
//
// Sources, in order of precedence:
//   1. ~/.config/cornice/theme.json   (user override, wins outright)
//   2. <prefix>/themes/<name>/theme.json
//   3. the built-in fallback below
//
// Nothing in the shell may hardcode a colour: read it from qs.Commons.Color.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"

  // Set by shell.qml from config.theme.
  property string name: "mono"

  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") !== undefined && Quickshell.env("XDG_CONFIG_HOME") !== ""
    ? Quickshell.env("XDG_CONFIG_HOME")
    : home + "/.config"

  readonly property string userPath: configHome + "/cornice/theme.json"
  readonly property string builtinPath: prefix + "/themes/" + name + "/theme.json"

  readonly property var fallback: ({
    colors: {
      foreground: "#c9d1d9",
      background: "#0d1117",
      accent: "#58a6ff",
      urgent: "#f85149",
      muted: "#6e7681"
    },
    metrics: {
      barHeight: 38,
      fontSize: 16,
      radius: 0,
      gap: 8,
      padding: 12
    }
  })

  property var userValues: undefined
  property var builtinValues: undefined
  property string error: ""

  readonly property var values: {
    if (userValues) return userValues
    if (builtinValues) return builtinValues
    return fallback
  }

  readonly property var colors: Util.deepMerge(fallback.colors, values.colors || ({}))
  readonly property var metrics: Util.deepMerge(fallback.metrics, values.metrics || ({}))

  function apply(text, fromUser) {
    if (!text || text.trim() === "") return
    try {
      const parsed = JSON.parse(text)
      if (fromUser) userValues = parsed
      else builtinValues = parsed
      error = ""
    } catch (e) {
      error = "theme parse failed (" + (fromUser ? userPath : builtinPath) + "): " + e
      console.warn("cornice: " + error)
    }
  }

  readonly property FileView userFile: FileView {
    path: root.userPath
    watchChanges: true
    printErrors: false
    onLoaded: root.apply(text(), true)
    onTextChanged: root.apply(text(), true)
  }

  readonly property FileView builtinFile: FileView {
    path: root.builtinPath
    watchChanges: false
    printErrors: false
    onLoaded: root.apply(text(), false)
    onTextChanged: root.apply(text(), false)
  }
}
