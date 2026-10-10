import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Owns one recorder per desktop shell. The encoding backend has no UI.
Item {
  id: root
  property var host: null
  property var plugin: null
  property string state: "idle"
  readonly property bool active: state !== "idle"
  property string output: ""
  property string file: ""
  property string lastFile: ""
  property string error: ""
  property string diagnostics: ""
  property double startedAt: 0
  property int seconds: 0
  property string message: ""
  property var noticeScreen: null
  property bool compositorLocked: false
  readonly property bool locked: compositorLocked || !!(host && host.services["cn.lock"] && host.services["cn.lock"].secure)
  readonly property var settings: host && host.config ? Util.option(host.config, "recording", ({})) : ({})
  readonly property string directory: {
    const value = String(Util.option(settings, "directory", "~/Videos/Cornice"))
    return value.startsWith("~/") ? Quickshell.env("HOME") + value.slice(1) : value
  }
  function start(name) {
    if (locked) return "locked"
    if (active) return "busy"
    if (!directory.startsWith("/")) return "absolute-directory-required"
    const screen = Quickshell.screens.find(s => s.name === name)
    if (!screen) return "no-output"
    const service = host ? host.services["cn.agent-desktop"] : null
    if (DesktopSession.agentShell ? name !== DesktopSession.output
      : service && service.desktops.some(d => !d.primary && d.output === name)) return "wrong-desktop-output"
    noticeScreen = screen; output = name
    file = directory + "/Recording-" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss-zzz") + "-" + name.replace(/[^A-Za-z0-9_-]/g, "_") + ".mp4"
    error = ""; diagnostics = ""; message = ""; seconds = 0; state = "starting"
    prepare.command = ["mkdir", "-p", "-m", "700", "--", directory]
    prepare.running = true; deadline.restart()
    return "requested"
  }
  function stop() {
    if (!active) return "idle"
    if (state === "stopping" || state === "saving") return state
    if (state === "starting" && !recorder.running) {
      prepare.running = false; state = "idle"; deadline.stop(); return "cancelled"
    }
    state = "stopping"; recorder.signal(2); deadline.restart()
    return "requested"
  }
  function fail(reason) {
    error = reason; state = "idle"; deadline.stop(); tick.stop()
    if (!locked) notice(I18n.t("recording.failed") + " · " + reason)
  }
  function notice(text) {message = text; noticeTimer.restart()}
  function status() {return JSON.stringify({state:state,active:active,output:output,file:file,lastFile:lastFile,seconds:seconds,error:error})}
  onLockedChanged: if (locked) {stop(); message = ""; noticeTimer.stop()}
  Component.onDestruction: if (recorder.running) recorder.signal(2)
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "sessionlock") root.compositorLocked = event.data === "locked"
    }
  }
  Connections {
    target: Quickshell
    function onScreensChanged() {if (root.active && !Quickshell.screens.some(s => s.name === root.output)) root.stop()}
  }
  Process {
    id: prepare
    onExited: (code, status) => {
      if (root.state !== "starting") return
      if (code !== 0) {root.fail(I18n.t("recording.directoryFailed")); return}
      if (root.locked) {root.state = "idle"; deadline.stop(); return}
      recorder.command = ["sh", "-c", 'umask 077; exec wf-recorder "$@"', "cornice-record",
        "--output", root.output, "--file", root.file, "--codec", "libx264", "--pixel-format", "yuv420p",
        "--framerate", "30", "--codec-param", "preset=ultrafast", "--codec-param", "crf=23"]
      recorder.running = true
    }
  }
  Process {
    id: recorder
    environment: ({PATH: Quickshell.env("HOME") + "/.local/bin:" + Quickshell.env("PATH")})
    stderr: SplitParser {onRead: data => root.diagnostics = (root.diagnostics + data + "\n").slice(-1500)}
    onStarted: {
      root.startedAt = Date.now(); root.seconds = 0; root.state = "recording"
      deadline.stop(); tick.start()
    }
    onExited: (code, status) => {
      deadline.stop(); killDeadline.stop(); tick.stop()
      if (root.error !== "") {root.fail(root.error); return}
      if (code !== 0) {root.fail(root.diagnostics.trim() || I18n.t("recording.backendFailed")); return}
      root.state = "saving"; verify.command = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", root.file]
      verify.running = true; deadline.restart()
    }
  }
  Process {
    id: verify
    stdout: StdioCollector {id: verifyOutput}
    onExited: (code, status) => {
      deadline.stop()
      if (code !== 0 || verifyOutput.text.trim() !== "h264") {root.fail(I18n.t("recording.invalidVideo")); return}
      root.lastFile = root.file; root.state = "idle"
      if (!root.locked) root.notice(I18n.t("recording.saved") + " · " + root.lastFile)
    }
  }
  Timer {id: tick; interval: 1000; repeat: true; onTriggered: root.seconds = Math.floor((Date.now() - root.startedAt) / 1000)}
  Timer {
    id: deadline; interval: 15000
    onTriggered: {
      root.error = I18n.t("recording.timeout")
      prepare.running = false; verify.running = false
      if (recorder.running) {root.state = "stopping"; recorder.signal(15); killDeadline.restart()}
      else root.fail(root.error)
    }
  }
  Timer {id: killDeadline; interval: 2000; onTriggered: if (recorder.running) recorder.signal(9)}
  Timer {id: noticeTimer; interval: 6000; onTriggered: root.message = ""}
  PanelWindow {
    screen: root.noticeScreen
    visible: root.message !== "" && !root.locked
    anchors {top:true;left:true;right:true}
    margins.top: Style.barHeight + Style.space(2)
    implicitHeight: Style.space(7); exclusionMode: ExclusionMode.Ignore; color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-recording-notice"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {item: emptyNotice}
    Item {id: emptyNotice; width: 0; height: 0}
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width - Style.space(4), label.implicitWidth + Style.space(4)); height: parent.height
      radius: Style.radius; color: Color.panel; border.width: 1; border.color: Color.surfaceBorder
      Text {id: label; anchors.fill: parent; anchors.margins: Style.space(1); text: root.message; elide: Text.ElideMiddle; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: Color.foreground; font.family: Style.fontFamily; font.pixelSize: Style.fontSize}
    }
  }
  ShellIpc {
    target: "recording"
    function start(output:string):string {return root.start(output)}
    function stop():string {return root.stop()}
    function status():string {return root.status()}
  }
}
