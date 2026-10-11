# Desktop context and session ownership

Cornice separates desktop operations from services shared by a login session.
The distinction is declared at the boundary; widgets do not guess it from the
selected desktop or keep their own workspace/focus model.

## IPC and service lifetime

`config/session-services.json` is the common declaration read by both
`bin/cornice` and `Commons.SessionServices`. Each entry identifies a plugin,
its `scope` (`session` or `desktop`) and its IPC `targets`.

The shipped session owners are lock, idle, notifications and polkit. Only the
primary shell instantiates these daemons. Desktop panels remain local; secondary
notification centers and indicators consume the owner's shared history, unread
count and DND state. A new session plugin declares ownership and targets in this
file, rather than adding plugin-name branches to the CLI or registry.

Session commands always address the primary endpoint. Desktop commands address
the caller's seat; native shortcut identity takes precedence over inherited
shell variables and an obsolete identity is rejected. A missing scoped socket
never falls back to another Quickshell instance.

A custom primary endpoint is published atomically in the instance-specific
runtime descriptor. `cornice path --json` exposes read-only endpoint resolution;
secondary shells can discover it even if the Broker started before the primary
shell. Explicit `CORNICE_PRIMARY_SHELL_SOCKET` remains supported. Python and jq
are declared runtime dependencies and checked before installation changes.

Secondary shared-state requests have a deadline and continue on a wall clock
when the output is not presented. Disconnects retain the last readable history
but mark it unavailable, disable operations and discard pending mutations.
Reconnect never replays a notification action or reply.

## Workspace and window state

`Commons.DesktopSession` supplies `currentWorkspace`, `observedWorkspace`,
`focusedWindowAddress`, `focusedWindowTitle`, `windowSnapshot` and workspace
slots. Workspace identity normalizes address/name and retains numeric IDs as
compatibility data; a named workspace need not have a numeric `id`.

The active-window widget and workspace occupancy use this same snapshot. Window
addresses identify focus; two windows with the same title remain distinct.
Readonly browsing shows the observed workspace's windows without inventing
focus or changing the controlling seat's current workspace. Follow and takeover
use its actual current focus. Returning to main restores main's own state.

Compositor events coalesce on the Qt event loop, with a bounded wall-clock
recovery refresh. A private output's lack of frame callbacks cannot stop state
refresh or shared-service health checks.

Secondary focus commands carry seat ID, generation and expected workspace.
The Broker resolves the address to the compositor's stable window ID, then uses
the native `seat act` command: identity, generation, input permission and current
workspace membership are checked by the compositor in one action. Primary focus
keeps the official numeric-workspace interface and also accepts a normalized
named workspace identity. A queued click from another workspace is ignored.

## Applications and readonly controls

Normal, Terminal=true, Shift+Enter and `>` Launcher paths all use
`DesktopSession.launchApplication()`. Secondary launches go through the Broker,
including physical takeover authorization; main's ordinary application launch
does not require a running Desktop Broker. See
[application rules](desktop-application-rules.md) for profile adaptation.

Application helpers inherit the target desktop, not the short-lived native
shortcut authorization. Notification focus prefers the sender PID, filters
secondary candidates to the current workspace, and rejects a sender on another
workspace instead of focusing an unrelated application of the same class.

`Util.exec()` launches applications through that common boundary.
`Util.execSession()` is used explicitly for session controls such as audio,
network scans, power and configuration. During readonly observation, Cornice's
own controls (including notification history/DND) remain available; third-party
notification actions and inline replies cannot run. Losing takeover also clears
an unfinished reply.

## Repeatable verification

Real-compositor suites run with `test/isolated-desktop-test.sh`, a private HOME,
D-Bus, Wayland display and input devices. Set `CORNICE_TEST_PRODUCT` to the built
product and `CORNICE_TEST_HYPRLAND_SOURCE` to the fork checkout.

| Suite | Boundary exercised |
| --- | --- |
| `desktop-state-contract-verify.py` | Numeric/named workspaces, identical titles, stale identity/workspace, actual bar clicks, readonly browse, follow/takeover, background updates |
| `desktop-context-verify.py` | Custom endpoint discovered after Broker startup, three desktops, native session shortcuts, configured terminal launch, exact notification sender focus, owner disconnect |
| `session-services-verify.py` | Shared real notifications, DND/read/clear, readonly actions, takeover actions/replies, disconnect handling |
| `launcher-native-seat-verify.py` | First Super+R, first Enter, shell restart and primary input isolation at 2x scale |
| `ime-session-verify.py` | Real GTK/Chrome/Fcitx Chinese composition and takeover |
| `human-lock-verify.py` | Native lock, sleep, owner loss and multi-seat revocation |
| `application-launch-config-verify.py` | Real application profiles and rejection of identity overrides |
| `ipc-routing-verify.py`, `install-test.sh` | IPC framing/routing negatives, declared dependencies, installation without partial side effects |

The existing headless and fresh-install suites remain required. Report inherited
baseline failures separately from new regression results. Never restart the main
shell/lock owner in a locked physical session to validate these changes.
