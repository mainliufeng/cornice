import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Calendar panel behind the clock.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 300
  panelHeight: 320
  takesKeyboard: false

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
