---
name: cornice-desktop
description: Operate an explicitly assigned Cornice desktop, including native apps and its managed browser, through Cornice tools. Use when asked to perform or observe a task on a Cornice desktop.
---

Use the Cornice MCP tools for the desktop assigned to this harness. Tool names may carry a host prefix; identify them by their `desktop_` or `browser_` suffix.

- Begin with `desktop_state`. Identify the actual desktop and controller. Desktop 1 is the primary desktop and defaults to Agent control disabled. There is no implicit “current desktop” fallback.
- If no desktop is assigned, explain the required setup: enable “允许 Agent 控制” on the intended desktop and have the operator run `cornice desktop attach NAME codex` for the Codex plugin. Other MCP clients use an operator-issued private binding through `CORNICE_MCP_BINDING`. Do not issue yourself a binding, change permissions, or switch assignments to escape an interruption.
- For browser work, use `desktop_browser_connect`, inspect `browser_tabs`, then use a fresh `browser_snapshot` tree and semantic actions. Browser tools address only that desktop’s Broker-managed browser. Never connect to a global CDP port or an unrelated browser profile.
- For native apps or visual information absent from the browser tree, use `desktop_capture`. Its coordinates are pixels in `pixelSize`; pass its fresh `frameId` to `desktop_input`. After focus/workspace changes, observe again. Native accessibility trees are not currently exposed.
- Permission changes, pause, human takeover and session lock can revoke control. Stop sending input, then choose `desktop_wait` or `desktop_finish` with an explained blocker/cancellation. After explicit restoration reconnect and observe again; a human may have changed the page, focus or workspace. Never blindly replay an action with uncertain outcome.
- Verify the user’s actual requested result before `desktop_finish completed`. Tool success alone is not task completion. Use the harness’s usual task logs and report any unresolved limitation.

Cornice scopes these tools to a desktop, but applications still run as the same Linux user. Application launch is not an OS sandbox. This skill does not grant permission for publication, messages, payments or other external actions beyond the user’s task.
