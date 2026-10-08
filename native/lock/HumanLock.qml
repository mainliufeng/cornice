import QtQuick
Rectangle {
  id: root
  color: content.background
  function focusPassword() { content.focusPassword() }
  Image {
    anchors.fill: parent
    source: lockController.backgroundSource
    fillMode: Image.PreserveAspectCrop
    cache: false
  }
  Rectangle {
    id: wash
    anchors.fill: parent
    visible: lockController.backgroundSource !== ""
    readonly property real scrim: lockController.appearance.scrim === undefined ? 1 : lockController.appearance.scrim
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.rgba(0, 0, 0, .62 * wash.scrim) }
      GradientStop { position: .45; color: Qt.rgba(0, 0, 0, .30 * wash.scrim) }
      GradientStop { position: 1; color: Qt.rgba(0, 0, 0, .66 * wash.scrim) }
    }
  }
  LockContent {
    id: content
    anchors.fill: parent
    appearance: lockController.appearance
    user: lockController.user
    showUser: lockController.showUser
    busy: lockController.busy
    failed: !busy && lockController.message !== ""
    message: busy ? label("checking", "正在验证…") : lockController.message
    onSubmitted: value => lockController.authenticate(value)
    onEdited: lockController.clearMessage()
  }
  Connections {
    target: lockController
    function onAuthenticationChanged() { if (!lockController.busy) content.focusPassword() }
  }
}
