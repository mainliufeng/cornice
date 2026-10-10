import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
Item {
  id: root
  property string icon: "󰍹"
  property string description: "桌面"
  property bool alert: false
  property var entries: []
  property var stableEntries: []
  onEntriesChanged: if (JSON.stringify(entries) !== JSON.stringify(stableEntries)) stableEntries = entries
  Component.onCompleted: stableEntries = entries
  property bool opened: false
  property int badge: 0
  property int selectionLayers: 0
  readonly property bool capturing: selectionLayers > 0
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // Slurp's selection surface temporarily owns the pointer. Preserve the
      // menu throughout selection and the following grim frame read.
      if (event.data !== "selection") return
      if (event.name === "openlayer") { root.selectionLayers++; closeDelay.stop() }
      else if (event.name === "closelayer") { root.selectionLayers = Math.max(0, root.selectionLayers - 1); if (!root.capturing) closeDelay.restart() }
    }
  }
  // Extend the popup's hit area through the gap below the icon. Its visible
  // content still starts at the bar edge, so slow pointer travel stays inside.
  readonly property real bridgeHeight: root.QsWindow.window
    ? Math.max(0, Style.barHeight - root.mapToItem(root.QsWindow.window.contentItem, 0, 0).y - root.height) : 0
  implicitWidth: Style.widgetHeight
  implicitHeight: Style.widgetHeight
  signal chosen(string key)
  function rows() {
    const out = [{name: "menu", x: root.x, y: root.y, width: root.width, height: root.height, capturing:root.capturing}]
    if (opened) for (let i = 0; i < items.count; ++i) {
      const item = items.itemAt(i)
      out.push({name: item.modelData.key, x: popup.margins.left + column.x, y: popup.margins.top + root.bridgeHeight + Style.space(1) + item.y - menuScroll.contentY,
        width: item.width, height: item.height, enabled: item.enabled, label: item.modelData.label, detail:item.modelData.detail || "",
        kind:item.modelData.kind || "action", scope:item.modelData.scope || "", target:item.modelData.target || "", checked:item.modelData.checked,
        detailHeight:item.detailHeight, alert:item.modelData.alert === true})
    }
    return out
  }
  Rectangle {
    anchors.fill: parent; radius: Style.radius
    color: mouse.containsMouse || root.opened ? Color.hover : "transparent"
    Text { anchors.centerIn: parent; text: root.icon; color: Color.foreground; font.family: Style.iconFamily; font.pixelSize: Style.fontSize + 3 }
    Text {anchors.right:parent.right;anchors.bottom:parent.bottom;visible:root.badge > 0;text:root.badge;font.pixelSize:Style.smallFontSize;color:Color.foreground}
    Rectangle {anchors.right:parent.right;anchors.top:parent.top;width:7;height:7;radius:3.5;visible:root.alert;color:Color.urgent}
    MouseArea {
      id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onEntered: { closeDelay.stop(); root.opened = true }
      onExited: if (!root.capturing) closeDelay.restart()
      onClicked: root.opened = true
    }
  }
  Timer { id: closeDelay; interval: 400; onTriggered: if (!root.capturing && !mouse.containsMouse && !popupHover.hovered) root.opened = false }
  PanelWindow {
    id: popup
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    visible: root.opened
    implicitWidth: Style.space(40); implicitHeight: Math.min(column.implicitHeight + root.bridgeHeight + Style.space(2), (screen ? screen.height : 1080) - Style.barHeight - Style.space(2))
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
    Rectangle {y:root.bridgeHeight;width:parent.width;height:parent.height-root.bridgeHeight;color:Color.panel;radius:Style.radius + Style.space(0.5);border.width:1;border.color:Color.surfaceBorder}
    // Track the whole popup independently of its periodically rebuilt rows.
    // A sibling MouseArea loses hover to the clickable row MouseAreas.
    HoverHandler {
      id: popupHover; parent: popup.contentItem; blocking: false
      onHoveredChanged: { if (hovered) closeDelay.stop(); else if (!root.capturing) closeDelay.restart() }
    }
    Flickable {
      id:menuScroll
      y:root.bridgeHeight + Style.space(1)
      width:parent.width;height:parent.height-root.bridgeHeight-Style.space(2)
      contentHeight:column.implicitHeight
      clip:true;boundsBehavior:Flickable.StopAtBounds
    Column {
      id: column; x:Style.space(1); width: parent.width - Style.space(2)
      Repeater {
        id: items; model: root.stableEntries
        delegate: Rectangle {
          required property var modelData
          required property int index
          readonly property bool section: modelData.kind === "section"
          property real detailHeight: detailText.visible ? detailText.implicitHeight : 0
          width: column.width; height: section ? (modelData.detail ? labelText.implicitHeight + detailHeight + Style.space(3) : Style.space(4.5)) : modelData.detail ? labelText.implicitHeight + detailHeight + Style.space(2) : Style.space(5)
          enabled: !section && modelData.enabled !== false
          radius:Style.radius
          color: modelData.selected ? Color.panelAlt : !section && rowMouse.containsMouse ? Color.hover : "transparent"
          Rectangle { visible: parent.section && index > 0; anchors.top:parent.top; width:parent.width; height:1; color:Color.hover }
          Text {
            anchors {left:parent.left;leftMargin:Style.space(1.5);verticalCenter:parent.verticalCenter}
            visible:!parent.section && !!modelData.icon
            text:modelData.icon || "";color:parent.enabled ? Color.foreground : Color.muted
            font.family:Style.iconFamily;font.pixelSize:Style.fontSize + 1
          }
          Text {
            anchors {right:parent.right;rightMargin:Style.space(1.5);verticalCenter:parent.verticalCenter}
            visible:modelData.selected === true
            text:"✓";color:Color.accent;font.pixelSize:Style.fontSize
          }
          Rectangle {
            anchors {right:parent.right;rightMargin:Style.space(1.5);verticalCenter:parent.verticalCenter}
            visible:modelData.checked !== undefined
            width:Style.space(3.5);height:Style.space(2);radius:height/2
            color:modelData.checked ? Color.accent : Color.surfaceBorder
            Rectangle {width:parent.height-4;height:width;radius:width/2;y:2;x:modelData.checked ? parent.width-width-2 : 2;color:modelData.checked ? Color.background : Color.foreground}
          }
          Text {
            id:labelText
            anchors { left: parent.left; right:parent.right; leftMargin: Style.space(modelData.icon && !section ? 4.5 : 1.5); rightMargin:Style.space(modelData.selected || modelData.checked !== undefined ? 5 : 1.5) }
            y: modelData.detail ? (section ? Style.space(1.5) : Style.space(1)) : (parent.height - implicitHeight) / 2
            text: modelData.label; color: modelData.alert ? Color.urgent : parent.enabled ? Color.foreground : Color.muted
            elide:Text.ElideRight
            font.family: Style.fontFamily; font.pixelSize: section ? Style.smallFontSize : Style.fontSize
          }
          Text {
            id:detailText;visible:!!modelData.detail
            anchors {left:labelText.left;right:labelText.right}
            y:labelText.y + labelText.implicitHeight
            text:modelData.detail || "";wrapMode:Text.Wrap;maximumLineCount:8;elide:Text.ElideRight
            color:modelData.alert ? Color.urgent : section ? Color.foreground : Color.muted
            font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize
          }
          MouseArea {
            id: rowMouse; anchors.fill: parent; enabled: !parent.section; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: { if (!modelData.keepOpen) root.opened = false; root.chosen(modelData.key) }
          }
        }
      }
    }
    }
  }
}
