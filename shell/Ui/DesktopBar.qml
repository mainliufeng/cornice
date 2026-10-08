import QtQuick
import qs.Commons
import qs.Ui
Rectangle {
  id: root
  property var host: null
  property var registry: host ? host.registry : null
  readonly property var layout: host && host.config.bar ? host.config.bar.layout || ({}) : ({})
  function entries(section) {
    return (layout[section] || []).map(entry => typeof entry === "string" ? {id:entry} : entry)
  }
  property var leftEntries: entries("left")
  property var centerEntries: entries("center")
  property var rightEntries: entries("right")
  readonly property var sections: [left, center, right]
  height: Style.barHeight
  color: Color.barBackground
  BarSection {
    id: left
    anchors {left:parent.left;leftMargin:Style.padding;verticalCenter:parent.verticalCenter}
    host: root.host; registry: root.registry; entries: root.leftEntries; section: "left"
    maxWidth: Math.max(0, (parent.width-center.width)/2-Style.padding*2)
  }
  BarSection {
    id: center
    anchors.centerIn: parent
    host: root.host; registry: root.registry; entries: root.centerEntries; section: "center"
  }
  BarSection {
    id: right
    anchors {right:parent.right;rightMargin:Style.padding;verticalCenter:parent.verticalCenter}
    host: root.host; registry: root.registry; entries: root.rightEntries; section: "right"
    maxWidth: Math.max(0, (parent.width-center.width)/2-Style.padding*2)
  }
}
