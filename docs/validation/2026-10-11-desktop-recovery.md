# Desktop recovery and multi-seat product fixes — 2026-10-11

This is a **feature-branch checkpoint with partial real graphical acceptance**. After the operator explicitly requested the feature environment, the supported one-login trial was prepared and armed at 15:37. The running daily compositor remains official Hyprland and Cornice main until a normal logout/login; it was not terminated by this work. The selected immutable snapshot is `~/.local/state/cornice/session-trial/releases/20261011-153714-5489261a`, with the final clean Hyprland `9c45a72` build. Its stable entry/binaries and original configuration remain available for fallback. The MCP helper link selects this same snapshot and its previous target is recorded under `session-trial/mcp-entry-backups/`.

The selected candidate includes the frozen Clipboard pump and UI notice fixes. It does not include the ongoing independent systemd application lifetime implementation. No claim is made that all graphical regressions have passed.

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
| Cross-seat real GTK clipboard, text/PNG/clear/limits/isolated mode | Final transfer guards: 6 PASS before the subsequent nonblocking pump change; pump graphical rerun pending |
| Core real seat lifecycle, event restoration, bounded history, preserved apps and resource cap | Final 6 PASS, including a genuinely new compositor login restoring stable named workspace definitions |
| Actual visible UI bootstrap retry and empty-desktop creation | Two real runs each passed bootstrap retry and native empty-desktop creation. First later timed out in Broker; second reopened correctly and visually browsed WS2, then hit a fixture selector prefix mismatch. Fixture corrected; complete rerun pending |
| Actual human takeover → completion → Agent input | Initial failure exposed native focus defect; final rerun required |
| Broker/browser restart, default reset, explicit application closure and slow-start responsiveness | Final real Chrome extended suite: 8 PASS, including PID/tab/form/DOM survival, slow-start takeover responsiveness and immediate startup revocation |
| Native close/fullscreen/activation focus lifecycle | Final 40 real native/secondary-seat comparisons PASS; actual survivor keyboard input and unrelated desktops preserved |
| Actual Fcitx/launcher/Chrome composition and scaling | Final 9 PASS, including readonly return, physical secondary takeover, real Chrome Chinese composition, and native 2x versus forced 4x reproduction |
| Clipboard Qt/Wayland nonblocking pump | Actual private Wayland connection with stale Qt readiness: original blocks (3s timeout), fixed returns within 250ms and Qt timer continues; runtime build PASS. Original intermittent UI timeout cause remains unproven |
| Required `headless-verify.sh`, fresh committed `install-verify.sh`, lock/launcher/voice regression | Fresh committed copy/layout and all helpers PASS. Bash fixtures now explicitly select the final fork/Lua and one coordinate output. First graphics run was invalidated by modifying its running Bash source; corrected run pending. Voice isolation fixture updated to cover both configured isolated and shared clipboard policy; rerun pending |
| Physical suspend/resume and real devices | Not exercised on the daily session |

## Remaining graphical acceptance

The operator's newer instruction authorized previously rejected work and impact on the current desktop. Shared-render-only isolated runs then passed the browser, core, clipboard, focus and IME suites above. Subsequent UI and clipboard-pump runs were nevertheless rejected by automatic review, which continued to cite a stop-new-render-tests restriction. No rejected run was executed through another caller or alternative path. A new question explicitly naming `/dev/dri/renderD128` is pending; no further graphics are submitted until that response resolves the conflict.

The only render node is shared by the daily compositor. Tests hide physical input, modesetting card devices and host display/bus sockets, and serialize CPU/memory/process limits, but shared rendering still has potential host GPU impact. Software-only Mutter exposes linux-dmabuf v3 while the fork's Aquamarine requires v4; earlier software startup failures do not establish graphical acceptance.

Remaining gates are the complete product UI, handoff and launcher workflows; real clipboard after the pump change; voice and session/lock recovery suites; and the corrected full headless/fresh-install checks. Actual physical suspend/resume remains untested. The armed login is a feature trial requested by the operator, not a declaration that these remaining checks passed.

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

Native build outputs and the candidate tree belong in `/tmp`. `CORNICE_TEST_RUNTIME` selects that compiled runtime for `test/application-launch-plan-verify.py`. Build the explicit `cornice-browser-startup-unit` CMake target and run that binary for its private socket/WebSocket/pipe tests; the target builds its actual helper dependency and launches only its test-only pipe fixture, never a GUI browser or compositor. Run final graphical suites through `test/isolated-desktop-test.sh`. Expose a render node only after resolving its approval boundary; a software-only run that stops at compositor startup is not graphical acceptance. Never install or run a build in the current daily Hyprland process as a substitute for isolated acceptance.

Offline evidence logs are `/tmp/cornice-session-trial-health-unit.log`, `/tmp/cornice-browser-environment-final-unit.log`, `/tmp/cornice-product-final-checkpoint-build.log`, `/tmp/cornice-product-checkpoint-syntax.log`, `/tmp/cornice-presentation-regression.log`, `/tmp/cornice-install-atomic-recovery.log` and `/tmp/cornice-install-service-recovery.log` and `/tmp/cornice-product-final-install-verify.log`. They are local validation evidence, not part of the installed product.

Additional real evidence logs: `/tmp/cornice-browser-graphical-final.log`, `/tmp/cornice-core-lifecycle-final.log`, `/tmp/cornice-clipboard-final.log`, `/tmp/cornice-seat-focus-final.log`, `/tmp/cornice-ime-product-final.log`, `/tmp/cornice-product-ui-final.log`, `/tmp/cornice-clipboard-pump-before.log`, `/tmp/cornice-clipboard-pump-final.log`, `/tmp/cornice-clipboard-runtime-build.log`, `/tmp/cornice-feature-prepare-final.log` and `/tmp/cornice-feature-arm-final.log`. Actual Fcitx candidate screenshots were visually inspected at `/tmp/cornice-agent-test.3xt9fY/ad-6atttfi9/taken-over-desktop-candidates.png`; font/candidate rendering was normal in the secondary takeover. UI free-browse screenshots were also inspected.
