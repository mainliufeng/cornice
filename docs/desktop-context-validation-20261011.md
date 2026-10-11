# Desktop context validation — 2026-10-11

Branch: `codex/agent-desktop-recovery`. Main and Hyprland source were not changed.
Tests used private compositors, HOME, D-Bus and native virtual input; no physical
session was used to test locks, application launches or focus changes.

## Targeted results

| Suite | Passed groups |
| --- | ---: |
| Desktop workspace/window contract | 8 |
| Desktop/session context integration | 6 |
| Native Launcher first shortcut/Enter and restart | 11 |
| Real Fcitx/GTK/Chrome input method | 9 |
| Native lock, owner loss and sleep lifecycle | 17 |
| Configured application profiles and identity negatives | 6 |
| Shared session services, readonly actions/replies and reconnect | 10 |
| IPC routing, stale identity and framing negatives | 7 |
| Installation dependencies and copy completeness | 23 |
| **Total** | **97** |

The readonly workspace bar and notification center were visually inspected.
Real pointer clicks, keyboard typing and actual freedesktop action/reply signals
were asserted; IPC diagnostics alone were not the success criterion.

## Existing broad-suite baseline

The working-product headless suite returned **322 PASS / 31 FAIL**, exactly the
same failures and details as the prior baseline. There were no added or removed
failure labels. The known failures concern geocoding, power tooltips, menu
keyboard/cascade checks and the isolated logind monitor.

Fresh `install.sh --copy` verification exported the initial refactor commit
`883a22b98cece41f57d4dd1e3b1a328c4a9bf387`. All helpers were installed; installed
configuration, modules and source files matched that archive. The installed
headless run returned **323 PASS / 31 FAIL**, with the same 31 baseline failures.
Consequently the complete headless/install gate is **not green**; no new broad
regression was found. Subsequent changes added stricter service ID type
validation and extended real notification/reconnect tests, which passed.

Local evidence:

- `/tmp/cornice-context-headless.log`
- `/tmp/cornice-context-headless-comparison.json`
- `/tmp/cornice-context-install-verify.log`
- `/tmp/cornice-context-install-comparison.json`
- `/tmp/cornice-session-services-native-verify.log`
- `/tmp/cornice-desktop-state-contract-final.log`
- `/tmp/cornice-context-integration-final.log`
- `/tmp/cornice-context-launcher-final.log`
- `/tmp/cornice-context-ime-final.log`
- `/tmp/cornice-context-lock-final.log`
- `/tmp/cornice-context-app-rules-final.log`
- `/tmp/cornice-context-ipc-final.log`
- `/tmp/cornice-python-installer-test.log`

## Activation boundary

The current physical session is locked and its supervisor treats main shell or
Broker termination as failure. A candidate can be snapshotted and selected for
the next login; hot replacement would risk the lock owner and existing session.
Physical activation must be reported separately from the passing isolated tests.
The managed login snippet is reversible with `cornice-session-trial cancel` or
`cornice-session-trial remove-hook`; the current desktop need not be terminated
by an agent to prepare the candidate.
