pragma Singleton
import QtQuick

// Local to this Shell. Never publish application errors as session-wide
// notifications, or reinterpret an old result using the currently viewed seat.
QtObject {
  id: root
  property string detail: ""
  property string desktop: ""
  property string output: ""
  function show(message, sourceDesktop, sourceOutput) {
    detail = String(message || "")
    desktop = String(sourceDesktop || "")
    output = String(sourceOutput || "")
    expiry.restart()
  }
  function visibleFor(targetDesktop, targetOutput) {
    return detail !== "" && desktop !== "" && output !== ""
      && desktop === targetDesktop && output === targetOutput
  }
  function clear() { detail = ""; expiry.stop() }
  property Timer expiry: Timer { interval: 15000; onTriggered: root.clear() }
}
