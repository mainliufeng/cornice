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
      PanelHeader { width: parent.width; title: "Agent 桌面"; subtitle: root.service && root.service.available ? "独立输入与工作区 · 共享应用" : "需要启用配置和支持多 seat 的 Hyprland" }
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
            Text { text: modelData.name + " · WS " + (modelData.workspace || "?") + " · " + (modelData.paused ? "输入已暂停" : "允许 agent 输入"); color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: Style.fontSize }
            Text { width: parent.width; text: modelData.error || modelData.window || "无焦点窗口"; elide: Text.ElideRight; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
            Row {
              spacing: Style.space(1)
              PanelButton { label: "只读观察"; onClicked: { root.close(); root.host.summon("cn.desktop-observer", {name: modelData.name}) } }
              PanelButton { id: controlButton; label: modelData.paused ? "恢复输入" : "暂停输入"; enabled: root.service && !root.service.busy; onClicked: root.service.operate([modelData.paused ? "resume" : "pause", modelData.name]) }
              PanelButton { label: "删除 seat"; destructive: true; enabled: root.service && !root.service.busy; onClicked: root.service.operate(["remove", modelData.name]) }
            }
          }
        }
      }
      Text { text: "创建桌面（先创建 seats，再启动 GTK 应用）"; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
      Row {
        spacing: Style.space(1)
        TextField { id: name; width: 155; placeholder: "名称，如 writer" }
        TextField { id: workspace; width: 90; text: "10"; placeholder: "工作区" }
        TextField { id: output; width: 150; placeholder: "输出，如 eDP-1" }
        PanelButton { label: "创建"; enabled: root.service && root.service.available && !root.service.busy && name.text !== "" && output.text !== ""; onClicked: root.service.operate(["create", name.text, "--workspace", workspace.text, "--output", output.text]) }
      }
      Text { width: parent.width; wrapMode: Text.Wrap; text: "新桌面默认暂停。恢复后通过 CLI 绑定执行器；删除 seat 会保留共享窗口。"; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
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
