"""Exact production-Broker pipe identities across a real private session lock."""
from desktop_harness import *
import array
import fcntl
import stat
import termios

MIME = "application/x-cornice-lock-transport-unit-v1"
# Production Transfer uses a default QTimer at 4000 ms. Qt::CoarseTimer
# may fire 5% early (Qt QTimer accuracy/timerType documentation), so evidence
# must precede the earliest 3800 ms firing by a full second, not only nominal
# 4000 ms. Slow runs fail instead of accepting natural EOF as lock cancellation.
TRANSFER_TIMEOUT_SECONDS = 4.0
COARSE_TIMER_EARLY_TOLERANCE_SECONDS = TRANSFER_TIMEOUT_SECONDS * .05
EARLIEST_NATURAL_TIMEOUT_SECONDS = TRANSFER_TIMEOUT_SECONDS - COARSE_TIMER_EARLY_TOLERANCE_SECONDS
CANCELLATION_MARGIN_SECONDS = 1.0
CANCELLATION_BUDGET_SECONDS = EARLIEST_NATURAL_TIMEOUT_SECONDS - CANCELLATION_MARGIN_SECONDS
NO_REPLAY_SECONDS = .6


def wait_before(callback, deadline, label):
    """Absolute deadline, checked after callbacks too (CLI/IPC can block)."""
    while True:
        now = time.monotonic()
        assert now < deadline, (label, "deadline exceeded", now, deadline)
        value = callback()
        observed = time.monotonic()
        assert observed < deadline, (label, "callback exceeded deadline", observed, deadline)
        if value:
            return value
        time.sleep(min(.005, deadline - observed))


class Client:
    def __init__(self, seat, role, path, label):
        self.label = label
        self.role = role
        self.buffer = b""
        self.events = []
        # The helper does not emit a kernel pipe-creation timestamp. Starting
        # before Popen is a conservative lower bound on its endpoint creation
        # and on the production Transfer timer, rather than resetting time when
        # Python finally observes its stdout. Slow negotiation cannot pass.
        self.started_monotonic = time.monotonic()
        self.process = subprocess.Popen([os.environ["CORNICE_TEST_CLIPBOARD_PROBE"], "--client",
            ENV["WAYLAND_DISPLAY"], seat, role, str(path)], env=ENV, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=open(BASE / (label + ".log"), "w"), start_new_session=True)
        PROCESSES.append(self.process)
    def pump(self):
        if select.select([self.process.stdout], [], [], 0)[0]:
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, (self.label, "controlled client exited", self.process.poll())
            self.buffer += chunk
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            event = json.loads(line)
            event["observed_monotonic"] = time.monotonic()
            assert event.get("event") not in ("fatal", "error", "command_error", "read_error"), event
            self.events.append(event)
            (BASE / (self.label + "-events.json")).write_text(json.dumps(self.events, indent=2))
    def event(self, name, start=0):
        self.pump()
        return next((item for item in self.events[start:] if item.get("event") == name), None)
    def command(self, text, expected, deadline=None):
        self.pump(); start = len(self.events)
        self.process.stdin.write((text + "\n").encode()); self.process.stdin.flush()
        return wait_before(lambda: self.event(expected, start),
                           deadline if deadline is not None else time.monotonic() + 3, self.label + " " + text)
    def endpoint(self, deadline=None):
        endpoint = wait_before(lambda: self.event("endpoint"),
                               deadline if deadline is not None else self.started_monotonic + 3,
                               self.label + " endpoint")
        assert endpoint["mime"] == MIME and endpoint["held"] is True, endpoint
        assert endpoint["direction"] == ("writer" if self.role == "source" else "reader"), endpoint
        assert int(endpoint["pid"]) == self.process.pid, endpoint
        return endpoint
    def selection_ack(self):
        acknowledgement = wait_before(lambda: self.event("selection_ack"),
                                      self.started_monotonic + 3, self.label + " selection queue barrier")
        assert acknowledgement["server_acknowledged"] is True, acknowledgement
        assert acknowledgement["barrier"] == "wl_display_sync", acknowledgement
        assert acknowledgement["selection_acceptance"] == "not asserted", acknowledgement
        return acknowledgement
    def timing(self, endpoint):
        return {"clientStartedMonotonic": self.started_monotonic,
                "endpointCreationLowerBoundMonotonic": self.started_monotonic,
                "endpointCreationMonotonic": None,
                "endpointObservedMonotonic": endpoint["observed_monotonic"],
                "creationTimestampNote": "helper creation timestamp unavailable; pre-Popen lower bound is conservative"}
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.write(b"exit\n"); self.process.stdin.flush()
            self.process.wait(timeout=3)


