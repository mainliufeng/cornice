import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Cornice.Platform
import qs.Commons

// One capture transaction per shell/desktop. Coordinates UI, native persistence
// and generic popup holds; contains no shell commands or image manipulation.
Item {
  id: root
  property var host: null
  property var plugin: null
  property bool active: false
  property bool selecting: false
  property bool saving: false
  property string mode: "region"
  property string destination: ""
  property string lastFile: ""
  property string error: ""
  property bool clipboardCopied: false
  property string message: ""
  property var noticeScreen: null
  property var targets: []
  property var readyOutputs: ({})
  readonly property string owner: "cn.screenshot"
  property bool compositorLocked: false
  readonly property bool locked: (!DesktopSession.agentShell && compositorLocked) || host && host.services["cn.lock"] && host.services["cn.lock"].secure === true
  function capture(mode, destination) {
    if (locked) return "locked"
    if (active) return "busy"
    if (mode !== "region" && mode !== "screen") return "invalid-mode"
    if (destination && !destination.startsWith("/")) return "absolute-path-required"
    const service = host ? host.services["cn.agent-desktop"] : null
    const privateOutputs = service ? service.desktops.filter(d => !d.primary).map(d => d.output) : []
    const screens = Quickshell.screens.filter(s => DesktopSession.agentShell ? s.name === DesktopSession.output : privateOutputs.indexOf(s.name) < 0)
    if (!screens.length) return "no-output"
    root.mode = mode; root.destination = destination; error = ""; readyOutputs = ({})
    clipboardCopied = false; message = ""; noticeTimer.stop()
    selecting = false; saving = false; InteractionState.acquire(owner); active = true; deadline.restart(); targets = screens
    return "requested"
  }
  function ready(name) {
    if (!active) return
    const next = Object.assign({}, readyOutputs); next[name] = true; readyOutputs = next
    if (targets.every(s => next[s.name])) {
      selecting = true; deadline.stop()
      if (mode === "screen") {
        const focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        const window = windows.instances.find(w => w.screen.name === focused) || windows.instances[0]
        if (window) Qt.callLater(() => { if(root.active) window.chooseScreen() })
      }
    }
  }
  function close() {
    exporter.cancel(); active = false; selecting = false; saving = false; deadline.stop()
    InteractionState.release(owner); targets = []; readyOutputs = ({})
  }
  function notice(text) { message = text; noticeTimer.restart() }
  function fail(reason) {
    error = reason; close(); console.warn("cornice screenshot: " + reason)
    if (!locked) notice("截图失败 · " + reason)
  }
  function save(window, frame, area, size) {
    if (!selecting || saving) return
    noticeScreen = window.screen; saving = true; deadline.restart()
    Qt.callLater(() => {if(root.active) exporter.save(frame,area,size,root.destination)})
  }
  onLockedChanged: if (locked) {if(active) close();message="";noticeTimer.stop()}
  Component.onDestruction: InteractionState.release(owner)
  Connections {
    target:Hyprland
    function onRawEvent(event) {
      if(event.name !== "sessionlock") return
      root.compositorLocked = event.data === "locked"
      if(root.compositorLocked && root.active) root.close()
    }
  }
  Connections {
    target:Quickshell
    function onScreensChanged() {
      if(root.active && root.targets.some(s => Quickshell.screens.indexOf(s) < 0)) root.close()
    }
  }
  ScreenshotController {
    id:exporter
    onSaved:path => {if(root.active) {root.lastFile=path;root.clipboardCopied=true;root.close();root.notice("截图已保存并复制到剪贴板")}}
    onFailed:reason => root.fail(reason)
  }
  Timer {id:deadline;interval:10000;onTriggered:root.fail("屏幕捕获超时")}
  Timer {id:noticeTimer;interval:3000;onTriggered:root.message=""}
  PanelWindow {
    screen:root.noticeScreen
    visible:root.message !== "" && !root.locked
    anchors {top:true;left:true;right:true}
    margins.top:Style.barHeight + Style.space(2)
    implicitHeight:Style.space(7)
    exclusionMode:ExclusionMode.Ignore;color:"transparent"
    WlrLayershell.layer:WlrLayer.Overlay
    WlrLayershell.namespace:"cornice-screenshot-notice"
    WlrLayershell.keyboardFocus:WlrKeyboardFocus.None
    mask:Region {item:emptyNotice}
    Item {id:emptyNotice;width:0;height:0}
    Rectangle {
      anchors.horizontalCenter:parent.horizontalCenter
      width:Math.min(parent.width - Style.space(4), label.implicitWidth + Style.space(4));height:parent.height
      radius:Style.radius;color:Color.panel;border.width:1;border.color:Color.surfaceBorder
      Text {id:label;anchors.centerIn:parent;text:root.message;color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.fontSize}
    }
  }
  Variants {
    id:windows;model:root.targets
    SelectionOverlay {
      id:overlay
      required property var modelData
      screen:modelData;visible:root.active
      interactive:root.selecting;saving:root.saving
      onFrameReady:root.ready(screen.name)
      onChosen:(frame,area,size) => root.save(overlay,frame,area,size)
      onCancelled:root.close()
      onCaptureFailed:if(root.active) root.fail("合成器结束了屏幕捕获")
    }
  }
  ShellIpc {
    target:"screenshot"
    function capture(mode:string, path:string):string {return root.capture(mode,path)}
    function cancel():string {root.close();return "ok"}
    function status():string {return JSON.stringify({active:root.active,selecting:root.selecting,saving:root.saving,outputs:root.targets.map(s=>s.name),lastFile:root.lastFile,clipboardCopied:root.clipboardCopied,message:root.message,error:root.error,interactionHeld:InteractionState.active})}
  }
}
