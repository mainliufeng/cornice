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
  property real offsetX:Style.space(2)
  property real offsetY:Style.space(2)
  function clampOffsets() {
    if (resizing) return
    offsetX = Math.max(0, Math.min(offsetX, Math.max(0, (shelf.screen ? shelf.screen.width : 1280) - shelfContent.width)))
    offsetY = Math.max(0, Math.min(offsetY, Math.max(0, (shelf.screen ? shelf.screen.height : 1080) - shelfContent.height - Style.barHeight)))
  }
  property bool dragging: false
  property bool resizing: false
  property point resizeOrigin:Qt.point(0,0)
  property real preferredWidth: 320
  property real cardHeight: 220
  property bool sizeLoaded: false
  function loadSize() {
    if (sizeLoaded || !service) return
    preferredWidth = Math.max(240, Math.min(1600, Number(service.options.previewWidth) || 320))
    cardHeight = Math.max(160, Math.min(1000, Number(service.options.previewCardHeight) || 220))
    sizeLoaded = true
  }
  onServiceChanged: loadSize()
  Component.onCompleted: {previewNames = previews.map(item => item.name);loadSize()}
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
    Connections {
      target:shelf.screen
      function onWidthChanged() {Qt.callLater(root.clampOffsets)}
      function onHeightChanged() {Qt.callLater(root.clampOffsets)}
    }
    visible:root.visibleHere && root.previews.length > 0
    // Keep the Wayland surface stationary during a drag. The input region
    // contains only the visible shelf; everything else passes through.
    anchors {top:true;left:true;right:true;bottom:true}
    mask: Region { item:shelfContent }
    exclusionMode:ExclusionMode.Ignore
    focusable:false
    color:"transparent"
    WlrLayershell.layer:WlrLayer.Overlay
    WlrLayershell.namespace:"cornice-desktop-previews"
    WlrLayershell.keyboardFocus:WlrKeyboardFocus.None
    Item {
      id:shelfContent
      x:root.resizing ? root.resizeOrigin.x : (shelf.screen ? shelf.screen.width : 1280)-width-root.offsetX
      y:root.resizing ? root.resizeOrigin.y : (shelf.screen ? shelf.screen.height : 1080)-height-root.offsetY
      width:Math.min(root.preferredWidth, shelf.screen ? shelf.screen.width : 1280)
      height:Math.max(0, Math.min(stack.implicitHeight, (shelf.screen ? shelf.screen.height : 1080) - Style.barHeight - Style.space(6)))
      onWidthChanged:Qt.callLater(root.clampOffsets)
      onHeightChanged:Qt.callLater(root.clampOffsets)
    Flickable {
      id:shelfScroll
      interactive:!root.dragging && !root.resizing
      anchors.fill:parent
      clip:true
      contentHeight:stack.implicitHeight
      boundsBehavior:Flickable.StopAtBounds
      Column {
        id:stack
        width:shelfContent.width
        spacing:Style.space(1)
        Repeater {
          id:cards
          model:root.previewNames
          delegate:Rectangle {
            id:card
            required property string modelData
            readonly property var desktopState:root.service.desktops.find(item => item.name === modelData) || ({})
            function geometry() {
              return {name:modelData,x:shelfContent.x,y:shelfContent.y+card.y-shelfScroll.contentY,
                width:width,height:height,frames:frame.frameCount,hasFrame:frame.hasFrame,invalidations:frame.invalidations,error:frame.error}
            }
            width:stack.width
            height:root.cardHeight
            radius:Style.radius
            color:Color.panel
            border.color:Color.muted
            Rectangle {
              id:header
              width:parent.width;height:40
              color:"transparent"
              MouseArea {
                anchors {left:parent.left;right:hide.left;top:parent.top;bottom:parent.bottom}
                property point pressPoint:Qt.point(0,0)
                property real startOffsetX:0
                property real startOffsetY:0
                preventStealing:true
                cursorShape:pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                onPressed:mouse => {
                  pressPoint=mapToItem(shelf.contentItem, mouse.x, mouse.y)
                  startOffsetX=root.offsetX;startOffsetY=root.offsetY
                  root.dragging=true
                }
                onReleased:root.dragging=false
                onCanceled:root.dragging=false
                onPositionChanged:mouse => {
                  if (!pressed) return
                  const point=mapToItem(shelf.contentItem, mouse.x, mouse.y)
                  root.offsetX=Math.max(0,Math.min((shelf.screen ? shelf.screen.width : 1280)-shelfContent.width,startOffsetX-(point.x-pressPoint.x)))
                  root.offsetY=Math.max(0,Math.min((shelf.screen ? shelf.screen.height : 1080)-shelfContent.height-Style.barHeight,startOffsetY-(point.y-pressPoint.y)))
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
              active:shelf.visible && card.desktopState.available === true && !card.desktopState.humanLocked && card.y < shelfScroll.contentY + shelfContent.height && card.y + card.height > shelfScroll.contentY
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
      // Resize in the stationary surface's coordinate system, just like drag.
      Rectangle {
        anchors {right:parent.right;bottom:parent.bottom}
        width:24;height:24;radius:Style.radius
        color:resizeMouse.containsMouse || root.resizing ? Color.hover : "transparent"
        Text {anchors.centerIn:parent;text:"◢";color:Color.muted;font.pixelSize:14}
        MouseArea {
          id:resizeMouse;anchors.fill:parent;hoverEnabled:true;preventStealing:true
          cursorShape:Qt.SizeFDiagCursor
          property point pressPoint:Qt.point(0,0)
          property real startWidth:0
          property real startHeight:0
          property real startLeft:0
          property real startTop:0
          onPressed:mouse => {
            pressPoint=mapToItem(shelf.contentItem,mouse.x,mouse.y)
            startWidth=root.preferredWidth;startHeight=root.cardHeight
            startLeft=shelfContent.x;startTop=shelfContent.y;root.resizeOrigin=Qt.point(startLeft,startTop);root.resizing=true
          }
          onPositionChanged:mouse => {
            if(!pressed) return
            const point=mapToItem(shelf.contentItem,mouse.x,mouse.y)
            root.preferredWidth=Math.max(240,Math.min(1600,(shelf.screen ? shelf.screen.width : 1280)-startLeft,startWidth+point.x-pressPoint.x))
            root.cardHeight=Math.max(160,Math.min(1000,startHeight+(point.y-pressPoint.y)/Math.max(1,root.previews.length)))
          }
          onReleased:Qt.callLater(() => {
            root.offsetX=Math.max(0,(shelf.screen ? shelf.screen.width : 1280)-shelfContent.width-startLeft)
            root.offsetY=Math.max(0,(shelf.screen ? shelf.screen.height : 1080)-shelfContent.height-startTop)
            root.resizing=false;root.clampOffsets();root.service.savePreviewSize(root.preferredWidth,root.cardHeight)
          })
          onCanceled:root.resizing=false
        }
      }
    }
  }
  ShellIpc {
    target:"desktopPreviews"
    function status():string {
      const geometries=[]
      for(let i=0;i<cards.count;++i) geometries.push(cards.itemAt(i).geometry())
      return JSON.stringify({cards:geometries,output:shelf.screen ? shelf.screen.name : "",bounds:{x:shelfContent.x,y:shelfContent.y,width:shelfContent.width,height:shelfContent.height},visible:shelf.visible,preferredWidth:root.preferredWidth,cardHeight:root.cardHeight,desktops:root.previews.map(item => item.name),readonly:true})
    }
  }
}
