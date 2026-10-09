"""Run the compositor-owned regression in this product's device sandbox."""
import os, pathlib, runpy
assert os.getenv("CORNICE_TEST_SANDBOX") == "1"
os.environ["HYPRLAND_TEST_SANDBOX"] = "1"
os.environ["MULTISEAT_HYPRLAND"] = os.environ["CORNICE_TEST_HYPRLAND"]
runpy.run_path(str(pathlib.Path(os.environ["CORNICE_TEST_HYPRLAND_SOURCE"]) / "hyprtester/multiseat/generic-controller.py"), run_name="__main__")
