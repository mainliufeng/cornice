# Desktop recovery and multi-seat product fixes — 2026-10-11

This is a **feature-branch checkpoint, not a deployment approval or a completed graphical acceptance**. Daily use stays on the existing official Hyprland and Cornice main. No trial ticket is armed and no current compositor, shell, configuration, lock or power state is changed by this work.

## Why the two sessions ended

The installed trial supervisor recorded three health probe errors (`EAGAIN`) at 12:48:03 and 12:55:51, then deliberately rolled back and ended those compositors. A Broker crash at 12:48:05 followed the first rollback; destruction-time socket callbacks could access already-destroyed maps. Targeted kernel records did not show a matching GPU reset or OOM. The historical origin of EAGAIN is **not established**: a private AF_UNIX backlog test reproduces the same error, but does not prove it caused those incidents.

The new ready-session policy degrades and repairs components in place with bounded attempts and backoff. Post-ready autostart/notification failures and malformed health or repair responses also remain component diagnostics. Health failure, exhausted repair budget and failure to persist diagnostics do not log out the compositor. Explicit rollback and a compositor that actually exited still end the trial. This change exists in the feature source; the old installed supervisor was not hot-replaced.

## Modules and boundaries

- Hyprland owns seat focus: pause withdraws delivered input without erasing the selected application; keyboard replacement and layer closure restore that seat's application; noninteractive layers receive pointer events without stealing keyboard focus. It reuses existing layer focus policy and has no application or Cornice namespace exceptions.
- Cornice Broker owns stable desktop definitions, permissions, task credentials, generations, bounded resources, preparation jobs, clipboard sharing and handoff state. Input/credential withdrawal precedes cooperation-state persistence; persistence failure cannot escape task-expiry callbacks. A new login restores identity/workspace/geometry but not live credentials or primary Agent permission. Failed definitions remain visible with an error.
- The browser runtime helper owns Chrome and the CDP pipe. Broker restart preserves applications, tabs and forms. Startup is asynchronous; revocation closes control, not the browser. Deferred detach cleanup stays within the queue budget, debug-pipe failure preserves the application, and private lifecycle/environment messages cannot enter public CDP envelopes. Explicit `remove/reset --close-apps` is destructive; defaults retain applications.
- Application launch policy lives in `desktopApplications`. Literal env/shell wrappers and URL associations use those rules. Preparation runs in a cancellable child of the existing native runtime, then the Broker checks the live grant and view before launching. Compound scripts retain native argv and report the limits of profile adaptation. Requested browser environment is preserved and distinguished from configured reconnect policy. Relative and absolute commands share the resolved executable identity; explicit PATH is retained.
- The clipboard bridge uses the real data-control protocol. Sharing is configurable; MIME/byte/concurrency limits, superseded-reader cancellation and full-lock cancellation are enforced. Same-user desktops still share filesystem permissions; this is not OS-user isolation.
- MCP cancellation stops queued calls before submission. A submitted operation has an uncertain result and is never replayed silently. Restore needs an explicit operator decision and gives the existing task a fresh binding. Finish destroys the task reference and its credentials. Event waiting/logging does not start an idle harness/model turn.
- Cornice UI retains operation errors, retries service bootstrap, exposes actionable cooperation requests, and distinguishes following from free browsing. Native view control ignores replies to superseded targets. Read-only cooperation surfaces do not request keyboard focus.
- Copy installation publishes a validated whole generation atomically and retains rollback. Durable recovery covers interrupted activation and rollback. Requested install actions report failure truthfully; service/configuration restoration is scoped to the attempted operation.

## Validation status

The completed offline checks run in a serialized user scope with CPUQuota=200%, MemoryMax=3G, MemorySwapMax=0 and TasksMax=512. Graphical tests additionally use private HOME, PID/network/bus/runtime namespaces and hide host input and modesetting devices.

