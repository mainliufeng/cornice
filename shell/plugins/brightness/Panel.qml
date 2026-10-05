import QtQuick
import qs.Commons
import qs.Ui

PanelFrame {
  id: root
  edge: host && host.config.bar && host.config.bar.position === "bottom" ? "bottom" : "top"
  panelWidth: Math.min(420, window.screen ? window.screen.width - Style.space(4) : 420)
  panelHeight: 210
  readonly property var service: host ? host.services["cn.brightness"] : null
  onOpened: if (service) service.refresh()
  Column {
    anchors.fill: parent
    anchors.margins: Style.space(1.5)
    spacing: Style.space(1)
    PanelHeader {
      width: parent.width
      title: I18n.t("bar.widget.brightness")
      subtitle: root.service && root.service.known ? root.service.percent + "%" : I18n.t("osd.noBacklight")
      glyph: "\uf0eb"
    }
    Slider {
      id: slider
      width: parent.width
      enabled: !!root.service && root.service.known
      value: enabled ? root.service.percent / 100 : 0
      onMoved: value => root.service.setPercent(value * 100)
    }
    Text {
      width: parent.width
      text: root.service ? root.service.error : ""
      visible: text !== ""
      color: Color.accent
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
      wrapMode: Text.WordWrap
    }
  }
  ShellIpc {
    target: "brightnessPanel"
    function state(): string {
      const p = slider.mapToItem(root, 0, 0)
      return JSON.stringify({open: root.isOpen, edge: root.edge, percent: root.service ? root.service.percent : -1,
        slider: {x: p.x, y: p.y, width: slider.width, height: slider.height}})
    }
  }
}
