pragma Singleton
import QtQuick

// Owned temporary interactions explicitly hold hover popups. Token ownership
// makes nested interactions independent; callers release on every exit path.
QtObject {
  property var owners: ({})
  readonly property bool active: Object.keys(owners).length > 0
  function acquire(owner) {
    const next = Object.assign({}, owners); next[owner] = true; owners = next
  }
  function release(owner) {
    const next = Object.assign({}, owners); delete next[owner]; owners = next
  }
}
