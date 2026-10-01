import QtQuick
import Quickshell
import Quickshell.Services.Polkit
import qs.Commons
import qs.Ui

// PolicyKit authentication agent.
//
// Replaces polkit-gnome: the dialog for "authentication is required" prompts is
// drawn by the shell, in the same style as the lock screen. Only one agent can
// be registered with polkit at a time, so the old agent must not be running.
Item {
  id: root

  property var host: null
  property var plugin: null

  // PolkitAgent is a creatable type, not a singleton: it registers with polkit
  // when it is instantiated.
  PolkitAgent {
    id: agent
  }

  // flow is undefined (not null) when nothing is pending — normalise it, or the
  // `root.flow !== null` guards below still dereference undefined.
  readonly property var flow: agent.flow ? agent.flow : null
  readonly property var identities: (flow && flow.identities) ? flow.identities : []

  property string password: ""
  property int identityIndex: 0

  onFlowChanged: {
    password = ""
    identityIndex = 0
    if (flow) dialog.open("{}")
    else dialog.close()
  }

  function submit() {
    if (!flow) return
    if (flow.isResponseRequired && password === "") return
    flow.submit(password)
    password = ""
    field.text = ""
  }

  // Dropping the flow is how the agent dismisses a request; polkit reports the
  // caller a "dismissed" error, which is what the Cancel button should do.
  function cancel() {
    if (!flow) return
    console.log("cornice: polkit request cancelled by the user")
    flow.completed()
    dialog.close()
  }

  PanelFrame {
    id: dialog

    edge: "center"
    panelWidth: Math.min(520, window.screen ? window.screen.width - Style.space(8) : 520)
    panelHeight: content.implicitHeight + Style.space(4)
    takesKeyboard: true
    dismissOnClickAway: false

    onDismissed: if (root.flow) root.cancel()

    Column {
      id: content

      anchors.fill: parent
      spacing: Style.space(1)

      Row {
        width: parent.width
        spacing: Style.space(0.9)

        Image {
          width: Style.fontSize * 1.8
          height: width
          anchors.verticalCenter: parent.verticalCenter
          sourceSize.width: width
          sourceSize.height: height
          visible: root.flow && root.flow.iconName !== ""
          source: (root.flow && root.flow.iconName !== "") ? Quickshell.iconPath(root.flow.iconName, "") : ""
          fillMode: Image.PreserveAspectFit
        }

        Column {
          width: parent.width - (Style.fontSize * 1.8) - Style.space(0.9)
          spacing: Style.space(0.3)

          Text {
            width: parent.width
            text: I18n.t("lock.authRequired")
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize + 6
            font.bold: true
          }

          Text {
            width: parent.width
            text: root.flow ? root.flow.message : ""
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.75)
            wrapMode: Text.Wrap
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Color.surfaceBorder
      }

      // Identity picker, when polkit offers a choice (several sessions/users).
      Column {
        width: parent.width
        spacing: Style.space(0.3)
        visible: root.identities.length > 1

        Repeater {
          model: root.identities

          delegate: Rectangle {
            required property var modelData
            required property int index

            width: content.width
            height: Style.space(5.5)
            radius: Style.radius
            color: index === root.identityIndex ? Color.hover : "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(0.8)
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData)
              color: Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSize
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.identityIndex = index
                root.flow.selectedIdentity = modelData
              }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(0.4)
        visible: root.flow !== null && root.flow.isResponseRequired

        Text {
          width: parent.width
          text: root.flow ? root.flow.inputPrompt : "Password"
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.6)
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }

        TextField {
          id: field

          width: parent.width
          echoMode: (root.flow && root.flow.responseVisible) ? TextInput.Normal : TextInput.Password
          passwordCharacter: "\u25cf"
          placeholder: ""
          onTextChanged: root.password = text
          onAccepted: root.submit()
          onCanceled: root.cancel()

          Connections {
            target: dialog
            function onOpened() { field.forceFocus() }
          }
        }
      }

      Text {
        width: parent.width
        visible: root.flow !== null && root.flow.supplementaryMessage !== ""
        text: root.flow ? root.flow.supplementaryMessage : ""
        color: (root.flow && root.flow.supplementaryIsError) ? Color.urgent : Color.muted
        wrapMode: Text.Wrap
        font.family: Style.fontFamily
        font.pixelSize: Style.fontSize
      }

      Row {
        width: parent.width
        spacing: Style.space(0.6)
        layoutDirection: Qt.RightToLeft

        Rectangle {
          width: authorizeText.implicitWidth + Style.space(2)
          height: Style.space(5.5)
          radius: Style.radius
          color: Color.workspaceActive

          Text {
            id: authorizeText
            anchors.centerIn: parent
            text: I18n.t("lock.authenticate")
            color: Color.workspaceActiveText
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.submit()
          }
        }

        Rectangle {
          width: cancelText.implicitWidth + Style.space(2)
          height: Style.space(5.5)
          radius: Style.radius
          color: Color.hover

          Text {
            id: cancelText
            anchors.centerIn: parent
            text: I18n.t("common.cancel")
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSize
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.cancel()
          }
        }
      }
    }
  }

  ShellIpc {
    target: "polkit"

    function status(): string {
      return JSON.stringify({
        registered: agent.isRegistered,
        active: agent.isActive,
        hasFlow: root.flow !== null,
        actionId: root.flow ? root.flow.actionId : "",
        message: root.flow ? root.flow.message : "",
        needsResponse: root.flow ? root.flow.isResponseRequired : false
      })
    }

    function cancel(): string {
      root.cancel()
      return "ok"
    }
  }
}
