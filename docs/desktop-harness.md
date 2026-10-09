# Unified desktops and harness integration

All desktops use the same state, window, workspace, capture, input, application and browser interface. Desktop 1 (`main`) is the primary desktop, backed by the native primary seat. It retains native physical input and shell behavior. Other desktops retain independent seat/focus/cursor/workspace state and their native presentation.

Every desktop has an **允许 Agent 控制** switch on the bar. `main` defaults to disabled on every Broker/session startup; other desktops default to enabled. Enabled means a specific harness can be assigned control, not that every harness receives access. Turning permission off revokes bindings and CDP immediately. One harness controls a desktop at a time. Physical input on the primary desktop takes control before applying that event; explicit takeover on another desktop revokes the Agent generation. Session lock continues to override all grants.

## Codex plugin

Install Cornice with its desktop component and Node.js dependencies first. Add this repository as a local marketplace, then install the bundled plugin:

```sh
codex plugin marketplace add /absolute/path/to/cornice
codex plugin add cornice@cornice-local
```

On the desktop to be assigned, enable **允许 Agent 控制**. The operator then assigns it to Codex:

```sh
cornice desktop attach agent1 codex
# or, only after enabling permission on desktop 1:
cornice desktop attach main codex
```

The assignment is a 0600 binding at `$XDG_STATE_HOME/cornice/harness/codex.binding.json` (default `~/.local/state/...`); no token goes into the plugin or model prompt. Start a fresh Codex chat with the plugin enabled and use `$cornice:cornice-desktop`. The initial `desktop_state` confirms the assigned desktop. Installing the plugin never grants desktop control or redirects Codex's built-in computer-use tools.

Detach with `cornice desktop detach codex`. Reassigning a desktop revokes its previous binding. After pause/takeover/session lock, the operator must explicitly restore control and refresh the binding. A live MCP session cannot change its desktop identity; start a new chat when assigning a different desktop.

## Other MCP clients

The shared server is a local stdio process, `cornice-desktop-mcp`, backed by the existing Broker. It is not another desktop daemon. Set `CORNICE_MCP_BINDING` to an operator-issued binding file; configure the client to start that command. The same bundled skill is reusable outside Codex at `plugins/cornice/skills/cornice-desktop/SKILL.md`.

Pi's extension only connects this MCP and applies its screenshot-context budget. Native desktop tools and the allowlisted Playwright browser tools are implemented once in the shared MCP. CLI and JSON RPC remain available for management and scripts. Broker authorization is authoritative for all adapters.

The MCP exposes no desktop creation, permission switch, resume, rebinding, global browser endpoint, arbitrary JavaScript execution, or filesystem tool. It preserves full screenshot resolution and returns bounded JPEG image content plus structured frame metadata. Native apps currently use windows and screenshots, not a claimed AT-SPI implementation.

## Boundary

This is a same-user coordination and tool authorization boundary, not an OS sandbox. A harness with unrestricted host shell/Wayland/Hyprland access or arbitrary application launch can bypass it. Strong confinement requires a separate sandbox and management-channel access policy.
