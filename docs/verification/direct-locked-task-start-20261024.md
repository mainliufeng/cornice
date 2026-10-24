# Direct task start during human lock — candidate verification

Date: 2026-10-24. Both candidate worktrees use branch `codex/locked-agent-start`.
Bases: Cornice `14d6b79`, Hyprland `3f357eee`. No merge, push, install, current
compositor restart, current lock operation or current-session permission change
was performed. The source checkouts and their unrelated uncommitted files were
preserved.

## Implemented contract

The existing automatic Agent desktop model now works under stable human lock:
reuse a fresh/completed idle private desktop, or create a private desktop when
needed. There is no new preauthorization interaction or setting. Existing Agent
permission withdrawal and task ownership remain effective. Main cannot be a
fallback. A new task has independent input/export/browser authority tied to the
seat lifecycle, exact lock epoch and original private output object.

Fresh output privacy is registered before announcement and verified against an
actual managed headless backend, not a name. Fresh initialization cannot select
a workspace on a human output. Lock switches, full/orphaned lock, output loss,
manual pause, takeover, revoked permission, disconnect and service restart never
revive old leases. Normal completed task-idle is explicitly distinguished from
interruption. Existing pre-lock continuity still follows its original policy.

## Environment and evidence

All desktop tests used the repository's `test/isolated-desktop-test.sh`:
private HOME, PID/network/socket namespaces; no host input, DRM card, production
Wayland/compositor socket or host system bus. `/dev/dri/renderD128` was exposed
only for rendering. The unchanged limit was 2 CPU equivalents, 3 GiB RAM, no
swap, bounded tasks (1024) and 20 minutes per suite. Repeated task fixtures clean
up completed private desktops/browser processes to stay within that limit.
PAM used a private permit/deny fixture; sleep/lid tests used private logind and
real inhibitor FDs. No physical sleep or lid operation was attempted.

Persistent evidence directory:
`/home/liufeng/Documents/Codex/2026-10-24/task-2/evidence/`.
It contains full logs, `integration-results.json`, binary SHA-256 manifest and
actual rendered `agent-task.jpg` / `human-protection.png`. Screenshots are from
private test outputs. They are not captures of the user's running desktop.

## Passed

* Both compositor and Broker/native QML builds; script/Python/MCP syntax checks.
* `desktop-locked-start-verify.py`: default `pause` policy without setup or a new
  switch; simultaneous contenders reuse/create distinct private desktops;
  real GTK Unicode input and changing painted clock; managed Chrome document;
  primary input/capture and ordinary locked bind refusal; completion/new lease;
  old frame/reference/browser refusal; manual pause, existing permission
  withdrawal, cross-output rejection, full-lock/create race, old epochs,
  disconnect, same-name output recreation, human unlock, Broker restart and
  owner-loss fail-closed behavior.
* `desktop-lock-continuity-verify.py`: exact pre-lock task reference and Unicode
  input survive human lock under continue policy; native takeover/release and
  explicit restoration; full lock revokes input/capture/launch/CDP and never
  automatically restores them.
* `desktop-clipboard-verify.py`: real GTK copy/paste both ways, exact PNG MIME,
  secure-ack cancellation of identified in-flight pipes before coarse timeout,
  no replay of an old locked offer, selection clear/recovery, bounded oversized
  transfers and configured isolated mode. The test helper now uses the existing
  `bin/cornice-human-lock` wrapper so source builds require no installation.
* Existing clipboard lock transport unit with real libwayland peers. Its
  compiled controlled client was supplied to the full-lock clipboard test.
* MCP lifecycle, transport and cancellation regressions. Completion outcome is
  asserted on the wire; ordinary disconnect does not become normal completion.

## Full-suite failure and remaining gaps

`human-lock-verify.py` **did not pass as a whole**. It passed real GTK shared
workspace input, Chrome/CDP revocation, PAM success/failure and primary input,
secure human/full presentation, continuous protected output sampling, DPMS and
unknown-output hotplug, stale-owner refusal/recovery policy, guardian loss,
private-logind inhibitor ordering and two lid/PAM/LockedHint cycles. It then
failed its global no-QML-errors assertion at line 471:

```
shell/plugins/media/Panel.qml:110: TypeError: Cannot read property 'r' of undefined
shell/plugins/polkit/Polkit.qml:104: TypeError: Cannot read property 'r' of undefined
shell/plugins/polkit/Polkit.qml:166: TypeError: Cannot read property 'r' of undefined
```

These shell files were not modified in this candidate (`git diff HEAD -- shell`
was empty). The assertion was not suppressed and the failure remains recorded.
The following end-of-suite Cornice UI/guard crash/restart assertions were not
reached in that run. Broker restart and original/new task revocation were
independently verified by the two passing suites above. This report does not
claim a clean full shell acceptance or physical-session acceptance.

No physical DRM hotplug/mirroring, real lid/suspend/wake, or current user's PAM
configuration was tested. Same-UID applications remain outside an OS filesystem
or process sandbox. Already submitted application/network actions cannot be
retracted by withdrawing desktop control.

## Later rollout and rollback

Installation remains a separate explicitly approved action. Use matching
compositor and Cornice artifacts; preserve the previous pair and configuration.
Investigate the full-suite QML failure and run remaining shell recovery/physical
acceptance before treating this as release-ready. To roll back an eventual
trial, pause candidate tasks and restore the previous paired artifacts; do not
migrate active lease credentials. No new permission switch needs to be enabled.
