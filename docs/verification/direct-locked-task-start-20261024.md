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

## Full-suite gap closed by baseline reproduction and a compatibility fix

The first `human-lock-verify.py` run stopped at its strict no-QML-errors
assertion. This was investigated rather than suppressed. An untouched export of
Cornice `14d6b79` reproduced the same media/polkit `Color.foreground.r` errors
under the same Qt 6.12.0 and private compositor. QtQuick 6.12 adds its own `Color`
singleton; unqualified lookup selected it instead of the project theme singleton.
A minimal unchanged-baseline probe resolved `Color.rgba` but no `foreground`;
explicit `Commons.Color` resolved the existing `#c9d1d9` theme value.

The compatibility-only fix adds a module alias and qualifies 352 references in
55 QML files. An automated reverse comparison against `c310022` confirmed the
migration changes only those imports/qualifications, not layout, tokens, data or
behavior. Actual full-shell baseline/candidate rendering, after bar IPC geometry
was ready, measured the empty bar pixel as `[255,255,255]` on baseline versus the
expected mono theme `[13,17,23]` on candidate. QML errors disappeared. Screenshot
readiness requires the real bar and exact theme color, not merely a dark frame.

The **unchanged original full lock suite now passes**, including all previously
unreached UI/guard crash and output-loss assertions. A separate
`human-lock-recovery-verify.py` also passes native locker SIGKILL, whole UI/guard
SIGKILL, authentication recovery without Agent restoration, secure-full-before-
suspend and locked simulated wake using real private logind inhibitor FDs.
`headless-verify.sh` passes 379 checks, including actual panels/input/rendering
and log hygiene. `session-trial-verify.py` passes its real immutable snapshot,
synthetic SDDM login, failure, persistence and rollback checks. Final binary
identity is the committed Hyprland `4d6ef13c`, not the earlier base stamp; final
artifact checks are recorded separately after that metadata rebuild.

Original failed logs are retained. The result JSONs distinguish the initial run,
closure and final-artifact verification; no assertion was removed to obtain a
pass. See `qml-color-resolution-verify-final.log`, `human-lock-verify-final.log`,
`human-lock-recovery-verify-final.log`, `headless-verify-closed.log` and
`session-trial-verify-final.log` in the evidence directory.

## Remaining acceptance limits

No physical DRM hotplug/mirroring, real lid/suspend/wake, or current user's PAM
configuration was tested. Same-UID applications remain outside an OS filesystem
or process sandbox. Already submitted application/network actions cannot be
retracted by withdrawing desktop control.

## Later rollout and rollback

Installation remains a separate explicitly approved action. Use matching
compositor and Cornice artifacts; preserve the previous pair and configuration.
Software gaps described above are closed. Physical acceptance remains required
before treating this as production-accepted. Preparing/arming one future paired
trial is reasonable only after explicit owner approval. To roll back an eventual
trial, pause candidate tasks and restore the previous paired artifacts; do not
migrate active lease credentials. No new permission switch needs to be enabled.

Exact reviewed deployment and rollback plan: [paired rollout](../locked-agent-task-rollout.md).
