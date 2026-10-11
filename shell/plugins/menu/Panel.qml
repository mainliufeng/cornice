import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../notifications" as Notifications

// The menu.
//
// Everything here is reachable by clicking the bar button first: the whole
// point is that a user who does not want to learn keybindings can still open
// the clipboard, the emoji picker, the bar layout, the theme, the wallpaper,
// do-not-disturb, the lock screen and the power panel.
//
// Rows either toggle another cornice surface, call a plugin method, or run a
// `cornice` command (the CLI owns theme/language persistence).
PanelFrame {
  id: root

  edge: "top"
  windowWidth: Math.min(640, window.screen ? window.screen.width - Style.space(2) : 640)
  panelWidth: Math.min(page === "themes" ? 640 : 320, window.screen ? window.screen.width - Style.space(2) : 640)
  readonly property int rowHeight: Style.space(5.5)

  Notifications.Model { id: notificationModel; host: root.host }
  readonly property var notifications: notificationModel
  readonly property bool dnd: notifications ? notifications.dnd === true : false

  // Theme choices expand beside the persistent root menu.
  property string page: "root"
  property var themes: []
  // Index into `rows` of the keyboard highlight; -1 until the first move.
  property int selection: -1
  property int rootSelection: 0
  // Live theme preview: what to restore if the choice is cancelled with Esc.
  property string themeBefore: ""
  property bool themeConfirmed: false

  readonly property var rootRows: [
    { glyph: "\uf009", label: I18n.t("menu.applications"), toggle: "cn.launcher" },
    { glyph: "\uf0ea", label: I18n.t("menu.clipboard"), toggle: "cn.clipboard" },
    { glyph: "\uf118", label: I18n.t("menu.emoji"), toggle: "cn.emojis" },
    { glyph: "\uf0f3", label: I18n.t("menu.notifications"), toggle: "cn.notifications" },
    { separator: true },
    { glyph: "\uf1fc", label: I18n.t("menu.theme") + ": " + Theme.name, page: "themes" },
    { glyph: "\uf1ab", label: I18n.t("menu.language") + ": " + I18n.language,
      command: "cornice language " + (I18n.language === "zh-CN" ? "en" : "zh-CN") },
    { glyph: "\uf03e", label: I18n.t("menu.wallpaper"), command: "cornice background next" },
    { glyph: dnd ? "\uf1f6" : "\uf0f3", label: I18n.t("menu.dnd") + (dnd ? " · " + I18n.t("menu.on") : ""),
      action: "dnd", selected: dnd, enabled: notifications.available },
    { separator: true },
    { glyph: "\uf0c9", label: I18n.t("menu.barLayout"), toggle: "cn.bar-editor" },
    { glyph: "\uf023", label: I18n.t("menu.lock"), call: ["cn.lock", "lock"] },
    { glyph: "\uf011", label: I18n.t("menu.power"), toggle: "cn.power" }
  ]

  readonly property var themeRows: {
    const out = [{ glyph: "\uf060", label: I18n.t("common.back"), page: "root" }]
    for (const name of themes) {
      out.push({
        glyph: Theme.name === name ? "\uf00c" : "\uf111",
        label: name,
        theme: name,
        selected: Theme.name === name
      })
    }
    return out
  }

  readonly property var rows: page === "themes" ? themeRows : rootRows

  readonly property real contentHeight: rows.reduce(
    (sum, row) => sum + (row.separator === true ? Style.space(1.4) : rowHeight), 0)

  panelHeight: Math.min(
    window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 560,
    Math.max(contentHeight, rootRows.reduce((sum, row) => sum + (row.separator === true ? Style.space(1.4) : rowHeight), 0)) + Style.space(2.4))

  function activate(row) {
    if (row.enabled === false) return
    // Page rows navigate the panel; they must not close it.
    if (row.page === "themes") {
      if (root.page !== "themes") { rootSelection = selection; root.page = "themes" }
      return
    }
    if (row.page === "root") {
      root.page = "root"
      return
    }
    if (row.theme) {
      // Confirming keeps the preview: persist it so the choice survives a
      // restart, and mark it before closing so onDismissed does not revert.
      themeConfirmed = true
      Util.execSession("cornice theme " + Util.shellQuote(row.theme))
    } else if (row.toggle) {
      if (host) host.toggle(row.toggle, {})
    } else if (row.call) {
      if (host) host.callPlugin(row.call[0], row.call[1])
    } else if (row.action === "dnd") {
      if (notifications) notifications.setDnd(!root.dnd)
    } else if (row.command) {
      Util.execSession(row.command)
    }
    root.close()
  }

  // Moving the highlight through the theme list previews each theme live, so
  // the list is browsable; cancelling restores the one you came in with.
  function previewSelectedTheme() {
    if (page !== "themes") return
    const row = rows[selection]
    if (row && row.theme && row.theme !== Theme.name) Theme.name = row.theme
  }

  function cancelPreview() {
    if (!themeConfirmed && themeBefore !== "" && Theme.name !== themeBefore)
      Theme.name = themeBefore
    themeBefore = ""
  }

  // Refresh the installed themes each time the menu opens (a theme can be
  // dropped in while the shell is running).
  onOpened: {
    root.page = "root"
    rootSelection = 0
    themeBefore = ""
    themeConfirmed = false
    resetSelection()
    themeList.running = true
  }

  onDismissed: cancelPreview()
  onPageChanged: {
    // Entering the picker remembers the theme to fall back to; leaving it
    // cancels any preview that was not confirmed.
    if (page === "themes") {
      themeBefore = Theme.name
      themeConfirmed = false
    } else {
      cancelPreview()
    }
    if (page === "root") selection = rootSelection
    else resetSelection()
  }
  onSelectionChanged: {
    ensureVisible(selection)
    previewSelectedTheme()
  }

  function resetSelection() {
    selection = -1
    moveSelection(1)
  }

  // Skip separators and wrap around. `selection` stays a plain index so hover
  // and the keyboard share one highlight.
  function moveSelection(delta) {
    if (rows.length === 0) return
    let index = selection
    for (let step = 0; step < rows.length; step++) {
      index = (index + delta + rows.length) % rows.length
      if (rows[index] && rows[index].separator !== true) {
        selection = index
        return
      }
    }
  }

  function activateSelected() {
    if (selection < 0 || selection >= rows.length) return
    const row = rows[selection]
    if (row && row.separator !== true) activate(row)
  }

  function ensureVisible(index) {
    const viewport = page === "themes" ? themeViewport : rootViewport
    if (index < 0 || !viewport || viewport.height <= 0) return
    let y = 0
    for (let i = 0; i < index; i++)
      y += rows[i] && rows[i].separator === true ? Style.space(1.4) : rowHeight
    const height = rows[index] && rows[index].separator === true ? Style.space(1.4) : rowHeight
    if (y < viewport.contentY) viewport.contentY = y
    else if (y + height > viewport.contentY + viewport.height)
      viewport.contentY = Math.max(0, y + height - viewport.height)
  }

  // Navigation never closes the menu: only Escape (PanelFrame) or acting on a
  // row does. Up/Down and Ctrl-j/k move the highlight, Enter/Space acts.
  onKeyPressed: event => {
    const control = (event.modifiers & Qt.ControlModifier) !== 0
    switch (event.key) {
    case Qt.Key_Down:
      moveSelection(1); event.accepted = true; break
    case Qt.Key_Up:
      moveSelection(-1); event.accepted = true; break
    case Qt.Key_J:
      if (control) { moveSelection(1); event.accepted = true }
      break
    case Qt.Key_K:
      if (control) { moveSelection(-1); event.accepted = true }
      break
    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space:
      if (!event.isAutoRepeat) activateSelected(); event.accepted = true; break
    case Qt.Key_Left:
    case Qt.Key_Backspace:
      if (!event.isAutoRepeat) page = "root"
      event.accepted = true; break
    case Qt.Key_Right:
      if (!event.isAutoRepeat && rows[selection] && rows[selection].page === "themes") activateSelected()
      event.accepted = true; break
    case Qt.Key_Home:
      selection = -1; moveSelection(1); event.accepted = true; break
    case Qt.Key_End:
      selection = 0; moveSelection(-1); event.accepted = true; break
    }
  }

  Process {
    id: themeList
    command: ["sh", "-c", "ls -1 " + Util.shellQuote((host && host.prefix ? host.prefix : "") + "/themes") + " 2>/dev/null | sort"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const names = String(text).trim()
        root.themes = names === "" ? [] : names.split("\n").filter(name => name !== "")
      }
    }
  }

  component MenuViewport: Flickable {
    property bool themeColumn: false
    readonly property var displayedRows: themeColumn ? root.themeRows : root.rootRows
    function inspect() {
      const out = []
      for (let i = 0; i < displayedItems.count; ++i) {
        const row = displayedItems.itemAt(i)
        const point = row.mapToItem(root.window.contentItem, row.width / 2, row.height / 2)
        out.push({page: row.modelData.page || "", theme: row.modelData.theme || "", x: Math.round(point.x), y: Math.round(point.y)})
      }
      return out
    }
    readonly property int displayedSelection: themeColumn ? root.selection : root.page === "root" ? root.selection : root.rootSelection

    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: parent.width
      spacing: 1

      Repeater {
        id: displayedItems
        model: displayedRows

        delegate: Item {
          id: row
          required property var modelData
          required property int index
          width: column.width
          height: modelData.separator === true ? Style.space(1.4) : root.rowHeight

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            visible: row.modelData.separator === true
            color: Color.surfaceBorder
          }

          Rectangle {
            anchors.fill: parent
            visible: row.modelData.separator !== true
            radius: Style.radius
            color: row.index === displayedSelection ? Color.workspaceActive
                 : row.hovered ? Color.hover : "transparent"
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(0.9)
            anchors.rightMargin: Style.space(0.9)
            spacing: Style.space(1)
            visible: row.modelData.separator !== true

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(1.8)
              text: row.modelData.glyph || ""
              color: row.index === displayedSelection ? Color.workspaceActiveText : Color.accent
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(3.4)
              text: row.modelData.label || ""
              color: row.index === displayedSelection ? Color.workspaceActiveText : Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
          }

          property bool hovered: false

          MouseArea {
            anchors.fill: parent
            enabled: row.modelData.separator !== true && row.modelData.enabled !== false
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: {
              row.hovered = true
              if (themeColumn === (root.page === "themes")) root.selection = row.index
              else if (!themeColumn) root.rootSelection = row.index
            }
            onExited: row.hovered = false
            onClicked: {
              if (!themeColumn && row.modelData.page !== "themes") root.page = "root"
              root.activate(row.modelData)
            }
          }
        }
      }
    }
  }

  MenuViewport {
    id: rootViewport
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(1.1)
    width: (parent.width - Style.space(2.2)) / (root.page === "themes" ? 2 : 1)
  }
  Rectangle {
    visible: root.page === "themes"
    x: parent.width / 2
    width: 1
    height: parent.height
    color: Color.surfaceBorder
  }
  MenuViewport {
    id: themeViewport
    themeColumn: true
    visible: root.page === "themes"
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(1.1)
    width: rootViewport.width - Style.space(1.1)
  }

  ShellIpc {
    target: "menu"

    // Test hook: the suites cannot click a bar button, so they read the row
    // table itself. Structure only — the labels follow the UI language.
    function state(): string {
      // Structure of the root page, not whichever page happens to be open, so
      // the row table stays a stable contract.
      const entries = root.rootRows.filter(row => row.separator !== true)
      return JSON.stringify({
        open: root.isOpen,
        notificationsAvailable: root.notifications.available, dnd: root.dnd,
        serviceError: root.notifications.error || root.notifications.operationError,
        page: root.page,
        rows: entries.length,
        toggles: entries.filter(row => row.toggle).map(row => row.toggle),
        calls: entries.filter(row => row.call).map(row => row.call.join(".")),
        commands: entries.filter(row => row.command).map(row => String(row.command).split(" ").slice(0, 2).join(" ")),
        selected: entries.filter(row => row.selected === true).length,
        selection: root.selection,
        columns: root.page === "themes" ? 2 : 1,
        panels: root.page === "themes" ? [rootViewport.inspect(), themeViewport.inspect()] : [rootViewport.inspect()],
        theme: Theme.name,
        themes: root.themes
      })
    }

    // Test hook: open a picker page without simulating a click.
    function openPage(name: string): string {
      root.page = String(name)
      return root.page
    }
  }
}
