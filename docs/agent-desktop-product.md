# Independent desktop product boundary

Cornice supplies independent desktops; Codex, Pi and other external harnesses own their conversations, models, execution history and task results. Cornice does not run an embedded agent, configure a model gateway or collect task prompts.

The initial layout is the primary desktop plus one secondary desktop. Further desktops are created on demand through the harness tools. Desktop occupancy is a live control lease, not the presence of open applications. An external task acquires a free desktop or requests a new one; releasing the lease preserves its applications. Primary automation permission is disabled by default and requires explicit selection after it has been enabled.

Every desktop has the same native applications, workspace switching, capture and input capabilities. Workspace slots belong to that desktop identity. Observing another desktop is read-only; human takeover is a separate explicit action. Pausing, takeover, permission changes and locking revoke previous input grants. Continuing work requires respecting the current control state rather than replaying queued input or acquiring another desktop to bypass interruption.

The desktop UI manages desktop selection, observation, control, previews and live harness status. It has no new-task button, task editor, model setup, task submission hotkey or cancellation of harness conversations. Users create and follow their tasks in their chosen harness.

See [external harness integration](desktop-harness.md) for MCP/skill installation and allocation, [observation routing](agent-observation.md) for native and browser observation, and DESIGN.md for the current UI specification.
