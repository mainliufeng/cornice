# Desktop recovery and multi-seat product fixes — 2026-10-11

## Runtime selection

This remains a feature-branch delivery, with no merge to main. Cornice is developed in `codex/agent-desktop-recovery`; Hyprland is developed in `codex/cornice-agent-desktop`.

The current daily session was read back from `/proc`: official `/usr/bin/Hyprland` and Quickshell using `/home/liufeng/Code/self/cornice/shell`. It has not been logged out or hot-replaced by validation. The persistent selector currently points to the earlier control-only snapshot `~/.local/state/cornice/session-trial/releases/20261011-160020-15da4218`. That snapshot adds persistent feature selection but does not contain the final ApplicationScope, endpoint or handoff changes. The full product candidate `/tmp/cornice-feature-final-product-v2` is frozen for acceptance, not yet selected for a daily login.

Normal logout/login retains a persistent selection. Explicit rollback/cancel selects stable; a failed or interrupted selected startup fails closed to avoid a login loop. The original configuration and stable entry remain available. After final validation the complete immutable snapshot must replace the control-only selection; a normal new login is still required for actual activation.

## Root causes and module boundaries

- The old supervisor deliberately ended two daily sessions after repeated `EAGAIN` health-probe errors. Targeted kernel records did not show a matching GPU reset or OOM; the original source of those errors remains unproved. The new post-ready policy repairs/degrades individual components with bounded backoff and keeps the compositor alive, including when diagnostics cannot be persisted. Explicit rollback and an actually exited compositor still end the trial.
- Hyprland restores the selected seat's native application focus across input withdrawal, keyboard replacement, layer closure and fullscreen changes. The first keyboard attachment exposed an additional generic ordering defect: capability publication happened after the initial focus attempt, so the first input could be dropped. Commit `2287487` publishes capability before that attempt and preserves the native lock refocus path. No application-name or Cornice namespace special case was added.
- Broker owns desktop identity, permissions, generations and handoff state. Human input is withdrawn before an interrupted handoff is published. Explicit completion/cancellation bypasses the transient requeue and publishes the final state only after native control has ended. Workspace comparison normalizes the compositor's optional `name:` prefix; application closure refuses a workspace currently shared by another desktop.
- ApplicationScope launches applications into independent compositor-bound user units, rather than the shell/Broker service cgroup. Ordinary shell/Broker restarts retain applications; the compositor lifetime guard removes only that instance's application units when its event socket closes. Revocation during preparation prevents launch. Cancellation after submission reports uncertainty instead of replaying or killing an application.
- The browser helper retains Chrome and the CDP pipe across Broker restarts. A private startup nonce authorizes only a fresh helper launch; reusing a helper does not submit the URL twice. Explicit application closure remains a separate requested operation.
- The shared desktop socket uses `ipc-<sha256(instance) first 32 hex>` rather than the complete instance in `sun_path`. C++, MCP, shell and CLI share the same identity calculation. Logs/state retain the original name. The endpoint is bound before desktop/state changes; overlong paths fail without side effects. An active duplicate is rejected; only a confirmed stale socket is removed.
- CLI shell IPC sends once, retains the connection until a complete framed response or deadline, and reports transport uncertainty explicitly. It does not replay through legacy Quickshell after a submitted request. This fixes the old socat stdin-EOF grace period discarding slow but valid screenshot responses.
- Clipboard uses the actual data-control protocol, bounded MIME/byte/concurrency policy and a nonblocking Wayland pump. Full lock cancels transfers. Same-user desktops continue to share filesystem permissions; they are not OS-user isolation.
- UI follows the selected desktop or permits independent read-only workspace browsing, retains actionable errors, and exposes cooperation completion/cancellation. Application launch policy stays in `desktopApplications` configuration.
- Installation validates the whole copied generation, including the lifetime guard and shared endpoint module, before atomic publication and supports rollback. Test system-service fixtures run on private buses only; they cannot suspend or change power state on the host.

## Validation evidence

All build and graphical work uses the original serialized resource wrapper: CPUQuota=200%, MemoryMax=3G, MemorySwapMax=0, TasksMax=512 and RuntimeMaxSec=20min. Graphics use isolated HOME, runtime, PID, network and bus namespaces and hide physical input/modesetting devices. The operator explicitly authorized sharing `/dev/dri/renderD128` for these tests. The daily session is not the test compositor.

