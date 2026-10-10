---
name: cornice-desktop
description: Acquire and operate a task-owned Cornice desktop, including native apps and its managed browser, through Cornice tools. Use when asked to perform or observe a task on a Cornice desktop.
---

Use the Cornice MCP tools for the desktop assigned to this harness. Tool names may carry a host prefix; identify them by their `desktop_` or `browser_` suffix.

- For a new task, call `desktop_acquire` with no arguments. It reuses an allowed, unoccupied secondary desktop or creates a new desktop. Existing applications are preserved when a task-free desktop is reused; observe them before acting. Use `preferredDesktop` only when the user named a specific desktop, or `createNew:true` when the user requested a fresh desktop. An occupied preferred desktop creates another desktop; disabled or missing named desktops fail explicitly.
- Save the returned `desktop` reference in this task's context and pass it to **every** desktop and browser tool. Never use another conversation's reference. Call `desktop_state` with that reference before operating. Primary desktop is never automatically selected and still requires its pre-enabled “允许 Agent 控制” switch.
- A legacy explicitly assigned session starts with `desktop_state` and omits the reference; it cannot acquire other desktops. Do not change permissions or issue management credentials yourself.
- For browser work, use `desktop_browser_connect`, inspect `browser_tabs`, then use a fresh `browser_snapshot` tree and semantic actions. Browser tools address only that desktop’s Broker-managed browser. Never connect to a global CDP port or an unrelated browser profile.
- For native apps or visual information absent from the browser tree, use `desktop_capture`. Its coordinates are pixels in `pixelSize`; pass its fresh `frameId` to `desktop_input`. After focus/workspace changes, observe again. Native accessibility trees are not currently exposed.
- Permission changes, pause, human takeover and session lock can revoke control. Do not call desktop_acquire again to escape an interruption of this task. Stop sending input, then choose `desktop_wait` or `desktop_finish` with an explained blocker/cancellation. After explicit restoration reconnect and observe again; a human may have changed the page, focus or workspace. Never blindly replay an action with uncertain outcome.
- Verify the user’s actual requested result before `desktop_finish completed`. Tool success alone is not task completion. Use the harness’s usual task logs and report any unresolved limitation.

Cornice scopes these tools to a desktop, but applications still run as the same Linux user. Application launch is not an OS sandbox. This skill does not grant permission for publication, messages, payments or other external actions beyond the user’s task.
