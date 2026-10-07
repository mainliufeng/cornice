pragma Singleton
import QtQuick
import Quickshell

// This is the human seat's adapter. Agent commands use desktopd exclusively.
QtObject {
  readonly property string helper: (Quickshell.env("CORNICE_PATH") || "/usr/share/cornice") + "/bin/cornice-compositor"
  function workspace(id) { Quickshell.execDetached([helper, "workspace", String(id)]) }
}