| Check | Status |
| --- | --- |
| Session supervisor real private IPC/backlog, degradation, backoff, failed fork, malformed health/repair, auxiliary failures, diagnostic ENOSPC and explicit rollback | 12 PASS |
| Real BrowserSession event loop, private environment reconnection, public WebSocket protocol isolation, actual helper pipe backpressure/failure, cancellation and destruction | 15 PASS |
| MCP lifecycle / cancellation / transport, actual SDK stdio fixtures | 4 + 3 + 3 PASS |
| Native presentation private socket revision tests | 10 PASS; unchanged assertions reproduce the defect on the original source |
| Actual Observer method invocation for target-bound takeover intent and failure retries | 4 PASS, without a compositor or Qt rendering |
| Atomic installation and temporary-prefix service fixtures | 11 + 47 PASS, including interrupted rollback and concurrent service transactions |
| Native application planning with real XDG MIME association, executable identity, explicit environment and private HOME | 6 PASS, using the real native runtime and real XDG MIME lookup |
| Final Cornice native / Hyprland independent builds and syntax checks | Both final native builds and syntax checks passed; `/tmp` candidate completeness passed |
| Cross-seat real GTK clipboard, text/PNG/clear/limits/isolated mode | Earlier candidate 6 PASS; final transfer guards require rerun |
| Core real seat lifecycle, event restoration, bounded history, preserved apps and resource cap | Earlier 5 PASS; fresh-login restore initially failed, source corrected, final rerun required |
| Actual visible UI bootstrap retry and empty-desktop creation | Passed earlier candidate; reopen initially failed, native source corrected, final workflow rerun required |
| Actual human takeover → completion → Agent input | Initial failure exposed native focus defect; final rerun required |
| Broker/browser restart, default reset, explicit application closure and slow-start responsiveness | Earlier restart checks passed; final extended regression required |
| Required `headless-verify.sh`, fresh committed `install-verify.sh`, lock/IME/launcher regression | Final candidate not accepted |
| Physical suspend/resume and real devices | Not exercised on the daily session |

## Graphical blocker

Only `/dev/dri/renderD128` exists and the daily compositor uses it. Automatic approval review rejected the final browser recovery test using that shared render node because it could affect the current desktop; it explicitly disallowed retrying through another caller. No such retry was attempted. Software rendering does not start this Hyprland/Aquamarine version: the Mutter software parent offers linux-dmabuf v3 while the nested backend requires v4. Tests stopped before Broker startup. Passing offline checks or earlier candidates does not resolve this blocker or prove the final native desktop interaction.

The remaining acceptance requires a separately approved test window or an independent suitable graphics host. Keep both feature branches separate, preserve the current session, and do not deploy until the final graphical regressions and actual product inspection pass.

## Reproduce without touching the current session

Use the worktree's `test/resource-scope.sh` for pure suites and builds. It is valid to run:

```sh
test/resource-scope.sh python3 test/session-trial-health-unit.py
test/resource-scope.sh python3 test/install-atomic-verify.py
test/resource-scope.sh bash test/install-test.sh
test/resource-scope.sh bash test/desktop-presentation-unit.sh
test/resource-scope.sh node test/mcp-cancellation-verify.mjs
test/resource-scope.sh node test/mcp-lifecycle-verify.mjs
test/resource-scope.sh node test/mcp-transport-verify.mjs
test/resource-scope.sh node test/desktop-view-intent-verify.mjs
```

Native build outputs and the candidate tree belong in `/tmp`. `CORNICE_TEST_RUNTIME` selects that compiled runtime for `test/application-launch-plan-verify.py`. Build the explicit `cornice-browser-startup-unit` CMake target and run that binary for its private socket/WebSocket/pipe tests; the target builds its actual helper dependency and launches only its test-only pipe fixture, never a GUI browser or compositor. Run all final graphical suites through `test/isolated-desktop-test.sh` only after resolving the shared-render-node approval boundary. Never install or run a build in the current daily Hyprland process as a substitute for isolated acceptance.

Offline evidence logs are `/tmp/cornice-session-trial-health-unit.log`, `/tmp/cornice-browser-environment-final-unit.log`, `/tmp/cornice-product-final-checkpoint-build.log`, `/tmp/cornice-product-checkpoint-syntax.log`, `/tmp/cornice-presentation-regression.log`, `/tmp/cornice-install-atomic-recovery.log` and `/tmp/cornice-install-service-recovery.log`. They are local validation evidence, not part of the installed product.
