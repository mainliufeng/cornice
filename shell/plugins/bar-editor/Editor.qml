import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar layout editor: choose which widgets are visible, in which order.
//
// Every action goes through the `cornice bar` CLI, which owns the config edit and
// asks the shell to reload — so there is exactly one writer for the config file,
// and the same operations are available from a script (and already tested that
// way).
PanelFrame {
  id: editor

  edge: "center"
  panelWidth: 480
  panelHeight: 580
  takesKeyboard: false

  readonly property var sections: ["left", "center", "right"]

  readonly property var layout: (host && host.config && host.config.bar && host.config.bar.layout)
    ? host.config.bar.layout : ({})

  readonly property var widgets: (host && typeof host.barWidgets === "function")
    ? host.barWidgets() : []

  function shownIn(section) {
    return layout[section] || []
  }

  function isShown(id) {
    for (const section of sections) {
      for (const entry of shownIn(section)) {
        if (entry.id === id) return true
      }
    }
    return false
  }

  function labelFor(id) {
    for (const widget of widgets) {
      if (widget.id !== id) continue
      return widget.displayName || widget.name || id
    }
    return id
  }

  // One flat list, so the view needs a single Repeater: section headers, the
  // widgets of that section, then a header and entries for the hidden ones.
  readonly property var rows: {
    const out = []
    for (const section of sections) {
      const entries = shownIn(section)
      out.push({ kind: "header", text: section.toUpperCase() })
      if (entries.length === 0) out.push({ kind: "empty", text: I18n.t("bar.editor.nothing") })
      for (let index = 0; index < entries.length; index++) {
        const id = entries[index].id
        out.push({
          kind: "widget",
          id: id,
          section: section,
          label: labelFor(id),
          up: index > 0,
          down: index < entries.length - 1
        })
      }
    }
    const hidden = widgets.filter(widget => !isShown(widget.id))
    if (hidden.length > 0) {
      out.push({ kind: "header", text: I18n.t("bar.editor.hidden") })
      for (const widget of hidden) {
        out.push({ kind: "hidden", id: widget.id, label: labelFor(widget.id) })
      }
    }
    return out
  }

  function run(command) {
    Util.exec("cornice bar " + command)
  }

  function placementActions(row) {
    return sections.map(section => ({
      glyph: I18n.t("bar.editor." + section),
      command: row.kind === "hidden"
        ? "show " + Util.shellQuote(row.id) + " --section " + section
        : "move " + Util.shellQuote(row.id) + " " + section,
      enabled: row.section !== section,
      selected: row.section === section
    }))
  }

  component RowShell: Rectangle {
    id: shell
    property string label: ""
    property bool muted: false
    property var actions: []
    function inspect() {
      const out = []
      for (let i = 0; i < actionButtons.count; i++) {
        const button = actionButtons.itemAt(i)
        const point = button.mapToItem(editor.window.contentItem, button.width / 2, button.height / 2)
        out.push({ command: button.modelData.command, enabled: button.enabled,
          x: Math.round(point.x), y: Math.round(point.y) })
      }
      return out
    }

    // NB: inside an inline `component` declaration, `root` is the component
    // itself — using it here made the row reference its own width and collapse
    // to nothing. The parent is the delegate item, which is what we want.
    width: parent.width - Style.space(1.6)
    height: Style.widgetHeight
    radius: Style.radius
    color: Color.hover

    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(0.8)
      width: parent.width - actionsRow.width - Style.space(1.2)
      text: shell.label
      color: shell.muted ? Color.muted : Color.foreground
      elide: Text.ElideRight
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    Row {
      id: actionsRow
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.space(0.4)
      spacing: Style.space(0.3)

      Repeater {
        id: actionButtons
        model: shell.actions

        delegate: Rectangle {
          required property var modelData
          enabled: modelData.enabled !== false

          width: Style.widgetHeight
          height: Style.widgetHeight
          radius: Style.radius
          color: modelData.selected || (enabled && hoverArea.containsMouse) ? Color.accent : Color.background

          Text {
            anchors.centerIn: parent
            text: parent.modelData.glyph
            color: parent.modelData.selected ? Color.background : parent.enabled ? Color.foreground : Color.muted
            font.family: Style.iconFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            id: hoverArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: editor.run(modelData.command)
          }
        }
      }
    }
  }

  Column {
    id: contentColumn
    anchors.fill: parent
    spacing: Style.space(0.8)

    Text {
      id: titleLabel
      text: I18n.t("bar.editor.title")
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      font.bold: true
    }

    Text {
      id: hintLabel
      width: parent.width
      text: I18n.t("bar.editor.hint")
      color: Color.muted
      wrapMode: Text.Wrap
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Flickable {
      id: scroll
      width: parent.width
      height: Math.max(Style.widgetHeight, parent.height - titleLabel.height
        - hintLabel.height - footerLabel.height - parent.spacing * 3)
      contentHeight: list.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: list
        width: parent.width
        spacing: Style.space(0.4)

        Repeater {
          id: rowItems
          model: editor.rows

          delegate: Item {
            required property var modelData
            function inspect() {
              return { id: modelData.id || "", kind: modelData.kind,
                section: modelData.section || "", actions: modelData.kind === "widget"
                  ? shownRow.inspect() : modelData.kind === "hidden" ? hiddenRow.inspect() : [] }
            }

            width: list.width
            height: modelData.kind === "header"
              ? Style.widgetHeight * 0.8
              : (modelData.kind === "empty" ? Style.widgetHeight * 0.6 : Style.widgetHeight + Style.space(0.2))

            Text {
              visible: parent.modelData.kind === "header" || parent.modelData.kind === "empty"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: parent.modelData.text || ""
              color: Color.muted
              font.family: Style.fontFamily
              font.pixelSize: Style.smallFontSize
            }

            RowShell {
              id: shownRow
              visible: parent.modelData.kind === "widget"
              label: parent.modelData.label || ""
              actions: parent.modelData.kind === "widget" ? editor.placementActions(parent.modelData).concat([
                { glyph: "\u{F062}", command: "move " + Util.shellQuote(parent.modelData.id) + " up", enabled: parent.modelData.up },
                { glyph: "\u{F063}", command: "move " + Util.shellQuote(parent.modelData.id) + " down", enabled: parent.modelData.down },
                { glyph: "\u{F00D}", command: "hide " + Util.shellQuote(parent.modelData.id), enabled: true }
              ]) : []
            }

            RowShell {
              id: hiddenRow
              visible: parent.modelData.kind === "hidden"
              label: parent.modelData.label || ""
              muted: true
              actions: parent.modelData.kind === "hidden" ? editor.placementActions(parent.modelData) : []
            }
          }
        }
      }
    }

    Text {
      id: footerLabel
      width: parent.width
      text: I18n.t("bar.editor.scriptable")
      color: Color.muted
      wrapMode: Text.Wrap
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }
  }
  ShellIpc {
    target: "barEditor"
    function state(): string {
      const rows = []
      for (let i = 0; i < rowItems.count; i++) rows.push(rowItems.itemAt(i).inspect())
      const origin = scroll.mapToItem(editor.window.contentItem, 0, 0)
      return JSON.stringify({ open: editor.isOpen, rows: rows,
        moving: scroll.moving,
        viewport: { x: origin.x, y: origin.y, width: scroll.width, height: scroll.height } })
    }
  }
}
