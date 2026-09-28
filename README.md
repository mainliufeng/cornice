# Cornice
#
# A Hyprland shell built on Quickshell: one process for the bar and, later,
# panels, notifications and the launcher.
#
# Design notes live in DESIGN.md. This file records how to run it and where the
# boundaries are.

## Status

**P0 + P1 + P2 complete and verified** (33/33 checks in the headless harness).

- **Bar** — workspaces, active window, media (MPRIS), clock, indicators,
  system tray, network, bluetooth, audio, power, spacer. Config-driven layout,
  deep-merged user config, themed through tokens.
- **Panels** — clock/calendar, audio (sink/mic volumes, device list), network
  (Wi-Fi list + connect), bluetooth (scan, pair, connect), power (battery,
  power profiles, session actions), notification centre.
- **Notifications** — the shell owns `org.freedesktop.Notifications`: popups,
  history, do-not-disturb, action buttons, and a centre panel.
- **OSD** — volume/microphone/brightness overlay that also follows PipeWire
  volume changes (so volume keys show it without any wiring).
- **Launcher** — desktop entries with live filtering, keyboard navigation and a
  `>` run-command mode.
- **IPC** — the shell serves its own socket (`~/.local/share/cornice` style JSON
  line protocol) so plugins keep their own targets even though they load at
  runtime; `cornice ipc <target> <method> [args]` plus convenience verbs.
- **Verification** — `test/headless-verify.sh` (private compositor, never
  touches your GPU or session) and `cornice verify` (checks the shell you are
  looking at, inside a real Hyprland session).

Not implemented yet: lock screen, polkit agent, wallpaper, clipboard overlay.

Verified by `test/headless-verify.sh` (exit 0, 33 checks), which:
1. creates a private session bus, then starts a headless mutter and a **nested
   Hyprland** inside it — the Wayland backend, never DRM, so your real GPU,
   screen and desktop are untouched;
2. creates a headless output in that compositor and runs the shell there;
3. asserts IPC over the shell's own socket, all 15 plugins, every bar widget,
   and each of the six panels opening and closing;
4. delivers a real notification over D-Bus and checks the popup, the history
   and the do-not-disturb behaviour;
5. opens a window (kitty) to prove widgets react to compositor state, types
   into the launcher with `wtype`;
6. screenshots the result and asserts both the bar strip and the panel/OSD
   surfaces actually painted.

The assertion is visual as well as programmatic: workspace pills 1–5 (active
one highlighted), the focused window title, `Mon HH:MM`, and the battery
percentage all render.

Not implemented yet: panels, notifications, OSD, launcher, lock screen.
Audio is wired but only shows when PipeWire is reachable.

## Requirements

- Hyprland (Wayland session)
- Quickshell — `sudo pacman -S quickshell` (Arch `extra`)
- `jq` or `python3` (to read plugin manifests)
- A Nerd Font for the bar glyphs
- Optional: `wpctl` (PipeWire volume), `fc-list` (doctor)

## Install

```bash
git clone <this repo> ~/Code/self/cornice
for f in cornice cornice-doctor cornice-launch cornice-restart cornice-qs; do
  ln -sfn "$PWD/bin/$f" ~/.local/bin/$f     # ~/.local/bin must be on PATH
done
cornice doctor
```

Quickshell is needed. Prefer the package (`sudo pacman -S quickshell`, Arch
`extra`). Without sudo, `bin/cornice-qs` falls back to a user-local vendor tree
at `~/.local/share/cornice/vendor/root`, which is enough to develop and test;
`cornice doctor` tells you which of the two is in use.

Then add to `~/.config/hypr/hyprland.conf` — Cornice never edits it for you:

```conf
exec-once = cornice-launch
```

Cornice deliberately does **not** touch:

- `~/.config/hypr/hyprland.conf` (you paste the snippet yourself)
- `~/.config/hypr/*` (your lock screen, idle daemon, wallpaper stay yours)
- any system package or service

Rollback is `cornice stop` plus deleting the line you added.

## Commands

```bash
cornice start | stop | restart | status
cornice ping | version | plugins | widgets | targets | socket | config | theme [name]
cornice reload | reload-plugins
cornice panel <plugin-id> [json]   # toggle any panel
cornice launcher | notifications | dnd [on|off]
cornice osd volume | microphone | brightness | hide
cornice doctor                    # environment, conflicts, config
cornice verify                    # the running shell, in your real session
cornice logs
```

## Configuration

`~/.config/cornice/config.json` is deep-merged over `config/default.json`, so
you only write what differs:

```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "cn.battery", "showTimeRemaining": true },
        { "id": "cn.audio", "step": 10 }
      ]
    }
  }
}
```

Arrays are replaced, objects are merged. `cornice config` prints the result.

## Themes

Themes are `themes/<name>/theme.json` (`colors` + `metrics`). Override any
theme with `~/.config/cornice/theme.json`; switch by name with
`cornice theme <name>` or `"theme": "<name>"` in your config.

## Plugins

A plugin is a directory with a `manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "me.hello",
  "name": "Hello",
  "version": "0.1.0",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "Widget.qml" }
}
```

Built-in plugins live in `shell/plugins/`, yours in
`~/.config/cornice/plugins/<id>/`. A bar widget is a QML `Item` that declares:

```qml
property var host          // the ShellRoot: config, registries, IPC
property var plugin        // this plugin's manifest
property var widgetConfig  // the entry from config.json
```

Plugin code runs inside the shell process, unsandboxed — same trust model as
any dotfile. Run `cornice reload-plugins` after adding one.

## Verify without touching your desktop

`test/headless-verify.sh` starts a private headless Hyprland in a temporary
`XDG_RUNTIME_DIR`, runs the shell there, asserts IPC answers, screenshots the
bar with `grim`, and tears everything down. Your session, your config and your
running bar are untouched.
