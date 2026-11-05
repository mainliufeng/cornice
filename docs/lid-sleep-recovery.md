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

Rollback the local policy by removing only the task-created
`~/.config/systemd/user/no-sleep-inhibit.service.d/90-lid-sleep.conf`, then
reloading the user manager and restarting only `no-sleep-inhibit.service`
while the lid is open. The original unit is unchanged and backed up in the
task artifact directory. This restores the original sleep blocker.
Rollback the native change by selecting the previous immutable release at
the next safe login; the currently running release has not been modified.
