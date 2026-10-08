import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root
  property var host: null
  property var plugin: null
  readonly property var options: host && host.config ? host.config.agentDesktop || ({}) : ({})
  readonly property bool enabled: options.enabled === true
  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property string instance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/cornice/" + instance + "/desktop.sock"
  property string selectedDesktop: ""
  function show(name) {
    if (!host) return "unavailable"
    host.hide("cn.agent-desktop")
    if (!name) return host.hide("cn.desktop-observer")
    if (!available || !desktops.some(item => item.name === name)) return "desktop-unavailable"
    return host.summon("cn.desktop-observer", {name: name})
  }
  function desktopLabel(name) {
    const definition = (options.desktops || []).find(item => item.name === name)
    return definition && definition.label || String(name).replace(/^agent([0-9]+)(?:-[0-9a-f]{8})?$/, "Agent $1")
  }
  function stateLabel(desktop) {
    return desktop.error || !desktop.available ? "不可用" : desktop.controlMode === "human" ? "接管中" : desktop.paused ? "已暂停" : "运行中"
  }
  property bool available: false
  property var desktops: []
  property var workspaces: []
  property string error: ""
  property var pending: []
  property var bootstrapped: ({})
  readonly property bool busy: action.running || pending.length > 0

  function refresh() { if (enabled && !poll.running && !action.running) poll.running = true }
  function operate(args) {
    if (!enabled || instance === "") { error = "Enable Agent desktops in this compositor session first"; return }
    pending = pending.concat([args]); dispatch()
  }
  function dispatch() {
    if (action.running || pending.length === 0) return
    const next = pending.slice(); const args = next.shift(); pending = next
    action.command = [prefix + "/bin/cornice-desktop", "--instance", instance].concat(args)
    action.running = true
  }
  function bootstrap() {
    const list = options.desktops || []
    const done = Util.shallow(bootstrapped)
    for (const desktop of list) {
      const definition = JSON.stringify(desktop)
      if (!desktop.name || done[desktop.name] === definition) continue
      done[desktop.name] = definition
      // Existing seats keep their real workspace. Unknown seats are never claimed.
      if (!desktops.some(item => item.name === desktop.name))
        operate(["create", String(desktop.name)]
          .concat(desktop.initialWorkspace ? ["--workspace", String(desktop.initialWorkspace)] : [])
          .concat(desktop.output ? ["--output", String(desktop.output)] : ["--virtual-output", typeof desktop.virtualOutput === "object" ? String(desktop.virtualOutput.width || 1920) + "x" + String(desktop.virtualOutput.height || 1080) : String(desktop.virtualOutput || "1920x1080")])
          .concat(["--human-lock-policy", String(desktop.humanLockPolicy || "pause")]))
    }
    bootstrapped = done
  }
  Process {
    id: daemon
    command: [root.prefix + "/bin/cornice-desktop", "--instance", root.instance, "ensure"]
    running: root.enabled && root.instance !== ""
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.error = text.trim() }
  }
  Timer { interval: 1000; running: root.enabled; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Process {
    id: poll
    command: [root.prefix + "/bin/cornice-desktop", "--instance", root.instance, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const result = JSON.parse(text); root.desktops = result.desktops || []
          root.workspaces = result.workspaces || []; root.available = true; root.error = ""; root.bootstrap()
        } catch (e) { root.available = false; root.desktops = [] }
      }
    }
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.error = text.trim() }
  }
  Process {
    id: action
    stdout: StdioCollector { onStreamFinished: {} }
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.error = text.trim() }
    onExited: { root.refresh(); root.dispatch() }
  }
  onEnabledChanged: {
    if (!enabled) { available = false; desktops = []; pending = [] }
    else refresh()
  }
  ShellIpc {
    target: "desktop"
    function status(): string {
      return JSON.stringify({enabled: root.enabled, available: root.available, desktops: root.desktops,
        selected: root.selectedDesktop, error: root.error, socket: root.socketPath, busy: root.busy})
    }
    function observe(name: string): string {
      if (!root.available) return "desktop-unavailable"
      return root.show(name)
    }
  }
}
