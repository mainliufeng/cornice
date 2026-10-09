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
  property var drafts: ({})
  property var accepted: ({})
  property var submission: ({})
  property bool restoringDraft: false
  property int editorGeneration: 0
  readonly property var task: service && service.tasks[name] ? service.tasks[name] : ({phase:"idle"})
  function saveDraft(target, text) {
    if (!target) return
    drafts = Object.assign({}, drafts, {[target]:text})
  }
  function open(target) {
    saveDraft(name, editor.text)
    editorGeneration += 1
    restoringDraft = true; name = target; editor.text = String(drafts[target] || ""); restoringDraft = false
    error = ""; opened = true; Qt.callLater(() => editor.forceActiveFocus())
  }
  function updateTasks() {
    if (!service) return
    const records = Object.assign({}, accepted)
    for (const target of Object.keys(records)) {
      const record = Object.assign({}, records[target])
      const current = service.tasks[target]
      if (!current || current.runId !== record.runId) continue
      if (["failed", "needs_attention", "blocked"].includes(current.phase) && !record.failureSeen) {
        record.failureSeen = true
        if (!drafts[target]) saveDraft(target, record.text)
        if (name === target && editor.text === "") editor.text = String(drafts[target] || "")
      } else if (["running", "completed"].includes(current.phase) && !record.started) {
        record.started = true
        if (!opened && name === target && editor.text === record.text) editor.text = ""
        if (drafts[target] === record.text) saveDraft(target, "")
      }
      records[target] = record
    }
    accepted = records
  }
  Connections {target:root.service;function onTasksChanged() {root.updateTasks()}}
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
    submitted = editor.text.trim(); submission = {name:name,text:submitted,generation:editorGeneration}; error = ""
    saveDraft(name, editor.text); run.stdinEnabled = true; run.running = true
  }
  Process {
    id: run
    command: [root.service.prefix + "/bin/cornice-agent-runtime", "start", root.submission.name || root.name]
    property var reply: null
    property string replyError: ""
    stdinEnabled: true
    onStarted: { reply = null; replyError = ""; write(root.submission.text); stdinEnabled = false }
    stdout: StdioCollector { onStreamFinished: {try {run.reply = JSON.parse(text)} catch(e) {run.replyError = "任务启动结果无效，输入内容已保留。"}} }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") {
        try { run.replyError = String(JSON.parse(text).error || text.trim()) }
        catch(e) { run.replyError = text.trim() }
      }
    }
    onExited: code => {
      const currentEditor = root.name === root.submission.name && root.editorGeneration === root.submission.generation
      if (code === 0 && reply && reply.accepted === true && reply.started === true && reply.name === root.submission.name && reply.runId) {
        root.accepted = Object.assign({}, root.accepted, {[reply.name]:{runId:reply.runId,text:root.submission.text,started:false,failureSeen:false}})
        root.service.submissionResult(reply.name, "")
        if (currentEditor) root.opened = false
        root.updateTasks()
      } else {
        const message = replyError || "任务未能启动，输入内容已保留。"
        if (currentEditor) root.error = message
        if (root.service) root.service.submissionResult(root.submission.name, message)
      }
      if (root.service) root.service.refreshTasks()
    }
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
        id: editor; width:parent.width;height:150;wrapMode:TextEdit.Wrap
        onTextChanged:if (!root.restoringDraft) root.saveDraft(root.name, text)
        placeholderText:"描述希望 Agent 在这个桌面完成的任务…"
        placeholderTextColor:Color.muted
        color:Color.foreground; font.family:Style.fontFamily;font.pixelSize:Style.fontSize
        background: Rectangle {color:Color.background;radius:Style.radius;border.color:Color.surfaceBorder}
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Escape && !editor.inputMethodComposing) {root.opened = false;event.accepted = true}
          else if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {root.submit();event.accepted = true}
        }
      }
      Text {width:parent.width;wrapMode:Text.Wrap;text:root.error || (root.service ? root.service.taskError : "") || root.task.message || "接管时 Agent 会等待或中止；提交任务将启用 Agent 控制。";color:root.error || (root.service && root.service.taskError) || ["failed","needs_attention","blocked"].includes(root.task.phase) ? Color.urgent : Color.muted;font.family:Style.fontFamily;font.pixelSize:Style.smallFontSize}
      Row {spacing:Style.space(1)
        PanelButton {id:runButton;label:run.running ? "启动中…" : "运行 · Ctrl+Enter";enabled:!run.running && (editor.text.trim() !== "" || editor.preeditText !== "");onClicked:root.submit()}
        PanelButton {label:"关闭";onClicked:root.opened = false}
      }
    }
  }
}
