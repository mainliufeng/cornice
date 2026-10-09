import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// One focus/input surface, with a persistent column for every open menu.
// Opener lifetimes follow the branch: children remain valid until descendants
// are removed, and adding a column never replaces a pressed parent delegate.
Item {
  id: root
  property var handle: null
  property string ownerId: ""
  property string ownerTitle: ""
  property real anchorX: 0
  property var anchorWindow: null
  property int preferredWidth: 320
  readonly property bool opened: handle !== null
  property var submenuOpeners: []
  property var branch: []
  // ListModel insert/remove keeps existing delegates alive; assigning a new
  // numeric Repeater model resets delegates and can reuse a press target.
  property int activeLevel: 0
  property bool hoverArmed: true
  property point pointerPosition: Qt.point(-1, -1)
  property point hoverOrigin: Qt.point(-1, -1)
  property bool grabArmed: false
  property var clickEntry: null
  property point clickPosition: Qt.point(-1, -1)
  signal entryChosen(var entry)

  function canOpen(entry) { return entry && entry.hasChildren === true }
  function entries(level) {
    const source = level === 0 ? opener : submenuOpeners[level - 1]
    if (!source || !source.children) return []
    return source.children.values !== undefined ? source.children.values : source.children
  }
  function count() { return entries(activeLevel).length }
  function pauseHover() { hoverOrigin = pointerPosition; hoverArmed = false }
  function movedPointer(point) {
    pointerPosition = point
    if (clickEntry && Math.hypot(point.x - clickPosition.x, point.y - clickPosition.y) >= 2) clickEntry = null
    // Relayout can emit position/enter events without physical movement.
    if (!hoverArmed && Math.hypot(point.x - hoverOrigin.x, point.y - hoverOrigin.y) >= 2)
      hoverArmed = true
  }
  function captureClick(entry, point) {
    movedPointer(point)
    if (clickEntry && clickEntry !== entry) return false
    clickEntry = entry
    clickPosition = point
    return true
  }
  function trim(level) {
    const removed = submenuOpeners.slice(level)
    while (levelModel.count > level + 1) levelModel.remove(levelModel.count - 1)
    submenuOpeners = submenuOpeners.slice(0, level)
    branch = branch.slice(0, level)
    activeLevel = Math.min(activeLevel, level)
    for (let i = removed.length - 1; i >= 0; --i) removed[i].destroy()
  }
  function select(level, index, hover) {
    const column = levels.itemAt(level)
    if (!column) return
    column.selection = index
    column.ensureVisible(index)
    activeLevel = level
    if (hover && branch[level] && branch[level].entry !== column.rows[index]) trim(level)
  }
  function openSubmenu(level, entry, index) {
    if (!opened || !canOpen(entry) || entries(level)[index] !== entry) return false
    // Repeated clicks on a parent keep the same child; they cannot advance it.
    if (branch[level] && branch[level].entry === entry) { activeLevel = level + 1; return true }
    trim(level)
    const child = submenuFactory.createObject(root, { menu: entry })
    if (!child) return false
    pauseHover()
    branch = branch.concat([{entry: entry, text: entry.text,
      index: entries(level).slice(0, index).filter(row => row.text === entry.text).length}])
    submenuOpeners = submenuOpeners.concat([child])
    levelModel.append({depth: level + 1})
    activeLevel = level + 1
    Qt.callLater(() => {
      const column = levels.itemAt(level + 1)
      if (column) column.moveSelection(1)
    })
    return true
  }
  function goBack() {
    if (activeLevel === 0) return
    const parent = activeLevel - 1
    pauseHover()
    trim(parent)
    activeLevel = parent
  }
  function activate(level, entry, index) {
    if (!opened || !entry || !entry.enabled || entry.isSeparator || entries(level)[index] !== entry) return
    if (canOpen(entry)) { openSubmenu(level, entry, index); return }
    try {
      if (typeof entry.sendTriggered === "function") entry.sendTriggered()
      else if (root.ownerId !== "") {
        const path = branch.slice(0, level).map(row => ({text: row.text, index: row.index}))
        path.push({text: entry.text, index: entries(level).slice(0, index).filter(row => row.text === entry.text).length})
        const command = "cornice-tray-activate --id " + Util.shellQuote(root.ownerId)
          + " --label " + Util.shellQuote(entry.text) + " --path " + Util.shellQuote(JSON.stringify(path))
        console.log("cornice: tray menu activate → " + command)
        Util.exec(command)
      } else entry.display()
    } catch (error) { console.warn("cornice: menu entry failed: " + error) }
    entryChosen(entry)
    close()
  }
  function close() { handle = null }
  onHandleChanged: {
    trim(0)
    levelModel.clear()
    if (handle !== null) levelModel.append({depth: 0})
    activeLevel = 0
    hoverArmed = true
    clickEntry = null
    grabArmed = false
    if (handle !== null) {
      armTimer.restart()
      Qt.callLater(() => { const first = levels.itemAt(0); if (first) first.moveSelection(1) })
    }
    else armTimer.stop()
  }
  function inspect() {
    const columns = []
    for (let i = 0; i < levels.count; ++i) columns.push(levels.itemAt(i).inspect())
    return {opened: opened, depth: submenuOpeners.length, activeLevel: activeLevel,
      hoverArmed: hoverArmed, rows: columns[activeLevel] ? columns[activeLevel].rows : [],
      columns: columns, width: window.width, height: window.height}
  }
  ListModel { id: levelModel; dynamicRoles: true }
  QsMenuOpener { id: opener; menu: root.handle }
  Component { id: submenuFactory; QsMenuOpener {} }
  Timer { id: armTimer; interval: 220; onTriggered: root.grabArmed = true }
  HyprlandFocusGrab {
    windows: [window]
    active: root.opened && root.grabArmed
    onCleared: if (root.grabArmed) root.close()
  }
  PanelWindow {
    id: window
    screen: root.anchorWindow ? root.anchorWindow.screen : Quickshell.screens[0]
    visible: root.opened
    color: "transparent"
    focusable: true
    exclusiveZone: 0
    aboveWindows: true
    anchors.top: true
    anchors.left: true
    margins.top: Style.barHeight + Style.space(0.5)
    readonly property real screenWidth: screen ? screen.width : 1280
    readonly property real availableWidth: Math.max(1, screenWidth - Style.space(1))
    // Compress columns on small outputs; for exceptionally deep branches use
    // horizontal scrolling, so both the ancestors and the current level can
    // be revisited without clipping a surface off-screen.
    readonly property real columnWidth: Math.min(root.preferredWidth,
      Math.max(120, Math.floor(availableWidth / (levels.count || 1))))
    // Keep the Wayland surface origin and size fixed. Moving a layer
    // surface left leaves Qt with the previous surface-local pointer until
    // physical motion arrives, falsely entering the child under those coords.
    // A transparent click-away backdrop shares this fixed surface.
    implicitWidth: availableWidth
    implicitHeight: availableHeight
    readonly property real availableHeight: Math.max(1, (screen ? screen.height : 1080) - margins.top - Style.barHeight - Style.space(1))
    readonly property real tallestColumn: {
      let height = 0
      for (let i = 0; i < levels.count; ++i) height = Math.max(height, levels.itemAt(i).naturalHeight)
      return height
    }
    readonly property bool expandsLeft: root.anchorX > screenWidth / 2
    margins.left: Style.space(0.5)

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-menu"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }
    Flickable {
      id: cascade
      width: Math.min(window.availableWidth, columns.width)
      height: Math.min(window.availableHeight, window.tallestColumn)
      x: window.expandsLeft
        ? Math.max(0, Math.min(root.anchorX + window.columnWidth, window.availableWidth) - width)
        : Math.max(0, Math.min(root.anchorX, window.availableWidth - width))
      contentWidth: columns.width
      contentHeight: height
      flickableDirection: Flickable.HorizontalFlick
      boundsBehavior: Flickable.StopAtBounds
      clip: true
      focus: true
      function reveal() {
        const column = levels.itemAt(root.activeLevel)
        if (!column) return
        if (column.x < contentX) contentX = column.x
        else if (column.x + column.width > contentX + width) contentX = column.x + column.width - width
      }
      Connections {
        target: root
        function onActiveLevelChanged() { Qt.callLater(cascade.reveal) }
      }
      Keys.onPressed: event => {
        const column = levels.itemAt(root.activeLevel)
        if (!column) return
        const control = (event.modifiers & Qt.ControlModifier) !== 0
        switch (event.key) {
        case Qt.Key_Escape: root.close(); break
        case Qt.Key_Left:
        case Qt.Key_Backspace: if (!event.isAutoRepeat) root.goBack(); break
        case Qt.Key_Right:
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
          // Navigation/activation consumes a physical key once, even after
          // focus moves to the newly created column.
          if (!event.isAutoRepeat) {
            const entry = column.rows[column.selection]
            if (event.key !== Qt.Key_Right || root.canOpen(entry))
              root.activate(root.activeLevel, entry, column.selection)
          }
          break
        case Qt.Key_Down: column.moveSelection(1); break
        case Qt.Key_Up: column.moveSelection(-1); break
        case Qt.Key_J: if (!control) return; column.moveSelection(1); break
        case Qt.Key_K: if (!control) return; column.moveSelection(-1); break
        case Qt.Key_Home: column.selection = -1; column.moveSelection(1); break
        case Qt.Key_End: column.selection = 0; column.moveSelection(-1); break
        default: return
        }
        event.accepted = true
      }
      Row {
        id: columns
        layoutDirection: window.expandsLeft ? Qt.RightToLeft : Qt.LeftToRight
        spacing: 1
        Repeater {
          id: levels
          // Incremental inserts/removals preserve ancestor delegates.
          model: levelModel
          delegate: MenuColumn {
            required property int depth
            controller: root
            level: depth
            rows: root.entries(depth)
            width: window.columnWidth
            height: Math.min(window.availableHeight, naturalHeight)
            surfaceWindow: window
          }
        }
      }
    }
  }
}
