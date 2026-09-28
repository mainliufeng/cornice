pragma Singleton
import QtQuick

// Registry of every ShellIpc handler in the shell.
//
// Quickshell's own `qs ipc` only sees handlers that exist in the statically
// declared tree, so a handler inside a plugin loaded at runtime never shows up
// there. The shell therefore serves its own socket (see services/IpcServer) and
// dispatches through this registry, which sees every handler as it is created.
QtObject {
  id: root

  property var handlers: []

  function register(handler) {
    if (!handler) return
    if (handlers.indexOf(handler) !== -1) return
    handlers = handlers.concat([handler])
  }

  function unregister(handler) {
    handlers = handlers.filter(entry => entry !== handler)
  }

  function handlerFor(target) {
    for (const handler of handlers) {
      if (handler && handler !== null && handler.enabled !== false && handler.target === target) return handler
    }
    return null
  }

  function targets() {
    const out = []
    for (const handler of handlers) {
      if (handler && handler.enabled !== false && out.indexOf(handler.target) === -1) out.push(handler.target)
    }
    return out
  }

  function methods(target) {
    const handler = handlerFor(target)
    if (!handler) return []
    const out = []
    for (const key in handler) if (typeof handler[key] === "function") out.push(key)
    return out
  }

  // { ok: true, result } | { ok: false, error }
  function dispatch(target, method, args) {
    const handler = handlerFor(target)
    if (!handler) return { ok: false, error: "unknown target: " + target }

    const fn = handler[method]
    if (typeof fn !== "function") return { ok: false, error: "unknown method: " + target + "." + method }

    // Pad to the declared arity: a typed QML parameter rejects undefined.
    const arity = fn.length
    const padded = []
    for (let i = 0; i < arity; i++) {
      const value = args ? args[i] : undefined
      padded.push(value === undefined || value === null ? "" : String(value))
    }

    try {
      const result = fn.apply(handler, padded)
      return { ok: true, result: result === undefined ? "ok" : String(result) }
    } catch (e) {
      return { ok: false, error: String(e) }
    }
  }
}
