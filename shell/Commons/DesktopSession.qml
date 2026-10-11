pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
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
  readonly property var currentWorkspace: secondary
    ? workspaceIdentity({address:state.workspace, name:state.workspaceName || state.workspace})
    : workspaceIdentity(primaryWorkspace !== null ? primaryWorkspace : Hyprland.focusedWorkspace)
  readonly property var observedWorkspace: {
    if (!observing) return currentWorkspace
    const presentation = service.observer.presentationState || ({})
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
      if (root.secondary || workspacePoll.running || windowPoll.running || !root.contextRefreshPending) return
      root.contextRefreshPending = false
      workspacePoll.running = true
      windowPoll.running = true
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
  function launchApplication(argv) {
    if (readOnly || !argv.length) return false
    if (!secondary) {
      const home = Quickshell.env("HOME") || ""
      const path = (home ? home + "/.local/bin:" : "") + (Quickshell.env("PATH") || "/usr/local/bin:/usr/bin:/bin")
      Quickshell.execDetached(["env", "PATH=" + path].concat(argv))
      return true
    }
    const args = [(Quickshell.env("CORNICE_PATH") || "/usr/share/cornice") + "/bin/cornice", "desktop", "launch", selected]
    if (!agentShell && (!service || !service.observer || !service.observer.humanControl)) return false
    // Native panels belong to this desktop's shell even during physical
    // takeover. The Broker validates the current human seat and generation.
    if (state.controlMode === "human") {
      if (!state.seatId || !state.generation) return false
      args.push("--human-seat", String(state.seatId), String(state.generation))
    } else if (!agentShell) return false
    Quickshell.execDetached(args.concat(["--"], argv))
    return true
  }
  function focusWindow(address, expectedWorkspace) {
    address = windowAddress(address)
    const expected = workspaceIdentity(expectedWorkspace)
    if (readOnly || !address || !workspaceMatches(expected, observedWorkspace)) return false
    const prefix = Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
    if (secondary) {
      if (!state.seatId || !state.generation || !["agent", "human"].includes(state.controlMode)) return false
      if (!agentShell && (!observing || !service.observer.humanControl || state.controlMode !== "human")) return false
      Quickshell.execDetached([prefix + "/bin/cornice-desktop", "view-focus", selected, address,
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
