import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// A status-notifier (DBusMenu) menu, drawn as a layer-shell panel.
//
// Quickshell's QsMenuAnchor cannot open its native menu outside QApplication
// mode ("Cannot call QsMenuAnchor.open() as quickshell was not started in
// QApplication mode"), so the entries come from QsMenuOpener and are rendered
// here. A layer-shell panel is used instead of PopupWindow because that is what
// every other cornice surface uses and its placement is predictable: it is
// anchored to the top edge and shifted to the item's x position.
Item {
  id: root

  property var handle: null
  // The status-notifier item this menu belongs to, so entries that Quickshell
  // cannot activate by itself can be clicked through cornice-tray-activate.
  property string ownerId: ""
  property string ownerTitle: ""
  property real anchorX: 0
  property var anchorWindow: null
  property int preferredWidth: 260

  readonly property bool opened: handle !== null

  function entries() {
    const model = opener.children
    if (!model) return []
    if (model.values !== undefined) return model.values
    if (Array.isArray(model)) return model
    return []
  }

  function count() {
    return entries().length
  }

  function close() {
    handle = null
  }

  signal entryChosen(var entry)

  QsMenuOpener {
    id: opener
    menu: root.handle
  }

  PanelWindow {
    id: window

    visible: root.opened
    color: "transparent"
    focusable: false
    exclusiveZone: 0
    aboveWindows: true

    anchors.top: true
    anchors.left: true
    margins.top: Style.barHeight + Style.space(0.5)
    margins.left: Math.max(0, Math.round(root.anchorX))

    implicitWidth: Math.max(180, Math.min(root.preferredWidth, column.implicitWidth + Style.space(3)))
    implicitHeight: Math.max(Style.widgetHeight, column.implicitHeight + Style.space(1.6))

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-menu"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Surface {
      anchors.fill: parent
      padding: Style.space(0.7)

      Column {
        id: column
        width: parent.width
        spacing: 1

        Repeater {
          model: root.entries()

          delegate: Item {
            id: row

            required property var modelData
            // A Repeater delegate that uses required properties must declare the
            // index itself, otherwise row.index is undefined.
            required property int index

            width: column.width
            height: modelData.isSeparator ? Math.round(Style.gap * 0.6) : Style.widgetHeight

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: 1
              visible: row.modelData.isSeparator
              color: Color.surfaceBorder
            }

            Rectangle {
              anchors.fill: parent
              visible: !row.modelData.isSeparator
              radius: Style.radius
              color: row.hovered && row.modelData.enabled ? Color.hover : "transparent"
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(0.7)
              anchors.rightMargin: Style.space(0.7)
              spacing: Style.space(0.6)
              visible: !row.modelData.isSeparator

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(1.6)
                text: row.modelData.checkState === Qt.Checked ? "\uf00c"
                    : row.modelData.checkState === Qt.PartiallyChecked ? "\uf00d" : ""
                color: Color.accent
                font.family: Style.iconFamily
                font.pixelSize: Style.smallFontSize
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(4.4)
                text: row.modelData.text
                color: row.modelData.enabled ? Color.foreground : Color.muted
                elide: Text.ElideRight
                font.family: Style.fontFamily
                font.pixelSize: Style.fontSize
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(1.4)
                text: row.modelData.hasChildren ? "\uf105" : ""
                color: Color.muted
                font.family: Style.iconFamily
                font.pixelSize: Style.smallFontSize
              }
            }

            property bool hovered: false

            MouseArea {
              anchors.fill: parent
              enabled: !row.modelData.isSeparator && row.modelData.enabled
              cursorShape: Qt.PointingHandCursor
              hoverEnabled: true
              onEntered: row.hovered = true
              onExited: row.hovered = false
              onClicked: {
                const entry = row.modelData
                try {
                  if (entry.hasChildren) {
                    // Submenus are not rendered by this panel (yet): open them the
                    // only way we can and leave the menu where it is.
                    entry.display()
                  } else if (typeof entry.sendTriggered === "function") {
                    // A DBusMenuItem knows how to tell its app about the click.
                    entry.sendTriggered()
                  } else if (root.ownerId !== "") {
                    // Quickshell hands entries to QML as plain QsMenuEntry objects
                    // (no activation method at all) when the menu comes from a
                    // status-notifier item, and it does not expose the item's bus
                    // name either — so the click is sent by a helper that speaks
                    // DBusMenu directly.
                    const quote = value => "'" + String(value).replace(/'/g, "'\\''") + "'"
                    const command = "cornice-tray-activate --id " + quote(root.ownerId)
                      + " --label " + quote(entry.text)
                      // Menus repeat labels ("More" twice in ChatGPT's), so say
                      // which occurrence this row is — the helper resolves that
                      // against the menu it fetches.
                      + " --index " + String(root.entries().slice(0, row.index)
                          .filter(candidate => candidate.text === entry.text).length)
                    // Logged on purpose: if the helper is missing from PATH the
                    // click would otherwise fail silently (it did once).
                    console.log("cornice: tray menu activate → " + command)
                    Util.exec(command)
                  } else {
                    entry.display()
                  }
                } catch (e) {
                  console.warn("cornice: menu entry failed: " + e)
                }
                root.entryChosen(entry)
                root.close()
              }
            }
          }
        }
      }
    }

    // Clicking the bar again, or anywhere else, should dismiss a menu. Escape
    // is not available here (the menu does not take the keyboard), so the
    // timeout is what closes a menu the user walked away from.
    Timer {
      interval: 12000
      running: root.opened
      repeat: false
      onTriggered: root.close()
    }
  }
}
