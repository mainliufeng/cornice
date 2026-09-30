import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Calendar panel behind the clock.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: Math.min(480, window.screen ? window.screen.width - Style.space(8) : 480)
  panelHeight: Math.min(editing ? 600 : 720, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 720)
  readonly property int bodySize: Style.fontSize + 2
  takesKeyboard: false

  // The world-clock section reads offsets from the clock service.
  readonly property var service: (host && host.services) ? host.services["cn.clock"] : null
  // The zone picker reuses the weather plugin's city search: a city result
  // carries its timezone and a name already localized to the configured language.
  readonly property var citySearch: (host && host.services) ? (host.services["cn.weather"] || null) : null

  // Inline editing of the world clocks; every change goes through the CLI.
  readonly property bool editing: !!service && service.editorOpen
  property string editError: ""

  function runCommand(command) {
    editError = ""
    Util.exec("cornice clock " + command)
  }

  property int shownYear: 0
  property int shownMonth: 0   // 0-based

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  onOpened: { resetToToday(); if (service) service.editorOpen = false }

  function resetToToday() {
    const now = clock.date
    shownYear = now.getFullYear()
    shownMonth = now.getMonth()
  }

  function shiftMonth(delta) {
    let month = shownMonth + delta
    let year = shownYear
    if (month < 0) { month = 11; year -= 1 }
    if (month > 11) { month = 0; year += 1 }
    shownYear = year
    shownMonth = month
  }

  readonly property var cells: {
    const now = clock.date
    const today = { day: now.getDate(), month: now.getMonth(), year: now.getFullYear() }

    const first = new Date(shownYear, shownMonth, 1)
    const daysInMonth = new Date(shownYear, shownMonth + 1, 0).getDate()
    // Monday-first grid.
    const leading = (first.getDay() + 6) % 7

    const out = []
    for (let i = 0; i < leading; i++) out.push({ label: "", today: false })
    for (let day = 1; day <= daysInMonth; day++) {
      out.push({
        label: String(day),
        today: day === today.day && shownMonth === today.month && shownYear === today.year
      })
    }
    while (out.length < 42) out.push({ label: "", today: false })
    return out
  }

  readonly property string monthLabel: {
    const date = new Date(shownYear, shownMonth, 1)
    return I18n.dateTime(date, I18n.t("clock.monthFormat"))
  }

  Flickable {
    id: viewport
    anchors.fill: parent
    anchors.margins: Style.space(1.5)
    contentHeight: body.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    Column {
      id: body
      width: viewport.width
      spacing: Style.space(2)
      Column {
        width: parent.width
        spacing: Style.space(0.7)
        Text { text: I18n.t("clock.sameTime"); color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.fontSize }
        Text {
          text: I18n.dateTime(clock.date, "HH:mm")
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize * 3.6
        }
        Text {
          width: parent.width
          text: I18n.dateTime(clock.date, I18n.t("clock.dateFormat"))
          color: Color.muted
          font.family: Style.fontFamily
          font.pixelSize: root.bodySize
          elide: Text.ElideRight
        }
      }
      Item {
        width: parent.width
        height: Style.space(5.5)
        visible: !root.editing
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - monthActions.width - Style.space(1)
          text: root.monthLabel
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: root.bodySize
          font.bold: true
          elide: Text.ElideRight
        }
        Row {
          id: monthActions
          anchors.right: parent.right
          spacing: Style.space(0.5)
          PanelButton { id: prev; width: height; glyph: "\uf104"; onClicked: root.shiftMonth(-1) }
          PanelButton { id: next; width: height; glyph: "\uf105"; onClicked: root.shiftMonth(1) }
          PanelButton { id: todayButton; label: I18n.t("weather.today"); filled: true; onClicked: root.resetToToday() }
        }
      }
      Grid {
        id: grid
        visible: !root.editing
        width: parent.width
        columns: 7
        spacing: Style.space(0.5)
        Repeater {
          model: I18n.weekdayNames("ddd")
          delegate: Text {
            required property var modelData
            width: (grid.width - grid.spacing * 6) / 7
            height: Style.space(3.5)
            text: modelData
            color: Color.muted
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }
        }
        Repeater {
          model: root.cells
          delegate: Rectangle {
            required property var modelData
            width: (grid.width - grid.spacing * 6) / 7
            height: Style.space(5.2)
            color: modelData.today ? Color.workspaceActive : "transparent"
            radius: Style.radius
            Text {
              anchors.centerIn: parent
              text: modelData.label
              color: modelData.today ? Color.workspaceActiveText : Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: root.bodySize
              font.bold: modelData.today
            }
          }
        }
      }
      Column {
        width: parent.width
        spacing: Style.space(1.5)
        readonly property int revision: root.service ? root.service.revision : 0
        Item {
          width: parent.width
          height: Style.space(5.5)
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: I18n.t("clock.world")
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
          PanelButton {
            id: zoneToggle
            anchors.right: parent.right
            label: I18n.t(root.editing ? "editor.done" : "clock.manage")
            filled: true
            onClicked: if (root.service) root.service.editorOpen = !root.service.editorOpen
          }
        }
        Item {
          width: parent.width
          height: Style.space(5.5)
          visible: root.editing
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - clearZone.width - Style.space(1)
            text: {
              const rows = root.service ? root.service.rows : []
              return rows.length > 0 ? rows[0].name + " · " + rows[0].zone : I18n.t("clock.noZones")
            }
            color: Color.foreground
            elide: Text.ElideRight
            font.family: Style.fontFamily
            font.pixelSize: root.bodySize
          }
          PanelButton {
            id: clearZone
            anchors.right: parent.right
            glyph: "\u{F0156}"
            onClicked: root.runCommand("zone clear")
          }
        }
        PickerList {
          id: zonePicker
          width: parent.width
          visible: root.editing
          rowHeight: Style.space(5.5)
          textSize: root.bodySize
          maxVisible: 4
          placeholder: I18n.t("clock.searchZone")
          emptyText: I18n.t("editor.noMatches")
          busy: !!root.citySearch && root.citySearch.searching
          items: (root.citySearch ? root.citySearch.searchResults || [] : []).filter(entry => entry.timezone !== "")
            .map(entry => ({ label: entry.name + " — " + entry.timezone, detail: entry.country }))
          onQueryChanged: if (root.citySearch) root.citySearch.search(query)
          onPicked: index => {
            const list = root.citySearch ? root.citySearch.searchResults.filter(entry => entry.timezone !== "") : []
            const entry = list[index]
            if (!entry) return
            root.runCommand("zone use " + Util.shellQuote(entry.name) + " " + Util.shellQuote(entry.timezone))
            zonePicker.clear()
          }
        }
        Column {
          width: parent.width
          spacing: Style.space(1)
          visible: !root.editing
          Repeater {
            model: root.service ? root.service.rows : []
            delegate: Rectangle {
              required property var modelData
              width: body.width
              height: Style.space(9)
              color: Color.surface
              radius: Style.radius
              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(1.5)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - zoneTime.width - Style.space(4)
                spacing: Style.space(0.5)
                Text {
                  width: parent.width
                  text: modelData.name
                  color: Color.foreground
                  elide: Text.ElideRight
                  font.family: Style.fontFamily
                  font.pixelSize: root.bodySize
                }
                Text {
                  width: parent.width
                  text: root.service.zoneTime(modelData.zone, "ddd d MMM") + " · " + root.service.zoneDiff(modelData.zone)
                  color: Color.muted
                  elide: Text.ElideRight
                  font.family: Style.fontFamily
                  font.pixelSize: Style.smallFontSize
                }
              }
              Text {
                id: zoneTime
                anchors.right: parent.right
                anchors.rightMargin: Style.space(1.5)
                anchors.verticalCenter: parent.verticalCenter
                text: root.service.zoneTime(modelData.zone, "HH:mm")
                color: Color.foreground
                font.family: Style.fontFamily
                font.pixelSize: Style.largeFontSize + 4
              }
            }
          }
        }
      }
    }
  }
  function action(item, name) {
    const point = item.mapToItem(window.contentItem, item.width / 2, item.height / 2)
    return { name: name, x: point.x, y: point.y }
  }
  ShellIpc {
    target: "clockPanel"
    function state(): string {
      return JSON.stringify({ open: root.isOpen, editing: root.editing, width: root.panelWidth, height: root.panelHeight,
        year: root.shownYear, month: root.shownMonth, contentHeight: body.implicitHeight, viewportHeight: viewport.height,
        actions: [root.action(prev, "prev"), root.action(next, "next"), root.action(todayButton, "today"), root.action(zoneToggle, "edit")],
        picker: zonePicker.inspect(root.window.contentItem) })
    }
  }
}
