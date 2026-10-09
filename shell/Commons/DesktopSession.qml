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
  function workspace(slot) {
    if (selected && selected !== "main") {
      if (!agentShell && service && service.observer && service.observer.isOpen && !service.observer.humanControl) {
        service.observer.browseWorkspace("name:cornice-agent-" + selected + "-ws-" + slot)
        return
      }
      if (service) service.operate(["view-workspace", selected, String(slot)])
      return
    }
    Quickshell.execDetached([(Quickshell.env("CORNICE_PATH") || "/usr/share/cornice") + "/bin/cornice-compositor", "workspace", String(slot)])
  }
}
