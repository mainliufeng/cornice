#!/usr/bin/env python3
"""Real QML feedback state, without a Shell, compositor, session bus or apps."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="cornice-feedback-") as directory:
    temporary = Path(directory)
    runtime = temporary / "runtime"
    runtime.mkdir(mode=0o700)
    module = temporary / "imports/CorniceFeedbackTest"
    module.mkdir(parents=True)
    # Import only the production component under test, avoiding Commons'
    # Quickshell singletons (which require a real compositor).
    (module / "ActionFeedback.qml").symlink_to(ROOT / "shell/Commons/ActionFeedback.qml")
    (module / "qmldir").write_text(
        "module CorniceFeedbackTest\nsingleton ActionFeedback 1.0 ActionFeedback.qml\n")
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(temporary),
                   "XDG_RUNTIME_DIR": str(runtime), "QT_QPA_PLATFORM": "offscreen",
                   "QSG_RHI_BACKEND": "software", "QML_IMPORT_PATH": str(temporary / "imports")}
    result = subprocess.run(["/usr/lib/qt6/bin/qmltestrunner", "-input",
                             str(ROOT / "test/qml/tst_action_feedback.qml")],
                            env=environment, timeout=20)
    raise SystemExit(result.returncode)
