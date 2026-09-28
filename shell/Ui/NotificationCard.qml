import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// One notification in the popup stack or the history list.
Item {
  id: root

  property var notification: null
  property var entry: ({})

  signal dismissed()
  signal activated()

  implicitHeight: layout.implicitHeight

  readonly property string summary: entry.summary !== undefined ? entry.summary : (notification ? notification.summary : "")
  readonly property string body: entry.body !== undefined ? entry.body : (notification ? notification.body : "")
  readonly property string appName: entry.appName !== undefined ? entry.appName : (notification ? notification.appName : "")
  readonly property string appIcon: entry.appIcon !== undefined ? entry.appIcon : (notification ? notification.appIcon : "")
  readonly property var actions: notification ? notification.actions : []

  Column {
    id: layout

    width: parent.width
    spacing: Style.space(0.5)

    Row {
      width: parent.width
      spacing: Style.space(0.8)

      Image {
        width: Style.fontSize + 6
        height: width
        sourceSize.width: width
        sourceSize.height: height
        visible: root.appIcon !== ""
        source: root.appIcon === "" ? "" : Quickshell.iconPath(root.appIcon, "")
        fillMode: Image.PreserveAspectFit
      }

      Text {
        width: parent.width - (Style.fontSize + 6) - Style.space(0.8)
        text: root.appName
        color: Color.muted
        elide: Text.ElideRight
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }
    }

    Text {
      width: parent.width
      visible: root.summary !== ""
      text: root.summary
      color: Color.foreground
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
      font.bold: true
    }

    Text {
      width: parent.width
      visible: root.body !== ""
      text: root.body
      color: Color.foreground
      opacity: 0.85
      wrapMode: Text.Wrap
      maximumLineCount: 4
      elide: Text.ElideRight
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    Row {
      spacing: Style.space(0.6)
      visible: root.actions.length > 0

      Repeater {
        model: root.actions

        delegate: Rectangle {
          required property var modelData

          width: actionLabel.implicitWidth + Style.space(2)
          height: actionLabel.implicitHeight + Style.space(0.8)
          radius: Style.radius
          color: Color.hover

          Text {
            id: actionLabel
            anchors.centerIn: parent
            text: modelData.text
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              modelData.invoke()
              root.dismissed()
            }
          }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      if (mouse.button === Qt.MiddleButton) {
        root.dismissed()
        return
      }
      if (root.notification) root.notification.dismiss()
      root.activated()
      root.dismissed()
    }
  }
}
