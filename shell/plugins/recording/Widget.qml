import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Item {
  id: root
  property var host: null
  property var plugin: null
  property var widgetConfig: ({})
  readonly property var recorder: host ? host.service("cn.recording") : null
  readonly property bool active: !!recorder && recorder.active
  readonly property bool enabledControl: !!recorder && !recorder.locked && recorder.state !== "stopping" && recorder.state !== "saving"
  implicitWidth: active ? Style.widgetHeight + elapsed.implicitWidth + Style.space(1) : Style.widgetHeight
  implicitHeight: Style.widgetHeight
  Rectangle {anchors.fill: parent; anchors.margins: Math.round(Style.gap * 0.25); radius: Style.radius; color: hit.containsMouse && root.enabledControl ? Color.hover : "transparent"}
  Row {
    anchors.centerIn: parent; spacing: Style.space(0.6)
    Text {text: root.active ? "\uf04d" : "\uf03d"; color: root.active ? "#ef5350" : root.enabledControl ? Color.barForeground : Color.muted; font.family: Style.iconFamily; font.pixelSize: Style.fontSize}
    Text {id: elapsed; visible: root.active; text: root.recorder ? Math.floor(root.recorder.seconds / 60) + ":" + String(root.recorder.seconds % 60).padStart(2, "0") : ""; color: Color.barForeground; font.family: Style.fontFamily; font.pixelSize: Style.fontSize}
  }
  MouseArea {
    id: hit; anchors.fill: parent; enabled: root.enabledControl; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (root.active) root.recorder.stop()
      else {const window = root.QsWindow.window; root.recorder.start(window && window.screen ? window.screen.name : "")}
    }
  }
  BarTooltip {host: root.host; anchorItem: root; hovered: hit.containsMouse; title: I18n.t(root.active ? "recording.stop" : "bar.widget.recording"); detail: root.active ? recorder.file : I18n.t("recording.start")}
}
