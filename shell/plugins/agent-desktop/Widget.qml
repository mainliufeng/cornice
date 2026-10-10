import QtQuick
import Quickshell
import qs.Commons
Row {
  id: root
  property var host: null
  property var plugin: null
  property var widgetConfig: ({})
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  readonly property bool grouped: widgetConfig.grouped !== false
  visible: service && service.enabled
  spacing: Style.space(0.5)
  function controls() {
    const out = []
    for (const item of grouped ? [group] : [switcher, control]) {
      const point = item.mapToItem(root.QsWindow.window.contentItem, 0, 0)
      out.push({name:item === group ? "group" : item === switcher ? "switch" : "status",x:point.x,y:point.y,width:item.width,height:item.height})
      out.push(...item.rows().filter(row => row.name !== "menu"))
    }
    return out
  }
  DesktopMenu {
    id:group
    visible:root.grouped
    icon:DesktopSession.secondary ? "󰚩" : "󰍹"
    description:"桌面"
    badge:root.service ? root.service.activeDesktops.length : 0
    entries: root.service ? root.service.desktops.map(desktop => ({
      key:"view:" + desktop.name,label:root.service.desktopLabel(desktop.name) + " · " + root.service.stateLabel(desktop),
      selected:desktop.name === root.service.selectedDesktop,enabled:desktop.primary === true || (!!desktop.available && !desktop.error)
    })).concat(control.entries.filter(item => item.key !== "state").map(item => Object.assign({},item,{key:"control:"+item.key}))) : []
    onChosen:key => {
      if (key.startsWith("view:")) root.service.show(key.slice(5))
      else control.chosen(key.slice(8))
    }
  }
  DesktopSwitcher { id:switcher; visible:!root.grouped; service: root.service }
  DesktopControl { id:control; visible:!root.grouped; service: root.service }
}
