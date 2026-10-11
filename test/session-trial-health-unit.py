#!/usr/bin/python3
"""Exercise the real ready-session supervision logic without a compositor."""
import errno
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
from unittest.mock import patch

root = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("cornice_trial_health", str(root / "bin/cornice-session-trial"))
spec = importlib.util.spec_from_loader(loader.name, loader)
trial_module = importlib.util.module_from_spec(spec)
loader.exec_module(trial_module)


class Process:
    def __init__(self, pid, returncode=None):
        self.pid = pid
        self.returncode = returncode

    def poll(self):
        return self.returncode


class Clock:
    value = 100.0

    def advance(self, seconds=1):
        self.value += seconds


def make_trial(directory):
    trial = trial_module.Trial.__new__(trial_module.Trial)
    trial.directory = Path(directory)
    trial.interrupted = False
    trial.compositor = Process(900001)
    trial.components = {"desktop": {"arguments": ["test-broker"],
        "process": Process(900002), "restarts": [], "retryAt": 0.0}}
    trial.component_failures = {}
    trial.recovery = {}
    trial.health_failures = 0
    trial.next_health_check = 0.0
    trial.info = {"status": "ready", "lastHealthyAt": 0.0, "compositorPid": trial.compositor.pid}
    trial.history = []

    def update(status, **details):
        trial.info.update(status=status, **details)
        trial.history.append(dict(trial.info))
    trial.update = update
    return trial


def topology_trial(directory):
    trial = make_trial(directory)
    base = Path(directory) / "topology"
    state = base / "state"
    runtime = base / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    trial.environment = {"XDG_STATE_HOME": str(state), "XDG_RUNTIME_DIR": str(runtime), "HOME": str(base)}
    trial.version = {"commit": "unit"}
    trial.ticket = {"startupSeconds": 5}
    trial.ready_desktops = set()
    trial.desktop_startups = {}
    trial.sockets = []
    desktops = [{"name": "main", "stableId": "main-stable", "seatId": "main-seat", "primary": True,
                 "available": True, "output": "HEADLESS-1", "workspaceSlots": list(range(10)), "humanLockPolicy": "pause"},
                {"name": "research-blue", "stableId": "blue-stable", "seatId": "blue-seat", "primary": False,
                 "available": True, "output": "blue-output", "display": "blue-wayland", "workspaceSlots": list(range(10)), "humanLockPolicy": "pause"}]
    with socket.socket(socket.AF_UNIX) as private_display:
        private_display.bind(str(runtime / "blue-wayland"))
    definition_path = state / "cornice/desktops.json"
    def save():
        trial_module.atomic(definition_path, {"schema": 1, "desktops": {
            desktop["name"]: {"stableId": desktop["stableId"], "humanLockPolicy": desktop["humanLockPolicy"]} for desktop in desktops}})
    save()
    calls = []
    def command(*arguments):
        calls.append(arguments)
        if arguments == ("ping",): return "pong fixture"
        if arguments == ("desktop", "list"): return json.dumps({"desktops": desktops})
        if arguments[:2] == ("desktop", "lock-policy"):
            next(desktop for desktop in desktops if desktop["name"] == arguments[2])["humanLockPolicy"] = arguments[3]
            save(); return "ok"
        raise AssertionError(arguments)
    trial.command = command
    outputs = {"HEADLESS-1", "blue-output"}
    bars = {"HEADLESS-1", "blue-output"}
    def ipc_reply(environment, command, structured=True):
        if command == "version": return {"commit": "unit"}
        if command == "configerrors": return ""
        if command == "monitors": return [{"name": name} for name in sorted(outputs)]
        if command == "layers": return {name: {"levels": {"2": [{"namespace": "cornice-bar"}]}} for name in bars}
        raise AssertionError(command)
    return trial, desktops, save, calls, outputs, bars, ipc_reply, definition_path


def failure(error):
    def throw():
        raise error
    return throw


