import QtQuick
import qs.Commons

// Inline list editor: turns a small list of records into editable rows.
//
// The rows come from the plugin's live state and every change goes back through
// the plugin as a `cornice` CLI command — the CLI stays the only writer of the
// config file, exactly like the bar editor. This component owns only the
// interaction (fields, add/remove buttons) and shows the command's error, so a
// rejected value (say an unknown timezone) is visible in the panel instead of
// failing silently.
//
//   EditList {
//     rows: [["Shanghai", "Shanghai"], …]     // current values, in field order
//     fields: [I18n.t("editor.name"), I18n.t("weather.placeCity")]
//     onAddRequested: values => panel.run("add " + quote(values[0]) + " --city " + quote(values[1]))
//     onUpdateRequested: (index, values) => …
//     onRemoveRequested: index => …
//   }
Item {
  id: root

  property var rows: []
  property var fields: []
  property string error: ""
  // When false the caller supplies its own "add" affordance — the pickers do,
  // because a place or a zone must be chosen from a list, not typed.
  property bool allowAdd: true

  signal addRequested(var values)
  signal updateRequested(int index, var values)
  signal removeRequested(int index)

  implicitHeight: content.implicitHeight
  implicitWidth: content.implicitWidth

  // One delegate type covers both the existing rows and the trailing "add" row,
  // so the layout code exists once.
  readonly property var model: {
    const out = []
    for (let i = 0; i < root.rows.length; i++)
      out.push({ adding: false, index: i, values: root.rows[i] })
    if (root.allowAdd) out.push({ adding: true, index: -1, values: blank() })
    return out
  }

  function blank() {
    const out = []
    for (let i = 0; i < root.fields.length; i++) out.push("")
    return out
  }

  function collect(fieldRepeater) {
    const out = []
    for (let i = 0; i < fieldRepeater.count; i++) {
      const field = fieldRepeater.itemAt(i)
      out.push(field ? String(field.text) : "")
    }
    return out
  }

  function clear(fieldRepeater) {
    for (let i = 0; i < fieldRepeater.count; i++) {
      const field = fieldRepeater.itemAt(i)
      if (field) field.text = ""
    }
  }

  Column {
    id: content
    width: parent.width
    spacing: Style.space(0.6)

    Repeater {
      model: root.model

      delegate: Row {
        id: rowItem
        required property var modelData

        visible: !modelData.adding || root.allowAdd
        width: content.width
        spacing: Style.space(0.6)

        Repeater {
          id: fieldRepeater
          model: root.fields

          delegate: TextField {
            required property int index
            required property string modelData

            width: (rowItem.width - actionButton.width - Style.space(1.2)) / Math.max(1, root.fields.length)
            placeholder: modelData
            text: rowItem.modelData.values[index] === undefined ? "" : String(rowItem.modelData.values[index])

            onAccepted: {
              if (rowItem.modelData.adding) actionButton.commit()
              else root.updateRequested(rowItem.modelData.index, root.collect(fieldRepeater))
            }
          }
        }

        Item {
          id: actionButton
          width: Style.space(2.4)
          height: Style.space(2.4)

          readonly property bool adding: rowItem.modelData.adding

          function commit() {
            const values = root.collect(fieldRepeater)
            if (values.join("").trim() === "") return
            root.clear(fieldRepeater)
            root.addRequested(values)
          }

          Text {
            anchors.centerIn: parent
            text: actionButton.adding ? "\u{F0415}" : "\u{F0156}" // add / delete
            color: actionArea.containsMouse ? Color.accent : Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }

          MouseArea {
            id: actionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: actionButton.adding
              ? actionButton.commit()
              : root.removeRequested(rowItem.modelData.index)
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: root.error !== ""
      text: root.error
      color: Color.accent
      wrapMode: Text.Wrap
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }
  }
}
