import QtQuick
import qs.Commons
DesktopMenu {
  id: root
  objectName: "DesktopSwitcher"
  property var service: null
  property bool compact: true
  property string selected: service ? service.selectedDesktop : ""
  icon: selected && selected !== "main" ? "󰚩" : "󰍹"
  description: service ? service.desktopLabel(selected || "main") : "桌面 1 · 主桌面"
  entries: service && service.desktops.length ? service.desktops.map(desktop => ({
    key: desktop.name, label: service.desktopLabel(desktop.name) + " · " + service.stateLabel(desktop),
    selected: desktop.name === (selected || "main"), enabled: desktop.primary || (!!desktop.available && !desktop.error)
  })) : [{key:"main",label:"桌面 1 · 主桌面",selected:true}]
  onChosen: key => { if (service) service.show(key) }
  function controls() { return rows() }
}
