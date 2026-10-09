import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Ui

// StatusNotifier tray. Icons come from the icon theme; a click activates the
// item, a right click opens its DBusMenu.
Item {
  id: root

  property var host: null
  property var plugin: null
  property var widgetConfig: ({})

  // 0 = match the bar's type size, which is what most themes want.
  readonly property int configuredIconSize: Util.option(widgetConfig, "iconSize", 0)
  readonly property int iconSize: configuredIconSize > 0 ? configuredIconSize : Style.fontSize + 4

  // Quickshell hands out a ready-to-use image URL here ("image://icon/<name>"),
  // not a bare icon-theme name. Running it through iconPath() a second time
  // produced "image://icon/image://icon/..." — an unresolvable source, which Qt
  // renders as a magenta placeholder box.
  // Some items advertise icon names the current icon theme cannot resolve
  // (fcitx sends "input-keyboard-symbolic", which breeze does not carry). A
  // failed Image draws Qt's magenta placeholder, so track failures and fall
  // back to a glyph of our own.
  function fallbackGlyph(item) {
    const hint = (String(item.id) + " " + String(item.tooltipTitle)).toLowerCase()
    if (hint.indexOf("fcitx") !== -1 || hint.indexOf("input") !== -1 || hint.indexOf("keyboard") !== -1) return "\uf11c"
    return "\uf10c"
  }

  function iconSource(item) {
    const icon = String(item.icon || "")
    if (icon === "") return ""

    // A path or a ready-made provider URL that is not a theme lookup: use it.
    if (icon.startsWith("/")) return icon
    if (icon.indexOf("://") !== -1 && !icon.startsWith("image://icon/")) return icon

    // Theme lookup. Quickshell renders a magenta placeholder when a name does
    // not resolve, and Image reports that as a successful load — so decide here
    // with hasThemeIcon() instead of discovering it afterwards. Try the plain
    // name as well as the -symbolic variant: fcitx asks for
    // "input-keyboard-symbolic", which breeze does not carry.
    const inner = icon.startsWith("image://icon/")
      ? icon.slice("image://icon/".length)
      : icon

    // The icon provider also hands out *file paths* wrapped as
    // image://icon/<abs path>?path=<dir>. Apps using the tray-icon crate (Clash
    // Verge) do exactly that; treating the path as a theme icon name made the
    // lookup fail and drew a generic circle instead of the app's icon.
    const asPath = inner.split("?")[0]
    if (asPath.startsWith("/")) return "file://" + asPath

    const name = inner
    const candidates = [name]
    if (name.endsWith("-symbolic")) candidates.push(name.slice(0, -"-symbolic".length))
    else candidates.push(name + "-symbolic")

    for (const candidate of candidates)
      if (Quickshell.hasThemeIcon(candidate)) return "image://icon/" + candidate
    return ""
  }
  readonly property var items: SystemTray.items ? SystemTray.items.values : []

  // Which item's menu is open, and where to anchor it.
  property var openItem: null
  property Item openAnchor: null

  implicitHeight: Style.widgetHeight
  implicitWidth: row.implicitWidth
  visible: items.length > 0

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(0.4)

    Repeater {
      id: trayRepeater
      model: root.items

      delegate: Item {
        id: entry

        required property var modelData

        property bool iconFailed: false

        implicitWidth: root.iconSize + Style.space(0.6)
        implicitHeight: root.iconSize + Style.space(0.6)

        readonly property string iconUrl: root.iconSource(modelData)

        Image {
          id: iconImage

          anchors.centerIn: parent
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: width
          sourceSize.height: height
          source: entry.iconUrl
          visible: entry.iconUrl !== "" && !entry.iconFailed
          fillMode: Image.PreserveAspectFit
        }

        Text {
          anchors.centerIn: parent
          visible: entry.iconUrl === "" || entry.iconFailed
          text: root.fallbackGlyph(entry.modelData)
          color: Color.barForeground
          font.family: Style.iconFamily
          font.pixelSize: Style.fontSize
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
          enabled: !DesktopSession.readOnly

          onClicked: mouse => {
            const item = entry.modelData
            // A left click on a tray item means "show me its menu" for most
            // items (nm-applet, fcitx, bluetooth); items without one activate.
            if (mouse.button === Qt.MiddleButton) { if (!DesktopSession.readOnly) item.secondaryActivate() }
            else if (item.hasMenu) root.showMenu(item, entry)
            else if (!DesktopSession.readOnly) item.activate()
          }

          onWheel: wheel => { if (!DesktopSession.readOnly) entry.modelData.scroll(wheel.angleDelta.y > 0 ? 1 : 0, false) }
        }

        Connections {
          target: iconImage
          function onStatusChanged() {
            if (iconImage.status === Image.Error) entry.iconFailed = true
            else if (iconImage.status === Image.Ready) entry.iconFailed = false
          }
        }


      }
    }
  }

  Connections {
    target: DesktopSession
    function onReadOnlyChanged() { if (DesktopSession.readOnly) root.closeMenu() }
  }

  // Second click on the same item toggles its menu closed.
  function showMenu(item, anchorItem) {
    if (DesktopSession.readOnly) return
    if (openItem === item) {
      closeMenu()
      return
    }
    openItem = item
    openAnchor = anchorItem
    // The menu needs to know which item it belongs to: entries that Quickshell
    // cannot activate are clicked through cornice-tray-activate, which looks the
    // item up by its status-notifier id.
    menu.ownerId = String(item.id || "")
    menu.ownerTitle = String(item.title || "")
    menu.handle = item.menu
  }

  MenuPopup {
    id: menu
    anchorWindow: root.openAnchor ? root.openAnchor.QsWindow.window : null
    anchorX: root.openAnchor ? root.openAnchor.mapToItem(null, 0, 0).x : 0
    onEntryChosen: root.closeMenu()
    onOpenedChanged: {
      if (!opened) root.openItem = null
    }
  }

  function closeMenu() {
    menu.handle = null
    openItem = null
    openAnchor = null
  }


  // Read-only support hook: what the watcher actually handed us.
  ShellIpc {
    target: "tray"

    // Diagnostics: try each activation path for an item and report what it did.
    function invoke(id: string, method: string): string {
      for (const item of root.items) {
        if (String(item.id) !== id) continue
        if (method === "activate") item.activate()
        else if (method === "secondary") item.secondaryActivate()
        else if (method === "display") item.display()
        else if (method === "menu") root.showMenu(item, trayRepeater.itemAt(root.items.indexOf(item)))
        else return "unknown-method"
        return "ok"
      }
      return "unknown-item"
    }

    function menuCount(): string {
      const openerCounts = []
      for (let i = 0; i < root.items.length; i++) {
        const item = root.items[i]
        const handle = item.menu
        openerCounts.push(String(item.id) + "=" + (handle === null || handle === undefined ? "null" : "handle"))
      }
      return JSON.stringify(openerCounts)
    }

    function menuState(): string {
      return JSON.stringify(menu.inspect())
    }

    function dump(): string {
      const out = []
      for (let i = 0; i < root.items.length; i++) {
        const item = root.items[i]
        const delegate = trayRepeater.itemAt(i)
        const point = delegate ? delegate.mapToItem(null, 0, 0) : null
        out.push({
          x: point ? Math.round(point.x) : -1,
          width: delegate ? Math.round(delegate.width) : -1,
          id: String(item.id),
          icon: String(item.icon),
          resolved: String(root.iconSource(item)),
          title: String(item.tooltipTitle),
          status: String(item.status),
          hasMenu: item.hasMenu === true,
          handleNull: item.menu === null || item.menu === undefined,
          category: String(item.category)
        })
      }
      return JSON.stringify(out)
    }
  }
}