def broker_pipe(pid, endpoint, expected_mode):
    candidates = []
    for file in pathlib.Path(f"/proc/{pid}/fd").iterdir():
        try:
            identity = file.stat()
            if not stat.S_ISFIFO(identity.st_mode) or identity.st_ino != int(endpoint["inode"]) or identity.st_dev != int(endpoint["device"]):
                continue
            info = pathlib.Path(f"/proc/{pid}/fdinfo/{file.name}").read_text()
            flags = int(next(row.split()[1] for row in info.splitlines() if row.startswith("flags:")), 8)
            if flags & os.O_ACCMODE == expected_mode:
                candidates.append({"fd": int(file.name), "inode": identity.st_ino,
                                   "device": identity.st_dev, "mode": flags & os.O_ACCMODE})
        except (FileNotFoundError, ProcessLookupError):
            continue
    assert len(candidates) <= 1, candidates
    return candidates[0] if candidates else None


def exact_endpoint_open(pid, identity):
    try:
        value = pathlib.Path(f"/proc/{pid}/fd/{identity['fd']}").stat()
        return stat.S_ISFIFO(value.st_mode) and value.st_ino == identity["inode"] and value.st_dev == identity["device"]
    except (FileNotFoundError, ProcessLookupError):
        return False


def queued_reader_bytes(client, endpoint):
    # Inspect the exact held receiving pipe without consuming a byte. Close the
    # temporary inspection fd immediately; it cannot keep a writer alive later.
    fd = os.open(f"/proc/{client.process.pid}/fd/{endpoint['fd']}", os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        identity = os.fstat(fd)
        assert stat.S_ISFIFO(identity.st_mode) and identity.st_ino == int(endpoint["inode"]) and identity.st_dev == int(endpoint["device"]), endpoint
        count = array.array("i", [0])
        fcntl.ioctl(fd, termios.FIONREAD, count, True)
        return {"queuedBytes": count[0], "capacityBytes": fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ),
                "observedMonotonic": time.monotonic()}
    finally:
        os.close(fd)


