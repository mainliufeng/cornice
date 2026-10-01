import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// One notification in the popup stack or the history list.
//
// Inline reply (org.freedesktop.Notifications' `inline-reply` action) is only
// offered where the surface can take the keyboard: the centre panel. Popups stay
// `focusable: false` so a notification can never steal typing.
Item {
  id: root

  property var notification: null
  property var entry: ({})
  property bool allowReply: false

  signal dismissed()
  signal activated()

  property bool replying: false

  implicitHeight: layout.implicitHeight

  readonly property string summary: entry.summary !== undefined ? entry.summary : (notification ? notification.summary : "")
  readonly property string body: entry.body !== undefined ? entry.body : (notification ? notification.body : "")
  readonly property string appName: entry.appName !== undefined ? entry.appName : (notification ? notification.appName : "")
  readonly property string appIcon: entry.appIcon !== undefined ? entry.appIcon : (notification ? notification.appIcon : "")
  readonly property var actions: notification ? notification.actions : []
  readonly property bool canReply: allowReply && notification !== null && notification.hasInlineReply === true
  readonly property string replyPlaceholder: {
    if (!notification) return "Reply…"
    const given = String(notification.inlineReplyPlaceholder || "")
    return given === "" ? "Reply…" : given
  }

  function sendReply(value) {
    const message = String(value || "").trim()
    replying = false
    if (message === "" || !notification) return
    try {
      notification.sendInlineReply(message)
    } catch (error) {
      console.warn("cornice: inline reply failed: " + error)
      return
    }
    // A notification you have answered is normally done with.
    root.dismissed()
  }

  // Declared *before* the content: a MouseArea declared later would sit on top
  // and swallow the clicks meant for action chips and the reply field.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    enabled: !root.replying
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

  Column {
    id: layout

    width: parent.width
    spacing: Style.space(0.75)

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
      font.pixelSize: Style.fontSize + 2
      font.bold: true
    }

    Text {
      width: parent.width
      visible: root.body !== "" && !root.replying
      text: root.body
      color: Color.foreground
      opacity: 0.85
      wrapMode: Text.Wrap
      maximumLineCount: 4
      elide: Text.ElideRight
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize
    }

    Flow {
      width: parent.width
      spacing: Style.space(1)
      visible: root.actions.length > 0 && !root.replying

      Repeater {
        model: root.actions

        delegate: Rectangle {
          required property var modelData

          width: Math.min(parent.width, actionLabel.implicitWidth + Style.space(2))
          height: Style.space(5.5)
          radius: Style.radius
          color: actionColor.containsMouse ? Color.accent : Color.hover

          Text {
            id: actionLabel
            anchors.centerIn: parent
            width: parent.width - Style.space(2)
            text: modelData.text
            elide: Text.ElideRight
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.smallFontSize
          }

          MouseArea {
            id: actionColor
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              modelData.invoke()
              root.dismissed()
            }
          }
        }
      }
    }

    // ---- inline reply ------------------------------------------------------
    Rectangle {
      visible: root.canReply && !root.replying
      width: replyLabel.implicitWidth + Style.space(2)
      height: Style.space(5.5)
      radius: Style.radius
      color: replyHover.containsMouse ? Color.accent : Color.hover

      Text {
        id: replyLabel
        anchors.centerIn: parent
        text: I18n.t("notifications.reply")
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: Style.smallFontSize
      }

      MouseArea {
        id: replyHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.replying = true
          replyField.forceFocus()
        }
      }
    }

    TextField {
      id: replyField

      width: parent.width
      visible: root.replying
      placeholder: root.replyPlaceholder
      onAccepted: root.sendReply(replyField.text)
      onCanceled: {
        replyField.text = ""
        root.replying = false
      }
    }
  }
}
