import QtQuick
import qs.Commons

Row {
  id: root
  property var service: null
  property bool compact: true
  property string selected: service ? service.selectedDesktop : ""
  spacing: Style.space(0.5)
  function controls() {
    const rows = [{name: "", x: human.x, width: human.width, height: human.height}]
    for (let i = 0; i < agents.count; ++i) {
      const item = agents.itemAt(i)
      rows.push({name: item.modelData.name, x: item.x, width: item.width, height: item.height})
    }
    return rows
  }
  component SwitchButton: Rectangle {
    id: button
    property string label: ""
    property bool chosen: false
    property bool online: true
    property string phase: ""
    signal clicked()
    width: content.implicitWidth + Style.space(2)
    height: root.compact ? Style.widgetHeight : Style.space(5.5)
    radius: Style.radius
    color: chosen ? Color.accent : mouse.containsMouse ? Color.hover : "transparent"
    border.width: chosen ? 0 : 1
    border.color: Color.surfaceBorder
    Row {
      id: content; anchors.centerIn: parent; spacing: Style.space(0.7)
      Text {
        text: button.label + (!root.compact && button.phase ? " · " + button.phase : "")
        color: !button.online ? Color.urgent : button.chosen ? Color.background : Color.foreground
        font.family: Style.fontFamily; font.pixelSize: Style.fontSize
      }
      Rectangle {
        visible: root.compact && button.phase !== ""
        width: Style.space(0.7); height: width; radius: width / 2; anchors.verticalCenter: parent.verticalCenter
        color: !button.online ? Color.urgent : button.phase === "运行中" ? "#7bb97b" : button.phase === "接管中" ? Color.accent : Color.muted
      }
    }
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: button.clicked() }
  }
  SwitchButton { id: human; label: "人"; chosen: root.selected === ""; onClicked: if (root.service) root.service.show("") }
  Repeater {
    id: agents
    model: root.service ? root.service.desktops : []
    delegate: SwitchButton {
      required property var modelData
      label: root.service.desktopLabel(modelData.name)
      phase: root.service.stateLabel(modelData)
      online: !modelData.error && !!modelData.available
      chosen: root.selected === modelData.name
      onClicked: if (root.service) root.service.show(modelData.name)
    }
  }
}
