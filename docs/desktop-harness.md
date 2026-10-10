# Desktop allocation and harness integration

Cornice provides independent desktops and shared MCP tools. Codex, Pi and other harnesses own their conversations, models, task history and results. Cornice has no embedded executor, model configuration, task prompt, new-task button or task-submission shortcut.

## Automatic task allocation

A fresh session starts with exactly two desktops: primary `main` and one task-ready secondary `desktop2`. Recovered or explicitly created desktops are preserved; startup does not create a second unused secondary desktop. Additional desktops are created only when a harness needs another one.

Installing a plugin connects tools without granting a desktop. When a user asks the agent to operate a desktop, the agent calls `desktop_acquire`. Broker atomically reserves an allowed, paused, unoccupied secondary desktop; if none is available, it creates a new private display/seat at the primary output's pixel resolution and starts its native Cornice shell. No local confirmation popup or manual attach command is required.

The returned `desktop` reference belongs to that task. Every native and browser call includes it. This also supports multiple conversations sharing one MCP process: focus, windows, workspace, browser connection and control grants stay separate. Another MCP process cannot use a reference from this one. Tokens remain private inside MCP and never enter prompts.

- No arguments: reuse the lowest-numbered eligible unoccupied desktop, otherwise create one.
- `preferredDesktop`: use a user-named desktop if unoccupied and allowed. If occupied, create a new desktop. A missing or disabled explicit target fails; it does not silently grant permission.
- `createNew:true`: always create a fresh desktop.
- Desktop 1 (`main`) is never automatically selected. Explicit primary acquisition still requires the operator to have enabled its “允许 Agent 控制” switch beforehand.
- Active tasks, live bindings and human takeover count as occupied. Open applications alone do not occupy a desktop: task-free desktops retain their applications and can be reused. Request `createNew:true` when a task requires an empty desktop.
- Allocation has a 32-desktop service limit; reaching it reports an error rather than evicting a desktop.

Example tool sequence:

```json
{"tool":"desktop_acquire","arguments":{}}
{"tool":"desktop_state","arguments":{"desktop":"reference-returned-above"}}
{"tool":"desktop_browser_connect","arguments":{"desktop":"reference-returned-above"}}
{"tool":"browser_snapshot","arguments":{"desktop":"reference-returned-above"}}
{"tool":"desktop_finish","arguments":{"desktop":"reference-returned-above","outcome":"completed","reason":"Verified the requested result"}}
```

Finish releases occupancy and pauses only that task's desktop; applications are preserved. Connection loss or a missed heartbeat releases the owner's reservation. Late calls or disconnects from an old owner cannot interrupt a replacement owner. Pause, human takeover, permission changes and locks revoke old input; an agent must not acquire another desktop merely to bypass interruption. New allocation is denied during a lock. Existing preauthorized continue-policy tasks retain their established lock policy.

## Codex App plugin

The local plugin packages the shared STDIO MCP and skill. Install it once; subsequent user tasks acquire desktops through tools, without running Cornice commands. For local development the equivalent installer is:

```sh
codex plugin marketplace add /absolute/path/to/cornice
codex plugin add cornice@cornice-local
```

Use `$cornice:cornice-desktop` in a new Codex App conversation. Installing this plugin does not redirect Codex's built-in computer-use tools. The skill routes Cornice tasks to the shared tools. Keep `cornice-desktop-mcp` on the App's PATH, and update the plugin cache when changing the local plugin version.

## Independent Pi package

Pi has its own package, which registers the same MCP and loads the same skill:

```sh
pi install /absolute/path/to/cornice/plugins/pi-cornice
pi
```

Its extension applies the desktop screenshot-context budget and registers `CORNICE_HARNESS=pi`. There is no Cornice model configuration, internal task thread or model gateway dependency. The installed Pi package uses the user's normal model and task interface. Browser tools and native input are implemented once in the shared MCP.

## Other MCP clients and transport

Start `cornice-desktop-mcp` as a local **STDIO** server. There is no HTTP MCP listener or port to configure. It connects to Broker through a user-owned Unix socket. In the desktop session it uses the explicit compositor environment; a GUI App without that environment can use Broker's private runtime `cornice/active.json` endpoint. An old live connection never automatically switches compositors or tasks after a failure.

Expose the bundled skill at `plugins/cornice/skills/cornice-desktop/SKILL.md`. The shared catalog has 27 tools including task acquisition, native desktop operations and allowlisted Playwright browser operations. It includes task-owned cooperation requests, completion/cancellation and restoration after that specific request. It does not expose permission changes, arbitrary resume/rebinding, global CDP endpoints or arbitrary JavaScript execution.

## Human cooperation and remote exit

The Codex and Pi 0.4.0 plugins expose `desktop_handoff`. It is part of the existing Broker/MCP, not another service or chat runtime. A task must have acquired its desktop through `desktop_acquire`; legacy explicit bindings cannot issue cooperation requests.

```json
{"tool":"desktop_handoff","arguments":{"desktop":"task-reference","action":"request","title":"请扫码登录","instructions":"扫描这个桌面的二维码，登录成功后点击“已完成，退出接管”。"}}
{"tool":"desktop_handoff","arguments":{"desktop":"task-reference","action":"status"}}
{"tool":"desktop_handoff","arguments":{"desktop":"task-reference","action":"resolve","requestId":"id-from-request","outcome":"cancelled","note":"用户在对话中要求远程退出接管"}}
{"tool":"desktop_handoff","arguments":{"desktop":"task-reference","action":"resume","requestId":"id-from-request"}}
```

