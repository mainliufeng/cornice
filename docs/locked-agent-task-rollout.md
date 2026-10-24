# Paired rollout and rollback: approval plan only

No command below has been run against the host installation or login selection.
The candidate was tested only in private compositors. Do not hot-replace the
running compositor, unlock the current session, or apply this as a UI-only update.
The compositor and Broker changes require a matched new session.

## Recommendation and current identities

Software verification permits preparing and arming **one future login trial**
after explicit owner approval. Full persistent rollout is deferred until the
owner validates the actual display, PAM and suspend/wake behavior in that trial.
The current session is not restarted by prepare/arm. Saving work and ordinary
logout/login remain the owner's actions.

Read-only host inspection found the current/selected release:

```
/home/liufeng/.local/state/cornice/session-trial/releases/20261017-181706-8b686a8e
```

Candidate sources and tested executable:

```
/home/liufeng/Documents/Codex/2026-10-24/task-2/cornice
/home/liufeng/Documents/Codex/2026-10-24/task-2/hyprland/build-candidate/Hyprland
```

Workspace-only inputs are in
`/home/liufeng/Documents/Codex/2026-10-24/task-2/rollout/`:

* `previous-state/`: read-only copies of selection/prepared/current records.
* `hyprland.lua`: current immutable configuration copied to the workspace; its
  22 old product-path references point at the candidate source so `prepare`
  rewrites them to the new immutable product. No other configuration changed.
* `autostart.json`: the existing 16 commands copied unchanged; none references
  the old release. They have not been executed by this task.
* `manifest.json`: input checksums and previous release/manifest identity.

These copied files are mode 0600. The original profile, selection and files were
not modified. Re-read the selected/current release before applying: if they no
longer match the above release, stop and regenerate/review these inputs rather
than overwriting another deployment's state.

## Exact commands after approval

Use the existing immutable snapshot mechanism. This avoids overwriting
`/usr/bin`, the stable Cornice installation or the previous release. It needs no
package install and no development symlink install. It copies the already-built
native helpers/modules and pinned MCP dependencies from the tested source tree.

```
task_root=/home/liufeng/Documents/Codex/2026-10-24/task-2
trial_state=/home/liufeng/.local/state/cornice/session-trial
trial_cli="$task_root/cornice/bin/cornice-session-trial"
previous_release=/home/liufeng/.local/state/cornice/session-trial/releases/20261017-181706-8b686a8e

CORNICE_TRIAL_STATE_DIR="$trial_state" /usr/bin/python3 "$trial_cli" status
# Check selected/current identity against rollout/manifest.json first.

XDG_CONFIG_HOME="$previous_release/config-home" \
CORNICE_TRIAL_STATE_DIR="$trial_state" /usr/bin/python3 "$trial_cli" prepare \
  --hyprland "$task_root/hyprland/build-candidate/Hyprland" \
  --cornice "$task_root/cornice" \
  --config "$task_root/rollout/hyprland.lua" \
  --autostart "$task_root/rollout/autostart.json"
```

The explicit `XDG_CONFIG_HOME` preserves the currently selected release's active
Cornice settings, rather than accidentally taking a different stable-install
configuration from `~/.config`. The prepare command copies them into the new
snapshot; it does not edit the old config-home.

Record the returned absolute `prepared` release path and verify its manifest,
Hyprland/Broker hashes against `evidence/candidate-binaries.sha256`, plus the
prepared configuration/product paths. `prepare` snapshots the user's Cornice
configuration, adds the already-existing candidate-only orphan-lock UI restore
policy, and freezes all matched artifacts. This restores authentication UI only;
it does not authenticate or unlock. No new Agent permission switch is added.

The installed Codex plugin uses bare `cornice-desktop-mcp`, currently resolving
to `/home/liufeng/.local/share/cornice/bin/cornice-desktop-mcp`. That old client
still applies the old continue-only check and does not send the completed
outcome. Therefore the approved matched deployment must also point this CLI
entry at the new immutable product. No plugin schema or user Agent authorization
step is added. **This entrypoint has not been changed by the candidate task.**

After verifying the prepared release, set `new_release` to that exact returned
path and replace only this symlink under the existing installer lock:

```
new_release=/absolute/path/returned/by/prepare
mcp_entry=/home/liufeng/.local/bin/cornice-desktop-mcp
mcp_old=/home/liufeng/.local/share/cornice/bin/cornice-desktop-mcp
mcp_staged="$mcp_entry.next-$(basename "$new_release")"
(
  set -eu
  flock -x 9
  test -L "$mcp_entry"
  test "$(readlink "$mcp_entry")" = "$mcp_old"
  test -x "$new_release/cornice/bin/cornice-desktop-mcp"
  ln -s -- "$new_release/cornice/bin/cornice-desktop-mcp" "$mcp_staged"
  mv -T -- "$mcp_staged" "$mcp_entry"
) 9>/home/liufeng/.local/state/cornice/install.lock
```

