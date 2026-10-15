#!/usr/bin/env python3
"""Real Shell callbacks with a stub routing command and no desktop connection."""
from pathlib import Path
import resource
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="cornice-feedback-shell-") as directory:
    temporary = Path(directory)
    (temporary / "runtime").mkdir(mode=0o700)
    (temporary / "bin").mkdir()
    (temporary / "Commons").symlink_to(ROOT / "shell/Commons", target_is_directory=True)
    fixture = temporary / "bin/hyprctl"
    fixture.write_text('''#!/usr/bin/python3
import json,sys
if 'route-context' in sys.argv:
    print(json.dumps({} if sys.argv[-1]=='invalid-output' else {'context':'fixture-context','token':'fixture-token'}))
elif 'activeworkspace' in sys.argv: print('{"name":"1"}')
else: print('[]')
''')
    fixture.chmod(0o700)
    (temporary / "shell.qml").write_text('''import QtQuick
import Quickshell
import qs.Commons
ShellRoot {
  QtObject { id: service; property string selectedDesktop: "main"; property var desktops: [] }
  property int failureCount: 0
  function require(ok, message) { if (!ok) { console.error("FAIL " + message); Qt.exit(1) } }
  Timer { interval: 100; running: true; onTriggered: {
    DesktopSession.service = service
    DesktopSession.primaryMonitors = [{name:"source-output", activeWorkspace:{name:"1"}}]
    require(DesktopSession.trayAction(null, "Activate", null, null, 0, false, "source-output"), "tray request accepted")
    service.selectedDesktop = "B"
    trayCheck.start()
  } }
  Timer { id: trayCheck; interval: 250; onTriggered: {
    require(ActionFeedback.detail === "Tray item has no exact routable handle", "failure without caller callback is reported")
    require(ActionFeedback.visibleFor("main", "source-output"), "source was captured before view switch")
    require(!ActionFeedback.visibleFor("B", "source-output"), "notice never follows the new view")
    require(Object.keys(DesktopSession.trayCallbacks).length === 0, "tray callbacks drained")
    console.log("PASS real asynchronous tray failure keeps its captured source without a caller callback")
    service.selectedDesktop = "main"
    DesktopSession.primaryMonitors = [{name:"invalid-output", activeWorkspace:{name:"1"}}]
    require(DesktopSession.withAction(() => require(false, "invalid preparation dispatched"),
      () => failureCount++, "invalid-output"), "preparation request accepted")
    sourceCheck.start()
  } }
  Timer { id: sourceCheck; interval: 250; onTriggered: {
    require(failureCount === 1, "preparation failure callback ran exactly once")
    require(ActionFeedback.visibleFor("main", "invalid-output"), "preparation failure has source feedback")
    require(Object.keys(DesktopSession.actionCallbacks).length === 0, "preparation callbacks drained")
    console.log("PASS real native preparation failure reports locally and dispatches no action")
    Qt.quit()
  } }
}
''')
    environment = {"PATH": str(temporary / "bin") + ":/usr/bin:/bin", "HOME": str(temporary),
                   "XDG_RUNTIME_DIR": str(temporary / "runtime"), "QT_QPA_PLATFORM": "offscreen",
                   "QSG_RHI_BACKEND": "software", "CORNICE_PATH": str(ROOT),
                   "QML_IMPORT_PATH": str(ROOT / "native/platform-build/qml")}
    def no_core():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    result = subprocess.run(["qs", "--no-color", "-p", str(temporary / "shell.qml")],
                            env=environment, capture_output=True, text=True, timeout=12, preexec_fn=no_core)
    output = result.stdout + result.stderr
    print(output)
    # Failed QML loading can exit before either assertion timer runs.
    raise SystemExit(result.returncode or (0 if output.count("PASS real ") == 2 else 1))
