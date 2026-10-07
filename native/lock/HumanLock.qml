import QtQuick
Rectangle {
  id: root
  color: "#131820"
  readonly property bool busy: lockController.busy
  function focusPassword() { input.forceActiveFocus() }
  function authenticate() {
    if (busy) return
    const value = input.text; input.text = ""
    lockController.authenticate(value)
  }
  Connections {
    target: lockController
    function onAuthenticationChanged() { if (!lockController.busy) input.forceActiveFocus() }
  }
  Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: clock.text = Qt.formatDateTime(new Date(), "hh:mm") }
  Column {
    width: Math.min(420, parent.width - 64)
    anchors.centerIn: parent; spacing: 24
    Text { id: clock; anchors.horizontalCenter: parent.horizontalCenter; color: "#f1f3f5"; font.pixelSize: 64 }
    Text { visible: lockController.showUser; text: lockController.user; anchors.horizontalCenter: parent.horizontalCenter; color: "#a9b3c1"; font.pixelSize: 20 }
    Rectangle {
      width: parent.width; height: 56; radius: 12; color: "#242c38"; border.color: input.activeFocus ? "#89b4fa" : "#4c566a"
      TextInput {
        id: input; anchors.fill: parent; anchors.margins: 16
        color: "#f1f3f5"; font.pixelSize: 20; echoMode: TextInput.Password
        enabled: !root.busy; focus: true; selectByMouse: true
        onAccepted: root.authenticate()
      }
      Text { visible: input.text.length === 0; text: "密码"; anchors.centerIn: parent; color: "#a9b3c1"; font.pixelSize: 18 }
    }
    Rectangle {
      width: parent.width; height: 48; radius: 12; color: root.busy ? "#4c566a" : "#89b4fa"
      Text { text: root.busy ? "正在验证…" : "解锁"; anchors.centerIn: parent; color: "#131820"; font.pixelSize: 18 }
      MouseArea { anchors.fill: parent; enabled: !root.busy; onClicked: root.authenticate() }
    }
    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: lockController.message; color: "#f1f3f5"; font.pixelSize: 16; wrapMode: Text.Wrap }
    Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: lockController.scope === "human" ? "人的桌面已锁定 · 获准的 Agent 可继续运行" : "整个会话已锁定 · Agent 已暂停"; color: "#a9b3c1"; font.pixelSize: 14; wrapMode: Text.Wrap }
  }
  Component.onCompleted: input.forceActiveFocus()
}
