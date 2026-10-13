"""Exercise the production helper with deterministic compositor replies only."""
import json
import os
import shutil
import signal
import time
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
HELPER = Path(os.environ.get("CORNICE_CYCLE_HELPER", ROOT / "bin/cornice-cycle-focus"))

HYPRCTL = r'''#!/usr/bin/env python3
import json, os, re, sys, time
from pathlib import Path
path = Path(os.environ["CYCLE_TEST_STATE"])
args = sys.argv[1:]
run = os.environ.get("CYCLE_TEST_RUN_ID")
if run:
    with open(os.environ["CYCLE_TEST_EVENTS"], "a") as log:
        log.write(json.dumps([run, args]) + "\n")
    gate = Path(os.environ.get("CYCLE_TEST_GATE", str(path) + ".unused"))
    stage = os.environ.get("CYCLE_TEST_GATE_STAGE")
    chosen = (stage == "snapshot" and args[:2] == ["-j", "activewindow"]) or (stage == "fullscreen" and args[-1].startswith("hl.dsp.window.fullscreen_state("))
    if run == "first" and chosen and not gate.exists():
        gate.write_text("reached")
        deadline = time.monotonic() + 10
        while not Path(str(gate) + ".release").exists():
            if time.monotonic() >= deadline:
                raise SystemExit("test gate timeout")
            time.sleep(.01)
state = json.loads(path.read_text())
seat = os.environ.get("HYPRLAND_SEAT_NAME")
active_key = "seat_active" if seat else "active"
if args[:2] == ["-j", "clients"]:
    answer = state["clients"]
elif args[:2] == ["-j", "activewindow"]:
    answer = next((item for item in state["clients"] if item["address"] == state["active"]), {})
elif args[:2] == ["-j", "activeworkspace"]:
    answer = state["workspace"]
elif args[:3] == ["-j", "seat", "state"]:
    answer = {"windowAddress": state["seat_active"], "workspace": str(state["workspace"]["id"]), "seatId": 1, "generation": 1}
else:
    command = args[-1]
    state.setdefault("dispatches", []).append(args)
    if command.startswith("hl.dsp.focus("):
        state[active_key] = re.search(r'address:([^\"]+)', command)[1]
    elif command.startswith("hl.dsp.group."):
        item = next(item for item in state["clients"] if item["address"] == state[active_key])
        members = item["grouped"]
        offset = -1 if ".prev(" in command else 1
        state[active_key] = members[(members.index(item["address"]) + offset) % len(members)]
    elif command.startswith("hl.dsp.window.fullscreen_state("):
        internal, client = map(int, re.search(r'internal=(\d+),client=(\d+)', command).groups())
        for item in state["clients"]:
            chosen = item["address"] == state[active_key]
            item["fullscreen"] = internal if chosen else 0
            item["fullscreenClient"] = client if chosen else 0
            item["at"] = [0, 0] if chosen and internal else item["tiled_at"]
    else:
        raise SystemExit("unexpected dispatch: " + command)
    path.write_text(json.dumps(state))
    print("ok")
    raise SystemExit(0)
print(json.dumps(answer))
'''


def window(address, x, y=0, history=1, grouped=None):
    return {"address": address, "workspace": {"id": 2, "name": "2"}, "at": [x, y],
            "tiled_at": [x, y], "focusHistoryID": history, "grouped": grouped or [],
            "mapped": True, "pinned": False, "fullscreen": 0, "fullscreenClient": 0}


