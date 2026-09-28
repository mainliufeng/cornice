import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Application launcher.
//
// Type to filter the desktop entries; arrows move, Enter runs. A query starting
// with ">" runs the rest as a shell command, which covers everything the
// .desktop database does not.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 520
  panelHeight: 420
  takesKeyboard: true

  property string query: ""
  property int selected: 0

  readonly property var applications: DesktopEntries.applications ? DesktopEntries.applications.values : []

  function commandMode() {
    return query.trim().startsWith(">")
  }

  readonly property var results: {
    const text = query.trim().toLowerCase()
    const list = []

    if (text === "" || commandMode()) {
      // Nothing typed: show the first few applications so the panel is not blank.
      const source = applications || []
      const limit = commandMode() ? 0 : 6
      for (let i = 0; i < Math.min(limit, source.length); i++) {
        const entry = source[i]
        if (!entry.noDisplay) list.push({ entry: entry, name: entry.name, comment: entry.comment, icon: entry.icon })
      }
      if (commandMode() && text.length > 1)
        list.push({ command: query.trim().slice(1), name: "Run: " + query.trim().slice(1), comment: "shell command" })
      return list
    }

    for (const entry of applications || []) {
      if (entry.noDisplay) continue
      const haystack = (String(entry.name) + " " + String(entry.genericName) + " " + String(entry.keywords) + " " + String(entry.id)).toLowerCase()
      if (haystack.indexOf(text) === -1) continue
      list.push({ entry: entry, name: entry.name, comment: entry.comment || entry.genericName, icon: entry.icon })
      if (list.length >= 12) break
    }
    return list
  }

  onOpened: {
    query = ""
    selected = 0
    focusTimer.restart()
  }

  Timer {
    id: focusTimer
    interval: 50
    onTriggered: field.forceFocus()
  }

  function move(delta) {
    if (results.length === 0) return
    selected = ((selected + delta) % results.length + results.length) % results.length
  }

  function accept() {
    if (results.length === 0) return
    const item = results[Math.max(0, Math.min(selected, results.length - 1))]
    if (item.command !== undefined) Util.exec(item.command)
    else if (item.entry) launch(item.entry)
    close()
  }

  function launch(entry) {
    // runInTerminal entries need a terminal wrapper; everything else is spawned
    // directly from its Exec line.
    if (entry.runInTerminal === true) Util.exec("kitty -e " + entry.execString)
    else Quickshell.execDetached(["sh", "-c", entry.execString])
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(0.8)

    TextField {
      id: field
      width: parent.width
      placeholder: "Search applications, or > to run a command"
      onTextChanged: root.query = text
      onAccepted: root.accept()
      onCanceled: root.close()
      onMoved: delta => root.move(delta)
    }

    Text {
      width: parent.width
      visible: root.results.length === 0
      text: root.commandMode() ? "type a command" : "no matching application"
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    ListView {
      id: list

      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(0.3)
      model: root.results
      currentIndex: root.selected

      delegate: Rectangle {
        required property var modelData
        required property int index

        width: list.width
        height: Style.widgetHeight + Style.space(1)
        radius: Style.radius
        color: index === root.selected ? Color.hover : "transparent"

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(0.8)
          anchors.rightMargin: Style.space(0.8)
          spacing: Style.space(0.8)

          Image {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.fontSize + 6
            height: width
            visible: modelData.icon !== undefined && modelData.icon !== ""
            source: modelData.icon === undefined || modelData.icon === "" ? "" : Quickshell.iconPath(modelData.icon, "")
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectFit
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(3)

            Text {
              width: parent.width
              text: modelData.name
              color: Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              width: parent.width
              text: modelData.comment || ""
              color: Color.muted
              elide: Text.ElideRight
              visible: (modelData.comment || "") !== ""
              font.family: Style.fontFamily
              font.pixelSize: Style.smallFontSize
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.selected = index
            root.accept()
          }
        }
      }
    }
  }
}