def verify_full_lock(broker, target):
    assert os.getenv("CORNICE_TEST_SANDBOX") == "1"
    assert os.environ.get("CORNICE_TEST_CLIPBOARD_PROBE"), "Controlled actual protocol client required for full-lock gate"
    initial = cli("doctor")["clipboard"]
    completed = initial["transfers"]
    expected_enabled = {row["name"]: row["enabled"] for row in initial["seats"]}
    assert initial["mode"] == "shared" and initial["connected"] and any(expected_enabled.values()), initial
    # Prepare files before either cancellation-sensitive Transfer exists.
    payload = b"synthetic writer payload " * 8192
    payload_file = BASE / "writer-payload.bin"; payload_file.write_bytes(payload)
    held_file = BASE / "held-reader-payload.bin"; held_file.write_bytes(b"synthetic held reader secret")
    received_file = BASE / "blocked-writer-data.bin"; received_file.write_bytes(b"")
    pam = BASE / "clipboard-pam"; pam.mkdir()
    (pam / "permit").write_text("auth required pam_permit.so\n")
    (pam / "other").write_text("auth required pam_deny.so\naccount required pam_deny.so\n")
    events = BASE / "clipboard-provider-events.jsonl"
    proof = {"accepted": False, "passed": False, "naturalTimeoutSeconds": TRANSFER_TIMEOUT_SECONDS,
             "coarseTimerEarlyToleranceSeconds": COARSE_TIMER_EARLY_TOLERANCE_SECONDS,
             "earliestNaturalTimeoutSeconds": EARLIEST_NATURAL_TIMEOUT_SECONDS,
             "requiredMarginSeconds": CANCELLATION_MARGIN_SECONDS,
             "cancellationBudgetSeconds": CANCELLATION_BUDGET_SECONDS}
    proof_path = BASE / "full-lock-exact-pipes.json"
    def save():
        proof["lastRecordedMonotonic"] = time.monotonic()
        proof_path.write_text(json.dumps(proof, indent=2))
    try:
        producer = Client("Hyprland", "source", payload_file, "complete-producer")
        copy_deadline = producer.started_monotonic + 3
        send_endpoint = producer.endpoint(copy_deadline)
        while True:
            progress = producer.command(f"send 1048576 {send_endpoint['id']}", "sent", copy_deadline)
            if progress["payload_complete"]:
                break
            time.sleep(.005)
        producer.command(f"release {send_endpoint['id']}", "closed", copy_deadline)
        wait_before(lambda: cli("doctor")["clipboard"]["transfers"] > completed, copy_deadline, "initial copied payload")
        receiver = Client(target, "receiver", received_file, "held-receiver")
        writer_deadline = receiver.started_monotonic + CANCELLATION_BUDGET_SECONDS
        receive_endpoint = receiver.endpoint(writer_deadline)
        writer = wait_before(lambda: broker_pipe(broker.pid, receive_endpoint, os.O_WRONLY), writer_deadline, "identified production writer")
        def backpressured_writer():
            assert broker.poll() is None, broker.returncode
            queue = queued_reader_bytes(receiver, receive_endpoint)
            assert 0 <= queue["queuedBytes"] <= queue["capacityBytes"], queue
            return queue if exact_endpoint_open(broker.pid, writer) and 0 < queue["queuedBytes"] == queue["capacityBytes"] < len(payload) else None
        queue = wait_before(backpressured_writer, writer_deadline, "nonempty full held-reader pipe and live blocked writer")
        proof.update(writer=writer, writerClientEndpoint=receive_endpoint,
                     writerTiming=receiver.timing(receive_endpoint), writerBackpressure=queue,
                     writerPayloadBytes=len(payload), writerBytesStillPending=len(payload) - queue["queuedBytes"])
        save()
        held = Client("Hyprland", "source", held_file, "held-producer")
        reader_deadline = held.started_monotonic + CANCELLATION_BUDGET_SECONDS
        lock_deadline = min(writer_deadline, reader_deadline)
        held_endpoint = held.endpoint(lock_deadline)
        reader = wait_before(lambda: broker_pipe(broker.pid, held_endpoint, os.O_RDONLY), lock_deadline, "identified production reader")
        old_endpoint_ids = {}
        for client in (producer, held, receiver):
            client.pump()
            old_endpoint_ids[client.label] = [item["id"] for item in client.events if item.get("event") == "endpoint"]
        proof["oldEndpointIdBaselines"] = old_endpoint_ids.copy()
        proof["oldEndpointBaselinesObservedMonotonic"] = time.monotonic()
        before = cli("doctor")["clipboard"]["transfers"]
        assert time.monotonic() < lock_deadline, ("pre-lock doctor query consumed cancellation budget", lock_deadline)
        assert broker.poll() is None and exact_endpoint_open(broker.pid, reader) and exact_endpoint_open(broker.pid, writer)
        final_queue = queued_reader_bytes(receiver, receive_endpoint)
        assert 0 < final_queue["queuedBytes"] == final_queue["capacityBytes"] < len(payload), final_queue
        assert broker.poll() is None and exact_endpoint_open(broker.pid, reader) and exact_endpoint_open(broker.pid, writer)
        last_inflight = time.monotonic()
        lock_deadline = min(lock_deadline, last_inflight + CANCELLATION_BUDGET_SECONDS)
        proof.update(reader=reader, readerClientEndpoint=held_endpoint, readerTiming=held.timing(held_endpoint),
                     lastInFlightConfirmedMonotonic=last_inflight, finalWriterBackpressure=final_queue,
                     cancellationDeadlineMonotonic=lock_deadline, readerOpenAtLastInFlight=True, writerOpenAtLastInFlight=True)
        save()
        assert time.monotonic() < lock_deadline, ("proof write consumed cancellation budget", lock_deadline)
        provider_started = time.monotonic()
        provider = subprocess.Popen([str(PRODUCT / "native/bin/cornice-human-lock"), "--scope", "session",
            "--pam-service", "permit", "--pam-directory", str(pam), "--allow-emergency"], env=ENV,
            stdin=subprocess.PIPE, stdout=open(events, "w"), stderr=open(BASE / "clipboard-provider.log", "w"),
            start_new_session=True)
        PROCESSES.append(provider)
        proof["providerStartedMonotonic"] = provider_started
        def secure():
            assert provider.poll() is None, provider.returncode
            for line in events.read_text().splitlines():
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if item.get("event") == "secure" and item.get("secure") is True:
                    return item
            return None
        acknowledgement = wait_before(secure, lock_deadline, "secure acknowledgement before transfer timeout margin")
        locked_at = time.monotonic()
        assert broker.poll() is None, broker.returncode
        # Inspect immediately after observing secure, before any potentially
        # slow native/doctor query can turn a natural four-second EOF into proof.
        # The provider and Broker are separate processes. Observe cancellation
        # within the original pre-Popen deadline, never an ack-relative timeout.
        # Record each first observed close so queue scheduling cannot masquerade
        # as the Transfer's natural coarse-timer timeout.
        first_closed = {}
        initial_open = {"reader": exact_endpoint_open(broker.pid, reader),
                        "writer": exact_endpoint_open(broker.pid, writer)}
        def cancelled():
            assert broker.poll() is None, broker.returncode
            for name, identity in (("reader", reader), ("writer", writer)):
                if name not in first_closed and not exact_endpoint_open(broker.pid, identity):
                    first_closed[name] = time.monotonic()
            return len(first_closed) == 2
        wait_before(cancelled, lock_deadline, "exact reader/writer lock cancellation before natural timeout")
        reader_open = exact_endpoint_open(broker.pid, reader)
        writer_open = exact_endpoint_open(broker.pid, writer)
        reader_checked = first_closed["reader"]
        writer_checked = first_closed["writer"]
        proof["endpointsOpenWhenSecureFirstObserved"] = initial_open
        proof.update(providerAcknowledgement=acknowledgement, secureAcknowledgementObservedMonotonic=locked_at,
                     readerOpenAtSecure=initial_open["reader"], writerOpenAtSecure=initial_open["writer"],
                     readerOpenAfterCancellation=reader_open, writerOpenAfterCancellation=writer_open,
                     readerClosureCheckedMonotonic=reader_checked, writerClosureCheckedMonotonic=writer_checked,
                     checkedAfterSecureMs=round((max(reader_checked, writer_checked) - locked_at) * 1000))
        for name, client, checked in (("reader", held, reader_checked), ("writer", receiver, writer_checked)):
            timing = proof[name + "Timing"]
            timing["secureAgeFromCreationLowerBoundMs"] = (locked_at - client.started_monotonic) * 1000
            timing["closureAgeFromCreationLowerBoundMs"] = (checked - client.started_monotonic) * 1000
            timing["secureAgeFromEndpointObservationMs"] = (locked_at - timing["endpointObservedMonotonic"]) * 1000
            timing["closureAgeFromLastInFlightMs"] = (checked - last_inflight) * 1000
            timing["naturalTimeoutRemainingLowerBoundMs"] = (EARLIEST_NATURAL_TIMEOUT_SECONDS - (checked - client.started_monotonic)) * 1000
        save()
        assert locked_at < lock_deadline and reader_checked < lock_deadline and writer_checked < lock_deadline, proof
        assert not reader_open and not writer_open, proof
        assert all(proof[name + "Timing"]["naturalTimeoutRemainingLowerBoundMs"] > CANCELLATION_MARGIN_SECONDS * 1000 for name in ("reader", "writer")), proof
        native = ctl("seat lock-state", True)
        proof["nativeLock"] = native; save()
        assert native["scope"] == "session" and native["secure"] and native["locked"], native
        assert cli("doctor")["clipboard"]["transfers"] == before
        assert all(not seat["enabled"] for seat in cli("doctor")["clipboard"]["seats"])
        record("actual secure ack closes identified in-flight reader/writer at least one second before the earliest coarse-timer timeout")
        held.command(f"send 1048576 {held_endpoint['id']}", "sent")
        held.pump()
        assert any(item.get("event") == "write_error" and item.get("inode") == held_endpoint["inode"] and item.get("errno") == errno.EPIPE
                   for item in held.events), held.events
        data = receiver.command(f"read 1048576 {receive_endpoint['id']}", "read")
        assert 0 < data["offset"] < len(payload), data
        actual_prefix = received_file.read_bytes()
        assert len(actual_prefix) == data["offset"] and actual_prefix == payload[:len(actual_prefix)], data
        assert any(item.get("event") == "closed" and item.get("reason") == "peer_eof"
                   and item.get("inode") == receive_endpoint["inode"] for item in receiver.events), receiver.events
        proof["closedWriterPrefixBytes"] = data["offset"]; save()
        # A real sync callback proves the locked offer was processed; ready is
        # merely queued and cannot establish this negative test's precondition.
        locked_source = Client("Hyprland", "source", held_file, "locked-new-producer")
        old_endpoint_ids[locked_source.label] = []
        proof["oldEndpointIdBaselines"] = old_endpoint_ids.copy()
        def no_old_endpoint_replay():
            counts = {}
            for client in (producer, held, receiver, locked_source):
                client.pump()
                assert client.process.poll() is None, (client.label, client.process.returncode)
                ids = [item["id"] for item in client.events if item.get("event") == "endpoint"]
                # Pending reads need not complete a copy. Check all old sources,
                # plus the receiver to catch direct cached-payload publication.
                assert ids == old_endpoint_ids[client.label], ("old clipboard endpoint replay", client.label, old_endpoint_ids[client.label], ids, client.events)
                counts[client.label] = len(ids)
            proof["latestOldEndpointCounts"] = counts
            return counts
        def locked_source_is_live():
            no_old_endpoint_replay()
            assert locked_source.process.poll() is None, locked_source.process.returncode
            # The helper survives source_cancelled after destroying its source
            # proxy. A live PID alone cannot establish the old-offer premise.
            assert not any(item.get("event") == "source_cancelled" for item in locked_source.events), ("locked source protocol object was cancelled before fresh copy; no-replay premise not exercised", locked_source.events)
            assert not any(item.get("event") == "endpoint" for item in locked_source.events), locked_source.events
        selection_ack = locked_source.selection_ack()
        locked_source_is_live()
        proof["lockedSourceSelectionProcessedAcknowledgement"] = selection_ack
        proof["lockedSourceSelectionAccepted"] = None
        save()
        locked_samples = []
        locked_deadline = time.monotonic() + .3
        while time.monotonic() < locked_deadline:
            assert provider.poll() is None, provider.returncode
            locked_source_is_live()
            clipboard = cli("doctor")["clipboard"]
            locked_source_is_live()
            assert clipboard["transfers"] == before and all(not row["enabled"] for row in clipboard["seats"]), clipboard
            locked_samples.append({"monotonic": time.monotonic(), "transfers": clipboard["transfers"], "sourceEndpointCount": 0,
                                   "oldEndpointCounts": proof["latestOldEndpointCounts"].copy()})
            time.sleep(.02)
        proof["lockedOfferObservationSamples"] = locked_samples; save()
        provider.stdin.write(b"emergency-unlock\n"); provider.stdin.flush(); provider.wait(timeout=5)
        assert provider.returncode == 0
        wait(lambda: not ctl("seat lock-state", True)["locked"])
        assert all(row["paused"] for row in cli("list")["desktops"])
        def policy_restored():
            locked_source_is_live()
            clipboard = cli("doctor")["clipboard"]
            locked_source_is_live()
            states = {row["name"]: row["enabled"] for row in clipboard["seats"]}
            assert clipboard["transfers"] == before, clipboard
            return clipboard if clipboard["connected"] and clipboard["mode"] == initial["mode"] and states == expected_enabled else None
        restored = wait_before(policy_restored, time.monotonic() + 3, "unlocked clipboard policy restored")
        restored_at = time.monotonic()
        replay_samples = []
        # Keep the actual locked source alive throughout policy restoration and
        # multiple Broker IPC/event-loop turns. Any replay issues offer.receive
        # and therefore a concrete endpoint even if it never completes a copy.
        while time.monotonic() - restored_at < NO_REPLAY_SECONDS or len(replay_samples) < 8:
            assert time.monotonic() - restored_at < 3, "unlocked no-replay observation exceeded bound"
            locked_source_is_live()
            clipboard = policy_restored()
            assert time.monotonic() - restored_at < 3, "unlocked no-replay IPC exceeded bound"
            assert clipboard, "clipboard policy regressed during unlocked no-replay observation"
            locked_source_is_live()
            replay_samples.append({"monotonic": time.monotonic(), "transfers": clipboard["transfers"], "sourceEndpointCount": 0,
                                   "sourceAlive": True, "oldEndpointCounts": proof["latestOldEndpointCounts"].copy(),
                                   "enabled": {row["name"]: row["enabled"] for row in clipboard["seats"]}})
            time.sleep(.02)
        proof.update(clipboardPolicyRestoredMonotonic=restored_at, clipboardPolicyRestored=restored,
                     unlockedNoReplaySamples=replay_samples, lockedSourceKeptAliveThroughNoReplay=True,
                     lockedSourceProtocolNotCancelledThroughNoReplay=True)
        save()
        locked_source_is_live()
        proof["freshCopySubmittedMonotonic"] = time.monotonic()
        # The locked source remains alive until this genuinely fresh copy has
        # replaced it and reached the other seat with the exact new payload.
        fresh = b"new synthetic copy after unlock"
        subprocess.run(["wl-copy", "--seat", "Hyprland", "--type", "text/plain;charset=utf-8"],
            input=fresh, env=ENV, check=True, timeout=8)
        wait(lambda: subprocess.check_output(["wl-paste", "--seat", target, "--no-newline", "--type", "text/plain;charset=utf-8"],
            env=ENV, timeout=5) == fresh)
        assert cli("doctor")["clipboard"]["transfers"] > before
        # source_cancelled is now allowed because a genuinely fresh selection
        # replaced it; newly requested old transfers are still forbidden.
        no_old_endpoint_replay()
        producer.close(); held.close(); locked_source.close(); receiver.close()
        proof["freshCopyRestoredSharing"] = True; proof["passed"] = True; save()
        record("processed locked offer is not replayed while alive after policy restoration; only a fresh copy restores sharing")
    except BaseException as failure:
        proof["failure"] = repr(failure)
        proof["failureObservedMonotonic"] = time.monotonic()
        save()
        raise
