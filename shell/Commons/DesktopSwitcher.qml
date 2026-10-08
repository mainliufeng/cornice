import QtQuick
import qs.Commons
DesktopMenu {
  id: root
  objectName: "DesktopSwitcher"
  property var service: null
  property bool compact: true
  property string selected: service ? service.selectedDesktop : ""
  icon: selected ? "󰚩" : "󰍹"
  description: selected && service ? service.desktopLabel(selected) : "人的桌面"
  entries: [{key: "", label: "人", selected: selected === ""}].concat(service ? service.desktops.map(desktop => ({
    key: desktop.name, label: service.desktopLabel(desktop.name) + " · " + service.stateLabel(desktop),
    selected: desktop.name === selected, enabled: !!desktop.available && !desktop.error})) : [])
  onChosen: key => { if (service) service.show(key) }
  function controls() { return rows() }
}
