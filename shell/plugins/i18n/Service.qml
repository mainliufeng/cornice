import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Loads the translation tables for the configured language.
//
// Keeping the file IO in a service means the rest of the shell only talks to the
// I18n singleton, and the configured language can change at runtime (cornice
// language <code>) without restarting anything.
Item {
  id: root

  property var host: null
  property var plugin: null

  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property var settings: (host && host.config) ? host.config : ({})

  readonly property string requested: Util.option(settings, "language", "en")
  readonly property string effective: requested === "" ? "en" : requested
  property string status: "loading"
  property string error: ""
  property int keyCount: 0

  readonly property string englishPath: prefix + "/i18n/en.json"
  readonly property string languagePath: prefix + "/i18n/" + effective + ".json"

  onEffectiveChanged: {
    english.reload()
    if (effective === "en") {
      // English is the fallback table; no second file to read.
      I18n.language = "en"
      I18n.table = I18n.fallback
      status = I18n.fallback === undefined || Object.keys(I18n.fallback).length === 0 ? "loading" : "ready"
    } else {
      translation.reload()
    }
  }

  // English doubles as the fallback table, so it is always loaded.
  readonly property FileView english: FileView {
    path: root.englishPath
    blockLoading: false

    onLoaded: {
      try {
        I18n.fallback = JSON.parse(text())
      } catch (error) {
        root.error = "en.json: " + error
        console.warn("cornice i18n: " + root.error)
      }
      if (root.effective === "en") {
        I18n.language = "en"
        I18n.table = I18n.fallback
      }
      root.refreshStatus()
    }

    onLoadFailed: error => {
      root.error = "could not read " + root.englishPath + ": " + error
      console.warn("cornice i18n: " + root.error)
      root.refreshStatus()
    }
  }

  readonly property FileView translation: FileView {
    path: root.languagePath
    blockLoading: false

    onLoaded: {
      try {
        const parsed = JSON.parse(text())
        I18n.table = parsed
        I18n.language = root.effective
        root.error = ""
      } catch (error) {
        root.error = root.languagePath + ": " + error
        console.warn("cornice i18n: " + root.error)
      }
      root.refreshStatus()
    }

    onLoadFailed: error => {
      // A missing language file is not fatal: English stays as the fallback and
      // the key itself is shown, so nothing renders empty.
      I18n.table = I18n.fallback
      root.error = "no translation file for '" + root.effective + "', using English"
      console.warn("cornice i18n: " + root.error)
      root.refreshStatus()
    }
  }

  function refreshStatus() {
    const keys = I18n.table ? Object.keys(I18n.table).length : 0
    keyCount = keys
    if (keys === 0 && I18n.fallback && Object.keys(I18n.fallback).length > 0) keyCount = keys
    status = keys > 0 ? "ready" : "loading"
  }

  // Languages that actually have a table on disk.
  readonly property Process listFiles: Process {
    command: ["sh", "-c",
      "ls " + JSON.stringify(prefix + "/i18n") + "/*.json 2>/dev/null | sed 's|.*/||; s|\\.json$||'"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: availableLanguages = String(text).split("\n").filter(line => line !== "")
    }
  }

  property var availableLanguages: []

  // One completion handler per object: QML rejects a second one
  // ("Property value set multiple times") and the whole plugin then fails to load.
  Component.onCompleted: {
    english.reload()
    listFiles.running = true
  }

  ShellIpc {
    target: "i18n"

    function status(): string {
      return JSON.stringify({
        language: I18n.language,
        requested: root.requested,
        status: root.status,
        keys: root.keyCount,
        available: root.availableLanguages,
        error: root.error,
        firstDayOfWeek: I18n.firstDayOfWeek
      })
    }

    function languages(): string {
      return JSON.stringify(root.availableLanguages)
    }

    function translate(key: string): string {
      return I18n.t(String(key))
    }

    // Test hook: every key the shell asks for must exist in the table, otherwise
    // a typo would silently render as the key itself.
    function missing(jsonKeys: string): string {
      try {
        const wanted = JSON.parse(jsonKeys)
        const table = I18n.table || ({})
        const fallback = I18n.fallback || ({})
        return JSON.stringify(wanted.filter(key => table[key] === undefined && fallback[key] === undefined))
      } catch (error) {
        return "[]"
      }
    }
  }
}
