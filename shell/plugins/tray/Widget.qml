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

  readonly property int iconSize: Util.option(widgetConfig, "iconSize", 16)
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

        implicitWidth: root.iconSize + Style.space(0.6)
        implicitHeight: root.iconSize + Style.space(0.6)

        Image {
          anchors.centerIn: parent
          width: root.iconSize
          height: root.iconSize
          sourceSize.width: width
          sourceSize.height: height
          source: entry.modelData.icon === "" ? "" : Quickshell.iconPath(entry.modelData.icon, "")
          visible: entry.modelData.icon !== ""
          fillMode: Image.PreserveAspectFit
        }

        Text {
          anchors.centerIn: parent
          visible: entry.modelData.icon === ""
          text: "\uf10c"
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
}
