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
  panelWidth: Math.min(620, window.screen ? window.screen.width - Style.space(8) : 620)
  panelHeight: Math.min(600, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 600)
  takesKeyboard: true

  property string query: ""
  property int selected: 0

  // Terminal-running configuration:
  //   { "terminal": "kitty", "terminalApps": ["paseo", "codex"] }
  // Entries listed by desktop id or name (case-insensitive) are started inside
  // the terminal, as are entries whose .desktop file sets Terminal=true.
  readonly property var launcherConfig: host && host.config ? Util.option(host.config, "launcher", ({})) : ({})
  readonly property string terminal: Util.option(launcherConfig, "terminal", "kitty")
  readonly property var terminalApps: Util.option(launcherConfig, "terminalApps", [])

  function wantsTerminal(entry, force) {
    if (force) return true
    if (!entry) return false
    if (entry.runInTerminal === true) return true
    const id = String(entry.id || "").toLowerCase()
    const name = String(entry.name || "").toLowerCase()
    for (const candidate of terminalApps) {
      const needle = String(candidate).toLowerCase()
      if (needle === id || needle === name) return true
    }
    return false
  }

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
        list.push({
          command: query.trim().slice(1),
          name: I18n.t("launcher.run") + " " + query.trim().slice(1),
          comment: I18n.t("launcher.shellCommand")
        })
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
    // The TextField owns the text; clearing only `query` left the previous
    // search sitting in the box the next time the launcher opened.
    field.text = ""
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

  function accept(forceTerminal) {
    if (results.length === 0) return
    const item = results[Math.max(0, Math.min(selected, results.length - 1))]
    if (item.command !== undefined) runInTerminal(item.command)
    else if (item.entry) launch(item.entry, forceTerminal)
    close()
  }

  function runInTerminal(command) {
    if (command === undefined || String(command).trim() === "") return
    Util.exec(terminal + " -e sh -c " + JSON.stringify(String(command)))
  }

  // .desktop Exec lines carry field codes (%U, %F, %c, %k, %i, ...). We have no
  // file arguments, so drop the file placeholders and expand the rest — and run
  // through sh with the user's own bin dir on PATH, because desktop files assume
  // a login-ish environment.
  function sanitizedCommand(entry) {
    return String(entry.execString || "")
      .replace(/%[uUfFdDnNickvm]/g, code => {
        if (code === "%c") return entry.name || ""
        if (code === "%k") return entry.id || ""
        if (code === "%i") return ""
        return ""
      })
      .replace(/\s+/g, " ")
      .trim()
  }

  function launch(entry, forceTerminal) {
    let executable = sanitizedCommand(entry)
    if (!executable) return
    if (DesktopSession.agentShell) {
      // Browsers otherwise forward to the human's existing singleton process,
      // even when started through the agent's own Wayland socket.
      const match = executable.match(/^("[^"\n]+"|'[^'\n]+'|[^\s]+)([\s\S]*)$/)
      const program = match ? match[1].replace(/^["']|["']$/g, "").split("/").pop() : ""
      const chromium = /^(google-chrome(?:-stable|-beta|-unstable)?|chromium(?:-browser)?)$/.test(program)
      const firefox = /^(firefox(?:-esr|-developer-edition)?)$/.test(program)
      if (chromium || firefox) {
        const data = Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share"
        const profile = data + "/cornice/desktops/" + DesktopSession.name + (chromium ? "/chrome" : "/firefox")
        const quoted = "'" + profile.replace(/'/g, "'\\''") + "'"
        const flags = chromium ? " --ozone-platform=wayland --no-first-run --no-default-browser-check --user-data-dir=" + quoted
                               : " --no-remote --profile " + quoted
        executable = "mkdir -p " + quoted + " && " + match[1] + flags + match[2]
      }
    }
    const command = "PATH=\"$HOME/.local/bin:$PATH\" " + executable
    if (command.trim() === "") return
    if (wantsTerminal(entry, forceTerminal)) runInTerminal(command)
    else Quickshell.execDetached(["sh", "-c", command])
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.space(1.5)
    spacing: Style.space(1.5)

    PanelHeader { width: parent.width; title: I18n.t("launcher.title"); glyph: "\uf009" }

    TextField {
      id: field
      width: parent.width
      placeholder: I18n.t("launcher.placeholder")
      onTextChanged: root.query = text
      onAccepted: root.accept(false)
      onShiftAccepted: root.accept(true)
      onCanceled: root.close()
      onMoved: delta => root.move(delta)
    }

    Text {
      width: parent.width
      text: {
        const item = root.results[Math.max(0, Math.min(root.selected, root.results.length - 1))]
        const terminal = item !== undefined && (item.command !== undefined || root.wantsTerminal(item.entry, false))
        const base = I18n.t("launcher.hint")
        if (item === undefined) return base
        return terminal ? base + "        " + I18n.t("launcher.runsIn") + " " + root.terminal : base
      }
      color: Color.muted
      elide: Text.ElideRight
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Text {
      width: parent.width
      visible: root.results.length === 0
      text: I18n.t(root.commandMode() ? "launcher.typeCommand" : "launcher.empty")
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    ListView {
      id: list

      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(0.75)
      model: root.results
      currentIndex: root.selected

      delegate: Rectangle {
        required property var modelData
        required property int index

        width: list.width
        height: Style.space(8)
        radius: Style.radius
        color: index === root.selected ? Color.hover : "transparent"

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(0.8)
          anchors.rightMargin: Style.space(0.8)
          spacing: Style.space(0.8)

          Image {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(4)
            height: width
            visible: modelData.icon !== undefined && modelData.icon !== ""
            source: modelData.icon === undefined || modelData.icon === "" ? "" : Quickshell.iconPath(modelData.icon, "")
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectFit
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(5)

            Text {
              width: parent.width
              text: modelData.name
              color: Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize + 2
            }

            Text {
              width: parent.width
              text: {
                const base = modelData.comment || ""
                const terminal = modelData.command !== undefined || root.wantsTerminal(modelData.entry, false)
                return terminal ? (base === "" ? "runs in " + root.terminal : base + "  ·  runs in " + root.terminal) : base
              }
              color: Color.muted
              elide: Text.ElideRight
              visible: text !== ""
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
            root.accept(false)
          }
        }
      }
    }
  }

  ShellIpc {
    target: "launcher"

    // Test hook: the suites cannot drive the input method, so they set the
    // query directly (same idea as weather.select / idle.feed).
    function setQuery(text: string): string {
      root.query = text
      return root.query
    }

    function debug(): string {
      return JSON.stringify({
        query: query,
        selected: selected,
        results: results.length,
        first: results.length > 0 ? String(results[0].name) : ""
      })
    }
  }
}