A failed guard/creation stops before replacing the entry. Keep the recorded
old target for rollback. Existing MCP processes remain the old code until they
exit: do not reuse their task references or hot-restart them to bypass the
current Broker. After the future login, reconnect/restart the Cornice MCP
integration if needed and verify its node command points into the new release.
The updated client remains compatible with ordinary old-Broker operations;
it does not bypass the old Broker's locked acquire refusal.

Then, for the existing running managed session:

```
CORNICE_TRIAL_STATE_DIR="$trial_state" /usr/bin/python3 "$trial_cli" arm --after-current
CORNICE_TRIAL_STATE_DIR="$trial_state" /usr/bin/python3 "$trial_cli" status
```

Readback must show the original running release unchanged, the new release as
`nextLogin.mode=trial`, and the previous persistent selection preserved. `arm`
updates the managed login snippet in `.zprofile` and writes a one-use ticket; it
does not stop current Cornice/Hyprland. Do not call `select` merely to try it.
The owner can then save work, log out normally and choose the existing SDDM
Hyprland entry. Never send logout/restart/lock/PAM input automatically as part of
this approval. After the future login, check `current.release` matches the new
release before any physical acceptance step.

`session-trial-verify.py` exercises the real prepare/immutable product, synthetic
SDDM login, readiness, failure and rollback paths inside private namespaces;
this does not constitute a real SDDM login acceptance.

## Rollback and exact effects

To cancel before the new login, or select the old pair for the next normal
login without ending the current one:

```
CORNICE_TRIAL_STATE_DIR="$trial_state" /usr/bin/python3 "$trial_cli" select \
  --release /home/liufeng/.local/state/cornice/session-trial/releases/20261017-181706-8b686a8e
CORNICE_TRIAL_STATE_DIR="$trial_state" /usr/bin/python3 "$trial_cli" status
```

This cancels a pending one-shot ticket and restores the previous immutable pair.
Restore the MCP entry as well (using the recorded `new_release`, `mcp_entry`
and `mcp_old` from the apply step):

```
mcp_restore="$mcp_entry.previous-$(basename "$new_release")"
(
  set -eu
  flock -x 9
  test -L "$mcp_entry"
  test "$(readlink "$mcp_entry")" = "$new_release/cornice/bin/cornice-desktop-mcp"
  test -x "$mcp_old"
  ln -s -- "$mcp_old" "$mcp_restore"
  mv -T -- "$mcp_restore" "$mcp_entry"
) 9>/home/liufeng/.local/state/cornice/install.lock
```

Do not overwrite an entry that another deployment changed. Reconnect MCP only
in the chosen future session; no old lease is restored. A one-shot trial's
automatic return to the old compositor does not automatically undo this separate
CLI link.
While already running the new pair, it affects the **next** normal login only.
The owner saves work and logs out normally to use that choice.

Emergency `session-trial rollback` (or Super+Ctrl+Alt+Backspace) **ends the running
managed trial and clears both pending and persistent selection**, returning the
next login to `/usr/bin/start-hyprland`. Never invoke it against the old current
release or without explicit permission to end a session. After returning to a
usable stable login/TTY, use the preceding `select --release ...` if the old
paired release is desired instead of the system stable entry. `cancel` similarly
clears persistent selection but does not end the current session; it is not the
command for restoring the previous selected pair.

No old immutable release, system binary or stable installation is overwritten.
Do not restore raw JSON selection files while a supervisor is running; use the
validated CLI to avoid stale identities. Leases are not migrated or revived.

## Risks and unresolved physical acceptance

* Real DRM/physical output coverage and hotplug/mirroring, actual user PAM, lid
  close and hardware suspend/wake remain untested. Until performed in the future
  trial, these block calling the change fully production-accepted.
* The new lock-created lease is revoked on unlock/lock epoch change. Tasks must
  handle interruption; no old-frame/browser replay is permitted.
* User configuration/autostart is preserved, not sandboxed. Applications keep
  the same Linux UID and file/network access. Existing application effects are
  not undone by revoking desktop control.
* System libraries remain shared. In particular Qt 6.12's new `Color` singleton
  broke the unmodified baseline shell; the candidate's separate namespace fix
  was verified with real baseline/candidate rendering. Returning to the old
  release also returns its original UI behavior under the system Qt version.
* Snapshot creation/arming and future login activation are separate actions.
  There is no technical reason to install into the active session or bypass the
  running old Broker's lock refusal.
