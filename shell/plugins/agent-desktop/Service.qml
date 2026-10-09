import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "."

Item {
  id: root
  property var host: null
  property var plugin: null
  readonly property var options: host && host.config ? host.config.agentDesktop || ({}) : ({})
  readonly property bool enabled: DesktopSession.agentShell || options.enabled === true
  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property string instance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/cornice/" + instance + "/desktop.sock"
  property string selectedDesktop: DesktopSession.name
  property var observer: null
  Component.onCompleted: DesktopSession.service = root
  function show(name) {
    if (!host) return "unavailable"
    if (DesktopSession.agentShell) {
      Quickshell.execDetached([prefix + "/bin/cornice-agent-view", name]); return "requested"
    }
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
  property var tasks: ({})
  property var modelConfig: ({})
  function prompt(name) { taskPrompt.open(name) }
  function cancelTask(name) { Quickshell.execDetached([prefix + "/bin/cornice-agent-runtime", "cancel", name]) }
  DesktopTaskPrompt {id:taskPrompt;service:root}
  Process {
    id: modelStatus; command:[root.prefix + "/bin/cornice-agent-runtime", "config-status"];running:root.enabled
    stdout:StdioCollector {onStreamFinished: {try {root.modelConfig = JSON.parse(text)} catch(e) {}}}
  }
  Timer {interval:1000;repeat:true;running:root.enabled;triggeredOnStart:true;onTriggered:if (!taskStatus.running) taskStatus.running = true}
  Process {
    id:taskStatus;command:[root.prefix + "/bin/cornice-agent-runtime", "status-all"]
    stdout:StdioCollector {onStreamFinished:{try {root.tasks = JSON.parse(text)} catch(e) {}}}
  }
  Connections {
    target:Hyprland
    function onRawEvent(event) {
      if (event.name === "seatshortcut" && event.data === DesktopSession.name + ",prompt") root.prompt(DesktopSession.agentShell ? DesktopSession.name : root.selectedDesktop)
      if (event.name === "seatworkspace" || event.name === "seatpresentation" || event.name === "seatcontrol") root.refresh()
    }
  }
  property bool available: false
  property var desktops: []
  property var workspaces: []
  property string error: ""
  property var pending: []
  property var bootstrapped: ({})
  property bool refreshPending: false
  readonly property bool busy: action.running || pending.length > 0

  function refresh() {
    if (!enabled) return
    if (poll.running || action.running) { refreshPending = true; return }
    refreshPending = false
    poll.running = true
  }
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
    const list = DesktopSession.agentShell ? [] : options.desktops || []
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
    onExited: if (root.refreshPending) root.refresh()
  }
  Process {
    id: action
    stdout: StdioCollector { onStreamFinished: {} }
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.error = text.trim() }
    onExited: { root.refresh(); root.dispatch() }
  }
  onEnabledChanged: {
    if (!enabled) { available = false; desktops = []; pending = []; refreshPending = false }
    else refresh()
  }
  ShellIpc {
    target: "desktop"
    function status(): string {
      return JSON.stringify({enabled: root.enabled, available: root.available, desktops: root.desktops,
        selected: root.selectedDesktop, prompt: {open:taskPrompt.opened,name:taskPrompt.name}, tasks: root.tasks, model: root.modelConfig, error: root.error, socket: root.socketPath, busy: root.busy})
    }
    function prompt(name: string): string { root.prompt(name); return "opened" }
    function promptDraft(): string { return JSON.stringify(taskPrompt.draft()) }
    function observe(name: string): string {
      if (!root.available) return "desktop-unavailable"
      return root.show(name)
    }
  }
}
