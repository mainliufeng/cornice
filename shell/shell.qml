import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "services"

// The single long-lived Quickshell instance that hosts the Cornice desktop.
//
// Everything visible is a plugin: the bar, its widgets, panels, overlays and
// menus. This file owns the contract between them — configuration, theme,
// plugin discovery, service lifetime, summon/hide, and IPC.
ShellRoot {
  id: shell

  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property string home: Quickshell.env("HOME")
  readonly property string version: "0.2.4"

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string userName: Quickshell.env("USER") || "user"
  // Keep this identical to the path bin/cornice computes.
  readonly property string socketPath: runtimeDir + "/cornice-" + userName + ".sock"

  // Quickshell.env() returns null for an unset variable (not undefined), so test
  // truthiness: the old check accepted null and turned the config path into
  // "/cornice/config.json", meaning user config was never read at all.
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME")
    ? Quickshell.env("XDG_CONFIG_HOME")
    : home + "/.config"

  readonly property string defaultsPath: prefix + "/config/default.json"
  readonly property string userConfigPath: configHome + "/cornice/config.json"

  // Effective configuration: defaults deep-merged with the user's file. A user
  // file is never required — write only what you want to differ.
  property var defaults: ({})
  property var userConfig: undefined
  property var config: ({ version: 1, theme: "mono", bar: ({}) })
  property string configError: ""

  // Long-lived plugin instances (kind: service), keyed by plugin id, so other
  // first-party plugins can talk to them without a round trip through IPC.
  property var services: ({})

  // Exposed so plugins can introspect the shell (the bar layout editor lists the
  // available bar widgets, for instance).
  readonly property var registry: pluginRegistry

  function barWidgets() {
    return pluginRegistry.barWidgets()
  }

  // Summonable plugin instances: [{ id, entry, payload }].
  property var summoned: []

  function registerService(id, item) {
    const next = Util.shallow(services)
    next[id] = item
    services = next
  }

  function service(id) {
    return services[id] === undefined ? null : services[id]
  }

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
    // The cn.i18n service watches this and loads the matching table.
    I18n.language = Util.option(merged, "language", "en")
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

  // FileView has no reload(), and its watchChanges cannot watch a file that did
  // not exist yet — so a config created *after* the shell started used to be
  // ignored until the next restart. A Loader lets us recreate the view, and a
  // poller recreates it until the file finally loads.
  readonly property bool userConfigLoaded: userConfigLoader.item !== null && userConfigLoader.item.loaded === true

  Loader {
    id: userConfigLoader
    active: true
    sourceComponent: Component {
      FileView {
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
    }
  }

  function reloadUserConfig() {
    userConfigLoader.active = false
    userConfigReload.restart()
  }

  Timer {
    id: userConfigReload
    interval: 60
    repeat: false
    onTriggered: userConfigLoader.active = true
  }

  // Retry while the user config has never been read (it may simply not exist).
  Timer {
    interval: 3000
    repeat: true
    running: !shell.userConfigLoaded
    onTriggered: shell.reloadUserConfig()
  }

  // FileView's watchChanges did not fire for this file in practice, so poll the
  // mtime: one stat every two seconds, and reload when it moves.
  property string userConfigStamp: ""

  Process {
    id: userConfigStampProbe

    command: ["sh", "-c", "stat -c %Y " + JSON.stringify(shell.userConfigPath) + " 2>/dev/null || echo 0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const stamp = String(text).trim()
        if (shell.userConfigStamp !== "" && stamp !== shell.userConfigStamp)
          shell.reloadUserConfig()
        shell.userConfigStamp = stamp
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: userConfigStampProbe.running = true
  }

  PluginRegistry {
    id: pluginRegistry
    host: shell
  }

  IpcServer {
    socketPath: shell.socketPath
  }

  // ---- the bar -------------------------------------------------------------

  readonly property var barPlugin: {
    const wanted = Util.option(config.bar, "id", "cn.bar")
    return pluginRegistry.byId(wanted) || pluginRegistry.byId("cn.bar")
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
        "registry": pluginRegistry,
        "config": shell.config
      })
    }

    Connections {
      target: pluginRegistry
      function onReadyChanged() { barLoader.rebuild() }
    }

    Connections {
      target: shell
      function onConfigChanged() { barLoader.rebuild() }
    }
  }

  // ---- services and summoned plugins --------------------------------------
  //
  // Instances live under a container Item rather than directly under the
  // ShellRoot: a Repeater parented to a non-Item root never instantiates its
  // delegates, which silently produced zero plugin instances.
  Item {
    id: pluginInstances

    visible: false

    // Long-lived (kind: service) plugins.
    Repeater {
      id: serviceRepeater
      model: pluginRegistry.services()
      delegate: PluginInstance {
        required property var modelData
        host: shell
        registry: pluginRegistry
        pluginId: modelData.id
        entry: "service"
      }
    }

    // Plugins that stay mounted between summons (the OSD, the notification
    // centre): loaded once, then only opened and closed.
    Repeater {
      id: keepLoadedRepeater
      model: pluginRegistry.keepLoaded()
      delegate: PluginInstance {
        required property var modelData
        host: shell
        registry: pluginRegistry
        pluginId: modelData.id
        entry: shell.entryFor(modelData)
        payload: ({})
        autoOpen: false
      }
    }

    // Summoned panels, overlays and menus.
    Repeater {
      id: summonedRepeater
      model: shell.summoned
      delegate: PluginInstance {
        required property var modelData
        host: shell
        registry: pluginRegistry
        pluginId: modelData.id
        entry: modelData.entry
        payload: modelData.payload
      }
    }
  }

  // Summonable plugins declare one of these entry points; a plugin with
  // several kinds is addressed by its most specific one.
  function entryFor(plugin) {
    const points = plugin.entryPoints || ({})
    for (const candidate of ["panel", "overlay", "menu"]) {
      if (points[candidate]) return candidate
    }
    return ""
  }

  function summon(id, payload) {
    const plugin = pluginRegistry.byId(id)
    if (!plugin) return "unknown"
    const entry = entryFor(plugin)
    if (entry === "") return "not-summonable"

    // Kept-loaded plugins are already mounted: open them, do not remount.
    if (plugin.keepLoaded === true) {
      const instance = instanceFor(id)
      if (!instance) return "not-loaded"
      return instance.open(payload || ({}))
    }

    const next = []
    let replaced = false
    for (const instance of summoned) {
      if (instance.id === id) {
        next.push({ id: id, entry: entry, payload: payload || ({}) })
        replaced = true
      } else {
        next.push(instance)
      }
    }
    if (!replaced) next.push({ id: id, entry: entry, payload: payload || ({}) })
    summoned = next
    return "ok"
  }

  function hide(id) {
    const plugin = pluginRegistry.byId(id)
    if (plugin && plugin.keepLoaded === true) {
      const instance = instanceFor(id)
      if (instance) instance.close()
      return "ok"
    }
    summoned = summoned.filter(instance => instance.id !== id)
    return "ok"
  }

  function toggle(id, payload) {
    const plugin = pluginRegistry.byId(id)
    if (!plugin) return "unknown"

    // A kept-loaded panel is already mounted: close it when it is open, open it
    // otherwise. (Without this, a second click on a bar widget re-opened it.)
    if (plugin.keepLoaded === true) {
      const instance = instanceFor(id)
      if (!instance) return "not-loaded"
      if (instance.item && instance.item.isOpen === true) return instance.close()
      return instance.open(payload || ({}))
    }

    for (const instance of summoned) {
      if (instance.id === id) return hide(id)
    }
    return summon(id, payload)
  }

  function callPlugin(id, method, argument) {
    const instance = instanceFor(id)
    if (instance) return String(instance.call(method, argument))

    const service = shell.service(id)
    if (service && typeof service[method] === "function") {
      const result = service[method](argument)
      return result === undefined ? "ok" : String(result)
    }
    return "not-loaded"
  }

  function registerInstance(id, instance) {
    const next = Util.shallow(instanceMap)
    next[id] = instance
    instanceMap = next
  }

  function unregisterInstance(id) {
    const next = Util.shallow(instanceMap)
    delete next[id]
    instanceMap = next
  }

  ShellIpc {
    target: "shell"

    function ping(): string {
      return "pong " + shell.version
    }

    function version(): string {
      return shell.version
    }

    function debug(): string {
      return JSON.stringify({
        registryReady: pluginRegistry.ready,
        plugins: pluginRegistry.plugins.length,
        serviceModels: pluginRegistry.services().map(plugin => plugin.id),
        keepLoadedModels: pluginRegistry.keepLoaded().map(plugin => plugin.id),
        serviceRepeaterCount: serviceRepeater.count,
        keepLoadedCount: keepLoadedRepeater.count,
        summonedCount: summonedRepeater.count,
        instances: Object.keys(shell.instanceMap),
        openStates: Object.keys(shell.instanceMap).map(id => id + "=" + (shell.instanceMap[id].item ? (shell.instanceMap[id].item.isOpen === true ? "open" : "closed") : "noitem")),
        services: Object.keys(shell.services),
        barStatus: barLoader.status,
        targets: IpcRegistry.targets()
      })
    }

    // Where the visible plugin windows actually are: panel placement has bitten
    // this shell more than once (a panel sized for the wrong edge, a popup
    // overlapping the bar), and clicking one needs real numbers.
    function windows(): string {
      const out = []
      const map = shell.instanceMap || ({})
      for (const id of Object.keys(map)) {
        const instance = map[id]
        const item = instance ? instance.item : null
        if (!item || !item.window) continue
        const window = item.window
        out.push({
          id: id,
          entry: instance.entry,
          loaded: instance.loaded === true,
          open: item.isOpen === true,
          visible: window.visible === true,
          screen: window.screen ? window.screen.name : "",
          x: Math.round(window.x),
          y: Math.round(window.y),
          width: Math.round(window.width),
          height: Math.round(window.height)
        })
      }
      return JSON.stringify(out)
    }

    function targets(): string {
      return JSON.stringify(IpcRegistry.targets())
    }

    function socket(): string {
      return shell.socketPath
    }

    function config(): string {
      return JSON.stringify(shell.config)
    }

    function plugins(): string {
      return JSON.stringify(shell.pluginSummary())
    }

    function widgets(): string {
      return JSON.stringify(pluginRegistry.barWidgets())
    }

    function services(): string {
      return JSON.stringify(pluginRegistry.services().map(plugin => plugin.id))
    }

    function summon(id: string, payload: string): string {
      const parsed = shell.parseJson(payload === undefined ? "{}" : payload, "summon payload")
      return shell.summon(String(id), parsed || ({}))
    }

    function hide(id: string): string {
      return shell.hide(String(id))
    }

    function toggle(id: string, payload: string): string {
      const parsed = shell.parseJson(payload === undefined ? "{}" : payload, "toggle payload")
      return shell.toggle(String(id), parsed || ({}))
    }

    function call(id: string, method: string, argument: string): string {
      return shell.callPlugin(id, method, argument)
    }

    function reloadConfig(): string {
      shell.reloadUserConfig()
      return "ok"
    }

    function reloadPlugins(): string {
      pluginRegistry.rescan()
      return "ok"
    }

    function setTheme(themeName: string): string {
      Theme.name = themeName
      return Theme.name
    }

    function theme(): string {
      return Theme.name
    }
  }

  // The Repeater owns the instances; this maps an id back to its PluginInstance
  // so IPC can call into a summoned plugin.
  property var instanceMap: ({})

  function instanceFor(id) {
    return instanceMap[id] === undefined ? null : instanceMap[id]
  }

  function noteInstance(id, item) {
    const next = Util.shallow(instanceMap)
    if (item) next[id] = item
    else delete next[id]
    instanceMap = next
  }

  function pluginSummary() {
    const out = []
    for (const plugin of pluginRegistry.plugins) {
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

  // Hyprland only reports the focused toplevel through focus *events*. A shell
  // that starts into an already-focused session therefore has no active window
  // (and shows an empty title) until something steals focus. Ask once at
  // startup, and once more after the session has settled.
  Timer {
    interval: 1500
    repeat: false
    running: true
    onTriggered: shell.refreshHyprlandState()
  }

  function refreshHyprlandState() {
    if (Hyprland.refreshToplevels) Hyprland.refreshToplevels()
    if (Hyprland.refreshWorkspaces) Hyprland.refreshWorkspaces()
    if (Hyprland.refreshMonitors) Hyprland.refreshMonitors()
  }

  Component.onCompleted: {
    // Both FileViews load as soon as they are created; the user file is retried
    // by the poller above until it exists.
    refreshHyprlandState()
  }





}