with tempfile.TemporaryDirectory(prefix="cornice-trial-health-", dir="/tmp") as directory:
    # Exercise the actual IPC implementation with a private Unix socket backlog.
    # This reproduces EAGAIN without fork pressure or access to a desktop socket;
    # it does not establish which syscall failed in a historical incident.
    runtime = Path(directory) / "runtime"
    socket_path = runtime / "hypr" / "unit" / ".socket.sock"
    socket_path.parent.mkdir(parents=True)
    fillers = []
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(socket_path)); server.listen(1)
        try:
            for _ in range(16):
                client = socket.socket(socket.AF_UNIX)
                client.setblocking(False)
                try:
                    client.connect(str(socket_path))
                    fillers.append(client)
                except BlockingIOError:
                    client.close()
                    break
            else:
                raise AssertionError("Private socket backlog was not bounded")
            try:
                trial_module.ipc({"XDG_RUNTIME_DIR": str(runtime), "HYPRLAND_INSTANCE_SIGNATURE": "unit"}, "version")
                raise AssertionError("Backlogged IPC unexpectedly succeeded")
            except BlockingIOError as error:
                assert error.errno == errno.EAGAIN
        finally:
            for client in fillers:
                client.close()
    print("PASS: real timeout-mode AF_UNIX IPC reports EAGAIN on a private full backlog")
    # Read the real schema/file and execute the actual health/topology methods.
    # Service replies are local test doubles, not a replacement health callback.
    trial, desktops, save, calls, outputs, bars, ipc_reply, definition_path = topology_trial(directory)
    with patch.object(trial_module, "ipc", side_effect=ipc_reply):
        trial.initialize_desktops(False)
        trial.health()
        assert trial.info["desktops"] == ["main", "research-blue"]
        assert desktops[1]["humanLockPolicy"] == "pause"
        assert not any(call[:2] == ("desktop", "lock-policy") for call in calls)
        trial.initialize_desktops(True)
        assert calls.count(("desktop", "lock-policy", "research-blue", "continue")) == 1
        desktops[1]["humanLockPolicy"] = "pause"; save()
        trial.initialize_desktops(False)
        assert desktops[1]["humanLockPolicy"] == "pause"
        assert calls.count(("desktop", "lock-policy", "research-blue", "continue")) == 1
    print("PASS: arbitrary managed names preserve existing policies; only a genuinely fresh default receives continuation")

    preserved_definitions = definition_path.read_bytes()
    with patch.object(trial_module, "ipc", side_effect=ipc_reply):
        for desktop in desktops:
            desktop["available"] = False
        trial.health()
        assert trial.info["healthStage"] == "complete"
        assert definition_path.read_bytes() == preserved_definitions
        for desktop in desktops:
            desktop["available"] = True
    print("PASS: readonly presentation, DPMS and lock input unavailability preserve healthy native identities and topology")

    with patch.object(trial_module, "ipc", side_effect=ipc_reply):
        desktops.pop(); save()
        trial.health()
        assert trial.info["desktops"] == ["main"] and trial.ready_desktops == {("main", "main-seat")}
        trial.initialize_desktops(False)
        assert not any(call[:2] == ("desktop", "create") for call in calls)
        desktops.append({"name": "later-green", "stableId": "green-stable", "seatId": "green-seat", "primary": False,
                         "available": True, "output": "green-output", "display": "green-wayland", "workspaceSlots": list(range(10)), "humanLockPolicy": "continue"})
        with socket.socket(socket.AF_UNIX) as private_display:
            private_display.bind(str(Path(trial.environment["XDG_RUNTIME_DIR"]) / "green-wayland"))
        outputs.add("green-output"); save()
        trial.health()
        assert trial.info["initializingDesktops"] == ["later-green"]
        bars.add("green-output"); trial.health()
        assert trial.info["initializingDesktops"] == []
        desktops.pop(); save(); trial.health()
        assert trial.info["desktops"] == ["main"] and not trial.desktop_startups
    print("PASS: legal desktop deletion/main-only state and later creation update live health without stale requirements or bookkeeping")

    trial, desktops, save, calls, outputs, bars, ipc_reply, definition_path = topology_trial(directory + '/missing')
    original = dict(desktops[1])
    with patch.object(trial_module, "ipc", side_effect=ipc_reply):
        for mutation in ("missing-from-list", "unavailable-entry", "missing-seat-identity", "output-lost"):
            desktops[:] = [desktops[0], dict(original)]
            outputs.add("blue-output")
            if mutation == "missing-from-list": desktops.pop()
            elif mutation == "unavailable-entry": desktops[1] = {"name": "research-blue", "error": "seat not found"}
            elif mutation == "missing-seat-identity": desktops[1]["seatId"] = ""
            else: outputs.remove("blue-output")
            try:
                trial.health()
                raise AssertionError("Missing native topology was accepted: " + mutation)
            except RuntimeError as error:
                assert any(text in str(error) for text in ("definitions", "unavailable", "output is missing")), str(error)
            assert trial.compositor.poll() is None
    print("PASS: surviving live seats cannot hide a missing managed definition, failed native seat or lost output")

    trial, desktops, save, calls, outputs, bars, ipc_reply, definition_path = topology_trial(directory + '/race')
    original_command = trial.command
    changed = []
    def concurrent_delete(*arguments):
        if arguments == ("desktop", "list") and not changed:
            changed.append(True); desktops.pop(); save()
        return original_command(*arguments)
    trial.command = concurrent_delete
    with patch.object(trial_module, "ipc", side_effect=ipc_reply):
        trial.health()
    assert trial.info["desktops"] == ["main"] and calls.count(("desktop", "list")) == 2
    assert not any(call[:2] in (("desktop", "create"), ("desktop", "lock-policy")) for call in calls)
    print("PASS: concurrent legal definition changes retry a consistent read-only snapshot without replaying any mutation")

    clock = Clock()
    with patch.object(trial_module.time, "monotonic", lambda: clock.value), patch.object(trial_module.time, "time", lambda: clock.value):
        trial, desktops, save, calls, outputs, bars, ipc_reply, definition_path = topology_trial(directory + '/topology-classification')
        desktops[1]["error"] = "native seat view is unavailable"
        with patch.object(trial_module, "ipc", side_effect=ipc_reply), patch.object(trial, "recover_component") as repair:
            for _ in range(4):
                assert trial.supervise_once()
                clock.advance(6)
            repair.assert_not_called()
        assert trial.info["degraded"] and trial.info["recoveryRequired"] == "diagnostics"
        assert trial.compositor.poll() is None and not trial.components["desktop"]["restarts"]
        assert definition_path.exists() and 'research-blue' in json.loads(definition_path.read_text())["desktops"]
        print("PASS: a real valid Broker list reporting native topology loss diagnoses degradation without restarting unrelated owners")

        trial, desktops, save, calls, outputs, bars, ipc_reply, definition_path = topology_trial(directory + '/transport-classification')
        original_command = trial.command
        def unreachable(*arguments):
            if arguments == ("desktop", "list"):
                raise TimeoutError("Private Broker transport deadline")
            return original_command(*arguments)
        trial.command = unreachable
        with patch.object(trial_module, "ipc", side_effect=ipc_reply), patch.object(trial, "recover_component") as repair:
            for _ in range(3):
                assert trial.supervise_once()
                clock.advance(6)
            repair.assert_called_once_with("desktop", "Private Broker transport deadline")
        assert trial.compositor.poll() is None and trial.info["status"] == "ready"
        print("PASS: a genuine Broker transport failure retains the bounded component repair path without ending the compositor")

        trial = make_trial(directory)
        trial.health = failure(BlockingIOError(errno.EAGAIN, "Resource temporarily unavailable"))
        for _ in range(12):
            assert trial.supervise_once()
            clock.advance(6)
        assert trial.info["degraded"] and trial.info["recoveryRequired"] == "diagnostics"
        assert trial.compositor.poll() is None and trial.info["status"] == "ready"
        assert not any(item["status"] == "rolled-back" for item in trial.history)
        trial.health = lambda: None
        assert trial.supervise_once()
        assert not trial.info["degraded"] and trial.info["healthFailures"] == 0
        print("PASS: repeated real EAGAIN health exceptions keep the ready compositor alive and clear after recovery")

        trial = make_trial(directory)
        trial.components["desktop"]["process"].returncode = 1
        trial.health = failure(trial_module.ComponentUnhealthy("desktop", "Broker exited"))
        starts = []
        def start(arguments, name):
            process = Process(900010 + len(starts), 1)
            starts.append(process)
            return process
        trial.start = start
        for _ in range(20):
            assert trial.supervise_once()
            clock.advance(2)
        assert len(starts) == 3, len(starts)
        assert trial.info["degraded"] and trial.info["recoveryRequired"] == "desktop"
        assert "recovery budget exhausted" in trial.info["lastHealthError"]
        assert trial.compositor.poll() is None
        clock.advance(61)
        assert trial.supervise_once() and len(starts) == 4
        print("PASS: restart budget stops repeated repair without logout and admits a later bounded retry")

        trial = make_trial(directory)
        trial.components["desktop"]["process"].returncode = 1
        trial.health = failure(trial_module.ComponentUnhealthy("desktop", "Broker exited"))
        attempts = []
        def fail_start(arguments, name):
            attempts.append(clock.value)
            raise BlockingIOError(errno.EAGAIN, "Resource temporarily unavailable")
        trial.start = fail_start
        for _ in range(20):
            assert trial.supervise_once()
            clock.advance(2)
        assert len(attempts) == 3 and len(trial.components["desktop"]["restarts"]) == 3
        assert trial.info["degraded"] and trial.compositor.poll() is None
        print("PASS: failed fork consumes recovery budget and cannot cause an unlimited restart loop")

        # Trigger the ComponentUnhealthy handler and its real repair parser.
        # Sibling exception handlers cannot catch failures thrown by that
        # handler, so this path needs its own ready-session boundary.
        for payload in ('{"desktops":[{}]}', '{}', '{"desktops":null}'):
            trial = make_trial(directory)
            trial.components["cornice"] = {"arguments": ["test-shell"],
                "process": Process(900003, 1), "restarts": [], "retryAt": 0.0}
            trial.health = failure(trial_module.ComponentUnhealthy("cornice", "Shell exited"))
            commands = []
            def malformed_repair_reply(*arguments):
                commands.append(arguments)
                return payload
            trial.command = malformed_repair_reply
            starts = []
            trial.start = lambda arguments, name: starts.append(name)
            for _ in range(3):
                assert trial.supervise_once()
                clock.advance(10)  # Admit each bounded exponential retry.
            assert commands == [("desktop", "list")] * 3
            assert not starts  # A malformed pause list never proceeds to UI restart.
            assert len(trial.components["cornice"]["restarts"]) == 3
            assert trial.info["degraded"] and trial.info["recoveryRequired"] == "cornice"
            assert trial.compositor.poll() is None and trial.info["status"] == "ready"
            trial.interrupted = True
            try:
                trial.supervise_once()
                raise AssertionError("Explicit termination during repair was swallowed")
            except RuntimeError as error:
                assert "Manual rollback" in str(error)
            assert commands == [("desktop", "list")] * 3
        print("PASS: real UI repair parser shape failures stay degraded with bounded attempts and never swallow explicit termination")

        trial = make_trial(directory)
        trial.health = failure(BlockingIOError(errno.EAGAIN, "Resource temporarily unavailable"))
        def failed_persistence(status, **details):
            raise OSError(errno.ENOSPC, "No space left on device")
        trial.update = failed_persistence
        for _ in range(4):
            assert trial.supervise_once()
            clock.advance(6)
        assert trial.info["degraded"] and "No space" in trial.info["statusWriteError"]
        assert trial.compositor.poll() is None
        print("PASS: diagnostic status persistence failure cannot terminate the working desktop")

        trial = make_trial(directory)
        trial.info["status"] = "starting"
        trial.update = failed_persistence
        with patch("builtins.print", side_effect=OSError(errno.ENOSPC, "Diagnostic sink is full")):
            trial.mark_ready()
        assert trial.info["status"] == "ready" and "No space" in trial.info["statusWriteError"]
        assert trial.compositor.poll() is None
        print("PASS: verified readiness survives failed durable status and failed diagnostic output")

        trial = make_trial(directory)
        trial.release = Path(directory)
        starts = []
        def auxiliary_start(arguments, name):
            starts.append(name)
            if name == "autostart-0":
                raise BlockingIOError(errno.EAGAIN, "Resource temporarily unavailable")
            if name == "notice":
                raise OSError(errno.EACCES, "Cannot open notice log")
            return Process(900020)
        trial.start = auxiliary_start
        with patch.object(trial_module, "read", return_value=["first application", "second application"]):
            trial.start_ready_auxiliaries()
        assert starts == ["autostart-0", "autostart-1", "notice"]
        assert [item["name"] for item in trial.info["auxiliaryStartFailures"]] == ["autostart-0", "notice"]
        trial.health = lambda: None
        assert trial.supervise_once() and trial.compositor.poll() is None
        assert len(trial.info["auxiliaryStartFailures"]) == 2  # Repair never erases the startup failure record.
        print("PASS: post-ready fork/log failures are isolated per auxiliary and the next application still starts")

        trial = make_trial(directory)
        trial.release = Path(directory)
        starts = []
        trial.start = lambda arguments, name: starts.append(name)
        with patch.object(trial_module, "read", side_effect=OSError(errno.EIO, "Autostart file read failed")):
            trial.start_ready_auxiliaries()
        assert starts == ["notice"] and trial.info["auxiliaryStartFailures"][0]["name"] == "autostart configuration"
        trial.interrupted = True
        with patch.object(trial_module, "read", return_value=["must not run"]):
            try:
                trial.start_ready_auxiliaries()
                raise AssertionError("Explicit termination before auxiliary startup was swallowed")
            except RuntimeError as error:
                assert "Manual rollback" in str(error)
        assert starts == ["notice"]
        print("PASS: post-ready autostart read failure is diagnostic; explicit termination is never swallowed by auxiliary guards")

        # Run the actual health parser on malformed but syntactically valid
        # component responses, rather than only replacing health() with a throw.
        for malformed in ("version", "monitors", "desktop"):
            trial = make_trial(directory)
            trial.environment = {"HOME": directory, "XDG_STATE_HOME": str(Path(directory) / "topology/state")}; trial.version = {"commit": "unit"}
            def ipc_reply(environment, command, structured=True):
                if command == "version":
                    return [] if malformed == "version" else {"commit": "unit"}
                if command == "configerrors":
                    return ""
                if command == "monitors":
                    return [{}] if malformed == "monitors" else [{"name": "HEADLESS-1"}]
                if command == "layers":
                    return {"HEADLESS-1": {"levels": {"2": [{"namespace": "cornice-bar"}]}}}
                raise AssertionError(command)
            trial.command = lambda *args: "pong" if args == ("ping",) else "{}"
            with patch.object(trial_module, "ipc", side_effect=ipc_reply):
                for _ in range(3):
                    assert trial.supervise_once()
                    clock.advance(6)
            assert trial.info["status"] == "ready" and trial.info["degraded"]
            assert trial.compositor.poll() is None
        print("PASS: real health parsing of malformed compositor/Broker response shapes cannot end a ready session")

        trial = make_trial(directory)
        trial.release = Path(directory)
        (trial.release / "hyprland.lua").write_text("-- unit startup configuration\n")
        trial.start = fail_start
        try:
            trial.execute()
            raise AssertionError("Pre-ready required compositor start failure was swallowed")
        except BlockingIOError as error:
            assert error.errno == errno.EAGAIN
        assert trial.info["status"] == "starting"
        print("PASS: required startup failures before readiness still propagate for the intentional rollback path")

        trial = make_trial(directory)
        trial.health = lambda: None
        trial.interrupted = True
        try:
            trial.supervise_once()
            raise AssertionError("Explicit rollback was ignored")
        except RuntimeError as error:
            assert "Manual rollback" in str(error)
        trial.interrupted = False
        trial.compositor.returncode = 0
        assert trial.supervise_once() is False and trial.info["status"] == "exited"
        print("PASS: explicit rollback and actual compositor exit retain their intended lifecycle")
