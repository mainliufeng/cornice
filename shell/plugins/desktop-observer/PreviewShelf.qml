import QtQuick
import Quickshell
import Quickshell.Wayland
import Cornice.Desktop
import qs.Commons
Item {
  id:root
  property var service:null
  readonly property var previews: service ? service.previewDesktops.filter(item => service.previewVisible(item.name)) : []
  property var previewNames:[]
  onPreviewsChanged: {
    const names = previews.map(item => item.name)
    if (JSON.stringify(names) !== JSON.stringify(previewNames)) previewNames = names
  }
  Component.onCompleted: previewNames = previews.map(item => item.name)
  property real offsetX:Style.space(2)
  property real offsetY:Style.space(2)
  function clampOffsets() {
    offsetX = Math.max(0, Math.min(offsetX, Math.max(0, (shelf.screen ? shelf.screen.width : 1280) - shelf.width)))
    offsetY = Math.max(0, Math.min(offsetY, Math.max(0, (shelf.screen ? shelf.screen.height : 1080) - shelf.height - Style.barHeight)))
  }
  readonly property bool visibleHere: !DesktopSession.agentShell && !DesktopSession.secondary
  PanelWindow {
    id:shelf
    screen: {
      const desktops = root.service ? root.service.desktops : []
      const primary = desktops.find(desktop => desktop.primary)
      // A shared-output secondary seat does not turn the primary output private.
      const physical = Quickshell.screens.filter(item => (primary && item.name === primary.output) || !desktops.some(desktop => !desktop.primary && desktop.output === item.name))
      return physical.find(item => primary && item.name === primary.output) || physical[0] || null
    }
    onScreenChanged: Qt.callLater(root.clampOffsets)
    onWidthChanged: Qt.callLater(root.clampOffsets)
    onHeightChanged: Qt.callLater(root.clampOffsets)
    Connections {
      target:shelf.screen
      function onWidthChanged() {Qt.callLater(root.clampOffsets)}
      function onHeightChanged() {Qt.callLater(root.clampOffsets)}
    }
    visible:root.visibleHere && root.previews.length > 0
    anchors {right:true;bottom:true}
    margins {
      right:Math.max(0, Math.min(root.offsetX, (screen ? screen.width : 1280) - implicitWidth))
      bottom:Math.max(0, Math.min(root.offsetY, (screen ? screen.height : 1080) - implicitHeight - Style.barHeight))
    }
    implicitWidth:Math.min(320, screen ? screen.width : 1280)
    implicitHeight:Math.max(0, Math.min(stack.implicitHeight, (screen ? screen.height : 1080) - Style.barHeight - Style.space(6)))
    exclusionMode:ExclusionMode.Ignore
    focusable:false
    color:"transparent"
    WlrLayershell.layer:WlrLayer.Overlay
    WlrLayershell.namespace:"cornice-desktop-previews"
    WlrLayershell.keyboardFocus:WlrKeyboardFocus.None
    Flickable {
      id:shelfScroll
      anchors.fill:parent
      clip:true
      contentHeight:stack.implicitHeight
      boundsBehavior:Flickable.StopAtBounds
      Column {
        id:stack
        width:shelf.width
        spacing:Style.space(1)
        Repeater {
          id:cards
          model:root.previewNames
          delegate:Rectangle {
            id:card
            required property string modelData
            readonly property var desktopState:root.service.desktops.find(item => item.name === modelData) || ({})
            function geometry() {
              return {name:modelData,x:shelf.screen.width-shelf.margins.right-shelf.width,y:shelf.screen.height-shelf.margins.bottom-shelf.height+card.y-shelfScroll.contentY,
                width:width,height:height,frames:frame.frameCount,hasFrame:frame.hasFrame,invalidations:frame.invalidations,error:frame.error}
            }
            width:stack.width
            height:220
            radius:Style.radius
            color:Color.panel
            border.color:Color.muted
            Rectangle {
              id:header
              width:parent.width;height:40
              color:"transparent"
              MouseArea {
                anchors {left:parent.left;right:hide.left;top:parent.top;bottom:parent.bottom}
                property real lastX:0
                property real lastY:0
                cursorShape:pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                onPressed:mouse => {lastX=mouse.x;lastY=mouse.y}
                onPositionChanged:mouse => {
                  if (!pressed) return
                  root.offsetX=Math.max(0,Math.min((shelf.screen ? shelf.screen.width : 1280)-shelf.width,root.offsetX-(mouse.x-lastX)))
                  root.offsetY=Math.max(0,Math.min((shelf.screen ? shelf.screen.height : 1080)-shelf.height-Style.barHeight,root.offsetY-(mouse.y-lastY)))
                }
              }
              Text {
                anchors {left:parent.left;right:hide.left;leftMargin:Style.space(1.5);rightMargin:Style.space(1)}
                anchors.verticalCenter:parent.verticalCenter
                text:root.service.desktopLabel(card.modelData) + " · " + root.service.stateLabel(card.desktopState)
                elide:Text.ElideRight
                color:Color.foreground
                font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize
              }
              Rectangle {
                id:hide
                anchors {right:parent.right;rightMargin:Style.space(0.5);verticalCenter:parent.verticalCenter}
                width:32;height:32;radius:Style.radius
                color:hideMouse.containsMouse ? Color.hover : "transparent"
                Text {anchors.centerIn:parent;text:"×";color:Color.muted;font.pixelSize:20}
                MouseArea {id:hideMouse;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor;onClicked:root.service.hidePreview(card.modelData)}
              }
            }
            DesktopThumbnail {
              id:frame
              anchors {top:header.bottom;left:parent.left;right:parent.right;bottom:parent.bottom;margins:Style.space(0.5)}
              socketPath:root.service.socketPath
              desktop:card.modelData
              // Hidden previews and the covered/off-screen portion never capture.
              active:shelf.visible && card.desktopState.available === true && !card.desktopState.humanLocked && card.y < shelfScroll.contentY + shelf.height && card.y + card.height > shelfScroll.contentY
            }
            Text {
              anchors.centerIn:frame
              visible:frame.error !== ""
              text:"预览暂不可用"
              color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize
            }
            MouseArea {
              anchors.fill:frame
              hoverEnabled:true
              cursorShape:Qt.PointingHandCursor
              onClicked:root.service.show(card.modelData)
            }
          }
        }
      }
    }
  }
  ShellIpc {
    target:"desktopPreviews"
    function status():string {
      const geometries=[]
      for(let i=0;i<cards.count;++i) geometries.push(cards.itemAt(i).geometry())
      return JSON.stringify({cards:geometries,output:shelf.screen ? shelf.screen.name : "",bounds:{x:shelf.screen ? shelf.screen.width-shelf.margins.right-shelf.width : 0,y:shelf.screen ? shelf.screen.height-shelf.margins.bottom-shelf.height : 0,width:shelf.width,height:shelf.height},visible:shelf.visible,desktops:root.previews.map(item => item.name),readonly:true})
    }
  }
}