Requesting immediately pauses and revokes Agent input. The primary desktop shows outstanding requests; the target desktop shows its own request while observed or taken over. “接管并处理” starts native human control; “已完成，退出接管” records completion and releases it. The desktop management panel lists recent requests, human instructions and terminal status. The Broker persists up to 20 records per desktop and 20 transitions per record for that desktop lifecycle. A Broker restart preserves records and cancels pending requests whose reservations were lost; a new compositor session is a new desktop lifecycle.

The task's separate cooperation credential permits only status and resolution for its reserved desktop across input-generation changes. It cannot operate applications, change permissions, or control other reservations. A remote resolution can release only the takeover associated with that request. A later independent human takeover, pause, lock or permission change cannot be overridden by retrying an old resume. After resolution, `resume` explicitly obtains a fresh input generation; reconnect the managed browser and read a fresh tree/frame before continuing.

User replies stay in Codex/Pi. The completion button does **not** automatically wake a new external harness turn. An already running `desktop_wait` returns promptly on completion/cancellation without restoring input. Read status on the user's reply or use bounded `desktop_wait`; never acquire another desktop to escape the pause. During a version transition, 0.4.0 MCP retains ordinary operation against the previous Broker, while cooperation requires the updated Broker and an acquired task reservation.

## Legacy explicit bindings

`cornice desktop attach NAME HARNESS` / `detach HARNESS` remain management operations. Set `CORNICE_MCP_BINDING` explicitly to use such a private assignment. Those sessions retain their single assigned desktop and cannot acquire others. Default Codex sessions do not read a global `codex.binding.json`, avoiding accidental cross-conversation assignment. The former internal Pi bridge and executor have been removed; explicit bindings only serve external clients.

## Desktop state and observation

`desktop_state` returns independent fields: `occupied` means a live harness lease, `harness` identifies its owner (Codex/Pi plugins supply `codex`/`pi`), and `activity` is one of `idle`, `running`, `paused`, `takeover`, `locked` or `unavailable`. Open windows do not prove that a harness is working, and releasing a lease preserves those windows.

The primary desktop shows read-only floating thumbnails for occupied secondary desktops. Preview refresh is limited to four frames per second; it never forwards keyboard or pointer input. The “始终显示预览” switch includes idle and finished-task desktops and persists across shell restarts. Drag a title to move the shelf and its bottom-right corner to resize it; size settings persist. Hide a thumbnail from its close control and restore it from the desktop menu. A click selects the full native read-only desktop view; human takeover is an explicit separate control. The default bar groups desktop selection and control in one button; `grouped:false` splits them into the two existing buttons. Full desktop presentation remains native Hyprland composition and is not a thumbnail or screenshot viewing loop.

## Native element trees

`desktop_snapshot` reads a bounded real AT-SPI tree from a window on the task desktop's current workspace (focused window by default). It returns roles, names, text, states, supported actions and short-lived element references. `desktop_action` supports `click`, `setText` and `focus` using the returned `snapshotId`/`elementRef`. It checks desktop control, lifecycle, workspace and window identity, and a mutation invalidates previous element references.

Unsupported applications, ambiguous window mappings and inaccessible application trees return an explicit unsupported error. They are not replaced with fabricated trees; use `desktop_capture` for visual content. Browsers use their existing CDP/Playwright tree and semantic tools. AT-SPI is supplied by the real application toolkit, not inferred from a screenshot.

## Boundary

This is same-user desktop coordination, not an OS sandbox. A harness with unrestricted host shell/Wayland/Hyprland access can bypass these tool boundaries. Primary permission, lock state and task leases are enforced by Broker for the shared tools.

## Verification

`test/desktop-acquire-verify.py`, through `test/isolated-desktop-test.sh`, runs real headless Hyprland, native Cornice shells, GTK applications, managed Chrome and the native session-lock protocol. It verifies concurrent allocation across harnesses, multiple tasks in one MCP process, fresh empty desktops, application-preserving reuse, task references, native Unicode input, independent browser trees, primary permission, finish/disconnect, heartbeat expiry and stale-owner rejection.

`test/desktop-harness-verify.py` retains explicit-binding regression coverage. `test/codex-plugin-verify.py` installs the actual Codex plugin into a temporary configuration; `test/pi-plugin-verify.mjs` installs the actual Pi package and loads its extension and skill. Both discover the live shared MCP catalog without model credentials. `test/mcp-transport-verify.mjs` checks transport failures and the pinned browser schemas, and `test/native-accessibility-verify.py` verifies real GTK/Qt trees and semantic actions. Removed internal-executor tests are not part of the product.

`test/desktop-handoff-verify.py` verifies real MCP request/resolve/resume, native takeover, physical input, actual completion buttons on secondary and primary desktops, stale grants and request IDs, foreign tasks, unrelated human control, permission revocation and Broker restart history. `test/desktop-preview-verify.py` exercises real screenshot selection, 36 pointer drag samples, physical corner resizing and shell-restart size persistence.
