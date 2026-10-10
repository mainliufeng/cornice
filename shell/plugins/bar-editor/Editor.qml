import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Spatial editor: the three columns mirror the actual bar. Every operation is
// persisted by the shared CLI, keeping inline widget options and rollback files.
PanelFrame {
  id: editor
  edge: "center"
  panelWidth: Math.min(840, window.screen ? window.screen.width - Style.space(6) : 840)
  panelHeight: Math.min(620, window.screen ? window.screen.height - Style.space(8) : 620)
  readonly property var sections: ["left", "center", "right"]
  readonly property var layout: host && host.config && host.config.bar ? host.config.bar.layout || ({}) : ({})
  readonly property var widgets: host && typeof host.barWidgets === "function" ? host.barWidgets() : []
  readonly property var hiddenWidgets: widgets.filter(widget => !sections.some(section => entries(section).some(entry => entry.id === widget.id)))
  readonly property int rowHeight: Style.space(5.5)
  property var menuRow: null
  property real menuX: 0
  property real menuY: 0
  property string draggedId: ""
  property var dragOwner: null
  property string statusText: ""

  function entries(section) { return layout[section] || [] }
  function labelFor(id) {
    const key = "bar.widget." + id.replace(/^cn\./, "")
    const translated = I18n.t(key)
    if (translated !== key) return translated
    const widget = widgets.find(widget => widget.id === id)
    return widget ? widget.displayName || widget.name : id
  }
  function iconFor(id) {
    const icons = { "cn.launcher": "\u{F00CA}", "cn.workspaces": "\u{F009}", "cn.active-window": "\u{F2D0}",
      "cn.recording": "\u{F03D}", "cn.clock": "\u{F017}", "cn.weather": "\u{F0C2}", "cn.media": "\u{F001}", "cn.indicators": "\u{F0F3}",
      "cn.tray": "\u{F141}", "cn.network": "\u{F1EB}", "cn.bluetooth": "\u{F293}", "cn.audio": "\u{F028}",
      "cn.brightness": "\u{F0EB}", "cn.power": "\u{F240}", "cn.keylayout": "\u{F11C}", "cn.spacer": "\u{F07E}" }
    return icons[id] || "\u{F12E}"
  }
  function run(command) {
    menuRow = null
    if (saveProcess.running) return
    saveProcess.command = ["sh", "-c", "cornice bar " + command]
    saveProcess.running = true
  }
  function place(id, section, index) {
    run("show " + Util.shellQuote(id) + " --section " + section + " --index " + index)
  }
  function showMenu(row, item) {
    if (menuRow && menuRow.id === row.id && menuRow.section === row.section) { menuRow = null; return }
    const point = item.mapToItem(canvas, item.width, item.height)
    menuX = Math.max(0, Math.min(point.x - actionMenu.width, canvas.width - actionMenu.width))
    menuY = point.y + Style.space(0.5)
    menuRow = row
  }
  readonly property var menuActions: {
    if (!menuRow) return []
    const row = menuRow
    const out = sections.map(section => ({
      label: I18n.t("bar.editor.to." + section),
      glyph: "\u{F061}",
      command: (row.section === "hidden" ? "show " + Util.shellQuote(row.id) + " --section " : "move " + Util.shellQuote(row.id) + " ") + section,
      enabled: row.section !== section
    }))
    if (row.section !== "hidden") {
      out.push({ label: I18n.t("bar.editor.up"), glyph: "\u{F062}", command: "move " + Util.shellQuote(row.id) + " up", enabled: row.index > 0 })
      out.push({ label: I18n.t("bar.editor.down"), glyph: "\u{F063}", command: "move " + Util.shellQuote(row.id) + " down", enabled: row.index < entries(row.section).length - 1 })
      out.push({ label: I18n.t("bar.editor.hide"), glyph: "\u{F070}", command: "hide " + Util.shellQuote(row.id), enabled: true })
    }
    return out
  }
  Timer { id: statusTimer; interval: 1800; onTriggered: editor.statusText = "" }
  Process {
    id: saveProcess
    onExited: (exitCode, exitStatus) => {
      editor.statusText = I18n.t(exitCode === 0 ? "bar.editor.applied" : "bar.editor.failed")
      statusTimer.restart()
    }
  }
  onDismissed: { menuRow = null; dragProxy.Drag.cancel(); draggedId = "" }

  component WidgetRow: Rectangle {
    id: card
    property string widgetId: ""
    property string section: "hidden"
    property int entryIndex: -1
    property bool compact: false
    width: 240
    height: editor.rowHeight
    radius: Style.radius
    color: menuHit.containsMouse || dragHit.containsMouse || (editor.menuRow && editor.menuRow.id === widgetId) ? Color.hover : "transparent"
    opacity: editor.draggedId === widgetId && dragHit.drag.active ? 0.35 : 1
    readonly property var row: ({ id: widgetId, section: section, index: entryIndex })
    function inspect() {
      const point = menuButton.mapToItem(editor.window.contentItem, menuButton.width / 2, menuButton.height / 2)
      const dragPoint = card.mapToItem(editor.window.contentItem, Style.space(3), card.height / 2)
      return { id: widgetId, kind: section === "hidden" ? "hidden" : "widget", section: section,
        menu: { x: Math.round(point.x), y: Math.round(point.y) },
        drag: { x: Math.round(dragPoint.x), y: Math.round(dragPoint.y) } }
    }
    Text {
      x: Style.space(1.3)
      anchors.verticalCenter: parent.verticalCenter
      text: editor.iconFor(card.widgetId)
      color: Color.muted
      font.family: Style.iconFamily
      font.pixelSize: Style.fontSize
    }
    Text {
      x: Style.space(4.8)
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - x - menuButton.width - Style.space(1)
      text: editor.labelFor(card.widgetId)
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      elide: Text.ElideRight
    }
    MouseArea {
      id: dragHit
      anchors.fill: parent
      anchors.rightMargin: menuButton.width
      hoverEnabled: true
      preventStealing: true
      cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      drag.target: dragProxy
      drag.threshold: Style.space(1)
      onPressed: mouse => {
        editor.menuRow = null
        editor.dragOwner = dragHit
        editor.draggedId = card.widgetId
        const point = card.mapToItem(canvas, mouse.x, mouse.y)
        dragProxy.x = point.x - dragProxy.width / 2
        dragProxy.y = point.y - dragProxy.height / 2
      }
      onReleased: { dragProxy.Drag.drop(); editor.draggedId = "" }
      onCanceled: { dragProxy.Drag.cancel(); editor.draggedId = "" }
    }
    Item {
      id: menuButton
      anchors.right: parent.right
      width: Style.widgetHeight + Style.space(0.5)
      height: parent.height
      activeFocusOnTab: true
      Keys.onReturnPressed: editor.showMenu(card.row, menuButton)
      Keys.onSpacePressed: editor.showMenu(card.row, menuButton)
      Text {
        anchors.centerIn: parent
        text: card.compact ? "\u{F067}" : "\u{F141}"
        color: menuHit.containsMouse || parent.activeFocus ? Color.accent : Color.muted
        font.family: Style.iconFamily
        font.pixelSize: Style.fontSize
      }
      MouseArea {
        id: menuHit
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: editor.showMenu(card.row, menuButton)
      }
    }
  }

  Item {
    id: canvas
    anchors.fill: parent
    anchors.margins: Style.space(1.2)
    Text {
      id: heading
      text: I18n.t("bar.editor.title")
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.largeFontSize + 2
      font.bold: true
    }
    Text {
      anchors.right: parent.right
      anchors.verticalCenter: heading.verticalCenter
      text: editor.statusText || I18n.t("bar.editor.autosave")
      color: editor.statusText ? Color.accent : Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }
    Text {
      id: hint
      anchors.top: heading.bottom
      anchors.topMargin: Style.space(1)
      width: parent.width
      text: I18n.t("bar.editor.hint")
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      wrapMode: Text.Wrap
    }
    Row {
      id: columns
      anchors.top: hint.bottom
      anchors.topMargin: Style.space(2.5)
      width: parent.width
      height: Math.max(0, hiddenSection.y - y - Style.space(2))
      spacing: Style.space(1.5)
      Repeater {
        id: columnItems
        model: editor.sections
        delegate: Rectangle {
          id: lane
          required property string modelData
          width: (columns.width - columns.spacing * 2) / 3
          height: columns.height
          radius: Style.radius
          color: Color.surface
          border.width: laneDrop.containsDrag ? 1 : 0
          border.color: Color.accent
          readonly property var laneEntries: editor.entries(modelData)
          property int insertion: 0
          function inspect() {
            const rows = []
            for (let i = 0; i < cards.count; i++) rows.push(cards.itemAt(i).inspect())
            const origin = laneList.mapToItem(editor.window.contentItem, 0, 0)
            return { section: modelData, rows: rows, moving: laneList.moving,
              viewport: { x: origin.x, y: origin.y, width: laneList.width, height: laneList.height } }
          }
          Text {
            x: Style.space(1.5)
            y: Style.space(1.8)
            text: I18n.t("bar.editor.section." + lane.modelData)
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
            font.bold: true
          }
          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(1.5)
            y: Style.space(1.8)
            text: lane.laneEntries.length
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
          Rectangle {
            x: Style.space(1.5); y: Style.space(5)
            width: parent.width - x * 2; height: 1
            color: Color.surfaceBorder
          }
          Flickable {
            id: laneList
            x: Style.space(0.6)
            y: Style.space(6.3)
            width: parent.width - x * 2
            height: parent.height - y - Style.space(1)
            contentHeight: cardList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
              id: cardList
              width: parent.width
              Repeater {
                id: cards
                model: lane.laneEntries
                delegate: WidgetRow {
                  required property var modelData
                  required property int index
                  width: cardList.width
                  widgetId: modelData.id
                  section: lane.modelData
                  entryIndex: index
                }
              }
            }
            Text {
              anchors.centerIn: parent
              visible: lane.laneEntries.length === 0
              text: I18n.t("bar.editor.drop")
              color: Color.muted
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
          }
          DropArea {
            id: laneDrop
            anchors.fill: laneList
            keys: ["cornice-widget"]
            function update(y) { lane.insertion = Math.max(0, Math.min(lane.laneEntries.length, Math.floor((y + laneList.contentY + editor.rowHeight / 2) / editor.rowHeight))) }
            onEntered: drag => update(drag.y)
            onPositionChanged: drag => update(drag.y)
            onDropped: drop => {
              const id = editor.draggedId
              let index = lane.insertion
              const old = lane.laneEntries.findIndex(entry => entry.id === id)
              if (old >= 0 && old < index) index--
              editor.place(id, lane.modelData, index)
              drop.acceptProposedAction()
            }
          }
          Rectangle {
            visible: laneDrop.containsDrag
            x: laneList.x
            y: Math.max(laneList.y, Math.min(laneList.y + laneList.height - 2, laneList.y + lane.insertion * editor.rowHeight - laneList.contentY))
            width: laneList.width
            height: 2
            color: Color.accent
          }
        }
      }
    }
    Item {
      id: hiddenSection
      anchors.bottom: parent.bottom
      width: parent.width
      readonly property bool compactLayout: canvas.height < Style.space(55)
      height: hiddenHeading.height + Style.space(1.5) + hiddenViewport.height
      Text {
        id: hiddenHeading
        text: I18n.t("bar.editor.hidden") + "  ·  " + editor.hiddenWidgets.length
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
      Flickable {
        id: hiddenViewport
        anchors.top: hiddenHeading.bottom
        anchors.topMargin: Style.space(1.5)
        width: parent.width
        height: hiddenSection.compactLayout ? editor.rowHeight : hiddenFlow.implicitHeight
        contentWidth: hiddenFlow.width
        contentHeight: hiddenFlow.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Flow {
          id: hiddenFlow
          width: hiddenSection.compactLayout ? Math.max(hiddenViewport.width, editor.hiddenWidgets.length * (Math.min(180, hiddenViewport.width) + spacing) - spacing) : hiddenViewport.width
          spacing: Style.space(0.8)
          Repeater {
            id: hiddenItems
            model: editor.hiddenWidgets
            delegate: WidgetRow {
              required property var modelData
              widgetId: modelData.id
              compact: true
              width: Math.min(180, hiddenViewport.width)
              color: Color.surface
            }
          }
        }
      }
    }
    MouseArea {
      anchors.fill: parent
      visible: editor.menuRow !== null
      z: 80
      onClicked: editor.menuRow = null
    }
    Surface {
      id: actionMenu
      x: editor.menuX; y: Math.max(0, Math.min(editor.menuY, canvas.height - height))
      width: Style.space(27)
      height: menuColumn.implicitHeight + padding * 2
      padding: Style.space(0.5)
      visible: editor.menuRow !== null
      z: 100
      Column {
        id: menuColumn
        width: parent.width
        Repeater {
          id: menuItems
          model: editor.menuActions
          delegate: Rectangle {
            required property var modelData
            enabled: modelData.enabled
            width: menuColumn.width
            height: editor.rowHeight
            color: actionHit.containsMouse || activeFocus ? Color.hover : "transparent"
            activeFocusOnTab: true
            Keys.onReturnPressed: editor.run(modelData.command)
            Keys.onSpacePressed: editor.run(modelData.command)
            Text {
              x: Style.space(1.2)
              anchors.verticalCenter: parent.verticalCenter
              text: parent.modelData.glyph
              color: Color.muted
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize
            }
            Text {
              x: Style.space(4.5)
              anchors.verticalCenter: parent.verticalCenter
              text: parent.modelData.label
              color: parent.enabled ? Color.foreground : Color.muted
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
            MouseArea {
              id: actionHit
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: editor.run(modelData.command)
            }
          }
        }
      }
    }
    Rectangle {
      id: dragProxy
      width: Math.max(120, (canvas.width - Style.space(3)) / 3)
      height: editor.rowHeight
      color: Color.panel
      border.width: 1
      border.color: Color.accent
      radius: Style.radius
      visible: Drag.active
      z: 120
      Drag.active: editor.dragOwner ? editor.dragOwner.drag.active : false
      Drag.keys: ["cornice-widget"]
      Drag.proposedAction: Qt.MoveAction
      Drag.hotSpot.x: width / 2
      Drag.hotSpot.y: height / 2
      Text {
        anchors.centerIn: parent
        text: editor.labelFor(editor.draggedId)
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }
    }
  }
  ShellIpc {
    target: "barEditor"
    function state(): string {
      const columns = [], rows = [], menu = []
      for (let i = 0; i < columnItems.count; i++) {
        const lane = columnItems.itemAt(i).inspect()
        columns.push(lane)
        rows.push(...lane.rows)
      }
      for (let i = 0; i < hiddenItems.count; i++) rows.push(hiddenItems.itemAt(i).inspect())
      for (let i = 0; i < menuItems.count; i++) {
        const item = menuItems.itemAt(i)
        const point = item.mapToItem(editor.window.contentItem, item.width / 2, item.height / 2)
        menu.push({ command: item.modelData.command, enabled: item.enabled, x: Math.round(point.x), y: Math.round(point.y) })
      }
      return JSON.stringify({ open: editor.isOpen, rows: rows, columns: columns,
        menuFor: editor.menuRow ? editor.menuRow.id : "", menu: menu, dragging: editor.draggedId,
        dragActive: dragProxy.Drag.active })
    }
  }
}
