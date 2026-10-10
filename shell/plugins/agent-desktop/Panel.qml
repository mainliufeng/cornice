import QtQuick
import qs.Commons
import qs.Ui
PanelFrame {
  id: root
  panelWidth: 610
  panelHeight: Math.min(580, window.screen ? window.screen.height - Style.barHeight - 40 : 580)
  takesKeyboard: true
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  Flickable {
    anchors.fill: parent; anchors.margins: Style.space(2); clip: true
    contentHeight: body.implicitHeight; boundsBehavior: Flickable.StopAtBounds
    Column {
      id: body; width: parent.width; spacing: Style.space(1.5)
      PanelHeader { width: parent.width; title: "桌面管理"; subtitle: root.service && root.service.available ? "独立输入与工作区 · 共享应用" : "需要启用配置和支持多 seat 的 Hyprland" }
      Text {
        width: parent.width; wrapMode: Text.Wrap; color: Color.urgent
        text: root.service ? root.service.error : "桌面服务未加载"; visible: text !== ""
        font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize
      }
      Repeater {
        id: desktopRows
        model: root.service ? root.service.desktops : []
        delegate: Rectangle {
          required property var modelData
          function controlRect() {
            const point = controlButton.mapToItem(root.window.contentItem, 0, 0)
            return {name: modelData.name, x: point.x, y: point.y,
              width: controlButton.width, height: controlButton.height}
          }
          width: body.width; height: rowBody.implicitHeight + Style.space(2)
          color: Color.hover; radius: Style.radius
          Column {
            id: rowBody; anchors.left: parent.left; anchors.right: parent.right
            anchors.top: parent.top; anchors.margins: Style.space(1); spacing: Style.space(0.7)
            Text { text: root.service.desktopLabel(modelData.name) + " · WS " + (modelData.workspace || "?") + " · " + (modelData.error || !modelData.available ? "桌面不可用" : root.service.stateLabel(modelData)); color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: Style.fontSize }
            Text { width: parent.width; text: modelData.error || modelData.window || "无焦点窗口"; elide: Text.ElideRight; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
            Row {
              spacing: Style.space(1)
              PanelButton { label: "允许 Agent · " + (modelData.agentAllowed ? "开" : "关"); enabled: !!root.service && !root.service.busy && !modelData.humanLocked; onClicked: root.service.operate(["allow-agent", modelData.name, modelData.agentAllowed ? "off" : "on"]) }
              PanelButton { label: "全屏查看"; onClicked: { root.close(); root.service.show(modelData.name) } }
              PanelButton { id: controlButton; label: modelData.paused ? "恢复输入" : "暂停输入"; enabled: !!root.service && !root.service.busy && !modelData.error && (modelData.primary || modelData.controlMode !== "human") && modelData.agentAllowed === true; onClicked: root.service.operate([modelData.paused ? "resume" : "pause", modelData.name]) }
              PanelButton { label: "删除桌面"; destructive: true; enabled: !modelData.primary && !!root.service && !root.service.busy && !modelData.error; onClicked: root.service.operate(["remove", modelData.name]) }
            }
          }
        }
      }
      PanelButton { label: root.service && root.service.allPreviewsVisible ? "隐藏全部浮动预览" : "显示全部浮动预览"; enabled: !!root.service && root.service.previewDesktops.length > 0; onClicked: root.service.togglePreviews() }
      Text { text: "额外桌面由 Agent 按需创建"; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
      Text { width: parent.width; wrapMode: Text.Wrap; text: "主桌面默认禁止 Agent 控制。其他桌面默认允许，但由外部 Harness 自动占用。关闭权限立即撤销控制；删除桌面会保留共享窗口。"; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
    }
  }
  ShellIpc {
    target: "desktopPanel"
    function controls(): string {
      const rows = []
      for (let i = 0; i < desktopRows.count; ++i) rows.push(desktopRows.itemAt(i).controlRect())
      return JSON.stringify(rows)
    }
  }

}