| Actual check | Result |
| --- | --- |
| Supervisor health, backlog, degraded components, bounded repair, failed fork, malformed reply, diagnostic ENOSPC | 12 PASS |
| Persistent selector file/CLI/signal/generation lifecycle | 13 PASS; actual two normal-login graphical cycles pending |
| Independent application ownership using the real user manager | 12 PASS |
| Browser event loop, real helper/CDP pipe, nonce, URL-once and long path rejection | 20 PASS |
| Native presentation and target intent | 11 + 5 PASS |
| Handoff state and endpoint using real private Unix sockets | 14 PASS |
| MCP actual SDK lifecycle/cancellation/transport | 4 + 3 + 3 PASS |
| Single-submission shell IPC, delayed reply and bounded timeout | 10 PASS |
| Atomic install with missing guard/module rejection | 13 PASS; prior service transaction fixture 47 PASS |
| Actual application planning/XDG associations/environment | 6 PASS |
| Real cross-seat GTK clipboard after the nonblocking pump | 6 PASS |
| Real core seat lifecycle and new-compositor restoration | 6 PASS on scope-enabled v1 |
| Real Chrome restart/reset/explicit close/slow startup | 8 PASS on scope-enabled v1; final v2 rerun pending |
| Native focus/fullscreen/close/controller lifecycle | 40 PASS before the final first-keyboard ordering change |
| Native launcher first Super+R/query/Enter and regression workflows | 11 + 4 PASS before the final first-keyboard ordering change |
| Real Fcitx pinyin in GTK/launcher/Chrome, read-only return and 2x scaling | 9 PASS |
| Hyprvoice production seat probe, stale focus/seat/workspace and clipboard routing | 13 PASS |
| Real Hyprvoice overlay read-only/takeover/disappearance | 3 PASS |
| Private typed UPower/login1 bus and actual Qt/monitor consumers | 4 PASS |
| Full product UI/handoff, daily/full lock and persistent session integration | Final v2 reruns pending |
| First-keyboard-before/after-panel and full-lock cold keyboard | Final new Hyprland graphical run pending |
| Complete required headless and committed fresh-install acceptance | Pending with new Hyprland and private standard system-service fixture |

The earlier full headless suite exposed two real boundaries: cold keyboard attachment lost focus, and its isolated system bus did not provide battery/login1 services required by existing UI assertions. A maintained-keyboard versus cold-keyboard probe reproduced the focus defect on the old binary without any secondary seat. The lock case additionally checks that restoring capability cannot deliver input to a pre-lock application. Standard private service fixtures cover the real Qt UPower properties and gdbus sleep signal consumers, without accessing the host system bus or removing existing hover/click assertions.

One v2 session trial passed its first 13 checks and then stopped on `Errno 28` while preparing the second snapshot: `/tmp` is a 16G tmpfs that had filled with historical test artifacts. Finished Cornice test directories were moved to `~/.local/state/cornice/validation-archive/2026-10-11-tmpfs`, retaining complete files and original `/tmp` paths as symlinks. Active candidates, build products and other services were left in place. That incomplete run is not counted as persistent-login acceptance.

## Practical limits

Actual physical suspend/resume, microphone capture/ASR and physical key presses were not exercised on the daily session. Voice tests use the production seat-routing probe and actual overlay binary; they do not establish microphone recognition. Shared render-node testing can affect GPU scheduling despite isolation and resource limits. A software-only compositor startup failure is not graphical acceptance.

## Reproduction

Use `test/resource-scope.sh` for builds and pure suites, and `test/isolated-desktop-test.sh SUITE` for actual graphics. Set `CORNICE_TEST_PRODUCT` to the frozen product, `CORNICE_TEST_HYPRLAND` to the independently built feature binary, `CORNICE_TEST_HYPRLAND_SOURCE` to its feature checkout, and the explicitly authorized `CORNICE_TEST_RENDER_NODE`. The fresh install suite exports committed `HEAD`; dirty source is not a substitute for that gate.

Evidence remains in local `/tmp/cornice-*.log` files and the preserved `cornice-agent-test.*` directories. Key final pure logs include `/tmp/cornice-handoff-endpoint-unit.log`, `/tmp/cornice-endpoint-browser-unit.log`, `/tmp/cornice-endpoint-presentation-unit.log`, `/tmp/cornice-endpoint-install-atomic.log`, `/tmp/cornice-endpoint-selector-unit.log`, `/tmp/cornice-endpoint-health-unit.log`, `/tmp/cornice-ipc-routing-scopefinal-v3.log` and `/tmp/cornice-private-system-services-proof.log`. Graphical evidence includes `/tmp/cornice-final-voice-seat.log`, `/tmp/cornice-final-voice-overlay.log`, `/tmp/cornice-final-launcher-native.log`, `/tmp/cornice-final-launcher-regression-staged.log` and `/tmp/cornice-keyboard-capability-focus-before.log`; representative actual screenshots were inspected.
