pragma Singleton
import QtQuick
import Quickshell

// Small, dependency-free helpers shared by every plugin.
QtObject {
  id: root

  // Recursive merge of plain objects; `override` wins. Arrays are replaced,
  // not concatenated — a bar layout is a list, not a set.
  function deepMerge(base, override) {
    if (!isPlainObject(base)) return clone(override)
    if (!isPlainObject(override)) return clone(base)

    const out = clone(base)
    for (const key in override) {
      const value = override[key]
      if (isPlainObject(value) && isPlainObject(out[key]))
        out[key] = deepMerge(out[key], value)
      else
        out[key] = clone(value)
    }
    return out
  }

  function isPlainObject(value) {
    return !!value && typeof value === "object" && !Array.isArray(value)
  }

  // Shallow copy for maps that hold live QML objects (plugin instances,
  // services). Never deep-copy those: enumerating a QObject walks parent and
  // children, which recurses until the stack dies.
  function shallow(object) {
    const out = {}
    if (!object) return out
    for (const key in object) out[key] = object[key]
    return out
  }

  function clone(value) {
    if (Array.isArray(value)) return value.map(clone)
    if (isPlainObject(value)) {
      const out = {}
      for (const key in value) out[key] = clone(value[key])
      return out
    }
    return value
  }

  // Quickshell object models expose `.values`; plain JS arrays do not.
  function list(model) {
    if (!model) return []
    if (Array.isArray(model)) return model
    if (model.values !== undefined) return model.values
    const out = []
    for (let i = 0; i < model.length; i++) out.push(model[i])
    return out
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value))
  }

  function pad2(value) {
    return value < 10 ? "0" + value : String(value)
  }

  function has(object, key) {
    return !!object && object[key] !== undefined && object[key] !== null
  }

  function option(object, key, fallback) {
    return has(object, key) ? object[key] : fallback
  }

  // Single-quote a value for a shell command line, so a city or a name with a
  // space (or an apostrophe) survives the trip through `sh -c`.
  function shellQuote(value) {
    const text = (value === undefined || value === null) ? "" : String(value)
    return "'" + text.replace(/'/g, "'\\''") + "'"
  }

  function exec(command) {
    Quickshell.execDetached(["sh", "-c", command])
  }
}
