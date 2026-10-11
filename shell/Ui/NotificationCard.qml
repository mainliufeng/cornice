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
  readonly property bool canReply: !DesktopSession.readOnly && allowReply && notification !== null && notification.hasInlineReply === true

  // Clients that send actions expect a click to invoke the "default" one (that
  // is how the freedesktop spec opens the app). Clients that send none — Paseo,
  // Grok Bot, satty here — leave only the D-Bus sender hint, so the click falls
  // back to focusing the window of the app that sent it.
  function actionList() {
    const raw = notification ? notification.actions : null
    if (!raw) return []
    if (Array.isArray(raw)) return raw
    // A Quickshell list can arrive as either an ObjectModel (`.values`, an
    // array) or a sequence (length + indices). On a sequence `.values` is
    // Array.prototype.values — a function — so it must never be returned.
    if (Array.isArray(raw.values)) return raw.values
    const out = []
    const count = raw.length === undefined ? 0 : Number(raw.length)
    for (let i = 0; i < count; i++) out.push(raw[i])
    return out
  }

  readonly property var defaultAction: {
    for (const action of actionList()) {
      if (action && action.identifier === "default") return action
    }
    return null
  }

  // "default" is the click-anywhere action and "inline-reply" has its own field
  // further down; neither belongs in the generic action chips.
  readonly property var visibleActions: actionList().filter(
    action => !action || (action.identifier !== "default" && action.identifier !== "inline-reply"))
  readonly property string replyPlaceholder: {
    if (!notification) return "Reply…"
    const given = String(notification.inlineReplyPlaceholder || "")
    return given === "" ? "Reply…" : given
  }

  function sendReply(value) {
    if (DesktopSession.readOnly) return
    const message = String(value || "").trim()
    replying = false
    if (message === "" || !notification) return
    try {
      if (notification.sendInlineReply(message) === false) return
    } catch (error) {
      console.warn("cornice: inline reply failed: " + error)
      return
    }
    // A notification you have answered is normally done with.
    root.dismissed()
  }

  // Coordinates of the real controls support native integration diagnostics.
  function inspect(target) {
    function point(item, x, y) { const p = item.mapToItem(target, x, y); return {x:p.x,y:p.y} }
    return {id:entry.id,readOnly:DesktopSession.readOnly,canReply:canReply,replying:replying,
      activation:point(root, root.width / 2, Style.space(1)),
      reply:point(replyChip, replyChip.width / 2, replyChip.height / 2),
      input:point(replyField, replyField.width / 2, replyField.height / 2)}
  }

  function senderPid() {
    if (entry.senderPid !== undefined && entry.senderPid !== "") return String(entry.senderPid)
    const hints = notification ? notification.hints : null
    if (hints && hints["sender-pid"] !== undefined && hints["sender-pid"] !== null)
      return String(hints["sender-pid"])
    return ""
  }

  function desktopEntryId() {
    if (entry.desktopEntry !== undefined && entry.desktopEntry !== "") return String(entry.desktopEntry)
    return notification && notification.desktopEntry ? String(notification.desktopEntry) : ""
  }

  function focusApp() {
    if (DesktopSession.readOnly) return false
    Util.exec("cornice-focus-app"
      + " --pid " + Util.shellQuote(senderPid())
      + " --desktop " + Util.shellQuote(desktopEntryId())
      + " --name " + Util.shellQuote(root.appName))
  }

  // A left click is an instruction to act on the notification, not just to
  // throw it away.
  function activate() {
    if (DesktopSession.readOnly) return false
    if (defaultAction) {
      try {
        if (defaultAction.invoke() === false) return false
      } catch (error) {
        console.warn("cornice: default notification action failed: " + error)
        return false
      }
    } else {
      focusApp()
    }
    if (notification) notification.dismiss()
    return true
  }

  Connections {
    target: DesktopSession
    function onReadOnlyChanged() {
      if (!DesktopSession.readOnly) return
      root.replying = false
      replyField.text = ""
    }
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
      if (!root.activate()) return
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
      visible: root.visibleActions.length > 0 && !root.replying
      enabled: !DesktopSession.readOnly
      opacity: enabled ? 1 : 0.45

      Repeater {
        model: root.visibleActions

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
              if (DesktopSession.readOnly || modelData.invoke() === false) return
              root.dismissed()
            }
          }
        }
      }
    }

    // ---- inline reply ------------------------------------------------------
    Rectangle {
      id: replyChip
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
