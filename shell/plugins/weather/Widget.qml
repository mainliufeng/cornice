import QtQuick
import Quickshell
import qs.Commons

// Weather in the bar: glyph + temperature, click for the panel, middle click to
// refresh, scroll to cycle through the next days in the tooltip-less way this
// bar does everything else (nothing hidden, nothing surprising).
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property var settings: widgetConfig || ({})
  readonly property string textFormat: Util.option(settings, "format", "{icon} {temp}")
  readonly property bool showPlace: Util.option(settings, "showPlace", false)
  readonly property var service: host ? host.services["cn.weather"] : null

  // `service` is undefined until the service plugin registers (panels/widgets can
  // be built first), so never assume null vs undefined.
  readonly property bool ready: !!service && service.hasData === true
  readonly property string glyph: ready ? service.glyph : "\u{F0590}"
  readonly property string temperature: ready ? service.temperatureLabel : "--"
  readonly property string place: ready ? (service.place || "") : ""
  readonly property string label: ready ? service.label : (service && service.status === "error" ? "unavailable" : "loading")

  readonly property string text: textFormat
    .replace("{icon}", glyph)
    .replace("{temp}", temperature)
    .replace("{place}", place)
    .replace("{label}", label)

  implicitHeight: Style.widgetHeight
  implicitWidth: content.implicitWidth + Style.space(1.2)

  onServiceChanged: if (service && typeof service.refresh === "function") service.refresh(false)
  Component.onCompleted: if (service && typeof service.refresh === "function") service.refresh(false)

  Row {
    id: content

    anchors.centerIn: parent
    spacing: Style.space(0.5)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.glyph
      color: root.ready ? Color.barForeground : Color.muted
      font.family: Style.iconFamily
      font.pixelSize: Style.fontSize
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.temperature
      color: root.ready ? Color.barForeground : Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showPlace && root.place !== ""
      text: root.place
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (!root.host) return
      if (mouse.button === Qt.MiddleButton) {
        if (root.service) root.service.refresh(true)
        return
      }
      root.host.toggle("cn.weather", {})
    }
  }
}
