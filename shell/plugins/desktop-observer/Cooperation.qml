import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
Item {
  id:root
  property var service:null
  readonly property var requests:service ? service.desktops.filter(item => item.handoff && ["requested","in_progress"].includes(item.handoff.status) && (DesktopSession.agentShell ? item.name === DesktopSession.name : service.selectedDesktop === "main")) : []
  PanelWindow {
    id:window
    screen:{
      const state=root.service ? root.service.desktops.find(item => item.name === (DesktopSession.agentShell ? DesktopSession.name : "main")) : null
      return Quickshell.screens.find(item => state && item.name === state.output) || Quickshell.screens[0] || null
    }
    visible:root.requests.length > 0 && !(root.service.desktops.find(item => item.primary) || ({})).humanLocked
    anchors {top:true}
    margins.top:Style.barHeight+Style.space(1)
    implicitWidth:Math.min(460,(screen ? screen.width : 1280)-Style.space(4))
    implicitHeight:Math.min(body.implicitHeight+Style.space(3),(screen ? screen.height : 800)-Style.barHeight-Style.space(4))
    color:"transparent";exclusionMode:ExclusionMode.Ignore
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
          Repeater {
            id:rows;model:root.requests
            delegate:Column {
              id:row;required property var modelData
              width:body.width;spacing:Style.space(.8)
              function geometry() {
                const p=button.mapToItem(window.contentItem,0,0)
                return {name:modelData.name,status:modelData.handoff.status,title:modelData.handoff.title,instructions:modelData.handoff.instructions,x:p.x,y:p.y,width:button.width,height:button.height}
              }
              Text {width:parent.width;text:root.service.desktopLabel(row.modelData.name)+" · "+root.service.handoffLabel(row.modelData.handoff.status);color:Color.accent;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
              Text {width:parent.width;text:row.modelData.handoff.title;wrapMode:Text.Wrap;color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.fontSize;font.bold:true}
              Text {width:parent.width;text:row.modelData.handoff.instructions;wrapMode:Text.Wrap;color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
              PanelButton {
                id:button
                label:row.modelData.handoff.status === "in_progress" ? "已完成，退出接管" : "接管并处理"
                enabled:!root.service.busy && !row.modelData.humanLocked
                onClicked:row.modelData.handoff.status === "in_progress" ? root.service.completeHandoff(row.modelData.name,row.modelData.handoff.id) : root.service.startHandoff(row.modelData.name,row.modelData.handoff.id)
              }
              Text {width:parent.width;text:"无法操作桌面时，可在 Agent 对话里让它撤回请求、退出接管。";wrapMode:Text.Wrap;color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
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
        return JSON.stringify({visible:window.visible,output:window.screen ? window.screen.name : "",controls:controls})
      }
    }
  }
}
