import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
Item {
  id: root
  property string icon: "󰍹"
  property string description: "桌面"
  property bool alert: false
  property var entries: []
  property bool opened: false
  // Extend the popup's hit area through the gap below the icon. Its visible
  // content still starts at the bar edge, so slow pointer travel stays inside.
  readonly property real bridgeHeight: root.QsWindow.window
    ? Math.max(0, Style.barHeight - root.mapToItem(root.QsWindow.window.contentItem, 0, 0).y - root.height) : 0
  implicitWidth: Style.widgetHeight
  implicitHeight: Style.widgetHeight
  signal chosen(string key)
  function rows() {
    const out = [{name: "menu", x: root.x, y: root.y, width: root.width, height: root.height}]
    if (opened) for (let i = 0; i < items.count; ++i) {
      const item = items.itemAt(i)
      out.push({name: item.modelData.key, x: popup.margins.left, y: popup.margins.top + column.y + item.y,
        width: item.width, height: item.height, enabled: item.enabled, label: item.modelData.label, detail:item.modelData.detail || "",
        detailHeight:item.detailHeight, alert:item.modelData.alert === true})
    }
    return out
  }
  Rectangle {
    anchors.fill: parent; radius: Style.radius
    color: mouse.containsMouse || root.opened ? Color.hover : "transparent"
    Text { anchors.centerIn: parent; text: root.icon; color: Color.foreground; font.family: Style.iconFamily; font.pixelSize: Style.fontSize + 3 }
    Rectangle {anchors.right:parent.right;anchors.top:parent.top;width:7;height:7;radius:3.5;visible:root.alert;color:Color.urgent}
    MouseArea {
      id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onEntered: { closeDelay.stop(); root.opened = true }
      onExited: closeDelay.restart()
      onClicked: root.opened = true
    }
  }
  Timer { id: closeDelay; interval: 250; onTriggered: if (!mouse.containsMouse && !popupHover.hovered) root.opened = false }
  PanelWindow {
    id: popup
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    visible: root.opened
    implicitWidth: Style.space(38); implicitHeight: column.implicitHeight + root.bridgeHeight
    exclusionMode: ExclusionMode.Ignore; color: "transparent"; focusable: false
    anchors { top: true; left: true }
    margins.top: Style.barHeight - root.bridgeHeight
    margins.left: {
      if (!root.QsWindow.window) return 0
      const point = root.mapToItem(root.QsWindow.window.contentItem, 0, 0)
      return Math.max(0, Math.min(point.x, (screen ? screen.width : 1280) - implicitWidth))
    }
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-desktop-menu"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    Rectangle {y:root.bridgeHeight;width:parent.width;height:column.implicitHeight;color:Color.panel}
    // Track the whole popup independently of its periodically rebuilt rows.
    // A sibling MouseArea loses hover to the clickable row MouseAreas.
    HoverHandler {
      id: popupHover; parent: popup.contentItem; blocking: false
      onHoveredChanged: { if (hovered) closeDelay.stop(); else closeDelay.restart() }
    }
    Column {
      id: column; y:root.bridgeHeight; width: parent.width
      Repeater {
        id: items; model: root.entries
        delegate: Rectangle {
          required property var modelData
          property real detailHeight: detailText.visible ? detailText.implicitHeight : 0
          width: column.width; height: modelData.detail ? labelText.implicitHeight + detailHeight + Style.space(2) : Style.space(5)
          enabled: modelData.enabled !== false
          color: rowMouse.containsMouse ? Color.hover : "transparent"
          Text {
            id:labelText
            anchors { left: parent.left; right:parent.right; leftMargin: Style.space(1.5); rightMargin:Style.space(1.5) }
            y: modelData.detail ? Style.space(1) : (parent.height - implicitHeight) / 2
            text: (modelData.selected ? "✓ " : "") + modelData.label; color: modelData.alert ? Color.urgent : parent.enabled ? Color.foreground : Color.muted
            elide:Text.ElideRight
            font.family: Style.fontFamily; font.pixelSize: Style.fontSize
          }
          Text {
            id:detailText;visible:!!modelData.detail
            anchors {left:labelText.left;right:labelText.right}
            y:labelText.y + labelText.implicitHeight
            text:modelData.detail || "";wrapMode:Text.Wrap;maximumLineCount:8;elide:Text.ElideRight
            color:modelData.alert ? Color.urgent : Color.muted
            font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize
          }
          MouseArea {
            id: rowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: { root.opened = false; root.chosen(modelData.key) }
          }
        }
      }
    }
  }
}
