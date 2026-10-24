# Direct Agent task start during human lock (candidate)

Agents keep the existing Cornice access model: `desktop_acquire` directly reuses
an eligible idle Agent desktop or creates a new private Agent desktop, including
while the human desktop is locked. There is **no new preauthorization step,
permission switch or default-off setting**. Existing per-desktop automation
permission still applies; primary control never becomes a fallback.

`humanLockPolicy: continue` keeps its original meaning for a task that began
before the lock. A task that begins under lock instead receives an independent,
revocable lease after compositor validation. It does not require changing the
continuity policy, including when that policy is the default `pause`.

## Allocation and interruption

Broker serializes reservations and checks existing task/binding ownership.
The compositor atomically checks seat lifecycle, current generation, actual
private output object, current lock epoch, human scope, connected owner and
presented secure coverage. Only then does it rotate input and export authority.
`taskIdle` distinguishes fresh/normal-completion idle state from manual pause,
takeover, permission withdrawal, lost harness connection and recovery. An
interrupted desktop is never silently resumed; another task may get a different
private desktop under the existing allocation rules. Task restore proves only
exact live continuity and cannot revive an interrupted lease.

Successful `desktop_finish outcome:completed` withdraws devices, bindings,
frames, browser grants and occupancy and records task-idle. Cancelled/blocked
finishes and disconnects record interruption. Missing outcomes from older MCP
clients use the conservative interruption path. General resume and normal
management bind still refuse locked desktops. The new internal initialize/start
commands are trusted Broker management IPC, not new Agent tool permissions.

A task started under lock is valid only for that lock epoch. Unlock, full-lock
upgrade, unknown/orphaned protection, output loss/recreation, or movement to a
different output immediately denies its input/capture. Moving back cannot revive
the old lease. Broker/compositor restart never restores old control. Fresh tasks
can still be allocated independently after healthy human-lock protection is
confirmed; they do not inherit interrupted credentials or devices.

## Creating a private desktop while locked

Only a stable, secure human lock permits creation. Broker carries the expected
lock epoch through private-output creation, seat creation, initialization and
allocation. The compositor creates only managed headless outputs and registers
their privacy **before** output/global announcement. Human scope excludes those
private output objects while all physical, mirrored and unknown outputs remain
protected. Standard full-session lock protects every output without exception.

Fresh initialization is limited to an unmanaged generation-one private seat and
a workspace on its own output. It does not route through the physical desktop,
reuse a human workspace or grant input. Allocation then issues its first lease.
Only the first configuration for that exact newly leased seat may be installed
while locked; existing locked configuration changes remain blocked. A lock
switch at any stage rejects the old epoch and cleanup cannot grant control.

Human output rendering, PAM, lock-only physical input, management/primary capture
prohibition and browser/clipboard routing remain in force. This is a desktop
control contract: applications run under the same Linux UID, with no added
filesystem/process sandbox. Withdrawing desktop control cannot undo submitted
application actions or stop their file/network activity.

## Verification and later rollout

Build both candidates without installing, then use the existing resource-limited
private compositor wrapper:

```
CORNICE_TEST_HYPRLAND_SOURCE=/absolute/candidate/hyprland \
CORNICE_TEST_HYPRLAND=/absolute/candidate/hyprland/build-candidate/Hyprland \
CORNICE_TEST_RENDER_NODE=/dev/dri/renderD128 \
  test/isolated-desktop-test.sh desktop-locked-start-verify.py
```

The wrapper supplies private HOME, PID/network/socket namespaces, CPU/memory/task
limits, and no host input or DRM card devices. A render node permits rendering
only. Never substitute the production compositor socket or lock. Existing human
lock, continuity/takeover and clipboard tests remain regression requirements.
Test results and remaining gaps are recorded separately; no fixture is claimed
as physical-session acceptance.

Later installation needs explicit permission for a matched Cornice/compositor
pair. Preserve the previous paired binaries/configuration; pause candidate tasks
and restore that pair for rollback. Never migrate active lease credentials.
Physical lock/PAM, sleep/wake and physical hotplug remain separate acceptance
work requiring permission. Do not merge, publish, install or restart the current
compositor automatically.

Candidate results and explicit gaps: [2026-10-24 verification](verification/direct-locked-task-start-20261024.md).
