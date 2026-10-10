pragma Singleton
import QtQuick
import Quickshell
QtObject {
  readonly property string name: Quickshell.env("CORNICE_DESKTOP_NAME") || ""
  readonly property string output: Quickshell.env("CORNICE_DESKTOP_OUTPUT") || ""
  readonly property bool agentShell: name !== ""
  property var service: null
  readonly property string selected: agentShell ? name : service ? service.selectedDesktop : "main"
  readonly property bool secondary: selected !== "" && selected !== "main"
  readonly property var state: service ? service.desktops.find(item => item.name === selected) || ({}) : ({})
  readonly property string viewedWorkspaceName: !agentShell && service && service.observer && service.observer.isOpen
    ? String(service.observer.presentationState.workspace || "").replace(/^name:/, "") : String(state.workspaceName || "")
  readonly property bool readOnly: !agentShell && secondary && service && service.observer
    && service.observer.isOpen && !service.observer.humanControl
  function exec(command) {
    if (readOnly || !service || !service.observer || !service.observer.isOpen || !service.observer.humanControl
        || state.controlMode !== "human" || !state.seatId || !state.generation) return false
    Quickshell.execDetached(["hyprctl", "seat", "dispatch", selected, String(state.seatId), String(state.generation),
      "hl.dsp.exec_cmd(" + JSON.stringify(String(command)) + ")"])
    return true
  }
  function launchApplication(argv) {
    if (readOnly || !secondary || !argv.length) return false
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
