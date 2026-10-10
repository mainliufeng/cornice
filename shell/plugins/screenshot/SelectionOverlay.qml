import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

PanelWindow {
  id: root
  property bool interactive: false
  property bool saving: false
  signal frameReady()
  signal chosen(var frame, rect region, size sourceSize)
  signal cancelled()
  signal captureFailed()
  anchors {top:true;bottom:true;left:true;right:true}
  exclusionMode:ExclusionMode.Ignore;color:"transparent"
  WlrLayershell.layer:WlrLayer.Overlay
  WlrLayershell.namespace:"cornice-screenshot"
  WlrLayershell.keyboardFocus:interactive && !saving ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  mask:Region {item:root.interactive ? root.contentItem : emptyRegion}
  Item {id:emptyRegion;width:0;height:0}
  Connections {
    target:root.screen
    function onGeometryChanged() {if(root.interactive) root.cancelled()}
    function onPhysicalPixelDensityChanged() {if(root.interactive) root.cancelled()}
  }
  property rect selection:Qt.rect(0,0,0,0)
  property point origin:Qt.point(0,0)
  function chooseScreen() { chosen(frame, Qt.rect(0,0,width,height), copy.sourceSize) }
  Item {
    id:frame
    anchors.fill:parent
    // The mapped window is transparent until capture has finished. Decorations
    // are separate siblings and never appear in this item's exported pixels.
    opacity:root.interactive ? 1 : 0
    ScreencopyView {
      id:copy;anchors.fill:parent
      captureSource:root.screen;live:false;paintCursor:false
      onHasContentChanged:if(hasContent) root.frameReady()
      onStopped:if(!hasContent) root.captureFailed()
    }
  }
  Item {
    anchors.fill:parent;visible:root.interactive && !root.saving
    Rectangle {x:0;y:0;width:parent.width;height:root.selection.y;color:"#66000000"}
    Rectangle {x:0;y:root.selection.y;width:root.selection.x;height:root.selection.height;color:"#66000000"}
    Rectangle {x:root.selection.x+root.selection.width;y:root.selection.y;width:parent.width-x;height:root.selection.height;color:"#66000000"}
    Rectangle {x:0;y:root.selection.y+root.selection.height;width:parent.width;height:parent.height-y;color:"#66000000"}
    Rectangle {x:root.selection.x;y:root.selection.y;width:root.selection.width;height:root.selection.height;color:"transparent";border.width:1;border.color:"#ffffff"}
    Rectangle {
      anchors.horizontalCenter:parent.horizontalCenter;y:Style.barHeight+Style.space(3)
      width:hint.implicitWidth+Style.space(4);height:hint.implicitHeight+Style.space(2);radius:Style.radius;color:Color.panel
      Text {id:hint;anchors.centerIn:parent;text:"拖动选择截图区域 · Esc / 右键取消";color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.fontSize}
    }
    MouseArea {
      anchors.fill:parent;hoverEnabled:true;acceptedButtons:Qt.LeftButton|Qt.RightButton;cursorShape:Qt.CrossCursor;focus:root.interactive
      Keys.onEscapePressed:root.cancelled()
      onPressed:mouse => {
        if(mouse.button === Qt.RightButton) {root.cancelled();return}
        root.origin=Qt.point(mouse.x,mouse.y);root.selection=Qt.rect(mouse.x,mouse.y,0,0)
      }
      onPositionChanged:mouse => {
        if(!pressed) return
        const px=Math.max(0,Math.min(width,mouse.x));const py=Math.max(0,Math.min(height,mouse.y))
        root.selection=Qt.rect(Math.min(px,root.origin.x),Math.min(py,root.origin.y),Math.abs(px-root.origin.x),Math.abs(py-root.origin.y))
      }
      onReleased:mouse => {if(mouse.button === Qt.LeftButton && root.selection.width>=2 && root.selection.height>=2) root.chosen(frame,root.selection,copy.sourceSize)}
    }
  }
}
