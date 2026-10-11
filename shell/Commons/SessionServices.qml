pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// One owner per session daemon; secondary shells share state over the existing
// shell IPC socket. The lifecycle and RPC target scope use the same declaration.
Item {
  id: root
  visible: false
  property var host: null
  readonly property bool secondary: (Quickshell.env("CORNICE_DESKTOP_NAME") || "") !== ""
  readonly property string prefix: Quickshell.env("CORNICE_PATH") || "/usr/share/cornice"
  readonly property string configuredPrimarySocket: Quickshell.env("CORNICE_PRIMARY_SHELL_SOCKET") || ""
  property string resolvedPrimarySocket: ""
  readonly property string primarySocket: configuredPrimarySocket || resolvedPrimarySocket
  property bool endpointResolved: configuredPrimarySocket !== ""
  property var declarations: []
  property bool metadataReady: false
  property string metadataError: ""
  property var states: ({})
  property var watched: []
  property var pending: null
  property var queue: []
  property double requestDeadline: 0
  readonly property bool connected: connection !== null && connection.connected
  property bool reconnecting: false
  readonly property var connection: connectionLoader.item
  property string error: ""
  property string operationError: ""

  function declaration(id) { return declarations.find(item => item.id === id) || null }
  function sessionOwned(id) { const entry = declaration(id); return entry !== null && entry.scope === "session" }
  function owns(id) { return !secondary || !sessionOwned(id) }
  function watch(id) {
    if (watched.indexOf(id) === -1) watched = watched.concat([id])
    if (secondary) Qt.callLater(root.refresh)
  }
  function state(id) { return states[id] || ({available:false,error:error || "Service state is not available",snapshot:({})}) }
  function localSnapshot() {
    const result = ({})
    for (const entry of declarations) {
      if (entry.scope !== "session") continue
      const service = host ? host.service(entry.id) : null
      if (!service) result[entry.id] = {available:false,error:"Service is not running",snapshot:({})}
      else if (typeof service.sessionSnapshot === "function") {
        try { result[entry.id] = {available:true,error:"",snapshot:service.sessionSnapshot()} }
        catch (failure) { result[entry.id] = {available:false,error:String(failure),snapshot:({})} }
      } else result[entry.id] = {available:true,error:"",snapshot:({})}
    }
    return result
  }
  function fail(message) {
    error = String(message)
    if (pending && pending.method !== "snapshot") operationError = error
    pending = null
    queue = [] // Never replay a mutation after reconnecting.
    requestTimeout.stop()
    const next = ({})
    for (const id of Object.keys(states)) next[id] = {available:false,error:error,snapshot:states[id].snapshot || ({})}
    states = next
  }
  function submit(method, args) {
    if (!secondary || !connection || !connection.connected || primarySocket === "") return false
    queue = queue.concat([{method:method,args:args}]); drain(); return true
  }
  function drain() {
    if (pending || !connection || !connection.connected || queue.length === 0) return
    pending = queue[0]; queue = queue.slice(1)
    connection.write(JSON.stringify({target:"sessionServices",method:pending.method,args:pending.args}) + "\n")
    connection.flush(); requestDeadline = Date.now() + 2500; requestTimeout.restart()
  }
  function refresh() {
    if (!secondary || !endpointResolved || watched.length === 0 || pending || queue.length > 0) return
    if (!connection || !connection.connected) {
      if (primarySocket === "") fail("Primary shell endpoint is missing")
      else reconnect()
      return
    }
    submit("snapshot", [])
  }
  function reconnect() {
    if (reconnecting) return
    reconnecting = true
    Qt.callLater(function() { root.reconnecting = false })
  }
  onPrimarySocketChanged: if (secondary) reconnect()
  function invoke(id, target, method, args) {
    const entry = declaration(id)
    if (!entry || entry.scope !== "session" || (entry.targets || []).indexOf(target) === -1) return false
    if (!secondary) {
      const reply = IpcRegistry.dispatch(target, method, args || [])
      operationError = reply.ok ? "" : reply.error; return reply.ok
    }
    if (!state(id).available || !connected) {
      operationError = state(id).error || "Session service is unavailable"; return false
    }
    operationError = ""
    return submit("invoke", [id,target,method,JSON.stringify(args || [])])
  }
  function accept(line) {
    if (!pending) return
    const request = pending; pending = null; requestTimeout.stop()
    try {
      const reply = JSON.parse(String(line))
      if (!reply.ok) throw new Error(reply.error || "Session service request failed")
      const payload = JSON.parse(reply.result)
      if (payload.ok === false) operationError = String(payload.error || "Session service operation failed")
      else if (request.method !== "snapshot") operationError = ""
      states = payload.states || ({}); error = ""
    } catch (failure) { fail(failure) }
    drain()
  }
  FileView {
    path: root.prefix + "/config/session-services.json"
    printErrors: false
    onLoaded: {
      try {
        const document = JSON.parse(text())
        if (!Array.isArray(document.services)) throw new Error("Missing services declaration")
        const seen = ({})
        const targets = ({})
        for (const entry of document.services) {
          if (typeof entry.id !== "string" || !entry.id || seen[entry.id] || ["session","desktop"].indexOf(entry.scope) === -1 || !Array.isArray(entry.targets))
            throw new Error("Invalid session service declaration")
          seen[entry.id] = true
          for (const target of entry.targets) {
            if (typeof target !== "string" || target === "" || targets[target])
              throw new Error("Duplicate or invalid session service target")
            targets[target] = true
          }
        }
        root.declarations = document.services; root.metadataReady = true
      } catch (failure) { root.metadataError = String(failure) }
    }
    onLoadFailed: root.metadataError = "Cannot load session service declarations"
  }
  // Reuse the CLI's endpoint resolution for old Brokers and custom sockets.
  // This is a read-only operation, not an IPC discovery or alternate server.
  Process {
    id: resolveEndpoint
    command: [root.prefix + "/bin/cornice", "path", "--json"]
    running: root.secondary && root.configuredPrimarySocket === ""
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const endpoint = JSON.parse(text).primarySocket
          if (typeof endpoint !== "string" || endpoint.charAt(0) !== "/") throw new Error("Invalid primary shell endpoint")
          root.resolvedPrimarySocket = endpoint; root.endpointResolved = true
          Qt.callLater(root.refresh)
        } catch (failure) { root.fail(failure) }
      }
    }
  }
  Loader {
    id: connectionLoader
    active: root.secondary && root.endpointResolved && root.watched.length > 0 && !root.reconnecting
    sourceComponent: Component {
      Socket {
        id: socket
        path: root.primarySocket
        Component.onCompleted: socket.connected = true
        onConnectionStateChanged: {
          if (socket.connected) { root.error = ""; Qt.callLater(root.refresh) }
          else if (root.connection === socket) root.fail("Primary shell connection closed")
        }
        onError: failure => root.fail("Primary shell connection failed (" + failure + ")")
        parser: SplitParser { onRead: line => root.accept(line) }
      }
    }
  }
  // SystemClock uses a wall-clock timer. QtQuick animation timers can stop
  // when an offscreen desktop has no frame callbacks; service health and IPC
  // deadlines must continue even when that desktop is not being presented.
  SystemClock {
    enabled: root.secondary && root.metadataReady && root.watched.length > 0
    precision: SystemClock.Seconds
    onDateChanged: {
      if (root.pending && Date.now() >= root.requestDeadline) {
        root.fail("Session service request timed out"); root.reconnect()
      }
      if (root.configuredPrimarySocket === "" && !root.connected && !resolveEndpoint.running)
        resolveEndpoint.running = true
      root.refresh()
    }
  }
  Timer {
    id: requestTimeout
    interval: 2500
    onTriggered: { root.fail("Session service request timed out"); root.reconnect() }
  }
  // A native shortcut does not inherit Broker variables. Publish the primary
  // endpoint for this compositor atomically, including configured custom paths.
  Process {
    command: ["python3","-c",
      "import hashlib,json,os,pathlib,sys,tempfile; " +
      "d=pathlib.Path(sys.argv[1]); p=d/('cs-'+hashlib.sha256(sys.argv[2].encode()).hexdigest()[:8]+'-session.json'); " +
      "fd,t=tempfile.mkstemp(prefix=p.name+'.',dir=d); os.fchmod(fd,0o600); " +
      "f=os.fdopen(fd,'w'); json.dump({'socket':sys.argv[3],'pid':int(sys.argv[4])},f); f.close(); os.replace(t,p)",
      Quickshell.env("XDG_RUNTIME_DIR") || "/tmp", Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
      root.host ? root.host.socketPath : "", String(Quickshell.processId)]
    running: !root.secondary && root.host !== null && (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""
    onExited: (code, status) => { if (code !== 0) root.metadataError = "Cannot publish primary shell endpoint" }
  }
  ShellIpc {
    target: "sessionServices"
    function snapshot(): string {
      if (root.secondary) return JSON.stringify({ok:false,error:"Session services belong to the primary shell"})
      return JSON.stringify({ok:true,states:root.localSnapshot()})
    }
    function invoke(id: string, target: string, method: string, args: string): string {
      if (root.secondary) return JSON.stringify({ok:false,error:"Session services belong to the primary shell"})
      const entry = root.declaration(id)
      if (!entry || entry.scope !== "session" || (entry.targets || []).indexOf(target) === -1)
        return JSON.stringify({ok:false,error:"Target is not a declared session service"})
      let values = null
      try { values = JSON.parse(args) } catch (failure) { return JSON.stringify({ok:false,error:"Invalid service arguments"}) }
      if (!Array.isArray(values)) return JSON.stringify({ok:false,error:"Service arguments must be an array"})
      const result = IpcRegistry.dispatch(target,method,values)
      return JSON.stringify({ok:result.ok,error:result.error || "",result:result.result || "",states:root.localSnapshot()})
    }
    function status(): string {
      return JSON.stringify({secondary:root.secondary,ready:root.metadataReady,connected:root.connected,
        primarySocket:root.primarySocket,endpointResolved:root.endpointResolved,
        error:root.error || root.metadataError,operationError:root.operationError,watched:root.watched,states:root.secondary ? root.states : root.localSnapshot()})
    }
  }
}
