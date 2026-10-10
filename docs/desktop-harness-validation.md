# External harness desktops — validation

2026-10-10. Cornice stays on `codex/agent-desktop-recovery`; Hyprland stays on `codex/cornice-agent-desktop` (`fa3b70a2093a578134b9f4ccc0882bfacd318f82`). No main branch or running desktop session is changed by these tests.

## Product exercised

- Fresh Broker and trial deployment create primary `main` plus one empty, paused secondary `desktop2`. Recovered desktops are preserved; additional desktops are created only by explicit requests or allocation when all eligible desktops are occupied.
- Codex plugin 0.4.0 and Pi package 0.4.0 both use the same local STDIO MCP with 27 tools. Real installed Codex/Pi discover the skill, load the extension and start the MCP in private temporary configurations. No model gateway or Cornice-owned task executor is involved.
- Real MCP tasks reuse idle desktops, create additional empty desktops under competition, preserve applications on reuse, and keep independent task references even within one MCP process. Primary requires explicit selection and its pre-enabled permission. Pause, takeover, lost heartbeat, stale owners and full lock reject old control.
- GTK and Qt windows expose actual AT-SPI roles, text, states, actions and geometry. Tests start with both accessibility flags disabled and no accessibility-forcing environment, map the applications, then enable and read them through the actual helper. Unicode semantic editing and clicking affect only the authorized window. Missing/ambiguous windows, wrong task references, expired trees, changed workspaces, missing `setText` text and unsupported trees fail explicitly.
- Browser tasks use the existing authorized CDP grant and pinned Playwright tree/actions, with independent managed browser profiles. Actual Chrome navigation, snapshots, Unicode editing and lifecycle interruption are exercised.
- The primary desktop shows live read-only thumbnails labelled with desktop number, Harness and activity. Actual pointer interactions exercise grouped bar selection, hide/restore, dragging and entering the native full desktop view. Screen shrinking/card count changes keep the shelf visible on the primary output. A real lock invalidation clears cached thumbnail images immediately.
- Native full desktop observation/takeover remains compositor presentation. Real physical pointer, keyboard, Chinese IME, focus/fullscreen, workspace shortcuts, application launch/close and scrolling are exercised. Pausing the Broker does not turn physical takeover input into a screenshot/input forwarding loop.

## Responsiveness and failure handling

AT-SPI reads/actions run asynchronously in bounded helper processes. A stalled application may reach the approximately 3.5-second native request budget, while other desktop status calls remain responsive and presentation/control heartbeats continue. Tests cover independent MCP clients and two task references sharing one MCP process, request deduplication and cancellation after owner/control loss. No uncertain mutation is blindly replayed.

Real session-trial tests verify one-shot login preparation, primary/secondary health, normal `main.available=false` during native observation, dynamic extra desktops, initialization deadlines, full lock, missing required seats, supervisor failures and rollback. These tests never lock, suspend or restart the user's session.

## Reproducible checks

Run `make check`, `test/install-test.sh`, `test/headless-verify.sh`, `test/install-verify.sh` and the actual transport/plugin tests. Native product integration uses `test/isolated-desktop-test.sh` with `desktop-acquire-verify.py`, `desktop-harness-verify.py`, `native-accessibility-verify.py`, `desktop-switcher-verify.py`, `desktop-preview-verify.py`, `ime-session-verify.py` and `session-trial-verify.py`. The native responsiveness suite is included alongside these checks. Test doubles are confined to fixtures; the production application tree is never fabricated.

## Deployment and limits

The tested Cornice copy and matching Hyprland binary are prepared as an immutable future-login candidate. The current live release remains active until a new login; `cornice-session-trial cancel` cancels the pending candidate before login. Existing rollback remains available after login. Codex/Pi plugin installation does not itself replace the running compositor.

Applications must expose an accessible AT-SPI tree for native semantic actions. Unsupported applications retain desktop capture/input; visual content may still require screenshots. These are same-user desktop coordination and control boundaries, not separate Linux-user/OS sandboxes. Ordinary Hyprvoice remains an independent installed application; Cornice's removed task editor and its special voice routing are not required by the external Harness interface.

## Cooperation and preview update

The 0.4.0 toolset adds task-owned human cooperation, without adding a model runtime. Installed-product tests exercise request → native takeover → physical text input → actual completion button → fresh Agent grant, remote cancellation, unrelated manual takeover protection, primary permission, status history rendering and Broker-crash recovery. The history remains in the existing Broker's desktop lifecycle record.

Previews default to occupied tasks; the persistent Always switch includes idle desktops. Tests use 36 real pointer drag samples in both directions (within 3 logical pixels), physical corner resizing with a stable origin, persistence across shell restart, input outside the shelf, smaller outputs, real session-lock image invalidation and removal without closing shared applications. A real Super+P/slurp grab preserves the menu during selection and restores normal hover dismissal afterward. The actual menu and cooperation/history panels are visually inspected from the running isolated product.

The updated MCP retains ordinary acquisition/state operation against the previous Broker; cooperation reports an explicit update requirement. This allows the installed harness plugins to be refreshed before the supported future-login desktop candidate replaces the running session. Actual Codex App-server discovery and the actual Pi resource loader list the new tool and shared skill. Main is not merged and no currently running desktop process is replaced.
