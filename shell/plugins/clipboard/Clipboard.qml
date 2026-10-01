import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Clipboard history on top of cliphist.
//
// Type to filter, arrows to move, Enter pastes (text and images keep their
// mime type), Delete removes the entry, Esc closes. Images are decoded on
// demand into the runtime dir and shown as a preview.
PanelFrame {
  id: root

  edge: "center"
  panelWidth: Math.min(860, window.screen ? window.screen.width - Style.space(8) : 860)
  panelHeight: Math.min(620, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 620)
  takesKeyboard: true

  property var entries: []
  property string query: ""
  property int selected: 0
  property string previewPath: ""
  property int previewRevision: 0
  property string status: ""

  readonly property var filtered: {
    const text = query.trim().toLowerCase()
    if (text === "") return entries
    const out = []
    for (const entry of entries) {
      if (String(entry.preview).toLowerCase().indexOf(text) !== -1) out.push(entry)
      if (out.length >= 300) break
    }
    return out
  }

  readonly property var current: filtered.length === 0
    ? null
    : filtered[Math.max(0, Math.min(selected, filtered.length - 1))]

  readonly property string previewFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/cornice-clip-preview.bin"

  function parseList(text) {
    const out = []
    for (const line of String(text).split("\n")) {
      if (line === "") continue
      const tab = line.indexOf("\t")
      if (tab === -1) continue
      const id = line.slice(0, tab)
      const preview = line.slice(tab + 1)
      const isImage = /binary data/i.test(preview)
      out.push({
        id: id,
        preview: preview,
        image: isImage,
        mime: isImage ? mimeFor(preview) : ""
      })
    }
    entries = out
    selected = 0
  }

  function mimeFor(preview) {
    const text = String(preview).toLowerCase()
    if (/\bpng\b/.test(text)) return "image/png"
    if (/\b(jpe?g)\b/.test(text)) return "image/jpeg"
    if (/\bwebp\b/.test(text)) return "image/webp"
    if (/\bgif\b/.test(text)) return "image/gif"
    return "application/octet-stream"
  }

  // Mirror of scripts/clipboard.sh: text goes back as text, images keep their
  // mime type, otherwise the paste loses its type.
  function paste(entry) {
    if (!entry) return
    const command = entry.image
      ? "cliphist decode " + entry.id + " | wl-copy -t " + entry.mime
      : "cliphist decode " + entry.id + " | wl-copy"
    Util.exec(command)
    status = "copied " + entry.id
    close()
  }

  function remove(entry) {
    if (!entry) return
    Util.exec("cliphist decode " + entry.id + " | cliphist delete")
    status = "deleted " + entry.id
    lister.running = true
  }

  function move(delta) {
    if (filtered.length === 0) return
    selected = ((selected + delta) % filtered.length + filtered.length) % filtered.length
  }

  onOpened: {
    field.text = ""
    query = ""
    selected = 0
    status = ""
    lister.running = true
    focusTimer.restart()
  }

  // Refresh the decoded preview whenever the selection changes.
  onCurrentChanged: {
    if (!current || !current.image) {
      previewPath = ""
      return
    }
    previewDecoder.command = ["sh", "-c",
      "cliphist decode " + current.id + " > \"" + previewFile + "\" 2>/dev/null"]
    previewDecoder.running = true
  }

  Timer {
    id: focusTimer
    interval: 50
    onTriggered: field.forceFocus()
  }

  readonly property Process lister: Process {
    id: listerProcess
    command: ["sh", "-c", "cliphist list | head -400"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseList(text)
    }
  }

  readonly property Process previewDecoder: Process {
    id: previewProcess
    onExited: if (exitCode === 0) {
      root.previewPath = "file://" + root.previewFile
      root.previewRevision = root.previewRevision + 1
    }
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.space(1.5)
    spacing: Style.space(1.5)

    PanelHeader { width: parent.width; title: I18n.t("clipboard.title"); glyph: "\uf0ea" }

    Row {
      width: parent.width
      spacing: Style.space(0.8)

      TextField {
        id: field
        width: parent.width - count.width - parent.spacing
        placeholder: I18n.t("clipboard.placeholder")
        onTextChanged: root.query = text
        onAccepted: root.paste(root.current)
        onCanceled: root.close()
        onMoved: delta => root.move(delta)
      }

      Text {
        id: count
        anchors.verticalCenter: parent.verticalCenter
        text: root.filtered.length + " / " + root.entries.length
        color: Color.muted
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }
    }

    Text {
      width: parent.width
      text: I18n.t("clipboard.hint")
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Row {
      width: parent.width
      height: parent.height - y
      spacing: Style.space(1)

      // preview pane
      Item {
        width: Math.round(parent.width * 0.42)
        height: parent.height

        Rectangle {
          anchors.fill: parent
          radius: Style.radius
          color: Color.hover
          visible: root.current !== null && root.current.image
        }

        Image {
          anchors.fill: parent
          anchors.margins: Style.space(0.8)
          visible: root.current !== null && root.current.image && root.previewRevision > 0
          source: root.previewPath
          fillMode: Image.PreserveAspectFit
          asynchronous: true
        }

        Text {
          anchors.centerIn: parent
          width: parent.width - Style.space(2)
          visible: root.current === null || !root.current.image
          text: root.current === null ? I18n.t("clipboard.empty") : root.current.preview
          color: Color.foreground
          wrapMode: Text.Wrap
          maximumLineCount: 12
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }
      }

      ListView {
        id: list

        width: parent.width - parent.children[0].width - Style.space(1)
        height: parent.height
        clip: true
        spacing: Style.space(0.75)
        model: root.filtered
        currentIndex: root.selected

        delegate: Rectangle {
          required property var modelData
          required property int index

          width: list.width
          height: Style.space(6.5)
          radius: Style.radius
          color: index === root.selected ? Color.hover : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(0.6)
            anchors.rightMargin: Style.space(0.6)
            spacing: Style.space(0.6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.image ? "\uf03e" : "\uf0f6"
              color: modelData.image ? Color.accent : Color.muted
              font.family: Style.iconFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(3)
              text: modelData.preview
              color: Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton

            onClicked: mouse => {
              root.selected = index
              if (mouse.button === Qt.MiddleButton) root.remove(modelData)
              else root.paste(modelData)
            }
          }
        }
      }
    }
  }

  ShellIpc {
    target: "clipinfo"

    function refresh(): string {
      lister.running = true
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        entries: entries.length,
        filtered: filtered.length,
        first: entries.length > 0 ? String(entries[0].preview).slice(0, 60) : "",
        images: entries.filter(entry => entry.image).length
      })
    }
  }
}
