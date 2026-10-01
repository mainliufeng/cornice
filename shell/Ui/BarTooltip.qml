import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Passive status outside the bar: no layout changes, focus or input region.
Item {
  id: root
  property var host: null
  property Item anchorItem: parent
  property bool hovered: false
  property string title: ""
  property string detail: ""
  property point anchorPoint: Qt.point(0, 0)
  readonly property var barWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property bool atBottom: host && host.config.bar && host.config.bar.position === "bottom"
  readonly property bool blocked: {
    if (!host) return false
    const lock = host.services["cn.lock"]
    if (lock && lock.locked) return true
    const instances = host.instanceMap || ({})
    for (const id of Object.keys(instances)) {
      const item = instances[id].item
      if (item && item.isOpen === true) return true
    }
    return false
  }
  readonly property bool eligible: hovered && !blocked && !!barWindow && title !== ""
  onEligibleChanged: {
    delay.stop()
    delay.ready = false
    if (eligible) delay.start()
  }
  Timer {
    id: delay
    interval: 450
    property bool ready: false
    onTriggered: {
      root.anchorPoint = root.anchorItem.mapToItem(null, root.anchorItem.width / 2, 0)
      ready = true
    }
  }
  PanelWindow {
    id: window
    visible: root.eligible && delay.ready
    screen: root.barWindow ? root.barWindow.screen : null
    color: "transparent"
    focusable: false
    exclusiveZone: 0
    aboveWindows: true
    anchors.left: true
    anchors.top: !root.atBottom
    anchors.bottom: root.atBottom
    margins.top: root.atBottom ? 0 : Style.barHeight + Style.space(0.75)
    margins.bottom: root.atBottom ? Style.barHeight + Style.space(0.75) : 0
    margins.left: Math.max(Style.padding, Math.min(root.anchorPoint.x - implicitWidth / 2,
      (screen ? screen.width : 1280) - implicitWidth - Style.padding))
    implicitWidth: Math.min(320, screen ? screen.width - Style.padding * 2 : 320,
      Math.max(Style.space(15), Math.ceil(Math.max(titleMeasure.implicitWidth, detailMeasure.implicitWidth)) + Style.space(3)))
    implicitHeight: Math.ceil(content.implicitHeight) + Style.space(3)
    mask: Region {}
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-status-tooltip"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    Text { id: titleMeasure; visible: false; text: root.title; font: titleLabel.font }
    Text { id: detailMeasure; visible: false; text: root.detail; font: detailLabel.font }
    Surface {
      anchors.fill: parent
      Column {
        id: content
        width: parent.width
        spacing: Style.space(0.5)
        Text {
          id: titleLabel
          width: parent.width
          text: root.title
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          id: detailLabel
          width: parent.width
          visible: root.detail !== ""
          text: root.detail
          color: Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
          elide: Text.ElideRight
        }
      }
    }
  }
}
