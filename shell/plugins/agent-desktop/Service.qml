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
    return desktop.error || !desktop.available ? "不可用" : desktop.controlMode === "human" ? "人工控制" : desktop.paused ? "已暂停" : "Agent 控制"
  }
  property var tasks: ({})
  property var modelConfig: ({})
  property string taskError: ""
  property var submissionErrors: ({})
  function submissionResult(name, error) {
    const errors = Object.assign({}, submissionErrors)
    if (error) errors[name] = error
    else delete errors[name]
    submissionErrors = errors
  }
  property bool taskRefreshPending: false
  property var notifiedTasks: ({})
  function refreshTasks() {
    if (!enabled) return
    if (taskStatus.running) { taskRefreshPending = true; return }
    taskRefreshPending = false
    taskStatus.running = true
  }
  function reportTaskFailures() {
    if (DesktopSession.agentShell) return
    const seen = Object.assign({}, notifiedTasks)
    for (const name of Object.keys(tasks)) {
      const task = tasks[name]
      if (!task.runId || !["failed", "needs_attention", "blocked"].includes(task.phase)) continue
      const key = task.runId + ":" + task.phase
      if (seen[name] === key) continue
      seen[name] = key
      Quickshell.execDetached(["notify-send", "--app-name=cornice", "--urgency=critical", "--expire-time=10000",
        desktopLabel(name) + " · " + (task.phase === "blocked" ? "任务受阻" : "任务未能执行"), String(task.message || "请查看任务状态。")])
    }
    notifiedTasks = seen
  }
  function prompt(name) { taskPrompt.open(name) }
  function cancelTask(name) {
    if (taskCancel.running) return
    taskCancel.command = [prefix + "/bin/cornice-agent-runtime", "cancel", name]
    taskCancel.running = true
  }
  DesktopTaskPrompt {id:taskPrompt;service:root}
  Process {
    id: modelStatus; command:[root.prefix + "/bin/cornice-agent-runtime", "config-status"];running:root.enabled
    stdout:StdioCollector {onStreamFinished: {try {root.modelConfig = JSON.parse(text)} catch(e) {}}}
  }
  Timer {interval:1000;repeat:true;running:root.enabled;triggeredOnStart:true;onTriggered:root.refreshTasks()}
  Process {
    id:taskStatus;command:[root.prefix + "/bin/cornice-agent-runtime", "status-all"]
    property bool validReply: false
    property string readError: ""
    onStarted: { validReply = false; readError = "" }
    stdout:StdioCollector {
      onStreamFinished: {
        try {
          const result = JSON.parse(text)
          if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("invalid status")
          for (const name of Object.keys(result)) {
            const task = result[name]
            if (!task || typeof task !== "object" || Array.isArray(task) || typeof task.phase !== "string" || task.phase.trim() === "")
              throw new Error("无效任务状态：" + name)
          }
          root.tasks = result; taskStatus.validReply = true; root.taskError = ""; root.reportTaskFailures()
        } catch(e) { taskStatus.validReply = false; taskStatus.readError = "任务状态读取失败：" + String(e.message || "当前显示可能已过期。") }
      }
    }
    stderr:StdioCollector {onStreamFinished:if (text.trim() !== "") taskStatus.readError = "任务状态读取失败：" + text.trim()}
    onExited: code => {
      if (code !== 0 || !validReply) root.taskError = readError || "任务状态读取失败，当前显示可能已过期。"
      if (root.taskRefreshPending) root.refreshTasks()
    }
  }
  Process {
    id:taskCancel
    stderr:StdioCollector {onStreamFinished:if (text.trim() !== "") root.taskError = text.trim()}
    onExited:root.refreshTasks()
  }
  Connections {
    target:Hyprland
    function onRawEvent(event) {
      if (event.name === "seatshortcut" && event.data === (DesktopSession.agentShell ? DesktopSession.name : "") + ",prompt") root.prompt(DesktopSession.agentShell ? DesktopSession.name : root.selectedDesktop)
      if (event.name === "seatworkspace" || event.name === "seatpresentation" || event.name === "seatcontrol") root.refresh()
      if (event.name === "seatcontrol") root.refreshTasks()
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
        selected: root.selectedDesktop, prompt: {open:taskPrompt.opened,name:taskPrompt.name}, tasks: root.tasks, taskError:root.taskError, submissionErrors:root.submissionErrors, model: root.modelConfig, error: root.error, socket: root.socketPath, busy: root.busy})
    }
    function prompt(name: string): string { root.prompt(name); return "opened" }
    function refreshTasks(): string { root.refreshTasks(); return "requested" }
    function promptDraft(): string { return JSON.stringify(taskPrompt.draft()) }
    function observe(name: string): string {
      if (!root.available) return "desktop-unavailable"
      return root.show(name)
    }
  }
}
