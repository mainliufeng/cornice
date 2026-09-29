import QtQuick
import qs.Commons
import qs.Ui

// Weather panel: now, the next hours, the next days.
PanelFrame {
  id: root

  edge: "top"
  panelWidth: 400
  panelHeight: 520
  takesKeyboard: false

  readonly property var service: host ? host.services["cn.weather"] : null
  readonly property bool ready: !!service && service.hasData === true
  readonly property var hours: service ? (service.hourly || []) : []
  readonly property var days: service ? (service.daily || []) : []
  readonly property string glyph: service ? service.glyph : "\u{F0590}"

  // Inline editing of the places. Every change runs the CLI, which is the only
  // writer of config.json and reloads the shell — so what you see here is what
  // the service (and a script) sees.
  readonly property bool editing: !!service && service.editorOpen
  property string editError: ""

  function runCommand(command) {
    editError = ""
    Util.exec("cornice weather " + command)
  }

  onOpened: if (service && typeof service.refresh === "function") service.refresh(false)

  function refresh() {
    if (service && typeof service.refresh === "function") service.refresh(true)
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(1)

    // ---- now ---------------------------------------------------------------
    Row {
      width: parent.width
      spacing: Style.space(1.4)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyph
        color: Color.accent
        font.family: Style.iconFamily
        font.pixelSize: Style.fontSize * 3
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.fontSize * 3 - Style.space(1.4)
        spacing: Style.space(0.2)

        Text {
          text: root.ready ? root.service.temperatureLabel : "--"
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize * 2
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.ready ? root.service.label : (root.service ? root.service.status : "loading")
          color: Color.foreground
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }

        Text {
          width: parent.width
          visible: root.ready && root.service.place !== ""
          text: root.service ? root.service.place : ""
          color: Color.muted
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }
      }
    }

    // ---- places ------------------------------------------------------------
    // An Item (not a Row): the chips sit left and the edit toggle sits right, and
    // a Row would both reject those anchors and position its children itself.
    Item {
      id: placeHeader
      width: parent.width
      height: Style.space(2.4)
      visible: root.ready

      readonly property var places: root.service && root.service.locations ? root.service.locations : []

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.editing && placeHeader.places.length > 1
        spacing: Style.space(0.6)

        Repeater {
          model: placeHeader.places

          delegate: Rectangle {
            required property var modelData
            height: Style.space(2.4)
            width: chipText.implicitWidth + Style.space(1.6)
            radius: Style.space(0.4)
            color: modelData.active ? Color.accent : Color.panelAlt

            Text {
              id: chipText
              anchors.centerIn: parent
              text: modelData.name
              color: modelData.active ? Color.background : Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.smallFontSize
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.service.select(modelData.index)
            }
          }
        }
      }

      // Edit toggle: pencil to start editing the places, check to stop.
      Item {
        id: placeToggle
        anchors.right: parent.right
        width: Style.space(2.4)
        height: Style.space(2.4)

        Text {
          anchors.centerIn: parent
          text: root.editing ? "\u{F012C}" : "\u{F03EB}" // check / pencil
          color: toggleArea.containsMouse ? Color.accent : Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }

        MouseArea {
          id: toggleArea
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

    EditList {
      width: parent.width
      visible: root.editing
      rows: (root.service && root.service.locations ? root.service.locations : []).map(entry => [entry.name, entry.city])
      fields: [I18n.t("editor.name"), I18n.t("weather.placeCity")]
      error: root.editError
      onAddRequested: values => root.runCommand(
        values[1] === "" ? "place add " + Util.shellQuote(values[0])
                         : "place add " + Util.shellQuote(values[0]) + " --city " + Util.shellQuote(values[1]))
      onUpdateRequested: (index, values) => root.runCommand(
        "place set " + index + " --name " + Util.shellQuote(values[0]) + " --city " + Util.shellQuote(values[1]))
      onRemoveRequested: index => root.runCommand("place remove " + index)
    }

    // ---- details -----------------------------------------------------------
    Row {
      width: parent.width
      visible: root.ready
      spacing: Style.space(1.6)

      Repeater {
        model: root.ready ? [
          { label: I18n.t("weather.feelsLike"), value: Math.round(root.service.apparent) + root.service.temperatureUnit },
          { label: I18n.t("weather.humidity"), value: Math.round(root.service.humidity) + "%" },
          { label: I18n.t("weather.wind"), value: Math.round(root.service.wind) + " " + root.service.windUnit },
          { label: I18n.t("weather.updated"), value: root.service.updatedLabel }
        ] : []

        delegate: Column {
          required property var modelData

          spacing: Style.space(0.2)

          Text {
            text: modelData.label
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          Text {
            text: modelData.value
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
        }
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      visible: root.ready
      color: Color.surfaceBorder
    }

    // ---- next hours --------------------------------------------------------
    Text {
      width: parent.width
      visible: root.ready && root.hours.length > 0
      text: I18n.t("weather.nextHours")
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Row {
      width: parent.width
      spacing: Style.space(0.4)
      visible: root.ready && root.hours.length > 0

      Repeater {
        model: root.hours.slice(0, 6)

        delegate: Column {
          required property var modelData

          width: (parent.width - Style.space(0.4) * 5) / 6
          spacing: Style.space(0.2)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: modelData.label
            color: Color.muted
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.service ? root.service.glyphFor(modelData.code, true) : ""
            color: Color.foreground
            font.family: Style.iconFamily
            font.pixelSize: Style.fontSize
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Math.round(modelData.temperature) + "°"
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }
        }
      }
    }

    // ---- next days ---------------------------------------------------------
    Text {
      width: parent.width
      visible: root.ready && root.days.length > 0
      text: I18n.t("weather.nextDays")
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Column {
      width: parent.width
      spacing: Style.space(0.4)
      visible: root.ready && root.days.length > 0

      Repeater {
        model: root.days

        delegate: Row {
          required property var modelData

          width: parent.width
          spacing: Style.space(0.8)

          Text {
            width: Style.space(8)
            text: modelData.isToday ? I18n.t("weather.today") : I18n.dayName(modelData.date, "ddd")
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }

          Text {
            width: Style.space(3)
            text: root.service ? root.service.glyphFor(modelData.code, true) : ""
            color: Color.foreground
            font.family: Style.iconFamily
            font.pixelSize: Style.fontSize
          }

          Text {
            width: parent.width - Style.space(8) - Style.space(3) - Style.space(0.8) * 2
            text: (root.service ? root.service.labelFor(modelData.code) : "")
            color: Color.muted
            elide: Text.ElideRight
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          Text {
            text: Math.round(modelData.high) + "° / " + Math.round(modelData.low) + "°"
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
        }
      }
    }

    // ---- states ------------------------------------------------------------
    Text {
      width: parent.width
      visible: !root.ready
      text: {
        if (!root.service) return "Weather service is not loaded"
        if (root.service.status === "error" || root.service.status === "unconfigured")
          return root.service.error !== "" ? root.service.error : "Weather is unavailable"
        return I18n.t("weather.loading")
      }
      color: Color.muted
      wrapMode: Text.Wrap
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }

    Item { width: 1; height: Style.space(0.5) }

    Rectangle {
      width: refreshLabel.implicitWidth + Style.space(2)
      height: Style.widgetHeight
      radius: Style.radius
      color: refreshHover.containsMouse ? Color.accent : Color.hover

      Text {
        id: refreshLabel
        anchors.centerIn: parent
        text: I18n.t("weather.refresh")
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }

      MouseArea {
        id: refreshHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.refresh()
      }
    }
  }
}
