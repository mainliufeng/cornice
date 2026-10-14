# Seat lock response normalization — 2026-10-14

The public Hyprland fork at `b18a6b98136420efc3838bab6bd4a7f7de02fff7` returns `lockScope=session` for full session locks and `scoped` for scope locks. Cornice uses the internal values `full` and `human`. The native adapter already translated scoped locks, but omitted session locks. ClipboardBridge only gates full-session access and cancels all transfers for `full`; an untranslated response did not reach that branch.

The fix adds `session → full` at the existing adapter boundary. State, control, lock-policy and seat-list responses all use that boundary. It does not change compositor policy, daily-lock continuation, authentication or the wire protocol. This is a statically confirmed control-flow defect; no clipboard leak was observed in the live desktop.

## Verification

Five regression cases exercise the actual adapter through private UNIX IPC, covering state/control/policy replies and both seat-list spellings. They verify full locks, scoped continuation, canonical legacy fields and unlocked states. Compositor replies alone are test doubles; the sockets, transport and adapter implementation are real.

The committed baseline with these cases exits 1: 26 existing cases pass and all 5 added cases fail. The fixed adapter exits 0: 31 pass, 0 fail. The complete resource-scoped comparison exits 0. No physical device or display is exposed to this test.

Artifacts: `/home/liufeng/.local/state/cornice/release-validation/20261014/seat-lock-adapter/before.log` and `after.log`; reproducible runner `/tmp/cornice-seat-lock-adapter-verify-20261014.sh`.

This verifies schema normalization, not real GUI clipboard cancellation during a session lock. That end-to-end gate remains pending on the final freshly installed candidate and matching compositor. The existing staged/live native helpers have not been replaced.

The remaining static compatibility audit matches 11 required capabilities and the principal seat command/response shapes. Static review does not count as runtime acceptance. Named Wayland connections in SeatDriver/ClipboardBridge still need an inherited-WAYLAND_SOCKET regression; the management connection already handles that case explicitly.
