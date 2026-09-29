import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Calendar panel behind the clock.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 300
  panelHeight: 470
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

  onOpened: resetToToday()

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
    return out
  }

  readonly property string monthLabel: {
    const date = new Date(shownYear, shownMonth, 1)
    return I18n.dateTime(date, "MMMM yyyy")
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(0.8)

    Row {
      width: parent.width
      spacing: Style.space(0.6)

      Text {
        id: prev
        text: "\uf104"
        color: Color.foreground
        font.family: Style.iconFamily
        font.pixelSize: Style.fontSize
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.shiftMonth(-1)
        }
      }

      Text {
        width: parent.width - prev.width - next.width - Style.space(1.2)
        text: root.monthLabel
        color: Color.foreground
        horizontalAlignment: Text.AlignHCenter
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
        font.bold: true
      }

      Text {
        id: next
        text: "\uf105"
        color: Color.foreground
        font.family: Style.iconFamily
        font.pixelSize: Style.fontSize
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.shiftMonth(1)
        }
      }
    }

    Grid {
      id: grid

      width: parent.width
      columns: 7
      spacing: 0

      Repeater {
        // Weekday headers follow the language (and the locale's first day of
        // week is applied when the grid is built).
        model: I18n.weekdayNames("ddd")

        delegate: Text {
          required property var modelData
          width: grid.width / 7
          height: Style.space(2)
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

          width: grid.width / 7
          height: Style.space(2.4)
          color: modelData.today ? Color.workspaceActive : "transparent"
          radius: Style.radius

          Text {
            anchors.centerIn: parent
            text: modelData.label
            color: modelData.today ? Color.workspaceActiveText : Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
        }
      }
    }

    Item { width: 1; height: 1 }

    // ---- world clocks ------------------------------------------------------
    Column {
      width: parent.width
      spacing: Style.space(0.6)

      readonly property int revision: root.service ? root.service.revision : 0

      Item { width: 1; height: Style.space(0.4) }

      Item {
        width: parent.width
        height: Math.max(worldTitle.height, zoneToggle.height)

        Text {
          id: worldTitle
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: I18n.t("clock.world")
          color: Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }

        Item {
          id: zoneToggle
          anchors.right: parent.right
          width: Style.space(2.4)
          height: Style.space(2.4)

          Text {
            anchors.centerIn: parent
            text: root.editing ? "\u{F012C}" : "\u{F03EB}" // check / pencil
            color: zoneToggleArea.containsMouse ? Color.accent : Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }

          MouseArea {
            id: zoneToggleArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.service) root.service.editorOpen = !root.service.editorOpen
              root.editError = ""
            }
          }
        }
      }


      Row {
        width: parent.width
        visible: root.editing
        spacing: Style.space(0.6)

        Text {
          width: parent.width - clearZone.width
          text: {
            const rows = root.service ? root.service.rows : []
            return rows.length > 0 ? rows[0].name + "   " + rows[0].zone : I18n.t("clock.noZones")
          }
          color: Color.foreground
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }

        Item {
          id: clearZone
          width: Style.space(2.4)
          height: Style.space(2.4)

          Text {
            anchors.centerIn: parent
            text: "\u{F0156}"
            color: clearZoneArea.containsMouse ? Color.accent : Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }

          MouseArea {
            id: clearZoneArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.runCommand("zone clear")
          }
        }
      }

      PickerList {
        id: zonePicker
        width: parent.width
        visible: root.editing
        placeholder: I18n.t("clock.searchZone")
        emptyText: I18n.t("editor.noMatches")
        busy: !!root.citySearch && root.citySearch.searching
        // Same city search as the weather panel: every result carries a timezone,
        // and the name is already localized by the configured language.
        items: (root.citySearch && root.citySearch.searchResults ? root.citySearch.searchResults : [])
          .filter(entry => entry.timezone !== "")
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

      Repeater {
        visible: !root.editing
        model: root.service ? root.service.rows : []

        delegate: Row {
          required property var modelData
          width: parent.width
          spacing: Style.space(1)

          Column {
            width: parent.width - zoneTime.width - Style.space(1)
            spacing: 0

            Text {
              width: parent.width
              text: modelData.name
              color: Color.foreground
              elide: Text.ElideRight
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }

            Text {
              text: (root.service ? root.service.zoneTime(modelData.zone, "ddd d MMM") : "")
                + "   " + (root.service ? root.service.zoneDiff(modelData.zone) : "")
              color: Color.muted
              font.family: Style.fontFamily
              font.pixelSize: Style.smallFontSize
            }
          }

          Text {
            id: zoneTime
            text: root.service ? root.service.zoneTime(modelData.zone, "HH:mm") : ""
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
        }
      }
    }

    Text {
      width: parent.width
      text: I18n.dateTime(clock.date, "dddd d MMMM yyyy")
      color: Color.muted
      horizontalAlignment: Text.AlignHCenter
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }
  }
}
