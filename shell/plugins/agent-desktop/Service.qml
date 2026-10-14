import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Cornice.Desktop
import qs.Commons
import "."

Item {
  id: root
  property var host: null
  property var plugin: null
  readonly property var options: host && host.config ? host.config.agentDesktop || ({}) : ({})
  readonly property bool enabled: DesktopSession.agentShell || options.enabled === true
  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property string instance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
  DesktopPresentation { id: endpointResolver }
  readonly property var brokerEndpoint: endpointResolver.endpoint(instance)
  readonly property string socketPath: brokerEndpoint.socket || ""
  property string selectedDesktop: DesktopSession.name || "main"
  property var observer: null
  Component.onCompleted: { DesktopSession.service = root; refresh() }
  function show(name) {
    if (!host) return "unavailable"
    if (DesktopSession.agentShell) {
      runHelper([prefix + "/bin/cornice-agent-view", name], "查看桌面", name); return "requested"
    }
    host.hide("cn.agent-desktop")
    if (!name || name === "main") { selectedDesktop = "main"; return host.hide("cn.desktop-observer") }
    if (!available || !desktops.some(item => item.name === name)) {reportViewError(name,"桌面服务暂不可用，请重试或查看诊断。",false);return "desktop-unavailable"}
    return host.summon("cn.desktop-observer", {name: name})
  }
  function desktopLabel(name) {
    const desktop = desktops.find(item => item.name === name)
    const definition = (options.desktops || []).find(item => item.name === name)
    if (definition && definition.label) return definition.label
    if (desktop && desktop.label) return desktop.label
    if (!name || name === "main") return "桌面 1 · 主桌面"
    return String(name).replace(/^agent([0-9]+)(?:-[0-9a-f]{8})?$/, "Agent $1")
  }
  function stateLabel(desktop) {
    const prefix = desktop.occupied === true ? harnessLabel(desktop) + " · " : ""
    if (desktop.activity === "locked" || (desktop.humanLocked && !(desktop.lockScope === "human" && desktop.humanLockPolicy === "continue"))) return prefix + "已锁定"
    if (desktop.primary && desktop.controlMode === "human") return prefix + "人工控制"
    if (desktop.error || !desktop.available) return prefix + "不可用"
    if (desktop.controlMode === "human") return prefix + "人工接管"
    if (desktop.handoff && desktop.handoff.status === "requested") return prefix + "等待你处理"
    if (awaitingContinuation(desktop)) return prefix + "等待 Agent 继续"
    if (desktop.occupied === true) return prefix + (desktop.paused ? "桌面控制已暂停" : "操作中")
    return "空闲"
  }
  function awaitingContinuation(desktop) {
    return desktop.occupied === true && desktop.paused !== false && !!desktop.handoff
      && ["completed", "cancelled"].includes(desktop.handoff.status) && !desktop.handoff.restored && !desktop.handoff.resumeUnavailable
  }
  readonly property var humanRequests: desktops.filter(item => item.handoff && item.handoff.status === "requested")
  readonly property var cooperationDesktops: desktops.filter(item => item.handoff && (["requested", "in_progress"].includes(item.handoff.status) || awaitingContinuation(item)))
  // Notice visibility is local UI state. Hiding a request never resolves it or
  // changes the Broker's input permissions; its record stays in the bar menu.
  property var dismissedCooperationRequests: ({})
  property string dismissedCooperationError: ""
  readonly property var cooperationNotices: humanRequests.filter(item => !dismissedCooperationRequests[item.handoff.id])
  readonly property string cooperationErrorKey: error ? JSON.stringify({error:error,action:actionResult}) : ""
  readonly property string cooperationNoticeError: cooperationErrorKey !== dismissedCooperationError ? error : ""
  readonly property var cooperationMenuEntries: cooperationDesktops.reduce((items, desktop) => items.concat(handoffMenuEntries(desktop)), [])
  function dismissCooperationRequest(name, requestId) {
    const desktop=desktops.find(item => item.name === name)
    if (!desktop || !desktop.handoff || desktop.handoff.id !== requestId) return
    dismissedCooperationRequests=Object.assign({},dismissedCooperationRequests,{[requestId]:true})
  }
  function dismissCooperationNotice() {
    const hidden=Object.assign({},dismissedCooperationRequests)
    for (const desktop of cooperationNotices) hidden[desktop.handoff.id]=true
    dismissedCooperationRequests=hidden;dismissedCooperationError=cooperationErrorKey
  }
  function handoffMenuEntries(desktop) {
    const request=desktop.handoff, continuation=awaitingContinuation(desktop)
    const status=continuation ? "等待 Agent 继续" : handoffLabel(request.status)
    return [
      {key:"handoff-heading:"+request.id,kind:"section",scope:"cooperation",target:desktop.name,label:desktopLabel(desktop.name)+" · "+status,
        detail:request.title+"\n"+request.instructions+(continuation ? "\n"+continuationMessage(desktop) : ""),fullDetail:true,enabled:false},
      {key:"handoff:"+request.id,scope:"cooperation",target:desktop.name,icon:"󰥷",label:continuation ? "查看桌面" : request.status === "in_progress" ? "已完成，退出接管" : "接管并处理",
        enabled:!busy && !desktop.humanLocked,alert:request.status === "requested"}
    ]
  }
  function activateCooperation(requestId) {
    const desktop=cooperationDesktops.find(item => item.handoff.id === requestId)
    if (!desktop) return
    if (awaitingContinuation(desktop)) show(desktop.name)
    else if (desktop.handoff.status === "in_progress") completeHandoff(desktop.name,requestId)
    else if (desktop.handoff.status === "requested") startHandoff(desktop.name,requestId)
  }
  function continuationMessage(desktop) {
    const support = desktop.continuation || ({})
    if (support.message) return support.message
    return (support.eventWait ? "正在等待的 Agent 会收到处理结果。" : "人工处理结果已保存。") + "若 Agent 对话已停止，请在原对话回复继续；这里不会启动新的 Agent 任务。"
  }
  function diagnostics(desktop) {
    const diagnostic=desktop.diagnostics || []
    const items=Array.isArray(diagnostic) ? diagnostic : Object.values(diagnostic)
    return items.filter(Boolean).map(item => typeof item === "string" ? item : item.code === "input-compatibility" ? "支持原生 Wayland 鼠标和键盘；此桌面暂不支持 Xwayland、触屏、手写板和手势输入。" : item.message || item.title || item.code || "").filter(Boolean)
  }
  function toggleTakeover(name, enabled) {
    if (DesktopSession.agentShell) runHelper([prefix + "/bin/cornice", "ipc", "desktopObserver", "takeover", String(enabled)], enabled ? "接管桌面" : "结束接管", name)
    else if (observer) observer.takeControl(enabled)
  }
  function createDesktop() {
    const name="desktop-" + Date.now().toString(36)
    const primary=desktops.find(item => item.primary) || ({})
    const size=primary.pixelSize || [1920,1080]
    operate(["create",name,"--virtual-output",String(size[0])+"x"+String(size[1])],{openAfter:name})
  }
  function presentationFor(desktop) {
    return !DesktopSession.agentShell && observer && observer.desktopName === desktop.name ? observer.presentationState : desktop.presentation || ({})
  }
  function follow() {
    if (DesktopSession.agentShell) runHelper([prefix + "/bin/cornice", "ipc", "desktopObserver", "follow"], "恢复跟随", selectedDesktop)
    else if (observer) observer.follow()
  }
  function viewDescription(desktop) {
    if (desktop.primary) return "主桌面"
    if (desktop.controlMode === "human") return "人工接管"
    const presentation = presentationFor(desktop)
    if (presentation.active !== true) return "Agent 工作区 · WS " + (desktop.workspaceName || desktop.workspace || "?")
    return presentation.following === false ? "只读浏览 · WS " + (presentation.workspace || presentation.viewWorkspace || desktop.workspaceName || desktop.workspace || "?") : "只读跟随 Agent"
  }
  function handoffLabel(status) {
    return ({requested:"等待处理",in_progress:"处理中",completed:"已完成",cancelled:"已撤回"})[status] || status
  }
  function handoffNote(note) {
    return ({"Agent requested human assistance":"Agent 请求人工处理","Human took control":"已接管，开始处理","Human marked the task completed":"已完成人工步骤","Harness disconnected":"Agent 连接已断开","Desktop service restarted; request owner disconnected":"桌面服务重启，请求已撤回","Human control ended":"已退出接管","Desktop view changed":"已切换桌面，等待继续处理","Viewer disconnected":"观察连接已断开","Human control revoked":"接管已结束，等待继续处理","Session locked":"桌面已锁定，等待继续处理"})[note] || note || ""
  }
  property string pendingTakeover: ""
  property string pendingRequestId: ""
  function startHandoff(name, requestId) {
    const state = desktops.find(item => item.name === name)
    if (!state || !state.handoff || state.handoff.status !== "requested" || (requestId && requestId !== state.handoff.id)) return
    requestId=state.handoff.id
    dismissCooperationRequest(name,requestId)
    if (state.primary) {operate(["handoff-start",name,requestId]);return}
    if (DesktopSession.agentShell) {
      runHelper([prefix + "/bin/cornice-agent-view", name, "--handoff", requestId], "接管并处理", name);return
    }
    pendingRequestId=requestId;pendingTakeover=name;pendingTakeoverSince=Date.now();show(name)
  }
  property double pendingTakeoverSince: 0
  function checkPendingTakeover() {
    if (!pendingTakeover) return
    const state=desktops.find(item => item.name === pendingTakeover)
    if (!state || (pendingRequestId && (!state.handoff || state.handoff.id !== pendingRequestId || state.handoff.status !== "requested"))) {pendingTakeover="";return}
    if (observer && observer.desktopName === pendingTakeover && observer.presentationState.active) {
      observer.takeControl(true,pendingRequestId);pendingTakeover=""
    } else if (Date.now() - pendingTakeoverSince > 8000) {
      reportViewError(pendingTakeover, "桌面未能打开，请重试。", true, pendingRequestId);pendingTakeover=""
    }
  }
  function completeHandoff(name, requestId) {operate(["handoff-complete",name,requestId])}
  property var hiddenPreviews: ({})
  property bool previewsEnabled: true
  readonly property bool alwaysShowPreviews: options.alwaysShowPreviews === true
  readonly property bool previewModeBusy: previewModeWriter.running
  readonly property var previewDesktops: desktops.filter(item => !item.primary && (alwaysShowPreviews || item.occupied === true))
  readonly property bool allPreviewsVisible: previewsEnabled && previewDesktops.length > 0 && previewDesktops.every(item => hiddenPreviews[item.name] !== true)
  readonly property var activeDesktops: desktops.filter(item => !item.primary && item.occupied === true)
  function setPreviewMode(always) {
    if (previewModeWriter.running) return
    previewModeWriter.command = [prefix + "/bin/cornice", "previews", always ? "always" : "active"]
    previewModeWriter.running = true
  }
  Process {
    id: previewModeWriter
    stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.reportError("保存预览设置", "", text.trim()) }
    onExited: if (root.host) root.host.reloadUserConfig()
  }
  function harnessLabel(desktop) {
    const name = String(desktop.harness || "")
    return ({codex:"Codex",pi:"Pi"})[name.toLowerCase()] || name || "外部 Agent"
  }
  function savePreviewSize(width, height) {
    sizeWriter.command = [prefix + "/bin/cornice", "previews", "size", String(Math.round(width)), String(Math.round(height))]
    if (!sizeWriter.running) sizeWriter.running = true
  }
  Process {
    id:sizeWriter
    stderr:StdioCollector {onStreamFinished:if(text.trim()) root.reportError("保存预览设置", "", text.trim())}
    onExited:if(root.host) root.host.reloadUserConfig()
  }
  function previewVisible(name) { return previewsEnabled && hiddenPreviews[name] !== true }
  function hidePreview(name) { hiddenPreviews = Object.assign({}, hiddenPreviews, {[name]:true}) }
  function restorePreviews() { previewsEnabled = true; hiddenPreviews = ({}) }
  function hidePreviews() { previewsEnabled = false }
  function togglePreviews() { if (allPreviewsVisible) hidePreviews(); else restorePreviews() }
  Connections {
    target:Hyprland
    function onRawEvent(event) {
      if (["seatworkspace", "seatpresentation", "seatcontrol"].includes(event.name)) root.refresh()
    }
  }
  property bool available: false
  property var desktops: []
  property var workspaces: []
  property string healthError: ""
  property var actionResult: ({})
  readonly property string actionError: actionResult.error || ""
  readonly property string retryLabel: actionResult.retry && actionResult.retry.label ? actionResult.retry.label : actionResult.operation === "接管桌面" ? "重试接管" : actionResult.operation === "查看桌面" ? "重试查看" : "重试操作"
  readonly property string error: actionError || healthError
  property var pending: []
  property var currentAction: ({})
  property string pendingView: ""
  property var bootstrapped: ({})
  property var bootstrapFailures: ({})
  property var bootstrapPending: ({})
  property bool refreshPending: false
  readonly property bool busy: action.running || pending.length > 0

  function readableError(detail) {
    const text=String(detail || "操作未完成").replace(/^cornice:\s*/, "")
    if (/stale|changed|generation|no longer/i.test(text)) return "桌面状态已变化，请刷新后重试。"
    if (/locked|Unlock session/i.test(text)) return "桌面已锁定，当前操作不可用。"
    if (/Another viewer|another human|owns human/i.test(text)) return "这个桌面正在由另一个观察者接管，请先结束接管。"
    if (/permission|not allowed|agentAllowed|authorization|control required/i.test(text)) return "当前桌面没有操作权限，请检查桌面控制状态。"
    if (/Xwayland|unsupported|not support/i.test(text)) return "此应用或操作尚不支持当前桌面，请查看兼容诊断。"
    if (/no responding|not loaded|unavailable|socket|Connection|not running/i.test(text)) return "桌面服务暂不可用，请重试或查看诊断。"
    return text
  }
  function reportError(operation, desktop, detail, retry) {
    actionResult={operation:operation,desktop:desktop,error:readableError(detail),detail:String(detail),retry:retry || null,at:Date.now()}
    publishActionResult(actionResult)
  }
  // A desktop shell's operation notice belongs to the session. Forward only
  // diagnostic metadata, never control credentials or a delayed launch command.
  property var pendingReport:null
  property int reportAttempts:0
  function publishActionResult(result) {
    if (!DesktopSession.agentShell) return
    pendingReport={operation:result.operation,desktop:result.desktop,detail:String(result.detail || "").slice(0,16384),at:result.at,clear:result.clear === true}
    reportAttempts=0;pumpReport()
  }
  function pumpReport() {
    if (!pendingReport || resultPublisher.running || reportAttempts >= 3) return
    resultPublisher.payload=JSON.stringify(pendingReport)
    resultPublisher.command=[prefix+"/bin/cornice","ipc","desktopObserver","actionResult",resultPublisher.payload]
    reportAttempts++;resultPublisher.running=true
  }
  function acceptActionResult(json) {
    try {
      const result=JSON.parse(json)
      if (DesktopSession.agentShell || typeof result.operation !== "string" || typeof result.desktop !== "string" || typeof result.detail !== "string" || !Number.isFinite(result.at) || result.detail.length > 16384) return "invalid-result"
      if (actionResult.at && actionResult.at > result.at) return "outdated-result"
      if (result.clear) {
        if (actionResult.operation === result.operation && actionResult.desktop === result.desktop) actionResult=({})
      } else {
        actionResult={operation:result.operation,desktop:result.desktop,error:readableError(result.detail),detail:result.detail,at:result.at,
          retry:result.desktop ? {kind:"view",name:result.desktop,takeover:false,label:"查看桌面处理"} : null}
      }
      return "ok"
    } catch (e) {return "invalid-result"}
  }
  Process {
    id:resultPublisher
    property string payload:""
    onExited:(exitCode,exitStatus) => {
      if (exitCode === 0 && root.pendingReport && JSON.stringify(root.pendingReport) === payload) root.pendingReport=null
      if (exitCode === 0) root.pumpReport()
    }
  }
  function reportViewError(name, detail, takeover, requestId) {
    reportError(takeover ? "接管桌面" : "查看桌面",name,detail,{kind:"view",name:name,takeover:takeover,requestId:requestId || ""})
  }
  function dismissError() {
    if (actionResult.operation) publishActionResult({operation:actionResult.operation,desktop:actionResult.desktop,at:Date.now(),clear:true})
    actionResult=({})
  }
  function retryAction() {
    const retry=actionResult.retry
    if (!retry || busy) return
    if (retry.kind === "view") {
      if (retry.requestId) {startHandoff(retry.name,retry.requestId);return}
      show(retry.name)
      if (retry.takeover) {pendingRequestId="";pendingTakeover=retry.name;pendingTakeoverSince=Date.now()}
    } else if (retry.args) operate(retry.args,retry.meta)
    else if (retry.command) runHelper(retry.command,retry.operation,retry.desktop)
  }
  function refresh() {
    if (!enabled) return
    if (poll.running || action.running) { refreshPending = true; return }
    refreshPending = false
    poll.running = true
  }
  function operationLabel(args) {
    return ({create:"创建空桌面",remove:"删除桌面",reset:"重置桌面",resume:"恢复桌面控制",pause:"暂停桌面控制",launch:"启动应用","view-focus":"切换应用焦点","allow-agent":"修改桌面权限","handoff-start":"开始人工处理","handoff-complete":"完成人工步骤","view-workspace":"切换工作区"})[args[0]] || "桌面操作"
  }
  function operate(args, meta) {
    if (!enabled || instance === "") { reportError(operationLabel(args),args[1] || "","请先在当前会话启用多桌面功能。"); return }
    pending = pending.concat([{args:args,meta:meta || ({})}]); dispatch()
  }
  function runHelper(command, operation, desktop) {
    pending=pending.concat([{command:command,operation:operation,desktop:desktop}]);dispatch()
  }
  function dispatch() {
    if (action.running || pending.length === 0) return
    const next = pending.slice(); currentAction = next.shift(); pending = next
    action.command = currentAction.command || [prefix + "/bin/cornice-desktop", "--instance", instance].concat(currentAction.args)
    action.stderrText="";action.stdoutText=""
    action.running = true
  }
  function bootstrap() {
    const list = DesktopSession.agentShell ? [] : options.desktops || []
    for (const desktop of list) {
      const name=String(desktop.name || ""), definition=JSON.stringify(desktop)
      if (!name || bootstrapped[name] === definition || bootstrapPending[name]) continue
      // A confirmed existing desktop counts as initialized. Explicit deletion
      // after success stays deleted; failed creation never receives this mark.
      if (desktops.some(item => item.name === name)) {bootstrapped=Object.assign({},bootstrapped,{[name]:definition});continue}
      const failure=bootstrapFailures[name]
      if (failure && failure.definition === definition && (failure.attempts >= 3 || Date.now() < failure.nextAt)) continue
      bootstrapPending=Object.assign({},bootstrapPending,{[name]:true})
      operate(["create", name]
        .concat(desktop.initialWorkspace ? ["--workspace", String(desktop.initialWorkspace)] : [])
        .concat(desktop.output ? ["--output", String(desktop.output)] : ["--virtual-output", typeof desktop.virtualOutput === "object" ? String(desktop.virtualOutput.width || 1920) + "x" + String(desktop.virtualOutput.height || 1080) : String(desktop.virtualOutput || "1920x1080")])
        .concat(["--human-lock-policy", String(desktop.humanLockPolicy || "pause")]),{bootstrapName:name,definition:definition})
    }
  }
  function actionFinished(exitCode) {
    const item=currentAction, meta=item.meta || ({}), name=meta.bootstrapName
    if (name) {
      const inflight=Object.assign({},bootstrapPending);delete inflight[name];bootstrapPending=inflight
      if (exitCode === 0) {
        bootstrapped=Object.assign({},bootstrapped,{[name]:meta.definition})
        const failures=Object.assign({},bootstrapFailures);delete failures[name];bootstrapFailures=failures
      } else {
        const previous=bootstrapFailures[name], attempts=previous && previous.definition === meta.definition ? previous.attempts+1 : 1
        bootstrapFailures=Object.assign({},bootstrapFailures,{[name]:{definition:meta.definition,attempts:attempts,nextAt:Date.now()+5000*Math.pow(2,attempts-1)}})
      }
    }
    const operation=item.operation || operationLabel(item.args || []), desktop=item.desktop || (item.args || [])[1] || ""
    if (exitCode !== 0) reportError(operation,desktop,action.stderrText || action.stdoutText || "操作未完成",item.command ? {command:item.command,operation:operation,desktop:desktop} : {args:item.args,meta:meta})
    else if (actionResult.operation === operation && actionResult.desktop === desktop) dismissError()
    if (exitCode === 0 && meta.openAfter) pendingView=meta.openAfter
    currentAction=({});refresh();dispatch()
  }
  Process {
    id: daemon
    command: [root.prefix + "/bin/cornice-desktop", "--instance", root.instance, "ensure"]
    running: root.enabled && root.instance !== ""
    stderr: StdioCollector { onStreamFinished: if (text.trim()) root.healthError = root.readableError(text.trim()) }
  }
  SystemClock {
    enabled:root.enabled
    precision:SystemClock.Seconds
    onDateChanged:{root.refresh();root.checkPendingTakeover();root.pumpReport()}
  }
  Process {
    id: poll
    property string stderrText: ""
    command: [root.prefix + "/bin/cornice-desktop", "--instance", root.instance, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const result = JSON.parse(text)
          if (!Array.isArray(result.desktops)) throw new Error("Invalid desktop list")
          root.desktops = result.desktops.sort((a,b) => Number(a.number || 0) - Number(b.number || 0))
          root.workspaces = result.workspaces || []; root.available = true; root.healthError = ""; root.bootstrap();Qt.callLater(root.checkPendingTakeover)
          if (root.pendingView && root.desktops.some(item => item.name === root.pendingView)) {const name=root.pendingView;root.pendingView="";root.show(name)}
        } catch (e) { root.available = false; root.healthError = "无法读取桌面状态，请检查桌面服务。" }
      }
    }
    stderr: StdioCollector { onStreamFinished: if (text.trim()) {root.healthError=root.readableError(text.trim());root.available=false} }
    onExited: if (root.refreshPending) root.refresh()
  }
  Process {
    id: action
    property string stderrText: ""
    property string stdoutText: ""
    stdout: StdioCollector { onStreamFinished: action.stdoutText=text.trim() }
    stderr: StdioCollector { onStreamFinished: action.stderrText=text.trim() }
    onExited: (exitCode, exitStatus) => root.actionFinished(exitCode)
  }
  onEnabledChanged: {
    if (!enabled) { available = false; desktops = []; pending = []; refreshPending = false }
    else refresh()
  }
  ShellIpc {
    target: "desktop"
    function status(): string {
      return JSON.stringify({enabled: root.enabled, available: root.available, desktops: root.desktops,
        selected: root.selectedDesktop, active: root.activeDesktops.map(item => item.name), hiddenPreviews:root.hiddenPreviews, previewsEnabled:root.previewsEnabled, alwaysShowPreviews:root.alwaysShowPreviews, allPreviewsVisible:root.allPreviewsVisible,
        error: root.error, endpointError: root.brokerEndpoint.error || "", healthError:root.healthError, actionResult:root.actionResult, bootstrapFailures:root.bootstrapFailures, requests:root.humanRequests.map(item => item.name), socket: root.socketPath, busy: root.busy})
    }
    function handoffStart(name: string, requestId: string): string {root.startHandoff(name,requestId);return "requested"}
    function retry(): string {root.retryAction();return "requested"}
    function dismissError(): string {root.dismissError();return "ok"}
    function previewMode(mode: string): string { if (!["always", "active"].includes(mode)) return "invalid-mode"; root.setPreviewMode(mode === "always"); return "requested" }
    function restorePreviews(): string { root.restorePreviews(); return "ok" }
    function hidePreviews(): string { root.hidePreviews(); return "ok" }
    function hidePreview(name: string): string { root.hidePreview(name); return "ok" }
    function observe(name: string): string {
      if (!root.available) return "desktop-unavailable"
      return root.show(name)
    }
  }
}
