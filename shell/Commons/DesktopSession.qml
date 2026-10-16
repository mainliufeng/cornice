pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Cornice.Platform
QtObject {
  id: root
  readonly property string name: Quickshell.env("CORNICE_DESKTOP_NAME") || ""
  readonly property string output: Quickshell.env("CORNICE_DESKTOP_OUTPUT") || ""
  readonly property bool agentShell: name !== ""
  property var service: null
  readonly property string selected: agentShell ? name : service ? service.selectedDesktop : "main"
  readonly property bool secondary: selected !== "" && selected !== "main"
  readonly property var state: service ? service.desktops.find(item => item.name === selected) || ({}) : ({})
  readonly property bool observing: !agentShell && secondary && !!service && !!service.observer && service.observer.isOpen
  readonly property bool readOnly: observing && !service.observer.humanControl

  // All consumers use workspace identity, never the compositor's optional
  // numeric id. Official Hyprland and named-workspace native seats share this
  // contract; address/name are canonical, numeric ids remain compatibility data.
  function workspaceIdentity(value) {
    if (value === null || value === undefined) return {address:"", name:"", id:null, key:""}
    const raw = typeof value === "object" ? value : {name:String(value)}
    const address = String(raw.address || "").replace(/^name:/, "")
    const name = String(raw.name || address || "").replace(/^name:/, "")
    const numeric = raw.id !== undefined && raw.id !== null ? Number(raw.id)
      : /^-?[0-9]+$/.test(name) ? Number(name) : NaN
    const id = Number.isFinite(numeric) ? numeric : null
    return {address:address, name:name, id:id, key:address || name || (id !== null ? String(id) : "")}
  }
  function workspaceMatches(left, right) {
    const a = workspaceIdentity(left), b = workspaceIdentity(right)
    if (!a.key || !b.key) return false
    if (a.address && b.address) return a.address === b.address
    if (a.name && b.name) return a.name === b.name
    return a.id !== null && b.id !== null && a.id === b.id
  }
  function windowAddress(value) {
    const address = String(value || "").replace(/^0x/, "")
    return /^[0-9a-f]+$/i.test(address) && !/^0+$/.test(address) ? "0x" + address.toLowerCase() : ""
  }

  property var windowSnapshot: []
  property var primaryWorkspace: null
  property var primaryWindow: null
  property var primaryMonitors: []
  readonly property var currentWorkspace: secondary
    ? workspaceIdentity({address:state.workspace, name:state.workspaceName || state.workspace})
    : workspaceIdentity(primaryWorkspace !== null ? primaryWorkspace : Hyprland.focusedWorkspace)
  readonly property var observedWorkspace: {
    const presentation = observing ? service.observer.presentationState || ({})
      : agentShell ? state.presentation || ({}) : ({})
    if (!observing && !presentation.active) return currentWorkspace
    if (presentation.following || presentation.workspace === "current") return currentWorkspace
    return workspaceIdentity(presentation.workspace || presentation.viewWorkspace || currentWorkspace)
  }
  readonly property string viewedWorkspaceName: observedWorkspace.name
  readonly property bool viewingCurrentWorkspace: workspaceMatches(observedWorkspace, currentWorkspace)
  readonly property string focusedWindowAddress: secondary
    ? (viewingCurrentWorkspace ? windowAddress(state.windowAddress) : "")
    : windowAddress(primaryWindow !== null ? primaryWindow.address : Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "")
  readonly property string focusedWindowTitle: {
    if (!focusedWindowAddress) return ""
    const client = windowSnapshot.find(window => windowAddress(window.address) === focusedWindowAddress
      && workspaceMatches(window.workspace, observedWorkspace))
    if (client) return String(client.title || "")
    if (secondary) return String(state.window || "")
    return primaryWindow !== null ? String(primaryWindow.title || "")
      : Hyprland.activeToplevel ? String(Hyprland.activeToplevel.title || "") : ""
  }
  readonly property var availableWorkspaces: service && service.available ? service.workspaces
    : Hyprland.workspaces ? Hyprland.workspaces.values : []
  function slotWorkspace(slot) {
    if (!secondary) return workspaceIdentity({id:slot, name:String(slot)})
    const item = (state.workspaceSlots || []).find(item => Number(item.id) === Number(slot))
    return workspaceIdentity(item ? item.name : null)
  }
  function workspaceSlots(count) {
    const out = []
    for (let slot = 1; slot <= count; ++slot) {
      const identity = slotWorkspace(slot)
      const occupied = windowSnapshot.some(window => workspaceMatches(window.workspace, identity))
      out.push({id:slot, label:String(slot), workspace:identity, occupied:occupied,
        active:workspaceMatches(observedWorkspace, identity)})
    }
    return out
  }

  property bool windowsRefreshPending: false
  property bool windowsRefreshScheduled: false
  function refreshWindows() {
    windowsRefreshPending = true
    if (windowsRefreshScheduled) return
    windowsRefreshScheduled = true
    Qt.callLater(function() {
      root.windowsRefreshScheduled = false
      if (clientsPoll.running || !root.windowsRefreshPending) return
      root.windowsRefreshPending = false
      clientsPoll.running = true
    })
  }
  property var clientsPoll: Process {
    command:["hyprctl", "-j", "clients"]
    stdout:StdioCollector {
      onStreamFinished: {
        try {
          root.windowSnapshot = JSON.parse(text).filter(window => window.mapped && !window.hidden
            && (window.class !== "" || window.title !== ""))
        } catch (e) { console.warn("cornice: desktop window state failed: " + e) }
      }
    }
    onRunningChanged:if (!running && root.windowsRefreshPending) root.refreshWindows()
  }
  // QtQuick animation timers can stop on an unpresented private output.
  // Recovery uses a wall clock, while raw events coalesce on the Qt event loop.
  property double lastResync: 0
  property var stateResync: SystemClock {
    enabled:true
    precision:SystemClock.Seconds
    onDateChanged:if (Date.now() - root.lastResync >= 3000) {
      root.lastResync = Date.now()
      root.refreshWindows()
      root.refreshContext()
    }
  }

  // Quickshell's built-in model handles the official numeric schema. Read the
  // native JSON too so main's named workspace and stable focus use the same
  // contract as other seats. Debounce the event stream; never poll per frame.
  property bool contextRefreshPending: false
  property bool contextRefreshScheduled: false
  function refreshContext() {
    if (secondary) return
    contextRefreshPending = true
    if (contextRefreshScheduled) return
    contextRefreshScheduled = true
    Qt.callLater(function() {
      root.contextRefreshScheduled = false
      if (root.secondary || workspacePoll.running || windowPoll.running || monitorPoll.running || !root.contextRefreshPending) return
      root.contextRefreshPending = false
      workspacePoll.running = true
      windowPoll.running = true
      monitorPoll.running = true
    })
  }
  property var workspacePoll: Process {
    command:["hyprctl", "-j", "activeworkspace"]
    stdout:StdioCollector {onStreamFinished: {try {root.primaryWorkspace = JSON.parse(text)} catch (e) {}}}
    onRunningChanged:if (!running && root.contextRefreshPending) root.refreshContext()
  }
  property var windowPoll: Process {
    command:["hyprctl", "-j", "activewindow"]
    stdout:StdioCollector {onStreamFinished: {try {root.primaryWindow = JSON.parse(text)} catch (e) {}}}
    onRunningChanged:if (!running && root.contextRefreshPending) root.refreshContext()
  }
  property var monitorPoll: Process {
    command:["hyprctl", "-j", "monitors"]
    stdout:StdioCollector {onStreamFinished: {try {root.primaryMonitors = JSON.parse(text)} catch (e) {}}}
    onRunningChanged:if (!running && root.contextRefreshPending) root.refreshContext()
  }
  property var contextEvents: Connections {
    target:Hyprland
    function onRawEvent(event) {
      if (/^(openwindow|closewindow|movewindow|windowtitle|activewindow|workspace|focusedmon|changegroup|togglegroup|minimize)/.test(event.name)) {
        root.refreshWindows()
        root.refreshContext()
      }
      if (event.name === "seatinputfocus" && event.data.split(",")[0] === root.selected && root.service)
        root.service.refresh()
    }
  }
  onSecondaryChanged:refreshContext()
  Component.onCompleted: {refreshContext(); refreshWindows()}
  property var actionCallbacks: ({})
  property var applicationCallbacks: ({})
  property var trayCallbacks: ({})
  property string actionError: ""
  property var actionRouter: DesktopActionRouter {
    onPrepared: (request, context, error) => {
      const callback = root.actionCallbacks[request]
      delete root.actionCallbacks[request]
      if (callback) callback(context, error)
    }
    onApplicationChecked: (request, error) => {
      const callback = root.applicationCallbacks[request]
      delete root.applicationCallbacks[request]
      if (callback) callback(error)
    }
    onActionFinished: (request, success, error) => {
      const callback = root.trayCallbacks[request]
      delete root.trayCallbacks[request]
      if (callback) callback(success, error)
    }
  }
  function reportActionError(error, source) {
    actionError = String(error).replace(/^(?:cornice(?: desktop)?:\s*)+/, "")
    ActionFeedback.show(actionError, source.desktop, source.output)
    console.warn("cornice: " + actionError)
  }
  function withAction(callback, failure, sourceOutput) {
    if (readOnly || (secondary && (!state.seatId || !state.generation))) return false
    // Copy everything at invocation; callbacks must not read selected/state.
    const output = String(sourceOutput || root.output || "-")
    const monitor = primaryMonitors.find(item => item.name === output)
    const workspace = !secondary && output !== "-" ? workspaceIdentity(monitor ? monitor.activeWorkspace : null) : observedWorkspace
    if (!workspace.key) return false
    const source = {output:output, desktop:selected || "main", secondary:secondary,
      human:state.controlMode === "human", seat:String(state.seatId || "-"),
      generation:String(state.generation || "-"), workspace:workspace.key}
    if (source.secondary && !agentShell && (!observing || !service.observer.humanControl || !source.human)) return false
    actionError = ""
    if (ActionFeedback.visibleFor(source.desktop, source.output)) ActionFeedback.clear()
    const request = actionRouter.prepare(source.desktop, source.seat, source.generation, source.workspace, source.output)
    actionCallbacks[request] = (context, error) => {
      if (error) { root.reportActionError(error, source); if (failure) failure(); return }
      callback(context, source)
    }
    return true
  }
  function trayAction(item, method, entry, callback, delta, horizontal, sourceOutput, menuPath) {
    return withAction((context, source) => {
      context.menuPath = menuPath || []
      // Only the physical shell can request ordinary tray compatibility while
      // a person has taken over another desktop. Native code rechecks the
      // Broker's seat identity/generation before granting this path.
      context.humanTakeover = source.secondary && source.human && root.observing && !root.agentShell
      const request = actionRouter.invokeTray(item, entry || null, method, context, delta || 0, horizontal || false)
      trayCallbacks[request] = (success, error) => {
        if (!success) root.reportActionError(error, source)
        if (callback) callback(success)
      }
    }, () => { if (callback) callback(false) }, sourceOutput)
  }
  function launchApplication(argv, sourceOutput) {
    if (readOnly || !argv.length) return false
    const command = argv.slice()
    return withAction((context, source) => {
      const launch = ["env", "XDG_ACTIVATION_TOKEN=" + context.token, "DESKTOP_STARTUP_ID=" + context.token].concat(command)
      if (!source.secondary) {
        const home = Quickshell.env("HOME") || ""
        const path = (home ? home + "/.local/bin:" : "") + (Quickshell.env("PATH") || "/usr/local/bin:/usr/bin:/bin")
        const prefix = Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
        const request = actionRouter.checkApplication(command, source.desktop)
        applicationCallbacks[request] = error => {
          if (error) { root.reportActionError(error, source); return }
          Quickshell.execDetached(["env", "PATH=" + path, "XDG_ACTIVATION_TOKEN=" + context.token,
            "DESKTOP_STARTUP_ID=" + context.token, prefix + "/bin/cornice-action-exec", "--"].concat(command))
        }
        return
      }
      if (!service) return
      const args = ["launch", source.desktop]
      // Native panels belong to this desktop's shell even during physical
      // takeover. The Broker validates the current human seat and generation.
      if (source.human) {
        args.push("--human-seat", source.seat, source.generation)
      } else if (!agentShell) return false
      // A launch is queued through the same result channel as workspace and
      // control actions, so a failed app/profile policy stays visible and retryable.
      service.operate(args.concat(["--"], launch), {sourceOutput:source.output})
    }, null, sourceOutput)
  }
  function focusWindow(address, expectedWorkspace) {
    address = windowAddress(address)
    const expected = workspaceIdentity(expectedWorkspace)
    if (readOnly || !address || !workspaceMatches(expected, observedWorkspace)) return false
    const prefix = Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
    if (secondary) {
      if (!state.seatId || !state.generation || !["agent", "human"].includes(state.controlMode)) return false
      if (!agentShell && (!observing || !service.observer.humanControl || state.controlMode !== "human")) return false
      if (!service) return false
      service.operate(["view-focus", selected, address,
        "--seat", String(state.seatId), String(state.generation), "--workspace", expected.key])
    } else {
      Quickshell.execDetached([prefix + "/bin/cornice-focus-window", address, JSON.stringify(expected)])
    }
    return true
  }
  function workspace(slot) {
    if (selected && selected !== "main") {
      if (!agentShell && service && service.observer && service.observer.isOpen && !service.observer.humanControl) {
        service.observer.browseWorkspace((state.workspaceSlots || []).find(item => item.id === slot)?.name || "")
        return
      }
      if (service) service.operate(["view-workspace", selected, String(slot)])
      return
    }
    Quickshell.execDetached([(Quickshell.env("CORNICE_PATH") || "/usr/share/cornice") + "/bin/cornice-compositor", "workspace", String(slot)])
  }
}
