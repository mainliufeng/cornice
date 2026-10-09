# Unified desktop integration validation

2026-10-09. Cornice remains on `codex/agent-desktop-recovery`; Hyprland remains on `codex/cornice-agent-desktop`. No main branch was merged. Hyprland candidate reports commit `054534629b3c6bb3bbcfd949aafb70529dcc98c5`.

## Actual execution

- `desktop-harness-verify.py`: real isolated Hyprland/Broker, primary and two secondary desktops, standard MCP client, full-resolution JPEG, GTK Unicode input and fresh-frame rejection. Both primary and secondary managed Chrome complete the same tree/type/click form task. Permissions off, competing harness, detach, native takeover, lost heartbeat, full lock and Broker restart revoke control as expected.
- `codex-plugin-verify.py`: actual installed Codex 0.160.1 installs the local marketplace/plugin in an independent configuration directory, discovers `cornice:cornice-desktop`, starts the bundled MCP and lists 23 live tools. Plugin installation does not grant a desktop.
- `agent-browser-model-verify.py`: actual Pi 1.1.0 and configured DeepSeek gateway complete a real browser form using shared MCP trees, with zero images and the primary desktop unchanged.
- `agent-model-verify.py`: actual model operates GTK through the shared MCP, verifies Chinese input/click, waits through native human takeover, resumes after explicit restoration, chooses cancellation when appropriate, and stops on user cancellation. Duplicate submissions leave the active job intact.
- `desktop-switcher-verify.py`: real bar/menu clicks, read-only observation, native pointer/keyboard/Fcitx, focus cycling, fullscreen/floating/drag/launch/close, workspace shortcuts, scrolling, laptop resolution, session lock and UI/Broker crash recovery. The Agent permission switch preserves human takeover input.
- `human-lock-verify.py`: 17 checks covering ordinary/full lock, CDP revocation, native authentication, guardian death, inhibitor/suspend/resume and output loss. Host sleep and lock are never invoked.
- `session-trial-verify.py`: real isolated login hook, new primary desktop health contract, one-shot consumption, supervisor/compositor failures, bounded shutdown and rollback.
- `headless-verify.sh`: 321 shell checks pass, including primary window/workspace widgets and no QML errors.
- `install-test.sh` and `install-verify.sh`: installer checks and fresh committed-tree installation pass; plugin, skill and MCP source files are included.
- `agent-runtime-protocol-verify.py`: 25 regressions pass. `mcp-transport-verify.mjs` checks actual SDK transport, bridge errors, environment stripping, terminal control and equality with the pinned real Playwright tool schemas. `agent-screenshot-verify.ts` loads the actual thin Pi extension and checks historical-image pruning.

## Delivery and scope

All destructive lock/suspend/input tests use a separate compositor/device/PID/bus environment and fixture applications. Real model tests send only test application content. Native accessibility trees are still unavailable; browser observation uses the pinned Playwright implementation. This is a same-user coordination boundary, not an OS sandbox.

The new compositor and Cornice must be selected together at a new login; replacing the running compositor would end the current session. The existing one-shot trial mechanism prepares an immutable candidate, preserves the current desktop, and supports `cornice-session-trial cancel` before login and the existing rollback shortcut afterwards. Integration instructions are in [desktop-harness.md](desktop-harness.md).
