import QtQuick
import Quickshell.Hyprland
import qs.Commons

// Workspace pills. Slots 1..N always exist so the bar does not reflow when a
// workspace is created; N is the highest workspace in use, at least minCount.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int minCount: Util.option(widgetConfig, "minCount", 5)

  readonly property var workspaces: Hyprland.workspaces ? Hyprland.workspaces.values : []
  readonly property var focusedId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1

  readonly property var slots: {
    const list = workspaces || []
    const focused = focusedId
    let highest = Math.max(minCount, focused)
    for (const workspace of list) if (workspace.id > highest) highest = workspace.id

    const out = []
    for (let id = 1; id <= highest; id++) {
      let occupied = false
      for (const workspace of list) if (workspace.id === id) occupied = true
      out.push({ id: id, occupied: occupied, label: String(id) })
    }
    return out
  }

  implicitHeight: Style.widgetHeight
  implicitWidth: row.implicitWidth

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(0.25)

    Repeater {
      model: root.slots

      delegate: Item {
        id: slot

        required property var modelData

        readonly property bool active: modelData.id === root.focusedId

        implicitWidth: Math.max(label.implicitWidth + Style.space(1.2), Style.space(2))
        implicitHeight: Style.widgetHeight

        Rectangle {
          anchors.fill: parent
          anchors.margins: Math.round(Style.gap * 0.3)
          radius: Style.radius
          color: slot.active ? Color.workspaceActive
               : slot.modelData.occupied ? Color.workspaceOccupied
               : "transparent"
          border.width: 0

          Behavior on color {
            ColorAnimation { duration: 120 }
          }
        }

        Text {
          id: label
          anchors.centerIn: parent
          text: slot.modelData.label
          color: slot.active ? Color.workspaceActiveText : Color.barForeground
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
          font.bold: slot.active
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: Hyprland.dispatch("workspace " + slot.modelData.id)
        }
      }
    }
  }
}
