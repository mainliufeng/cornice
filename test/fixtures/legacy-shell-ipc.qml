import QtQuick
import Quickshell
import Quickshell.Io
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
Item {
  id: root

  property string socketPath: ""

  readonly property bool listening: server.active && socketPath !== ""

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

  SocketServer {
    id: server

    active: root.socketPath !== ""
    path: root.socketPath

    handler: Component {
      Socket {
        id: connection

        parser: SplitParser {
          onRead: line => root.handle(connection, line)
        }
      }
    }
  }
}
