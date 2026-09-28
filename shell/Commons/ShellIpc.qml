import QtQuick
import Quickshell.Io
import qs.Commons

// A command target, the way a plugin exposes one.
//
// Usage is identical to Quickshell's IpcHandler:
//
//   ShellIpc {
//     target: "osd"
//     function volume(): string { ...; return "ok" }
//   }
//
// The difference is registration: the handler also joins qs.Commons.IpcRegistry
// so the Cornice socket can reach it no matter when the plugin was loaded.
IpcHandler {
  id: handler

  Component.onCompleted: IpcRegistry.register(handler)
  Component.onDestruction: IpcRegistry.unregister(handler)
}
