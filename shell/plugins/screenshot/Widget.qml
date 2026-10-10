import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root
  property var host: null
  property var plugin: null
  property var widgetConfig: ({})
  readonly property var captureService: host ? host.service("cn.screenshot") : null
  readonly property bool available: !!captureService && !captureService.active && !captureService.locked
  implicitWidth: Style.widgetHeight
  implicitHeight: Style.widgetHeight

  Rectangle {
    anchors.fill: parent
    anchors.margins: Math.round(Style.gap * 0.25)
    radius: Style.radius
    color: hit.containsMouse && root.available ? Color.hover : "transparent"
  }
  Text {
    anchors.centerIn: parent
    text: "\uf030"
    color: root.available ? Color.barForeground : Color.muted
    font.family: Style.iconFamily
    font.pixelSize: Style.fontSize
  }
  MouseArea {
    id: hit
    anchors.fill: parent
    enabled: root.available
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true
    onClicked: root.captureService.capture("region", "")
  }
  BarTooltip {
    host: root.host
    anchorItem: root
    hovered: hit.containsMouse && root.available
    title: I18n.t("bar.widget.screenshot")
    detail: I18n.t("screenshot.selectRegion")
  }
}
