import QtQuick
import Quickshell
import qs.Commons
Row {
  id: root
  property var host: null
  property var plugin: null
  property var widgetConfig: ({})
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  visible: service && service.enabled
  spacing: Style.space(0.5)
  function controls() {
    const out = []
    for (const item of [switcher, control]) {
      const point = item.mapToItem(root.QsWindow.window.contentItem, 0, 0)
      out.push({name:item === switcher ? "switch" : "status",x:point.x,y:point.y,width:item.width,height:item.height})
      out.push(...item.rows().filter(row => row.name !== "menu"))
    }
    return out
  }
  DesktopSwitcher { id:switcher; service: root.service }
  DesktopControl { id:control; service: root.service }
}
