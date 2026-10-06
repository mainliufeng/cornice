import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

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
  panelWidth: 320
  readonly property int rowHeight: Style.space(5.5)

  readonly property var notifications: host ? host.services["cn.notifications"] : null
  readonly property bool dnd: notifications ? notifications.dnd === true : false

  readonly property var rows: [
    { glyph: "\uf009", label: I18n.t("menu.applications"), toggle: "cn.launcher" },
    { glyph: "\uf0ea", label: I18n.t("menu.clipboard"), toggle: "cn.clipboard" },
    { glyph: "\uf118", label: I18n.t("menu.emoji"), toggle: "cn.emojis" },
    { glyph: "\uf0f3", label: I18n.t("menu.notifications"), toggle: "cn.notifications" },
    { separator: true },
    { glyph: "\uf53f", label: I18n.t("menu.theme") + ": " + Theme.name, command: "cornice theme toggle" },
    { glyph: "\uf1ab", label: I18n.t("menu.language") + ": " + I18n.language,
      command: "cornice language " + (I18n.language === "zh-CN" ? "en" : "zh-CN") },
    { glyph: "\uf03e", label: I18n.t("menu.wallpaper"), command: "cornice background next" },
    { glyph: dnd ? "\uf1f6" : "\uf0f3", label: I18n.t("menu.dnd") + (dnd ? " · " + I18n.t("menu.on") : ""),
      action: "dnd", selected: dnd },
    { separator: true },
    { glyph: "\uf0c9", label: I18n.t("menu.barLayout"), toggle: "cn.bar-editor" },
    { glyph: "\uf023", label: I18n.t("menu.lock"), call: ["cn.lock", "lock"] },
    { glyph: "\uf011", label: I18n.t("menu.power"), toggle: "cn.power" }
  ]

  readonly property real contentHeight: rows.reduce(
    (sum, row) => sum + (row.separator === true ? Style.space(1.4) : rowHeight), 0)

  panelHeight: Math.min(
    window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 560,
    contentHeight + Style.space(2.4))

  function activate(row) {
    root.close()
    if (row.toggle) {
      if (host) host.toggle(row.toggle, {})
    } else if (row.call) {
      if (host) host.callPlugin(row.call[0], row.call[1])
    } else if (row.action === "dnd") {
      if (notifications) notifications.setDnd(!root.dnd)
    } else if (row.command) {
      Util.exec(row.command)
    }
  }

  Flickable {
    anchors.fill: parent
    anchors.margins: Style.space(1.1)
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: parent.width
      spacing: 1

      Repeater {
        model: root.rows

        delegate: Item {
          id: row
          required property var modelData
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
            color: row.hovered ? Color.hover : (row.modelData.selected ? Color.workspaceActive : "transparent")
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
              color: row.modelData.selected ? Color.workspaceActiveText : Color.accent
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(3.4)
              text: row.modelData.label || ""
              color: row.modelData.selected ? Color.workspaceActiveText : Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
          }

          property bool hovered: false

          MouseArea {
            anchors.fill: parent
            enabled: row.modelData.separator !== true
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: row.hovered = true
            onExited: row.hovered = false
            onClicked: root.activate(row.modelData)
          }
        }
      }
    }
  }

  ShellIpc {
    target: "menu"

    // Test hook: the suites cannot click a bar button, so they read the row
    // table itself. Structure only — the labels follow the UI language.
    function state(): string {
      const entries = root.rows.filter(row => row.separator !== true)
      return JSON.stringify({
        open: root.isOpen,
        rows: entries.length,
        toggles: entries.filter(row => row.toggle).map(row => row.toggle),
        calls: entries.filter(row => row.call).map(row => row.call.join(".")),
        commands: entries.filter(row => row.command).map(row => String(row.command).split(" ").slice(0, 2).join(" ")),
        selected: entries.filter(row => row.selected === true).length
      })
    }
  }
}
