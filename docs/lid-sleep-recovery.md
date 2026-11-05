# Lid sleep recovery

The session guard keeps the full-session secure-lock prerequisite and the
ordinary logind `Suspend(true)` API. It does not skip authentication or any
other application's inhibitors. Docked/action policy remains logind's policy.

Each request expires after two minutes. Lock acquisition is requested at most
three times, initially and after 15/30 second waits. A confirmed full secure
lock is required for every API attempt. Explicit failures allow at most three
API calls, separated by 15 then 30 seconds. Authentication/authorization denial,
unsupported APIs, disconnected calls, timeouts, and accepted operations without
`PrepareForSleep` stop instead of risking duplicate operations. Reboot/poweroff
are never retried. Pending calls are not retried while awaiting a reply.

Opening the lid cancels a pending lid request (including queued lock/sleep
retries). The lid is re-read before a retry. A call already dispatched to logind
cannot be recalled, but its completion cannot revive a cancelled request.
Manual suspend requests remain independent of lid opening. Sleep/resume
invalidates previous requests and callbacks.

Events, bounded lock-wait diagnostics, chosen lid policy, and D-Bus error
names/messages are recorded with syslog identifier `cornice-session-guard`:

```sh
journalctl -t cornice-session-guard -o short-iso
```

The local `no-sleep-inhibit.service.d/90-lid-sleep.conf` override changes
`Codex-Scheduled` from `sleep/block` to `idle/block`. It keeps the service's
existing restart policy but permits lid/manual sleep. Local scheduled tasks
pause while the laptop sleeps. Restarting this helper affects only its
inhibitor and `sleep infinity` child, not Codex or scheduled job processes.
Do not restart the desktop, replace an active guard, or trigger real suspend
to install this repair during ongoing work. The native change requires a
new safe session/release and a later physical lid test.

Pure scheduling regression test (no bus, compositor or system sleep):

```sh
c++ -std=c++20 -Wall -Wextra -Werror test/session-sleep-unit.cpp -o /tmp/cornice-session-sleep-unit
/tmp/cornice-session-sleep-unit
```

The focused integration suite uses the existing bounded namespace harness,
real Hyprland management-display supervision and native full-lock provider,
and a private fake logind. The driver consumes the guard's lock request as QML
does. It checks missing/lost full-lock feedback, 15/30 second retry spacing,
opening cancellation, authorization denial, accepted-but-unconfirmed replies,
sleep/resume signals and the configured docked-ignore branch. It cannot suspend
the host. Stage a fixture product containing the rebuilt guard and unchanged
release components, then run:

```sh
CORNICE_TEST_HYPRLAND_SOURCE=/path/to/fork \
CORNICE_TEST_HYPRLAND=/path/to/built/Hyprland \
CORNICE_TEST_PRODUCT=/path/to/fixture-product \
./test/isolated-desktop-test.sh session-sleep-integration.py
```

Each new guard emits `guard-started` with `sleepPolicyVersion: 1`. At the next
safe login, confirm that `session-trial/current.json` names the selected new
release and that `journalctl -b -t cornice-session-guard` contains this marker
and `inhibitor-ready`. Merely rebooting does not load source-repository edits;
the fixed immutable release must be selected for future logins first.

Physical acceptance is deferred until all current work can safely pause:

1. Save work and log out/reboot only at a safe time; verify the fixed release
   and startup marker after login. Confirm Codex-Scheduled uses `idle/block`.
2. Put the laptop on a ventilated desk, disconnect external monitors/docks and
   use battery power so the normal undocked lid policy is exercised. Do not
   disable another application's inhibitor for this test.
3. Close the lid for 10–20 seconds, then open and authenticate normally.
4. Verify ordered lid close, `prepare-for-sleep`, kernel `PM: suspend entry`,
   suspend exit and `sleep-resumed` records. Confirm no queued retry causes
   another suspend after opening. A dark panel or lock screen alone is not
   evidence of suspend.
5. If no suspend occurred, retain the guard's policy, lock and D-Bus diagnostics
   and the inhibitor listing. Do not claim acceptance from panel state alone.

Rollback the local policy by removing only the task-created
`~/.config/systemd/user/no-sleep-inhibit.service.d/90-lid-sleep.conf`, then
reloading the user manager and restarting only `no-sleep-inhibit.service`
while the lid is open. The original unit is unchanged and backed up in the
task artifact directory. This restores the original sleep blocker.
Rollback the native change by selecting the previous immutable release at
the next safe login; the currently running release has not been modified.
