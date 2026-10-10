"""Real preview geometry and lock invalidation against an isolated compositor.

Reuse the switcher suite's real shell, Harness leases and physical-input fixture;
only run preview lifecycle, menu scope, geometry and lock regressions. Launch via isolated-desktop-test.sh.
"""
import os
import pathlib
import runpy

os.environ.pop("CORNICE_TEST_DESKTOP_MENU_ONLY", None)
os.environ["CORNICE_TEST_DESKTOP_PREVIEW_ONLY"] = "1"
runpy.run_path(str(pathlib.Path(__file__).with_name("desktop-switcher-verify.py")), run_name="__main__")
