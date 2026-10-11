import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
Item {
  id:root
  property var service:null
  readonly property var requests:service && (DesktopSession.agentShell || service.selectedDesktop === "main") ? service.cooperationDesktops : []
  readonly property bool noticeScope:!!service && (DesktopSession.agentShell || service.selectedDesktop === "main")
  PanelWindow {
    id:window
    screen:{
      const state=root.service ? root.service.desktops.find(item => item.name === (DesktopSession.agentShell ? DesktopSession.name : "main")) : null
      return Quickshell.screens.find(item => state && item.name === state.output) || Quickshell.screens[0] || null
    }
    visible:root.noticeScope && (root.requests.length > 0 || !!root.service.error) && !(root.service.desktops.find(item => item.primary) || ({})).humanLocked
    anchors {top:true}
    margins.top:Style.barHeight+Style.space(1)
    implicitWidth:Math.min(460,(screen ? screen.width : 1280)-Style.space(4))
    implicitHeight:Math.min(body.implicitHeight+Style.space(3),(screen ? screen.height : 800)-Style.barHeight-Style.space(4))
    color:"transparent";exclusionMode:ExclusionMode.Ignore;focusable:false
    WlrLayershell.layer:WlrLayer.Overlay
    WlrLayershell.namespace:"cornice-desktop-cooperation"
    WlrLayershell.keyboardFocus:WlrKeyboardFocus.None
    Rectangle {
      anchors.fill:parent;radius:Style.radius;color:Color.panel;border.color:Color.surfaceBorder
      Flickable {
        anchors.fill:parent;anchors.margins:Style.space(1.5);clip:true
        contentHeight:body.implicitHeight;boundsBehavior:Flickable.StopAtBounds
        Column {
          id:body;width:parent.width;spacing:Style.space(1.5)
          Column {
            visible:!!root.service && root.service.error !== ""
            width:body.width;spacing:Style.space(.8)
            Text {width:parent.width;wrapMode:Text.Wrap;text:root.service ? (root.service.actionResult.operation || "桌面服务") + (root.service.actionResult.desktop ? " · " + root.service.desktopLabel(root.service.actionResult.desktop) : "") : "";color:Color.urgent;font.family:Style.fontFamily;font.pixelSize:Style.fontSize;font.bold:true}
            Text {width:parent.width;wrapMode:Text.Wrap;text:root.service ? root.service.error : "";color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
            Row {
              spacing:Style.space(1)
              PanelButton {label:root.service ? root.service.retryLabel : "重试操作";visible:!!root.service && !!root.service.actionResult.retry;enabled:root.service && !root.service.busy;onClicked:root.service.retryAction()}
              PanelButton {label:"关闭提示";visible:!!root.service && !!root.service.actionError;onClicked:root.service.dismissError()}
            }
          }
          Repeater {
            id:rows;model:root.requests
            delegate:Column {
              id:row;required property var modelData
              width:body.width;spacing:Style.space(.8)
              function geometry() {
                const p=button.mapToItem(window.contentItem,0,0)
                return {name:modelData.name,status:modelData.handoff.status,continuation:root.service.awaitingContinuation(modelData),title:modelData.handoff.title,instructions:modelData.handoff.instructions,x:p.x,y:p.y,width:button.width,height:button.height}
              }
              Text {width:parent.width;text:root.service.desktopLabel(row.modelData.name)+" · "+(root.service.awaitingContinuation(row.modelData) ? "等待 Agent 继续" : root.service.handoffLabel(row.modelData.handoff.status));color:Color.accent;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
              Text {width:parent.width;text:row.modelData.handoff.title;wrapMode:Text.Wrap;color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.fontSize;font.bold:true}
              Text {width:parent.width;text:row.modelData.handoff.instructions;wrapMode:Text.Wrap;color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
              Text {width:parent.width;visible:root.service.awaitingContinuation(row.modelData);text:root.service.continuationMessage(row.modelData);wrapMode:Text.Wrap;color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
              Flow {
                width:parent.width;spacing:Style.space(1)
                PanelButton {
                  id:button
                  label:root.service.awaitingContinuation(row.modelData) ? "查看桌面" : row.modelData.handoff.status === "in_progress" ? "已完成，退出接管" : "接管并处理"
                  enabled:!root.service.busy && !row.modelData.humanLocked
                  onClicked:root.service.awaitingContinuation(row.modelData) ? root.service.show(row.modelData.name) : row.modelData.handoff.status === "in_progress" ? root.service.completeHandoff(row.modelData.name,row.modelData.handoff.id) : root.service.startHandoff(row.modelData.name,row.modelData.handoff.id)
                }
                PanelButton {label:"定位桌面";visible:!root.service.awaitingContinuation(row.modelData);enabled:!root.service.busy;onClicked:root.service.show(row.modelData.name)}
              }
              Text {width:parent.width;visible:!root.service.awaitingContinuation(row.modelData);text:"无法操作桌面时，可在原 Agent 对话里让它撤回请求、退出接管。";wrapMode:Text.Wrap;color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
            }
          }
        }
      }
    }
    ShellIpc {
      target:"desktopCooperation"
      function status():string {
        const controls=[]
        for(let i=0;i<rows.count;++i) controls.push(rows.itemAt(i).geometry())
        return JSON.stringify({visible:window.visible,error:root.service ? root.service.error : "",output:window.screen ? window.screen.name : "",controls:controls})
      }
    }
  }
}
