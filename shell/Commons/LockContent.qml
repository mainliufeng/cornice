import QtQuick

// Shared presentation for both Cornice lock protocols. Authentication and lock
// ownership stay in their providers; this component only presents the prompt.
Item {
  id: root
  property var appearance: ({})
  property string user: ""
  property bool showUser: true
  property bool busy: false
  property bool failed: false
  property bool acceptingInput: !busy
  property string message: ""
  signal submitted(string password)
  signal edited(string text)
  readonly property color background: appearance.background || "#0d1117"
  readonly property color foreground: appearance.foreground || "#c9d1d9"
  readonly property color accent: appearance.accent || "#58a6ff"
  readonly property color urgent: appearance.urgent || "#f85149"
  readonly property color muted: appearance.muted || "#6e7681"
  readonly property string fontFamily: appearance.fontFamily || "Hack Nerd Font"
  readonly property string iconFamily: appearance.iconFamily || fontFamily
  readonly property real fontSize: appearance.fontSize || 16
  readonly property real gap: appearance.gap || 8
  readonly property real radius: appearance.radius || 0
  property date now: new Date()
  function space(multiplier) { return Math.round(gap * multiplier) }
  function label(key, fallback) { return appearance.labels && appearance.labels[key] || fallback }
  function dateTime(format) { return now.toLocaleString(Qt.locale(appearance.language || "en"), format) }
  function focusPassword() { input.forceActiveFocus() }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.now = new Date() }
  // A soft card behind the content: a busy wallpaper should not decide
  // whether the password prompt is readable.
  Rectangle {
    anchors.horizontalCenter: content.horizontalCenter
    anchors.verticalCenter: content.verticalCenter
    width: Math.min(parent.width - root.space(4), content.width + root.space(8))
    height: content.height + root.space(8) * content.density
    color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.72)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
  }

  Column {
    id: content

    width: Math.min(480, parent.width - root.space(12))
    readonly property real density: Math.min(1, parent.height / 680)
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -Math.round(parent.height * 0.05)
    spacing: root.space(1.2) * density

    // ---- clock ---------------------------------------------------------
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: root.space(0.7)

      Text {
        id: lockTime
        text: root.dateTime("HH:mm")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Math.round(Math.min(root.fontSize * 8 * content.density, content.width / 3.3))
        font.bold: true
        font.letterSpacing: -2
      }

      Text {
        anchors.baseline: lockTime.baseline
        text: Qt.formatDateTime(root.now, "ss")
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
        font.family: root.fontFamily
        font.pixelSize: Math.max(root.fontSize, root.fontSize * 1.8 * content.density)
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.dateTime(root.label("dateFormat", "dddd, MMMM d"))
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.65)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize + 2
      font.letterSpacing: 1
    }

    Item { width: 1; height: root.space(2.6) * content.density }

    // ---- who is unlocking ----------------------------------------------
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: root.space(0.5)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "\uf023"
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
        font.family: root.iconFamily
        font.pixelSize: root.fontSize
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.showUser ? root.user : root.label("authRequired", "需要认证")
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize + 2
        font.letterSpacing: 1
      }
    }

    Item { width: 1; height: root.space(0.4) }

    // ---- password field ------------------------------------------------
    Item {
      id: field

      anchors.horizontalCenter: parent.horizontalCenter
      width: content.width - root.space(4)
      height: Math.max(root.space(5.5), root.space(7.5) * content.density)

      Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                       input.activeFocus ? 0.10 : 0.06)

        Behavior on color {
          ColorAnimation { duration: 120 }
        }
      }

      // The underline carries the state: accent = ready, muted = busy,
      // urgent = failed.
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 2
        color: root.failed ? root.urgent
             : root.busy ? root.muted
             : root.accent
      }

      Text {
        id: lead

        anchors.left: parent.left
        anchors.leftMargin: root.space(1.2)
        anchors.verticalCenter: parent.verticalCenter
        text: root.failed ? "\uf00d" : "\uf023"
        color: root.failed ? root.urgent : root.muted
        font.family: root.iconFamily
        font.pixelSize: root.fontSize * 1.1
      }

      TextInput {
        id: input

        anchors.left: lead.right
        anchors.leftMargin: root.space(0.9)
        anchors.right: parent.right
        anchors.rightMargin: root.space(1.2)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignLeft
        echoMode: TextInput.Password
        passwordCharacter: "\u25cf"
        color: root.foreground
        selectionColor: root.accent
        selectedTextColor: root.background
        font.family: root.fontFamily
        font.pixelSize: root.fontSize * 1.3
        focus: true
        clip: true
        // Enabled unless an attempt is really in flight: tying this to the
        // state alone is what made the prompt untypable.
        enabled: root.acceptingInput

        Component.onCompleted: forceActiveFocus()

        onTextChanged: root.edited(text)
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            const value = input.text
            input.text = ""
            root.submitted(value)
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            input.text = ""
            event.accepted = true
          }
        }
      }

      Text {
        anchors.left: lead.right
        anchors.leftMargin: root.space(0.9)
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text === ""
        text: root.busy ? root.label("checking", "正在验证…") : root.label("password", "密码")
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize * 1.15
      }
    }

    // Fixed height so a failure message does not move the field.
    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      width: content.width - root.space(4)
      height: root.space(3.5)

      Text {
        anchors.centerIn: parent
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.message === "Authentication failed" ? root.label("rejected", "验证失败，请重试")
          : root.message === "Too many attempts" ? root.label("tooMany", "尝试次数过多") : root.message
        color: root.failed ? root.urgent : root.muted
        font.family: root.fontFamily
        font.pixelSize: root.fontSize + 2
        elide: Text.ElideRight
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.label("hint", "输入密码，按 Enter 解锁")
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.60)
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      font.letterSpacing: 1
    }
  }

}
