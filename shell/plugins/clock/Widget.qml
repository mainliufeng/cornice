import QtQuick
import Quickshell
import qs.Commons

// SystemClock is a creatable type (not a global singleton): one instance per
// widget, ticking at the precision the format needs.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  readonly property string format: Util.option(widgetConfig, "format", "ddd HH:mm")
  readonly property string formatAlt: Util.option(widgetConfig, "formatAlt", "HH:mm:ss")
  // Optional world clock: "timezone": "Asia/Tokyo" turns this widget into that
  // zone's clock (add another clock widget in the bar editor for a second one).
  readonly property string timezone: Util.option(widgetConfig, "timezone", "")
  readonly property string zoneLabel: Util.option(widgetConfig, "label", "")
  // world: show every clock configured in clock.worldClocks instead of one zone.
  // A name is only shown when there is more than one, so a single entry stays as
  // quiet as the local clock.
  readonly property bool world: Util.option(widgetConfig, "world", false)
  // The list format is separate from `format`: the local clock may show the
  // weekday, but repeating it on every entry is just noise.
  readonly property string worldFormat: Util.option(widgetConfig, "worldFormat", "HH:mm")
  // host.services is the reactive registry (see the weather widget); the
  // service may register after this widget is built, so it is read reactively.
  readonly property var service: (host && host.services) ? host.services["cn.clock"] : null

  property bool showAlt: false

  // Fills in the zone time, falling back to the local clock until the service
  // has resolved the offset (revision keeps the binding reactive).
  function worldText(date, fmt) {
    if (!service) return ""
    service.revision // re-render when offsets are (re)resolved
    const rows = service.rows
    const parts = []
    for (let i = 0; i < rows.length; i++) {
      const text = service.zoneTimeAt(rows[i].zone, fmt, date.getTime())
      if (text === "") continue
      parts.push(rows.length > 1 && rows[i].name !== "" ? rows[i].name + " " + text : text)
    }
    return parts.join("  ")
  }

  function render(date, fmt) {
    // With a configured world clock the widget renders that zone, named.
    const configured = service && service.rows.length > 0 ? service.rows[0].zone : ""
    const timezone = configured !== "" ? configured : root.timezone
    if (timezone === "" || !service) return I18n.dateTime(date, fmt)
    service.revision // dependency: re-render when offsets are re-resolved
    const text = service.zoneTimeAt(timezone, fmt, date.getTime())
    return (text === "" ? I18n.dateTime(date, fmt) : text)
  }

  // Registration happens outside of bindings (writing to the service from a
  // binding would be a side effect during evaluation).
  function registerZone() {
    if (timezone !== "" && service) service.watchZone(timezone)
  }

  Connections {
    target: root
    function onServiceChanged() { root.registerZone() }
  }

  Component.onCompleted: registerZone()

  implicitHeight: Style.widgetHeight
  implicitWidth: label.implicitWidth + Style.space(1)

  SystemClock {
    id: clock
    enabled: true
    precision: root.showAlt ? SystemClock.Seconds : SystemClock.Minutes
  }

  Text {
    id: label
    anchors.horizontalCenter: parent.horizontalCenter
    y: Style.barTextBaseline - baselineOffset
    // Locale-aware: "ddd" must render as the configured language's weekday,
    // which Qt.formatDateTime does not do (it uses the process default locale).
    text: {
      const fmt = root.showAlt ? root.formatAlt : root.format
      if (root.world) return root.worldText(clock.date, root.worldFormat)
      const zone = root.service && root.service.rows.length > 0 ? root.service.rows[0] : null
      if (zone) return zone.name + " " + root.render(clock.date, fmt)
      return (root.zoneLabel !== "" ? root.zoneLabel + " " : "") + root.render(clock.date, fmt)
    }
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (mouse.button === Qt.MiddleButton) root.showAlt = !root.showAlt
      else if (root.host) root.host.toggle("cn.clock", {})
    }
  }
}
