import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Discovers plugins: manifests under <prefix>/shell/plugins/**/manifest.json
// (built-in) and ~/.config/cornice/plugins/*/manifest.json (user).
//
// One shell process emits one JSON object per line; jq is used when present,
// python3 as a fallback, so neither is a hard requirement.
Item {
  id: root

  property var host: null
  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property string home: Quickshell.env("HOME")

  readonly property string builtinDir: prefix + "/shell/plugins"
  readonly property string userDir: home + "/.config/cornice/plugins"

  property var plugins: []
  property bool ready: false
  property string error: ""

  function byId(id) {
    for (const plugin of plugins) if (plugin.id === id) return plugin
    return null
  }

  function forKind(kind) {
    const out = []
    for (const plugin of plugins) {
      const kinds = plugin.kinds || []
      if (kinds.indexOf(kind) !== -1) out.push(plugin)
    }
    return out
  }

  function barOptions() {
    return forKind("bar")
  }

  function barWidgets() {
    const out = []
    for (const plugin of plugins) {
      const kinds = plugin.kinds || []
      if (kinds.indexOf("bar-widget") === -1) continue
      const meta = plugin.barWidget || ({})
      out.push({
        id: plugin.id,
        name: plugin.name,
        displayName: meta.displayName || plugin.name,
        category: meta.category || "",
        origin: plugin.origin
      })
    }
    return out
  }

  function rescan() {
    root.plugins = []
    root.ready = false
    root.error = ""
    scan.running = true
  }

  property string scanScript: [
    "set -u",
    'builtin="$1"; user="$2"',
    "emit() {",
    '  manifest="$1"; origin="$2"',
    '  dir="${manifest%/manifest.json}"',
    '  if command -v jq >/dev/null 2>&1; then',
    '    jq -c --arg dir "$dir" --arg origin "$origin" \'. + {dir: $dir, origin: $origin}\' "$manifest" 2>/dev/null || true',
    '  elif command -v python3 >/dev/null 2>&1; then',
    '    python3 -c \'import json,sys;d=json.load(open(sys.argv[1]));d["dir"]=sys.argv[2];d["origin"]=sys.argv[3];print(json.dumps(d))\' "$manifest" "$dir" "$origin" 2>/dev/null || true',
    "  else",
    '    echo "cornice: need jq or python3 to read plugin manifests" >&2',
    "  fi",
    "}",
    'for manifest in "$builtin"/*/manifest.json "$builtin"/*/*/manifest.json; do',
    '  [ -f "$manifest" ] || continue',
    '  emit "$manifest" builtin',
    "done",
    'for manifest in "$user"/*/manifest.json; do',
    '  [ -f "$manifest" ] || continue',
    '  emit "$manifest" user',
    "done"
  ].join("\n")

  Process {
    id: scan

    command: ["sh", "-c", root.scanScript, "scan", root.builtinDir, root.userDir]
    running: true
    stdout: SplitParser {
      onRead: line => root.accept(line)
    }
    onExited: root.finish()
  }

  property var pending: []

  function accept(line) {
    const text = String(line).trim()
    if (text === "") return
    try {
      pending.push(JSON.parse(text))
    } catch (e) {
      console.warn("cornice: bad plugin manifest line: " + text)
    }
  }

  function finish() {
    const unique = []
    const seen = ({})
    for (const plugin of pending) {
      if (!plugin.id || seen[plugin.id]) continue
      seen[plugin.id] = true
      unique.push(plugin)
    }
    pending = []
    plugins = unique
    ready = true
  }

  Component.onCompleted: rescan()
}
