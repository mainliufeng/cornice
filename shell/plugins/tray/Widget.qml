import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import qs.Commons

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
    const name = icon.startsWith("image://icon/")
      ? icon.slice("image://icon/".length)
      : icon
    const candidates = [name]
    if (name.endsWith("-symbolic")) candidates.push(name.slice(0, -"-symbolic".length))
    else candidates.push(name + "-symbolic")

    for (const candidate of candidates)
      if (Quickshell.hasThemeIcon(candidate)) return "image://icon/" + candidate
    return ""
  }
  readonly property var items: SystemTray.items ? SystemTray.items.values : []

  implicitHeight: Style.widgetHeight
  implicitWidth: row.implicitWidth
  visible: items.length > 0

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(0.4)

    Repeater {
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

          onClicked: mouse => {
            if (mouse.button === Qt.LeftButton) entry.modelData.activate()
            else if (mouse.button === Qt.MiddleButton) entry.modelData.secondaryActivate()
            else if (mouse.button === Qt.RightButton) menuAnchor.open()
          }

          onWheel: wheel => entry.modelData.scroll(wheel.angleDelta.y > 0 ? 1 : 0, false)
        }

        Connections {
          target: iconImage
          function onStatusChanged() {
            if (iconImage.status === Image.Error) entry.iconFailed = true
            else if (iconImage.status === Image.Ready) entry.iconFailed = false
          }
        }

        // The item's own D-Bus menu, anchored under the icon.
        QsMenuAnchor {
          id: menuAnchor
          anchor.item: entry
          anchor.edges: Edges.Bottom
          menu: entry.modelData.hasMenu ? entry.modelData.menu : null
        }
      }
    }
  }

  // Read-only support hook: what the watcher actually handed us.
  ShellIpc {
    target: "tray"

    function dump(): string {
      const out = []
      for (const item of root.items) {
        out.push({
          id: String(item.id),
          icon: String(item.icon),
          resolved: String(root.iconSource(item)),
          title: String(item.tooltipTitle),
          status: String(item.status),
          hasMenu: item.hasMenu === true,
          category: String(item.category)
        })
      }
      return JSON.stringify(out)
    }
  }
}
