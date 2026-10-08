pragma Singleton
import QtQuick
import Quickshell
QtObject {
  readonly property string name: Quickshell.env("CORNICE_DESKTOP_NAME") || ""
  readonly property string output: Quickshell.env("CORNICE_DESKTOP_OUTPUT") || ""
  readonly property bool agentShell: name !== ""
  property var service: null
  readonly property string selected: agentShell ? name : service ? service.selectedDesktop : ""
  readonly property var state: service ? service.desktops.find(item => item.name === selected) || ({}) : ({})
  function workspace(slot) {
    if (selected) {
      if (service) service.operate(["view-workspace", selected, String(slot)])
      return
    }
    Quickshell.execDetached([(Quickshell.env("CORNICE_PATH") || "/usr/share/cornice") + "/bin/cornice-compositor", "workspace", String(slot)])
  }
}
