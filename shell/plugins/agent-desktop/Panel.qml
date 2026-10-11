import QtQuick
import qs.Commons
import qs.Ui
PanelFrame {
  id: root
  panelWidth: 650
  panelHeight: Math.min(580, window.screen ? window.screen.height - Style.barHeight - 40 : 580)
  takesKeyboard: true
  property var confirmation: null
  onConfirmationChanged: if (confirmation) bodyScroll.contentY=0
  onOpened: bodyScroll.contentY=0
  function buttonGeometry(item,key,target) {const p=item.mapToItem(root.window.contentItem,0,0);return {key:key,target:target || "",x:p.x,y:p.y,width:item.width,height:item.height,enabled:item.enabled,visible:item.visible}}
  function confirmOperation(desktop, operation) {confirmation={name:desktop.name,stableId:desktop.stableId || desktop.seatId,operation:operation,windowCount:desktop.retainedWindowCount,currentWindowCount:desktop.windowCount}}
  function executeConfirmed(closeApps) {
    if (!confirmation || !service) return
    const state=service.desktops.find(item => item.name === confirmation.name)
    if (!state || (state.stableId || state.seatId) !== confirmation.stableId) {service.reportError("桌面操作",confirmation.name,"桌面状态已变化，请重新选择。");confirmation=null;return}
    service.operate([confirmation.operation,confirmation.name].concat(closeApps ? ["--close-apps"] : []));confirmation=null
  }
  readonly property var service: host ? host.services["cn.agent-desktop"] : null
  Flickable {
    id:bodyScroll
    anchors.fill: parent; anchors.margins: Style.space(2); clip: true
    contentHeight: body.implicitHeight; boundsBehavior: Flickable.StopAtBounds
    Column {
      id: body; width: parent.width; spacing: Style.space(1.5)
      PanelHeader { width: parent.width; title: "桌面管理"; subtitle: root.service && root.service.available ? "独立输入与工作区 · 同一系统用户" : "需要启用配置和支持多 seat 的 Hyprland" }
      Text {width:parent.width;wrapMode:Text.Wrap;color:Color.urgent;text:root.service ? root.service.healthError : "桌面服务未加载";visible:text!=="";font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
      Column {
        width:parent.width;spacing:Style.space(.8);visible:!!root.service && !!root.service.actionError
        Text {width:parent.width;wrapMode:Text.Wrap;text:root.service ? (root.service.actionResult.operation || "桌面操作") + "：" + root.service.actionError : "";color:Color.urgent;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
        Text {width:parent.width;wrapMode:Text.Wrap;text:root.service ? root.service.actionResult.detail || "" : "";visible:text!=="" && root.service.actionResult.detail !== root.service.actionError;color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
        Row {spacing:Style.space(1);PanelButton {label:root.service ? root.service.retryLabel : "重试操作";visible:!!root.service && !!root.service.actionResult.retry;enabled:!!root.service && !root.service.busy;onClicked:root.service.retryAction()} PanelButton {label:"关闭提示";onClicked:root.service.dismissError()}}
      }
      Column {
        width:parent.width;visible:root.confirmation!==null;spacing:Style.space(1)
        Text {width:parent.width;wrapMode:Text.Wrap;text:root.confirmation ? (root.confirmation.operation === "reset" ? "重置 " : "删除 ") + root.service.desktopLabel(root.confirmation.name) + (root.confirmation.windowCount !== undefined ? " · 共 " + root.confirmation.windowCount + " 个窗口" : root.confirmation.currentWindowCount !== undefined ? " · 当前工作区 " + root.confirmation.currentWindowCount + " 个窗口" : "") : "";color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.fontSize;font.bold:true}
        Text {width:parent.width;wrapMode:Text.Wrap;text:root.confirmation && root.confirmation.operation === "reset" ? "回到初始工作区并暂停桌面控制。可以保留应用，也可以关闭全部应用；关闭时未保存内容可能丢失。网站 profile 和登录数据会保留。" : "保留应用会让窗口继续存在；关闭应用会结束该桌面的应用，未保存内容可能丢失。网站 profile 和登录数据会保留。";color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
        Flow {width:parent.width;spacing:Style.space(1)
          PanelButton {id:preserveButton;label:root.confirmation && root.confirmation.operation === "reset" ? "保留应用并重置" : "保留应用并删除";visible:!!root.confirmation;enabled:!!root.service && !root.service.busy;onClicked:root.executeConfirmed(false)}
          PanelButton {id:closeAppsButton;label:root.confirmation && root.confirmation.operation === "reset" ? "关闭应用并重置" : "关闭应用并删除";destructive:true;enabled:!!root.service && !root.service.busy;onClicked:root.executeConfirmed(true)}
          PanelButton {id:cancelButton;label:"取消";onClicked:root.confirmation=null}
        }
      }
      PanelButton {id:createButton;label:"创建空桌面";enabled:!!root.service && root.service.available && !root.service.busy;onClicked:root.service.createDesktop()}
      Repeater {
        id: desktopRows
        model: root.service ? root.service.desktops : []
        delegate: Rectangle {
          required property var modelData
          function controlRect() {
            const point = controlButton.mapToItem(root.window.contentItem, 0, 0)
            return {name: modelData.name, x: point.x, y: point.y,
              width: controlButton.width, height: controlButton.height, handoffs:Array.from({length:handoffRows.count}, (_,i) => handoffRows.itemAt(i).modelData),actions:[root.buttonGeometry(resetButton,"reset",modelData.name),root.buttonGeometry(deleteButton,"remove",modelData.name)]}
          }
          width: body.width; height: rowBody.implicitHeight + Style.space(2)
          color: Color.hover; radius: Style.radius
          Column {
            id: rowBody; anchors.left: parent.left; anchors.right: parent.right
            anchors.top: parent.top; anchors.margins: Style.space(1); spacing: Style.space(0.7)
            Text { text: root.service.desktopLabel(modelData.name) + " · WS " + (modelData.workspace || "?") + " · " + (modelData.error || !modelData.available ? "桌面不可用" : root.service.stateLabel(modelData)); color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: Style.fontSize }
            Text { width: parent.width; text: modelData.error || modelData.window || "无焦点窗口"; elide: Text.ElideRight; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
            Text {width:parent.width;wrapMode:Text.Wrap;text:modelData.retainedWindowCount !== undefined ? modelData.retainedWindowCount + " 个窗口 · " + (modelData.retainedApps ? "保留应用，可供下个任务复用" : "空桌面") : modelData.windowCount !== undefined ? "当前工作区 " + modelData.windowCount + " 个窗口" : "应用会在任务结束后保留";color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
            Repeater {model:root.service.diagnostics(modelData);delegate:Text {required property string modelData;width:rowBody.width;wrapMode:Text.Wrap;text:modelData;color:Color.urgent;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}}
            Repeater {
              id:handoffRows
              model:modelData.handoffs || []
              delegate:Column {
                required property var modelData
                width:rowBody.width;spacing:Style.space(.3)
                Text {width:parent.width;wrapMode:Text.Wrap;text:root.service.handoffLabel(modelData.status)+" · "+modelData.title;color:Color.accent;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
                Text {width:parent.width;wrapMode:Text.Wrap;text:modelData.instructions;color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
                Text {width:parent.width;wrapMode:Text.Wrap;text:Qt.formatDateTime(new Date(modelData.updatedAt),"MM-dd HH:mm")+" · "+root.service.handoffNote(modelData.note);color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
              }
            }
            Flow {
              width:parent.width;spacing: Style.space(1)
              PanelButton { label: "允许 Agent · " + (modelData.agentAllowed ? "开" : "关"); enabled: !!root.service && !root.service.busy && !modelData.humanLocked; onClicked: root.service.operate(["allow-agent", modelData.name, modelData.agentAllowed ? "off" : "on"]) }
              PanelButton { label: "全屏查看"; onClicked: { root.close(); root.service.show(modelData.name) } }
              PanelButton { id: controlButton; label: modelData.paused ? "恢复输入" : "暂停输入"; enabled: !!root.service && !root.service.busy && !modelData.error && (modelData.primary || modelData.controlMode !== "human") && modelData.agentAllowed === true; onClicked: root.service.operate([modelData.paused ? "resume" : "pause", modelData.name]) }
              PanelButton {id:resetButton;label:"重置桌面";enabled:!modelData.primary && !!root.service && !root.service.busy && !modelData.occupied && !modelData.error;onClicked:root.confirmOperation(modelData,"reset")}
              PanelButton {id:deleteButton; label: "删除桌面"; destructive: true; enabled: !modelData.primary && !!root.service && !root.service.busy && !modelData.occupied && !modelData.error; onClicked: root.confirmOperation(modelData,"remove") }
            }
          }
        }
      }
      PanelButton { label: root.service && root.service.allPreviewsVisible ? "隐藏全部浮动预览" : "显示全部浮动预览"; enabled: !!root.service && root.service.previewDesktops.length > 0; onClicked: root.service.togglePreviews() }
      PanelButton {label:"始终显示预览 · " + (root.service && root.service.alwaysShowPreviews ? "开" : "关");enabled:!!root.service && !root.service.previewModeBusy;onClicked:root.service.setPreviewMode(!root.service.alwaysShowPreviews)}
      Text { text: "Agent 默认复用保留应用的空闲桌面，也可请求创建空桌面。"; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
      Text { width: parent.width; wrapMode: Text.Wrap; text: "暂停只撤销桌面输入与浏览器控制，后台应用与 Harness 任务仍可能运行。主桌面开关仅约束 Cornice 桌面工具；所有桌面使用同一个 Linux 用户，共享 HOME、文件权限和应用数据。"; color: Color.muted; font.family: Style.fontFamily; font.pixelSize: Style.smallFontSize }
    }
  }
  ShellIpc {
    target: "desktopPanel"
    function actions(): string {
      const rows=[root.buttonGeometry(createButton,"create"),root.buttonGeometry(preserveButton,"preserve"),root.buttonGeometry(closeAppsButton,"close-apps"),root.buttonGeometry(cancelButton,"cancel")]
      for (let i=0;i<desktopRows.count;++i) rows.push(...desktopRows.itemAt(i).controlRect().actions)
      return JSON.stringify({open:root.isOpen,confirmation:root.confirmation,actions:rows,window:{x:root.window.margins.left,y:root.window.margins.top,width:root.window.width,height:root.window.height}})
    }
    function controls(): string {
      const rows = []
      for (let i = 0; i < desktopRows.count; ++i) rows.push(desktopRows.itemAt(i).controlRect())
      return JSON.stringify(rows)
    }
  }

}
