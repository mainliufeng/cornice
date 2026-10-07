import QtQuick
import Quickshell.Hyprland
import qs.Commons

// Workspace pills.
//
// Ten slots by default, all the same width so the row never shifts as the
// numbers change width. States follow what other bars do:
//   active    — filled accent pill, contrasting text
//   occupied  — normal text with a dot underneath (has windows)
//   empty     — dimmed number, no marker
//   hover     — faint fill so the click target is visible
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property int minCount: Util.option(widgetConfig, "minCount", 10)
  readonly property bool showDot: Util.option(widgetConfig, "showDot", true)

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
      out.push({
        id: id,
        label: String(id),
        occupied: occupied,
        active: id === focused
      })
    }
    return out
  }

  // Width of the widest label, so every slot matches.
  readonly property int highestId: slots.length > 0 ? slots[slots.length - 1].id : minCount

  readonly property real slotWidth: metrics.width + Style.space(1.1)

  implicitHeight: Style.widgetHeight
  implicitWidth: row.implicitWidth

  // Invisible ruler used to size the slots.
  Text {
    id: metrics
    visible: false
    text: String(root.highestId)
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
    font.bold: true
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(0.25)

    Repeater {
      model: root.slots

      delegate: Item {
        id: slot

        required property var modelData

        implicitWidth: root.slotWidth
        implicitHeight: Style.widgetHeight

        property bool hovered: false

        Rectangle {
          anchors.fill: parent
          anchors.margins: Math.round(Style.gap * 0.25)
          radius: Style.radius
          color: slot.modelData.active ? Color.workspaceActive
               : slot.hovered ? Color.hover
               : "transparent"

          Behavior on color {
            ColorAnimation { duration: 110 }
          }
        }

        Text {
          id: label

          anchors.centerIn: parent
          anchors.verticalCenterOffset: root.showDot && slot.modelData.occupied && !slot.modelData.active ? -1 : 0
          text: slot.modelData.label
          color: slot.modelData.active ? Color.workspaceActiveText
               : slot.modelData.occupied ? Color.barForeground
               : Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
          font.bold: slot.modelData.active
        }

        // Occupied marker: makes "has windows" readable without shouting.
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(0.35)
          width: Math.max(3, Math.round(Style.gap * 0.5))
          height: Math.max(2, Math.round(Style.gap * 0.25))
          radius: height / 2
          visible: root.showDot && slot.modelData.occupied && !slot.modelData.active
          color: Color.accent
          opacity: 0.9
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          hoverEnabled: true
          onEntered: slot.hovered = true
          onExited: slot.hovered = false
          onClicked: CompositorAdapter.workspace(slot.modelData.id)
          onWheel: wheel => {
            const target = slot.modelData.id + (wheel.angleDelta.y > 0 ? -1 : 1)
            if (target >= 1) Hyprland.dispatch("workspace " + target)
          }
        }
      }
    }
  }
}
