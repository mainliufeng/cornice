import QtQuick
import Quickshell
import Cornice.Platform
import qs.Commons

// The shell's own IPC socket.
//
// Requests are one JSON object per line:
//   {"target":"osd","method":"show","args":["volume","0.4",""]}
// Responses are one JSON object per line:
//   {"ok":true,"result":"ok"} | {"ok":false,"error":"unknown target: osd"}
//
// This exists because Quickshell's built-in IPC only enumerates handlers in the
// statically declared tree; plugins are loaded at runtime, so they would be
// unreachable. Going through our own socket also skips spawning a `qs ipc`
// client per call.
Scope {
  id: root
  reloadableId: "cornice-shell-ipc-scope"

  property string socketPath: ""
  property bool reloadPrepared: false

  // The caller invokes this only after its IPC reply has been flushed. Stop
  // accepting before a replacement (including an older shell) binds this path.
  function prepareReload() { root.reloadPrepared = true }
  function resumeReload() { root.reloadPrepared = false }
  function finishReload() {
    root.reloadPrepared = true
    root.reloadPrepared = false
  }

  Connections {
    target: Quickshell
    function onReloadCompleted() {
      // Reopen only after the previous QML generation has been dropped. The
      // native transport frees disconnected clients instead of retaining all
      // historical connections until this listener closes.
      Qt.callLater(root.finishReload)
    }
    function onReloadFailed(error) { root.resumeReload() }
  }

  readonly property bool listening: server.listening && socketPath !== ""

  function handle(socket, line) {
    const text = String(line).trim()
    if (text === "") return

    let request = null
    try {
      request = JSON.parse(text)
    } catch (e) {
      respond(socket, { ok: false, error: "malformed request" })
      return
    }

    if (!request || !request.target || !request.method) {
      respond(socket, { ok: false, error: "request needs target and method" })
      return
    }

    respond(socket, IpcRegistry.dispatch(String(request.target), String(request.method), request.args || []))
  }

  function respond(socket, payload) {
    if (!socket) return
    socket.write(JSON.stringify(payload) + "\n")
    socket.flush()
  }

  LocalIpcServer {
    id: server
    active: root.socketPath !== "" && !root.reloadPrepared
    path: root.socketPath
    onRequest: (connection, line) => root.handle(connection, line)
  }
}
