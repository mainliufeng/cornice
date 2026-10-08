import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
Item {
  id: root
  property string icon: "󰍹"
  property string description: "桌面"
  property var entries: []
  property bool opened: false
  implicitWidth: Style.widgetHeight
  implicitHeight: Style.widgetHeight
  signal chosen(string key)
  function rows() {
    const out = [{name: "menu", x: root.x, y: root.y, width: root.width, height: root.height}]
    if (opened) for (let i = 0; i < items.count; ++i) {
      const item = items.itemAt(i)
      out.push({name: item.modelData.key, x: popup.margins.left, y: popup.margins.top + item.y,
        width: item.width, height: item.height, enabled: item.enabled, label: item.modelData.label})
    }
    return out
  }
  Rectangle {
    anchors.fill: parent; radius: Style.radius
    color: mouse.containsMouse || root.opened ? Color.hover : "transparent"
    Text { anchors.centerIn: parent; text: root.icon; color: Color.foreground; font.family: Style.iconFamily; font.pixelSize: Style.fontSize + 3 }
    MouseArea {
      id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onEntered: { closeDelay.stop(); root.opened = true }
      onExited: closeDelay.restart()
      onClicked: root.opened = true
    }
  }
  Timer { id: closeDelay; interval: 250; onTriggered: if (!mouse.containsMouse && !popupHover.containsMouse) root.opened = false }
  PanelWindow {
    id: popup
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    visible: root.opened
    implicitWidth: Style.space(29); implicitHeight: column.implicitHeight
    exclusionMode: ExclusionMode.Ignore; color: Color.panel; focusable: false
    anchors { top: true; left: true }
    margins.top: Style.barHeight
    margins.left: {
      if (!root.QsWindow.window) return 0
      const point = root.mapToItem(root.QsWindow.window.contentItem, 0, 0)
      return Math.max(0, Math.min(point.x, (screen ? screen.width : 1280) - implicitWidth))
    }
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-desktop-menu"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    MouseArea {
      id: popupHover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton
      onEntered: closeDelay.stop()
      onExited: closeDelay.restart()
    }
    Column {
      id: column; width: parent.width
      Repeater {
        id: items; model: root.entries
        delegate: Rectangle {
          required property var modelData
          width: column.width; height: Style.space(5)
          enabled: modelData.enabled !== false
          color: rowMouse.containsMouse ? Color.hover : "transparent"
          Text {
            anchors { left: parent.left; leftMargin: Style.space(1.5); verticalCenter: parent.verticalCenter }
            text: (modelData.selected ? "✓ " : "") + modelData.label; color: parent.enabled ? Color.foreground : Color.muted
            font.family: Style.fontFamily; font.pixelSize: Style.fontSize
          }
          MouseArea {
            id: rowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onEntered: closeDelay.stop()
            onExited: closeDelay.restart()
            onClicked: { root.opened = false; root.chosen(modelData.key) }
          }
        }
      }
    }
  }
}