class FocusCycle(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cornice-cycle-test-")
        self.base = Path(self.directory.name)
        fake = self.base / "hyprctl"
        fake.write_text(HYPRCTL)
        fake.chmod(0o755)
        self.state_path = self.base / "state.json"
        self.env = os.environ.copy()
        for key in ("HYPRLAND_SEAT_NAME", "HYPRLAND_SEAT_ID", "HYPRLAND_SEAT_GENERATION", "HYPRLAND_ACTION_ID"):
            self.env.pop(key, None)
        self.env.update(PATH=str(self.base) + os.pathsep + self.env["PATH"], XDG_RUNTIME_DIR=str(self.base),
                        CYCLE_TEST_STATE=str(self.state_path))
        self.save({"clients": [window("a", 20), window("b", 600), window("c", 600, 250), window("d", 600, 500)],
                   "active": "c", "seat_active": "c", "workspace": {"id": 2, "name": "2"}})

    def tearDown(self):
        self.directory.cleanup()

    def save(self, state):
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def cache_path(self):
        suffix = "-" + self.env["HYPRLAND_SEAT_NAME"] if self.env.get("HYPRLAND_SEAT_NAME") else ""
        return self.base / (f"hypr-cycle-group-{os.getuid()}{suffix}.json")

    def cycle(self, direction="next", mode="workspace"):
        subprocess.run([str(HELPER), direction, mode], env=self.env, check=True, capture_output=True, text=True)
        state = self.state()
        return state["seat_active" if self.env.get("HYPRLAND_SEAT_NAME") else "active"]

    def wait_path(self, path):
        deadline = time.monotonic() + 5
        while not path.exists():
            if time.monotonic() >= deadline:
                self.fail("test gate timeout: " + str(path))
            time.sleep(.01)

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, (stdout, stderr))

    def stop(self, process):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.communicate(timeout=5)

    def fullscreen(self, mode=1):
        state = self.state()
        selected = state["seat_active" if self.env.get("HYPRLAND_SEAT_NAME") else "active"]
        for item in state["clients"]:
            chosen = item["address"] == selected
            item.update(fullscreen=mode if chosen else 0, fullscreenClient=mode if chosen else 0,
                        at=[0, 0] if chosen and mode else item["tiled_at"])
        self.save(state)

    def assert_ring(self, direction, addresses, mode="workspace"):
        initial = self.state()["seat_active" if self.env.get("HYPRLAND_SEAT_NAME") else "active"]
        visited = [self.cycle(direction, mode) for _ in addresses]
        self.assertEqual(set(visited), set(addresses), visited)
        self.assertEqual(visited[-1], initial, visited)
        return visited

    def test_cold_fullscreen_next_and_prev_visit_every_window(self):
        for mode in (1, 2):
            with self.subTest(mode=mode):
                self.cache_path().unlink(missing_ok=True)
                self.fullscreen(mode)
                next_order = self.assert_ring("next", "abcd")
                self.assertEqual(self.assert_ring("next", "abcd"), next_order)
                prev_order = self.assert_ring("prev", "abcd")
                self.assertEqual(prev_order, list(reversed(["c", *next_order[:-1]])))

    def test_fullscreen_membership_changes_keep_surviving_order(self):
        self.fullscreen()
        self.cycle()
        cache = json.loads(self.cache_path().read_text())
        ring = next(iter(cache["fullscreen_order"].values()))
        state = self.state()
        removed = next(address for address in ring if address != state["active"])
        state["clients"] = [item for item in state["clients"] if item["address"] != removed]
        state["clients"].append(window("e", 0))
        self.save(state)
        self.cycle()
        new_ring = next(iter(json.loads(self.cache_path().read_text())["fullscreen_order"].values()))
        self.assertEqual(new_ring, [address for address in ring if address != removed] + ["e"])
        self.assert_ring("next", new_ring)
        self.assert_ring("prev", new_ring)

    def test_leaving_fullscreen_refreshes_layout_and_discards_ring(self):
        self.fullscreen()
        self.cycle()
        self.fullscreen(0)
        state = self.state()
        state["active"] = "a"
        for item, x in zip(state["clients"], (200, 300, 100, 0)):
            item["at"] = item["tiled_at"] = [x, 0]
        self.save(state)
        self.assertEqual(self.cycle(), "b")
        self.assertEqual(json.loads(self.cache_path().read_text())["fullscreen_order"], {})
        self.fullscreen()
        self.assertEqual(self.cycle(), "d")
        self.assert_ring("next", "abcd")

    def test_all_mode_cycles_a_single_group(self):
        state = self.state()
        members = ["a", "b", "c"]
        state["clients"] = [window(address, 20, grouped=members) for address in members]
        state["active"] = "a"
        self.save(state)
        self.assertEqual([self.cycle(mode="all") for _ in members], ["b", "c", "a"])
        self.assertEqual([self.cycle("prev", "all") for _ in members], ["c", "b", "a"])

    def test_group_representative_uses_latest_zero_history_id(self):
        state = self.state()
        members = ["b", "c", "d"]
        state["clients"] = [window("a", 20), *[window(address, 600, history=history, grouped=members)
                            for address, history in zip(members, (0, 4, -1))]]
        state["active"] = "a"
        self.save(state)
        self.assertEqual(self.cycle(), "b")

    def test_missing_active_window_uses_latest_valid_history(self):
        state = self.state()
        state["active"] = "outside-workspace"
        for item, history in zip(state["clients"], (0, 9, -1, 4)):
            item["focusHistoryID"] = history
        self.save(state)
        self.assertEqual(self.cycle(), "b")

    def test_group_shortcut_preserves_fullscreen_ring(self):
        state = self.state()
        members = ["b", "c"]
        for item in state["clients"]:
            if item["address"] in members:
                item["grouped"] = members
        self.save(state)
        self.fullscreen()
        self.cycle()
        ring = json.loads(self.cache_path().read_text())["fullscreen_order"]
        state = self.state()
        state["active"] = "b"
        self.save(state)
        self.fullscreen()
        self.cycle(mode="group")
        self.assertEqual(json.loads(self.cache_path().read_text())["fullscreen_order"], ring)
        self.assert_ring("next", "acd")

    def test_tiled_group_shortcut_clears_ring_and_refreshes_positions(self):
        state = self.state()
        for item in state["clients"]:
            if item["address"] in ("b", "c"):
                item["grouped"] = ["b", "c"]
        self.save(state)
        self.fullscreen()
        self.cycle()
        self.fullscreen(0)
        state = self.state()
        state["active"] = "b"
        for item, x in zip(state["clients"], (200, 300, 300, 100)):
            item["at"] = item["tiled_at"] = [x, 0]
        self.save(state)
        self.cycle(mode="group")
        cache = json.loads(self.cache_path().read_text())
        self.assertEqual(cache["fullscreen_order"], {})
        self.assertEqual(cache["pos"]["c"], [300, 0])
        self.fullscreen()
        self.assertEqual(self.cycle(), "d")

    def test_fullscreen_all_mode_keeps_mixed_group_order(self):
        state = self.state()
        for item in state["clients"]:
            if item["address"] in ("b", "c"):
                item["grouped"] = ["b", "c"]
        self.save(state)
        self.fullscreen()
        self.assert_ring("next", "abcd", "all")
        self.assert_ring("prev", "abcd", "all")

    def test_regrouping_projects_the_saved_ring_onto_current_groups(self):
        self.fullscreen()
        self.cycle()
        state = self.state()
        for item in state["clients"]:
            if item["address"] in ("b", "d"):
                item["grouped"] = ["b", "d"]
        self.save(state)
        self.assertEqual(self.cycle(), "b")
        self.assert_ring("next", "abc")
        state = self.state()
        for item in state["clients"]:
            item["grouped"] = []
        self.save(state)
        self.assert_ring("next", "abcd")
        self.assert_ring("prev", "abcd")

    def test_single_window_noop_after_fullscreen_discards_the_old_ring(self):
        self.fullscreen()
        self.cycle()
        self.fullscreen(0)
        state = self.state()
        state["clients"] = [item for item in state["clients"] if item["address"] == state["active"]]
        self.save(state)
        self.assertEqual(self.cycle(), state["active"])
        self.assertEqual(json.loads(self.cache_path().read_text())["fullscreen_order"], {})

    def test_concurrent_requests_wait_before_snapshot_and_through_fullscreen(self):
        real_flock = shutil.which("flock")
        self.assertIsNotNone(real_flock)
        wrapper = self.base / "flock"
        wrapper.write_text("#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
                           "if os.environ.get('CYCLE_TEST_RUN_ID') == 'second':\n"
                           "    Path(os.environ['CYCLE_TEST_GATE'] + '.second-lock').write_text('waiting')\n"
                           "os.execv(os.environ['CYCLE_TEST_REAL_FLOCK'], ['flock', *sys.argv[1:]])\n")
        wrapper.chmod(0o755)
        for mode in ("workspace", "group", "all"):
            state = self.state()
            for item in state["clients"]:
                item["grouped"] = list("abcd") if mode == "group" else []
            self.save(state)
            self.fullscreen()
            for stage in ("snapshot", "fullscreen"):
                with self.subTest(mode=mode, stage=stage):
                    gate = self.base / (mode + "-" + stage + ".gate")
                    events = self.base / (mode + "-" + stage + ".events")
                    env = {**self.env, "CYCLE_TEST_GATE": str(gate), "CYCLE_TEST_GATE_STAGE": stage,
                           "CYCLE_TEST_EVENTS": str(events), "CYCLE_TEST_REAL_FLOCK": real_flock}
                    first = subprocess.Popen([str(HELPER), "next", mode], env={**env, "CYCLE_TEST_RUN_ID": "first"},
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                    second = None
                    try:
                        self.wait_path(gate)
                        second = subprocess.Popen([str(HELPER), "next", mode], env={**env, "CYCLE_TEST_RUN_ID": "second"},
                                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                        self.wait_path(Path(str(gate) + ".second-lock"))
                        self.assertIsNone(second.poll())
                        self.assertFalse(any(json.loads(line)[0] == "second" for line in events.read_text().splitlines()))
                        Path(str(gate) + ".release").touch()
                        self.finish(first)
                        self.finish(second)
                        runs = [json.loads(line)[0] for line in events.read_text().splitlines()]
                        self.assertEqual(runs, sorted(runs, key={"first": 0, "second": 1}.__getitem__))
                        json.loads(self.cache_path().read_text())
                    finally:
                        self.stop(first)
                        if second is not None:
                            self.stop(second)

    def test_eight_overlapping_next_requests_complete_two_full_rings(self):
        self.fullscreen()
        processes = [subprocess.Popen([str(HELPER), "next"], env=self.env, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, start_new_session=True) for _ in range(8)]
        try:
            for process in processes:
                self.finish(process)
        finally:
            for process in processes:
                self.stop(process)
        state = self.state()
        focused = [args[-1].split('address:')[1].split('"')[0] for args in state["dispatches"] if args[-1].startswith("hl.dsp.focus(")]
        self.assertEqual(focused, ["a", "b", "d", "c"] * 2)
        self.assertEqual(state["active"], "c")
        self.assertEqual(next(iter(json.loads(self.cache_path().read_text())["fullscreen_order"].values())), list("cabd"))

    def test_interrupted_cache_write_preserves_the_previous_snapshot(self):
        hooks = self.base / "hooks"
        hooks.mkdir()
        (hooks / "sitecustomize.py").write_text(
            "import json,os,time\nfrom pathlib import Path\noriginal=json.dump\n"
            "def paused_dump(data,stream,*args,**kwargs):\n"
            "    gate=os.environ.get('CYCLE_TEST_SAVE_GATE')\n"
            "    if gate and os.environ.get('CACHE_FILE'):\n"
            "        stream.write('{\"partial\":'); stream.flush()\n"
            "        Path(gate).write_text(os.readlink('/proc/self/fd/' + str(stream.fileno())))\n"
            "        deadline=time.monotonic()+10\n"
            "        while time.monotonic()<deadline: time.sleep(.01)\n"
            "        raise RuntimeError('test save gate expired')\n"
            "    return original(data,stream,*args,**kwargs)\n"
            "json.dump=paused_dump\n")
        for mode in ("workspace", "group", "all"):
            with self.subTest(mode=mode):
                state = self.state()
                state["active"] = "c"
                for item in state["clients"]:
                    item["grouped"] = list("abcd") if mode == "group" else []
                self.save(state)
                self.cache_path().unlink(missing_ok=True)
                self.fullscreen()
                self.cycle(mode="all" if mode == "group" else mode)
                original = self.cache_path().read_bytes()
                inode = self.cache_path().stat().st_ino
                gate = self.base / (mode + ".save")
                env = {**self.env, "PYTHONPATH": str(hooks), "CYCLE_TEST_SAVE_GATE": str(gate)}
                process = subprocess.Popen([str(HELPER), "next", mode], env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True, start_new_session=True)
                try:
                    self.wait_path(gate)
                    pending = Path(gate.read_text())
                    self.assertEqual(pending.parent, self.cache_path().parent)
                    self.assertNotEqual(pending, self.cache_path())
                    self.assertEqual(self.cache_path().read_bytes(), original)
                finally:
                    self.stop(process)
                self.assertEqual(self.cache_path().read_bytes(), original)
                self.fullscreen()
                self.cycle(mode=mode)
                self.assertNotEqual(self.cache_path().stat().st_ino, inode)
                json.loads(self.cache_path().read_text())

    def test_native_seat_uses_its_own_focus_and_cache(self):
        self.env.update(HYPRLAND_SEAT_NAME="agent1", HYPRLAND_ACTION_ID="action-1")
        state = self.state()
        state["active"] = "human-window"
        state["clients"].append({**window("human-window", 0), "workspace": {"id": 1, "name": "1"}})
        self.save(state)
        self.fullscreen()
        self.assert_ring("next", "abcd")
        self.assert_ring("prev", "abcd")
        state = self.state()
        self.assertEqual(state["active"], "human-window")
        self.assertTrue(self.cache_path().exists())
        self.assertFalse((self.base / f"hypr-cycle-group-{os.getuid()}.json").exists())
        self.assertTrue(all(args[:3] == ["seat", "context-dispatch", "action-1"] for args in state["dispatches"]))


if __name__ == "__main__":
    unittest.main()
