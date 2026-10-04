import QtQuick
import qs.Commons
import qs.Ui

// Spacious current conditions and forecasts; the editor keeps using the real
// service's geocoding results and the CLI's reversible config writes.
PanelFrame {
  id: root
  edge: "top"
  panelWidth: Math.min(620, window.screen ? window.screen.width - Style.space(8) : 620)
  panelHeight: Math.min(editing ? 520 : 720, window.screen ? window.screen.height - Style.barHeight - Style.space(4) : 720)
  readonly property int bodySize: Style.fontSize + 2
  readonly property var service: host ? host.services["cn.weather"] : null
  readonly property bool ready: !!service && service.hasData === true
  readonly property var hours: service ? service.hourly || [] : []
  readonly property var days: service ? service.daily || [] : []
  readonly property string glyph: service ? service.glyph : "\u{F0590}"
  readonly property bool editing: !!service && service.editorOpen
  readonly property var places: service ? service.locations || [] : []
  readonly property string placeTitle: service ? service.displayName(service.activeName || service.place || I18n.t("weather.title")) : I18n.t("weather.title")
  function runCommand(command) { Util.exec("cornice weather " + command) }
  function refresh() { if (service) service.refresh(true) }
  onOpened: {
    if (service) { service.editorOpen = false; service.refresh(false) }
  }

  Flickable {
    id: viewport
    anchors.fill: parent
    anchors.margins: Style.space(1.5)
    contentHeight: body.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Column {
      id: body
      width: viewport.width
      spacing: Style.space(1.25)

      Item {
        width: parent.width
        height: Style.space(5.5)
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - placeToggle.width - Style.space(2)
          text: root.placeTitle
          elide: Text.ElideRight
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.largeFontSize + 4
          font.bold: true
        }
        PanelButton {
          id: placeToggle
          anchors.right: parent.right
          label: I18n.t(root.editing ? "editor.done" : "weather.locations")
          filled: true
          onClicked: if (root.service) root.service.editorOpen = !root.service.editorOpen
        }
      }

      Item {
        width: parent.width
        height: Style.space(13.5)
        visible: !root.editing
        Column {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(0.5)
          Text {
            text: root.ready ? root.service.temperatureLabel : "--"
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize * 4.2
          }
          Text {
            text: root.ready ? root.service.label
              : root.service && (root.service.status === "error" || root.service.status === "unconfigured")
                ? I18n.t("weather.unavailable") : I18n.t("weather.loading")
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: root.bodySize
          }
        }
        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          text: root.glyph
          color: Color.accent
          font.family: Style.iconFamily
          font.pixelSize: Style.fontSize * 5
        }
      }

      Flow {
        width: parent.width
        spacing: Style.space(1)
        visible: !root.editing && root.places.length > 1
        Repeater {
          model: root.places
          delegate: Rectangle {
            required property var modelData
            height: Style.space(4.5)
            width: Math.min(body.width, placeLabel.implicitWidth + Style.space(3))
            radius: Style.radius
            color: modelData.active ? Color.workspaceActive : Color.surface
            Text {
              id: placeLabel
              anchors.centerIn: parent
              width: parent.width - Style.space(3)
              elide: Text.ElideRight
              text: root.service.displayName(modelData.name)
              color: modelData.active ? Color.workspaceActiveText : Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.service.select(modelData.index)
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(1.5)
        visible: root.editing
        Item {
          width: parent.width
          height: Style.space(5.5)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - clearPlace.width - Style.space(1)
            text: root.places.length > 0 ? root.service.displayName(root.places[0].name) : I18n.t("weather.noPlace")
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: root.bodySize
            elide: Text.ElideRight
          }
          PanelButton {
            id: clearPlace
            anchors.right: parent.right
            glyph: "\u{F0156}"
            onClicked: root.runCommand("place clear")
          }
        }
        PickerList {
          id: placePicker
          width: parent.width
          rowHeight: Style.space(5.5)
          textSize: root.bodySize
          maxVisible: 5
          placeholder: I18n.t("weather.searchCity")
          emptyText: I18n.t("weather.noResults")
          busy: !!root.service && root.service.searching
          items: (root.service ? root.service.searchResults || [] : []).map(entry => ({ label: entry.label, detail: entry.detail }))
          onQueryChanged: if (root.service) root.service.search(query)
          onPicked: index => {
            const entry = root.service ? root.service.searchResults[index] : null
            if (!entry) return
            root.runCommand("place use " + Util.shellQuote(entry.name) + " --lat " + entry.latitude + " --lon " + entry.longitude)
            placePicker.clear()
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(1)
        visible: root.ready && !root.editing
        Repeater {
          model: root.ready ? [
            { label: I18n.t("weather.feelsLike"), value: Math.round(root.service.apparent) + root.service.temperatureUnit },
            { label: I18n.t("weather.humidity"), value: Math.round(root.service.humidity) + "%" },
            { label: I18n.t("weather.wind"), value: Math.round(root.service.wind) + " " + root.service.windUnit }
          ] : []
          delegate: Rectangle {
            required property var modelData
            width: (body.width - Style.space(2)) / 3
            height: Style.space(8)
            color: Color.surface
            radius: Style.radius
            Column {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(1.5)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(0.6)
              Text { text: modelData.label; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
              Text { text: modelData.value; color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: root.bodySize }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(1)
        visible: root.ready && !root.editing && root.hours.length > 0
        Text { text: I18n.t("weather.nextHours"); color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.fontSize }
        Row {
          width: parent.width
          spacing: Style.space(1)
          Repeater {
            model: root.hours.slice(0, 6)
            delegate: Column {
              required property var modelData
              width: (body.width - Style.space(5)) / 6
              spacing: Style.space(0.8)
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.label; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.service.glyphFor(modelData.code, true); color: Color.foreground; font.family: Style.iconFamily; font.pixelSize: Style.fontSize * 1.5 }
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: Math.round(modelData.temperature) + "°"; color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: root.bodySize }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(0.5)
        visible: root.ready && !root.editing && root.days.length > 0
        Text { text: I18n.t("weather.nextDays"); color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.fontSize }
        Repeater {
          id: dayItems
          model: root.days
          delegate: Rectangle {
            required property var modelData
            required property int index
            width: body.width
            height: Style.space(5)
            color: index % 2 === 0 ? Color.surface : "transparent"
            radius: Style.radius
            function inspect() {
              const point = rangeLabel.mapToItem(root.window.contentItem, 0, 0)
              return { range: rangeLabel.text, x: point.x, width: rangeLabel.width, y: point.y }
            }
            Text {
              x: Style.space(1.2)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(7)
              text: modelData.isToday ? I18n.t("weather.today") : I18n.dayName(modelData.date, "ddd")
              color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: root.bodySize
            }
            Text {
              x: Style.space(9)
              anchors.verticalCenter: parent.verticalCenter
              text: root.service.glyphFor(modelData.code, true)
              color: Color.foreground; font.family: Style.iconFamily; font.pixelSize: root.bodySize
            }
            Text {
              x: Style.space(13)
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, rangeLabel.x - x - Style.space(1))
              text: root.service.labelFor(modelData.code)
              elide: Text.ElideRight
              color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.fontSize
            }
            Text {
              id: rangeLabel
              anchors.right: parent.right
              anchors.rightMargin: Style.space(1.2)
              anchors.verticalCenter: parent.verticalCenter
              text: Math.round(modelData.high) + "° / " + Math.round(modelData.low) + "°"
              color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: root.bodySize
            }
          }
        }
      }

      Text {
        width: parent.width
        visible: !!root.service && (root.service.status === "error" || root.service.status === "unconfigured")
        text: root.service ? root.service.error : ""
        color: Color.muted; wrapMode: Text.Wrap
        font.family: Style.fontFamily; font.pixelSize: Style.fontSize
      }
      Item {
        width: parent.width
        height: Style.space(5.5)
        visible: !root.editing
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - refreshButton.width - Style.space(1)
          text: root.ready ? I18n.t("weather.updated") + " " + root.service.updatedLabel : ""
          color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize
          elide: Text.ElideRight
        }
        PanelButton {
          id: refreshButton
          anchors.right: parent.right
          label: I18n.t("weather.refresh")
          glyph: "\u{F021}"
          filled: true
          onClicked: root.refresh()
        }
      }
    }
  }
  function action(item, name) {
    const point = item.mapToItem(window.contentItem, item.width / 2, item.height / 2)
    return { name: name, x: point.x, y: point.y }
  }
  ShellIpc {
    target: "weatherPanel"
    function state(): string {
      const forecasts = []
      for (let i = 0; i < dayItems.count; i++) forecasts.push(dayItems.itemAt(i).inspect())
      return JSON.stringify({ open: root.isOpen, editing: root.editing, place: root.placeTitle, width: root.panelWidth, height: root.panelHeight,
        contentHeight: body.implicitHeight, viewportHeight: viewport.height, forecasts: forecasts,
        actions: [root.action(placeToggle, "edit"), root.action(clearPlace, "clear"), root.action(refreshButton, "refresh")],
        picker: placePicker.inspect(root.window.contentItem) })
    }
  }
}
