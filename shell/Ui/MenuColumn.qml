import QtQuick
import qs.Commons

Surface {
  id: column
  property var controller
  property var surfaceWindow
  property int level: 0
  property var rows: []
  property int selection: -1
  onRowsChanged: {
    if (selection < 0 && rows.length && controller && controller.activeLevel === level)
      Qt.callLater(() => moveSelection(1))
  }
  padding: Style.space(0.7)
  readonly property real naturalHeight: content.implicitHeight + padding * 2
  function ensureVisible(index) {
    const row = menuRows.itemAt(index)
    if (!row) return
    if (row.y < scroll.contentY) scroll.contentY = row.y
    else if (row.y + row.height > scroll.contentY + scroll.height)
      scroll.contentY = Math.max(0, row.y + row.height - scroll.height)
  }
  function moveSelection(delta) {
    let next = selection
    for (let i = 0; i < rows.length; ++i) {
      next = (next + delta + rows.length) % rows.length
      if (rows[next].enabled && !rows[next].isSeparator) {
        selection = next
        controller.activeLevel = level
        ensureVisible(next)
        return
      }
    }
  }
  function inspect() {
    const result = []
    for (let i = 0; i < menuRows.count; ++i) {
      const row = menuRows.itemAt(i)
      const point = row.mapToItem(surfaceWindow.contentItem, row.width / 2, row.height / 2)
      result.push({text: row.modelData.text, submenu: controller.canOpen(row.modelData),
        enabled: row.modelData.enabled, x: Math.round(point.x), y: Math.round(point.y)})
    }
    const point = column.mapToItem(surfaceWindow.contentItem, 0, 0)
    const backPoint = back.mapToItem(surfaceWindow.contentItem, back.width / 2, back.height / 2)
    return {level: level, selection: selection, x: point.x, y: point.y,
      width: width, height: height, contentY: scroll.contentY,
      viewportHeight: scroll.height, contentHeight: scroll.contentHeight, rows: result, back: {x: backPoint.x, y: backPoint.y}}
  }
  // Disabled rows and separators consume clicks without dismissing a menu.
  MouseArea { anchors.fill: parent }
  Flickable {
    id: scroll
    anchors.fill: parent
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Column {
      id: content
      width: scroll.width
      spacing: 1
      Item {
        id: back
        visible: column.level > 0
        width: content.width
        height: visible ? Style.space(5.5) : 0
        Text {
          anchors.centerIn: parent
          text: "‹ " + I18n.t("common.back")
          color: Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { column.controller.activeLevel = column.level; column.controller.goBack() }
        }
      }
      Repeater {
        id: menuRows
        model: column.rows
        delegate: Item {
          id: row
          required property var modelData
          required property int index
          width: content.width
          height: modelData.isSeparator ? Style.space(0.6) : Style.space(5.5)
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            visible: row.modelData.isSeparator
            color: Color.surfaceBorder
          }
          Rectangle {
            anchors.fill: parent
            radius: Style.radius
            visible: !row.modelData.isSeparator
            color: row.index === column.selection || (column.controller.branch[column.level]
              && column.controller.branch[column.level].entry === row.modelData) ? Color.hover : "transparent"
          }
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(0.7)
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.checkState === Qt.Checked ? "✓" : row.modelData.checkState === Qt.PartiallyChecked ? "−" : ""
            color: Color.accent
            font.pixelSize: Style.fontSize
          }
          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.space(2.5)
            anchors.rightMargin: Style.space(2)
            verticalAlignment: Text.AlignVCenter
            text: row.modelData.text
            color: row.modelData.enabled ? Color.foreground : Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
            elide: Text.ElideRight
            visible: !row.modelData.isSeparator
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(0.7)
            anchors.verticalCenter: parent.verticalCenter
            text: column.controller.canOpen(row.modelData) ? "›" : ""
            color: Color.muted
            font.pixelSize: Style.fontSize
          }
          MouseArea {
            id: hit
            anchors.fill: parent
            enabled: !row.modelData.isSeparator && row.modelData.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            property var pressedEntry: null
            function point() {
              const p = hit.mapToItem(column.surfaceWindow.contentItem, mouseX, mouseY)
              return Qt.point(p.x + column.surfaceWindow.margins.left, p.y + column.surfaceWindow.margins.top)
            }
            function hover() {
              if (!containsMouse || pressed || !column.controller.hoverArmed) return
              const submenu = column.controller.canOpen(row.modelData)
              if (submenu) submenuHover.restart()
              column.controller.select(column.level, row.index, true)
            }
            onEntered: { column.controller.movedPointer(point()); hover() }
            onExited: submenuHover.stop()
            onPositionChanged: { if (column && column.controller) { column.controller.movedPointer(point()); hover() } }
            onPressed: {
              pressedEntry = column.controller.captureClick(row.modelData, point()) ? row.modelData : null
              submenuHover.stop()
            }
            onCanceled: pressedEntry = null
            onClicked: {
              const entry = pressedEntry
              pressedEntry = null
              if (entry === row.modelData) {
                column.controller.select(column.level, row.index, false)
                column.controller.activate(column.level, entry, row.index)
              }
            }
            Timer {
              id: submenuHover
              interval: 250
              onTriggered: if (hit.containsMouse && !hit.pressed && column.controller.hoverArmed)
                column.controller.openSubmenu(column.level, row.modelData, row.index)
            }
          }
        }
      }
    }
  }
}
