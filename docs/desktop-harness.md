# Desktop allocation and harness integration

Cornice provides independent desktops and shared MCP tools. Codex, Pi and other harnesses own their conversations, models, task history and results. Cornice does not need to launch a Pi job to serve an external harness.

## Automatic task allocation

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

Its extension applies the desktop screenshot-context budget and does not require `CORNICE_AGENT_BRIDGE`, a Cornice model configuration, an internal task thread or Magpie. The installed Pi package uses the user's normal model and task interface. Browser tools and native input are implemented once in the shared MCP.

## Other MCP clients and transport

Start `cornice-desktop-mcp` as a local **STDIO** server. There is no HTTP MCP listener or port to configure. It connects to Broker through a user-owned Unix socket. In the desktop session it uses the explicit compositor environment; a GUI App without that environment can use Broker's private runtime `cornice/active.json` endpoint. An old live connection never automatically switches compositors or tasks after a failure.

Expose the bundled skill at `plugins/cornice/skills/cornice-desktop/SKILL.md`. The shared catalog has 24 tools including task acquisition, native desktop operations and allowlisted Playwright browser operations. It does not expose permission changes, arbitrary resume/rebinding, global CDP endpoints or arbitrary JavaScript execution.

## Legacy explicit bindings

`cornice desktop attach NAME HARNESS` / `detach HARNESS` remain management operations. Set `CORNICE_MCP_BINDING` explicitly to use such a private assignment. Those sessions retain their single assigned desktop and cannot acquire others. Default Codex sessions no longer read a global `codex.binding.json`, avoiding accidental cross-conversation assignment. The existing internal Pi task bridge remains an explicit legacy executor; it is not involved in independent Pi or Codex App tasks.

## Boundary

This is same-user desktop coordination, not an OS sandbox. A harness with unrestricted host shell/Wayland/Hyprland access can bypass these tool boundaries. Primary permission, lock state and task leases are enforced by Broker for the shared tools.

## Verification

`test/desktop-acquire-verify.py`, through `test/isolated-desktop-test.sh`, runs real headless Hyprland, native Cornice shells, GTK applications, managed Chrome and the native session-lock protocol. It verifies concurrent allocation across harnesses, multiple tasks in one MCP process, fresh empty desktops, application-preserving reuse, task references, native Unicode input, independent browser trees, primary permission, finish/disconnect, heartbeat expiry and stale-owner rejection.

`test/desktop-harness-verify.py` retains explicit-binding regression coverage. `test/codex-plugin-verify.py` installs the actual Codex plugin into a temporary configuration; `test/pi-plugin-verify.mjs` installs the actual Pi package and loads its extension and skill. Both discover the live shared MCP catalog without model credentials. `test/mcp-transport-verify.mjs` checks transport failures and the pinned browser schemas, while `test/agent-runtime-protocol-verify.py` retains internal-executor protocol regression coverage.
