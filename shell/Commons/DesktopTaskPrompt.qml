import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
Item {
  id: root
  property var service: null
  property string name: ""
  property bool opened: false
  property string error: ""
  property string submitted: ""
  readonly property var task: service && service.tasks[name] ? service.tasks[name] : ({phase:"idle"})
  function open(target) { name = target; error = ""; opened = true; Qt.callLater(() => editor.forceActiveFocus()) }
  function draft() {
    const button = runButton.mapToItem(null, 0, 0)
    return {text:editor.text, preedit:editor.preeditText, focused:editor.activeFocus, submitted:submitted, error:error,
      run:{x:button.x,y:button.y,width:runButton.width,height:runButton.height}}
  }
  function submit() {
    if (run.running) return
    // Qt's commit() can turn unconfirmed pinyin into Latin preedit text. Let
    // the user choose the intended candidate instead of submitting it as-is.
    if (editor.inputMethodComposing) {
      error = "请先确认输入法候选词，再提交任务。"
      editor.forceActiveFocus(); return
    }
    if (editor.text.trim() === "") return
    submitted = editor.text.trim(); error = ""; run.stdinEnabled = true; run.running = true
  }
  Process {
    id: run
    command: [root.service.prefix + "/bin/cornice-agent-runtime", "start", root.name]
    stdinEnabled: true
    onStarted: { write(root.submitted); stdinEnabled = false }
    stderr: StdioCollector { onStreamFinished: root.error = text.trim() }
    onExited: code => { if (code === 0) { root.opened = false; editor.text = "" } }
  }
  PanelWindow {
    id: window; visible: root.opened
    implicitWidth: Math.min(720, screen ? screen.width - 48 : 720); implicitHeight: 360
    color: Color.panel; exclusiveZone: 0; focusable: true
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cornice-agent-prompt"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    Column {
      anchors.fill: parent; anchors.margins: Style.space(3); spacing: Style.space(1.5)
      Text { text: root.service ? root.service.desktopLabel(root.name) + " · 新任务" : "新任务"; color:Color.foreground;font.family:Style.fontFamily;font.pixelSize:Style.largeFontSize }
      Text { text: "默认模型 · " + (root.service ? root.service.modelConfig.model || "未配置" : "");color:Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize }
      TextArea {
        id: editor; width:parent.width;height:150;wrapMode:TextEdit.Wrap;placeholderText:"描述希望 Agent 在这个桌面完成的任务…"
        placeholderTextColor:Color.muted
        color:Color.foreground; font.family:Style.fontFamily;font.pixelSize:Style.fontSize
        background: Rectangle {color:Color.background;radius:Style.radius;border.color:Color.surfaceBorder}
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Escape && !editor.inputMethodComposing) {root.opened = false;event.accepted = true}
          else if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {root.submit();event.accepted = true}
        }
      }
      Text {width:parent.width;wrapMode:Text.Wrap;text:root.error || root.task.message || "接管时 Agent 会等待或中止；提交任务将启用 Agent 控制。";color:root.error ? Color.urgent : Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
      Row {spacing:Style.space(1)
        PanelButton {id:runButton;label:run.running ? "启动中…" : "运行 · Ctrl+Enter";enabled:!run.running && (editor.text.trim() !== "" || editor.preeditText !== "");onClicked:root.submit()}
        PanelButton {label:"关闭";onClicked:root.opened = false}
      }
    }
  }
}
