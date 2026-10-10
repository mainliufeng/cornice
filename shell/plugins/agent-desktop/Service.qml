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
  property string selectedDesktop: DesktopSession.name || "main"
  property var observer: null
  Component.onCompleted: DesktopSession.service = root
  function show(name) {
    if (!host) return "unavailable"
    if (DesktopSession.agentShell) {
      Quickshell.execDetached([prefix + "/bin/cornice-agent-view", name]); return "requested"
    }
    host.hide("cn.agent-desktop")
    if (!name || name === "main") { selectedDesktop = "main"; return host.hide("cn.desktop-observer") }
    if (!available || !desktops.some(item => item.name === name)) return "desktop-unavailable"
    return host.summon("cn.desktop-observer", {name: name})
  }
  function desktopLabel(name) {
    const desktop = desktops.find(item => item.name === name)
    if (desktop && desktop.label) return desktop.label
    if (!name || name === "main") return "桌面 1 · 主桌面"
    const definition = (options.desktops || []).find(item => item.name === name)
    return definition && definition.label || String(name).replace(/^agent([0-9]+)(?:-[0-9a-f]{8})?$/, "Agent $1")
  }
  function stateLabel(desktop) {
    const prefix = desktop.occupied === true ? harnessLabel(desktop) + " · " : ""
    if (desktop.humanLocked) return prefix + "已锁定"
    if (desktop.primary && desktop.controlMode === "human") return prefix + "人工控制"
    if (desktop.error || !desktop.available) return prefix + "不可用"
    if (desktop.controlMode === "human") return prefix + "人工接管"
    if (desktop.occupied === true) return prefix + (desktop.paused ? "已暂停" : "操作中")
    return "空闲"
  }
  property var hiddenPreviews: ({})
  readonly property var activeDesktops: desktops.filter(item => !item.primary && item.occupied === true)
  function harnessLabel(desktop) {
    const name = String(desktop.harness || "")
    return ({codex:"Codex",pi:"Pi"})[name.toLowerCase()] || name || "外部 Agent"
  }
  function previewVisible(name) { return hiddenPreviews[name] !== true }
  function hidePreview(name) { hiddenPreviews = Object.assign({}, hiddenPreviews, {[name]:true}) }
  function restorePreviews() { hiddenPreviews = ({}) }
  Connections {
    target:Hyprland
    function onRawEvent(event) {
      if (["seatworkspace", "seatpresentation", "seatcontrol"].includes(event.name)) root.refresh()
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
          const result = JSON.parse(text); root.desktops = (result.desktops || []).sort((a,b) => Number(a.number || 0) - Number(b.number || 0))
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
        selected: root.selectedDesktop, active: root.activeDesktops.map(item => item.name), hiddenPreviews:root.hiddenPreviews,
        error: root.error, socket: root.socketPath, busy: root.busy})
    }
    function restorePreviews(): string { root.restorePreviews(); return "ok" }
    function hidePreview(name: string): string { root.hidePreview(name); return "ok" }
    function observe(name: string): string {
      if (!root.available) return "desktop-unavailable"
      return root.show(name)
    }
  }
}
