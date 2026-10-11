import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Current workspace windows, followed by the focused title. Kept in the existing
// widget so customized bar layouts gain the switcher without rewriting config.
Item {
  id: root
  property var host: null
  property var plugin: null
  property var widgetConfig: ({})
  property real availableWidth: -1
  readonly property int maxWidth: Util.option(widgetConfig, "maxWidth", 420)
  readonly property bool showWindows: Util.option(widgetConfig, "showWindows", true)
  readonly property int maxIcons: Math.max(1, Util.option(widgetConfig, "maxIcons", 6))
  readonly property int slotWidth: Style.widgetHeight
  readonly property real budget: availableWidth >= 0 ? availableWidth : maxWidth + slotWidth * maxIcons

  readonly property var snapshot: DesktopSession.windowSnapshot
  property var windowOrder: []
  readonly property var workspace: DesktopSession.observedWorkspace
  // Numeric workspace remains in debug IPC for existing consumers only.
  readonly property int workspaceId: workspace.id !== null ? workspace.id : -1
  readonly property string workspaceKey: workspace.key
  readonly property var windows: {
    const list = snapshot.filter(window => DesktopSession.workspaceMatches(window.workspace, workspace))
    list.sort((a, b) => windowOrder.indexOf(a.address) - windowOrder.indexOf(b.address))
    return list
  }
  readonly property string focusedAddress: DesktopSession.focusedWindowAddress
  readonly property var focusedWindow: windows.find(window => DesktopSession.windowAddress(window.address) === focusedAddress) || null
  readonly property string title: focusedWindow ? (DesktopSession.focusedWindowTitle || focusedWindow.title) : ""
  // Reserve a More button before filling slots; the title uses what's left.
  readonly property real moreWidth: Math.min(slotWidth + Style.space(1), budget)
  readonly property bool needsOverflow: windows.length > maxIcons || windows.length * slotWidth > budget
  readonly property int iconCount: !showWindows ? 0 : needsOverflow
    ? Math.max(0, Math.min(maxIcons - 1, Math.floor((budget - moreWidth) / slotWidth))) : windows.length
  readonly property var shownWindows: windows.slice(0, iconCount)
  readonly property var overflowWindows: showWindows ? windows.slice(iconCount) : []
  readonly property real stripWidth: iconCount * slotWidth + (overflowWindows.length > 0 ? Math.min(slotWidth + Style.space(1), budget) : 0)
  readonly property real titleWidth: Math.max(0, Math.min(maxWidth,
    budget - stripWidth - (stripWidth > 0 ? Style.space(0.7) : 0), titleText.implicitWidth))

  implicitHeight: Style.widgetHeight
  implicitWidth: Math.min(budget, stripWidth + (titleWidth > 0 && stripWidth > 0 ? Style.space(0.7) : 0) + titleWidth)
  visible: windows.length > 0 || title !== ""

  function requestRefresh() { DesktopSession.refreshWindows() }
  onSnapshotChanged: {
    const addresses = snapshot.map(window => window.address)
    const order = windowOrder.filter(address => addresses.indexOf(address) !== -1)
    for (const address of addresses) if (order.indexOf(address) === -1) order.push(address)
    windowOrder = order
  }
  function appEntry(window) {
    const name = String(window.class || window.initialClass || "")
    if (name === "") return null
    const apps = DesktopEntries.applications.values || []
    for (const app of apps)
      if (String(app.startupClass || "").toLowerCase() === name.toLowerCase()) return app
    return DesktopEntries.heuristicLookup(name)
  }
  function appName(window) {
    const entry = appEntry(window)
    return entry ? entry.name : (window.class || window.initialClass || "Window")
  }
  function iconSource(window) {
    const entry = appEntry(window)
    const icon = entry ? String(entry.icon || "") : ""
    if (icon.startsWith("/") || icon.indexOf("://") !== -1) return icon
    return icon !== "" && Quickshell.hasThemeIcon(icon) ? Quickshell.iconPath(icon) : ""
  }
  function focusWindow(address) {
    if (DesktopSession.readOnly || !windows.some(window => window.address === address)) return
    picker.close()
    hoveredWindow = null
    // The popup must release its focus grab before focusing the chosen client.
    pendingFocus = address
    focusTimer.restart()
  }
  property string pendingFocus: ""
  Timer {
    id: focusTimer
    interval: 60
    onTriggered: {
      if (root.windows.some(window => window.address === root.pendingFocus))
        DesktopSession.focusWindow(root.pendingFocus, root.workspace)
      root.pendingFocus = ""
      root.requestRefresh()
    }
  }
  Component.onCompleted: requestRefresh()
  onWorkspaceKeyChanged: { picker.close(); hoveredWindow = null; pendingFocus = ""; focusTimer.stop(); requestRefresh() }

  property var hoveredWindow: null
  property Item hoverAnchor: null
  property Item moreAnchor: null
  function windowPoint(item) { return item.mapToItem(null, 0, 0) }

  Row {
    id: strip
    anchors.verticalCenter: parent.verticalCenter
    Repeater {
      id: windowIcons
      model: root.shownWindows
      delegate: Rectangle {
        id: button
        required property var modelData
        width: root.slotWidth
        height: Style.widgetHeight
        radius: Style.radius
        color: modelData.address === root.focusedAddress ? Color.workspaceActive
          : hit.containsMouse ? Color.hover : "transparent"
        readonly property string icon: root.iconSource(modelData)
        Image {
          id: image
          anchors.centerIn: parent
          width: Style.fontSize + 4
          height: width
          sourceSize.width: width
          sourceSize.height: height
          source: button.icon
          visible: button.icon !== "" && status !== Image.Error
        }
        Text {
          anchors.centerIn: parent
          visible: button.icon === "" || image.status === Image.Error
          text: root.appName(button.modelData).slice(0, 1).toUpperCase()
          color: button.modelData.address === root.focusedAddress ? Color.workspaceActiveText : Color.barForeground
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }
        MouseArea {
          id: hit
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: { root.hoverAnchor = button; root.hoveredWindow = button.modelData }
          onExited: if (root.hoverAnchor === button) root.hoveredWindow = null
          onClicked: root.focusWindow(button.modelData.address)
        }
      }
    }
    Rectangle {
      id: more
      width: visible ? Math.min(root.slotWidth + Style.space(1), root.budget) : 0
      height: Style.widgetHeight
      visible: root.overflowWindows.length > 0
      radius: Style.radius
      color: root.overflowWindows.some(window => window.address === root.focusedAddress)
        ? Color.workspaceActive : moreHit.containsMouse ? Color.hover : "transparent"
      Text {
        anchors.centerIn: parent
        text: "+" + root.overflowWindows.length
        color: root.overflowWindows.some(window => window.address === root.focusedAddress)
          ? Color.workspaceActiveText : Color.barForeground
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }
      MouseArea {
        id: moreHit
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.hoveredWindow = null
          root.moreAnchor = more
          if (picker.isOpen) picker.close(); else picker.open("{}")
        }
      }
    }
  }
  Text {
    id: titleText
    anchors.left: strip.right
    anchors.leftMargin: root.stripWidth > 0 ? Style.space(0.7) : 0
    anchors.verticalCenter: parent.verticalCenter
    width: root.titleWidth
    text: root.title
    elide: Text.ElideRight
    color: Color.barForeground
    font.family: Style.fontFamily
    font.pixelSize: Style.fontSize
  }

  // A non-interactive tooltip: hovering cannot focus a client or open a menu.
  PanelWindow {
    id: tooltip
    visible: root.hoveredWindow !== null && hoverDelay.ready && !picker.isOpen
    color: "transparent"
    exclusiveZone: 0
    aboveWindows: true
    focusable: false
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    anchors.left: true
    anchors.top: !root.atBottom
    anchors.bottom: root.atBottom
    margins.top: root.atBottom ? 0 : Style.space(0.5)
    margins.bottom: root.atBottom ? Style.space(0.5) : 0
    margins.left: Math.max(0, Math.min(root.hoverAnchor ? root.windowPoint(root.hoverAnchor).x : 0,
      (screen ? screen.width : 1280) - implicitWidth - Style.padding))
    implicitWidth: Math.min(420, Math.ceil(tooltipMeasure.implicitWidth) + Style.space(4))
    implicitHeight: tooltipText.implicitHeight + Style.space(3)
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-window-tooltip"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}
    Text {
      id: tooltipMeasure
      visible: false
      text: tooltipText.text
      font: tooltipText.font
    }
    Surface {
      anchors.fill: parent
      Text {
        id: tooltipText
        anchors.fill: parent
        text: root.hoveredWindow ? root.appName(root.hoveredWindow) + "\n" + root.hoveredWindow.title : ""
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
        wrapMode: Text.Wrap
      }
    }
  }
  readonly property bool atBottom: host && host.config.bar && host.config.bar.position === "bottom"
  Timer {
    id: hoverDelay
    property bool ready: false
    interval: 450
    onTriggered: ready = true
  }
  onHoveredWindowChanged: {
    hoverDelay.ready = false
    hoverDelay.stop()
    if (hoveredWindow !== null) hoverDelay.start()
  }

  PanelFrame {
    id: picker
    edge: root.atBottom ? "bottom" : "top"
    panelWidth: Math.min(420, window.screen ? window.screen.width - Style.padding * 2 : 420)
    panelHeight: Math.min(400, root.overflowWindows.length * (Style.widgetHeight + Style.space(1.2)) + Style.space(2.8))
    window.screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    window.margins.top: root.atBottom ? 0 : Style.space(0.5)
    window.margins.bottom: root.atBottom ? Style.space(0.5) : 0
    window.margins.left: Math.max(0, Math.min(root.moreAnchor ? root.windowPoint(root.moreAnchor).x : 0,
      (window.screen ? window.screen.width : 1280) - panelWidth - Style.padding))
    onDismissed: root.hoveredWindow = null
    onOpened: overflowList.positionViewAtBeginning()
    ListView {
      id: overflowList
      anchors.fill: parent
      clip: true
      model: root.overflowWindows
      delegate: Rectangle {
        id: overflowRow
        required property var modelData
        width: overflowList.width
        height: Math.max(Style.widgetHeight + Style.space(1.2), overflowText.implicitHeight + Style.space(1.4))
        radius: Style.radius
        color: modelData.address === root.focusedAddress ? Color.hover : overflowHit.containsMouse ? Color.panelAlt : "transparent"
        Image {
          id: overflowIcon
          x: Style.space(0.7)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.fontSize + 4
          height: width
          source: root.iconSource(overflowRow.modelData)
          visible: source !== "" && status !== Image.Error
        }
        Text {
          visible: overflowIcon.source === "" || overflowIcon.status === Image.Error
          x: overflowIcon.x
          width: overflowIcon.width
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          text: root.appName(overflowRow.modelData).slice(0, 1).toUpperCase()
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }
        Text {
          id: overflowText
          x: Style.space(4.5)
          width: parent.width - x - Style.space(0.7)
          anchors.verticalCenter: parent.verticalCenter
          text: root.appName(overflowRow.modelData) + "\n" + overflowRow.modelData.title
          color: Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
          wrapMode: Text.Wrap
        }
        MouseArea {
          id: overflowHit
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          hoverEnabled: true
          onClicked: root.focusWindow(overflowRow.modelData.address)
        }
      }
    }
    Rectangle {
      anchors.right: parent.right
      y: overflowList.visibleArea.yPosition * overflowList.height
      width: Style.space(0.3)
      height: Math.max(Style.space(1), overflowList.visibleArea.heightRatio * overflowList.height)
      radius: width / 2
      color: Color.muted
      visible: overflowList.contentHeight > overflowList.height
    }
  }
  onOverflowWindowsChanged: if (overflowWindows.length === 0) picker.close()

  ShellIpc {
    target: "windows"
    function state(): string {
      const origin = root.mapToItem(null, 0, 0)
      const buttons = []
      for (let i = 0; i < windowIcons.count; i++) {
        const item = windowIcons.itemAt(i)
        buttons.push({ address: item.modelData.address, x: Math.round(origin.x + item.x + item.width / 2),
          y: Math.round(Style.barHeight / 2), icon: item.icon })
      }
      const pickerRows = []
      if (picker.isOpen) {
        for (let i = 0; i < root.overflowWindows.length; i++) {
          const row = overflowList.itemAtIndex(i)
          if (!row) continue
          const point = row.mapToItem(picker.window.contentItem, row.width / 2, row.height / 2)
          pickerRows.push({ address: row.modelData.address, title: row.modelData.title,
            x: Math.round(point.x), y: Math.round(point.y) })
        }
      }
      return JSON.stringify({ workspace: root.workspaceId, workspaceIdentity: root.workspace, focused: root.focusedAddress,
        windows: root.windows.map(window => ({ address: window.address, title: window.title, app: root.appName(window) })),
        buttons: buttons, overflow: root.overflowWindows.map(window => window.address),
        moreX: Math.round(origin.x + more.x + more.width / 2), pickerOpen: picker.isOpen,
        tooltipVisible: tooltip.visible, budget: root.budget, width: root.implicitWidth,
        pickerRows: pickerRows, pickerMoving: overflowList.moving, title: root.title })
    }
  }
}
