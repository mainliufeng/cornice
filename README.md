# Cornice
#
# A Hyprland shell built on Quickshell: one process for the bar, panels,
# notifications, the launcher, the lock screen and idle handling.
#
# Design notes live in DESIGN.md. This file records how to run it and where the
# boundaries are.

## Status

Implemented and verified on a real Hyprland session (and in a private headless
compositor stack in CI-ish runs):

- **Bar** — workspaces, active window, media (MPRIS), clock, indicators, system
  tray, network, bluetooth, audio, power, spacer. Config-driven layout,
  deep-merged user config, themed through tokens.
- **Panels** — clock/calendar, audio (sink/mic volumes, device list), network
  (Wi-Fi list + connect), bluetooth (scan, pair, connect), power (battery,
  profiles, session actions), media (cover, progress, transport, volume,
  player switching), notification centre.
- **Notifications** — the shell owns `org.freedesktop.Notifications`: popups,
  history, do-not-disturb, action buttons, centre panel. It reclaims the bus
  name if another daemon disappears mid-session.
- **OSD** — volume/microphone/brightness overlay that also follows PipeWire
  volume changes, so the volume keys show it with no wiring.
- **Launcher** — desktop entries with live filtering, keyboard navigation and a
  `>` run-command mode.
- **Clipboard / emoji** — cliphist-backed history (type to filter, Enter copies,
  images previewed) and a searchable emoji picker.
- **Weather** — open-meteo (no API key): current conditions, next hours and next
  days in the bar and a panel. Located by `weather.city`, explicit coordinates,
  the system timezone or the IP address, in that order (the timezone is tried
  before the IP lookup because a VPN makes the IP report its exit node).
- **Keyboard layout** — the active Hyprland layout, fed by the compositor's event
  socket, click to cycle; hidden by default when only one layout is configured.
- **Inline reply** — notifications that carry an `inline-reply` action get a reply
  field in the notification centre (never in the popup: that would have to steal
  the keyboard).
- **Lock screen** — PAM-backed, `loginctl lock-session` aware, refuses to lock
  when PAM is unusable, releases an abandoned lock, documents the TTY recovery
  path when a lock client dies, and releases the session lock on graceful
  shutdown so `cornice stop`/`restart` never strand the session. Its background
  is the current wallpaper by default (no screenshot, no grim), with
  `lock.background: "screenshot"` to go back to the old behaviour.
- **Polkit agent** — in-shell authentication dialog (so `polkit-gnome` can go).
- **Wallpaper** — static layer with per-workspace overrides that yields to
  mpvpaper/hyprpaper/swaybg/swww/wbg unless `background.force` is set.
- **Idle** — dim, display-off and lock with separate AC/battery timeouts, idle
  inhibitor awareness, and a startup self-heal for a dimmed backlight left by a
  crash.
- **IPC** — the shell serves its own socket (JSON-lines) so plugins keep their
  own targets even though they load at runtime.
- **Takeover** — `cornice takeover` finds the daemons cornice replaces
  (mako/dunst/swaync, hypridle, waybar, polkit-gnome, …), shows a plan, and
  comments them out with a backup and a one-command undo.

Verification:

| Suite | What it covers |
| --- | --- |
| `test/headless-verify.sh` | private compositor: startup, every plugin, every bar widget, every panel, notifications over D-Bus, painting |
| `test/lock-verify.sh` | private compositor: lock success/failure/emergency unlock, never touches the live PAM stack |
| `test/takeover-test.sh` | sandbox: takeover plan/apply/idempotence/backup/undo round trip |
| `cornice verify` | the session you are actually looking at |

`cornice test` runs the applicable ones; `cornice test --quick` skips the two
that build a private compositor.

## Requirements

- Hyprland (Wayland session)
- Quickshell — `sudo pacman -S quickshell` (Arch `extra`)
- `jq` or `python3` (to read plugin manifests)
- A Nerd Font for the bar glyphs
- Optional, one per feature: `socat` (CLI → runtime plugins), `grim`
  (screenshots in `cornice verify`), `wpctl`/WirePlumber (audio), `bluez`
  (bluetooth), `brightnessctl` (brightness OSD), `cliphist` (clipboard
  history), `light` (idle dimming), `NetworkManager` (network panel), a Nerd
  Font (`ttf-nerd-fonts-symbols`) for the bar glyphs, `fc-list` (doctor)

## Install

```bash
git clone <this repo> ~/Code/self/cornice
cd ~/Code/self/cornice
./install.sh                 # symlink the CLI into ~/.local/bin, check deps
```

`./install.sh` never needs root and never edits a config file. Options:

```bash
./install.sh --copy              # self-contained tree in ~/.local/share/cornice
./install.sh --prefix /usr/local # somewhere else
./install.sh --takeover          # also hand over from mako/hypridle/… (see below)
./install.sh --uninstall         # remove the binaries (config and state stay)
make install                     # same as ./install.sh
```

Arch users can build a package instead — the PKGBUILD builds from the working
tree (there is no public remote yet):

```bash
make pkg        # makepkg -si; installs to /usr/share/cornice + /usr/bin
```

Then add one line to `~/.config/hypr/hyprland.conf`:

```conf
exec-once = cornice-launch
```

Cornice deliberately does **not** edit your Hyprland config, your
`~/.config/hypr/*`, or any package — except through `cornice takeover --apply`,
which does it explicitly, visibly, with backups. Optional keybinds live in
`config/snippet.hyprland.conf`; paste what you want.

Rollback: `cornice stop`, remove the `exec-once` line, `./install.sh --uninstall`.

## Commands

```bash
# lifecycle
cornice start | stop | restart | status | logs | health
cornice launch                       # foreground, with the watchdog

# inspecting the running shell
cornice ping | version | plugins | widgets | targets | socket | path
cornice config | theme [list|toggle|<name>] | reload | reload-plugins
cornice ipc <target> <method> [args] # raw IPC, e.g. cornice ipc idle status
  #   shell.windows            every panel/popup window and where it is
  #   shell.debug              counts, config path, service registry
  #   weather.{status,refresh,locate,place}
  #   keylayout.{status,next,refresh}
  #   idle.{status,dim,undim,displayOff,displayOn,lock,inhibit <s>,release}
  #   notifications.{status,inspect,reply <id> <text>,setDnd,markRead,dismissAll}
  #   lock.status / background.status / media.status

# things you bind to keys
cornice launcher | clipboard | emojis | notifications | dnd [on|off]
cornice panel <plugin-id> [json]     # toggle any panel
cornice osd volume | microphone | brightness | hide
cornice lock [status|try <pw>|emergency-unlock]
cornice background [status|set <path>|next|prev|clear|reload]

# machine
cornice doctor                       # dependencies, compositor, conflicts
cornice verify                       # the shell you are looking at
cornice takeover [--apply|--undo]    # hand over from mako/hypridle/waybar/…
cornice test [--quick|takeover|headless|lock|live]
cornice session-env                  # compositor env exports for TTYs/stale shells
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
The keys that are not just bar layout:

| Key | Default | Meaning |
| --- | --- | --- |
| `theme` | `"mono"` | active theme (`mono` dark, `dawn` light) |
| `background.enabled` | `true` | paint a static wallpaper layer |
| `background.dir` | `~/Pictures/wallpapers` | directory scanned for images |
| `background.mode` | `"fill"` | `fill` / `fit` / `stretch` / `center` / `tile` |
| `background.perWorkspace` | `{}` | `{"2": "/path/to.png"}` overrides |
| `background.force` | `false` | take over even if mpvpaper/hyprpaper/swaybg/swww runs |
| `notifications.takeover` | `true` | reclaim `org.freedesktop.Notifications` if it is free |
| `notifications.inlineReply` | `true` | advertise inline reply; clients then get a reply field in the centre |
| `weather.city` | `""` | city name to geocode (beats everything else) |
| `weather.latitude` / `weather.longitude` | `null` | explicit coordinates, used as-is |
| `weather.autoLocate` | `true` | locate via the timezone, then the IP address |
| `weather.useTimezone` | `true` | prefer the system timezone's city over the IP lookup (VPN-safe) |
| `weather.unit` | `"metric"` | `metric` or `imperial` |
| `weather.intervalMinutes` | `15` | refresh cadence (minimum 5) |
| `lock.background` | `"wallpaper"` | `wallpaper`, `screenshot` or `none` |
| `lock.blur` / `lock.scrim` | `1.0` / `1.0` | lock background blur and darkening |
| `idle.dimAc` / `idle.dimBattery` | `60` / `0` | seconds before the backlight dims (0 = never) |
| `idle.screenOffAc` / `idle.screenOffBattery` | `120` / `300` | seconds before the display turns off |
| `idle.lock` | `300` | seconds before the session locks |
| `idle.respectInhibitors` | `false` | if true, apps holding an idle inhibitor also block dim/lock (browsers hold them for all sorts of reasons, so this is off by default) |
| `idle.lockOnSleep` | `true` | lock when logind says the machine is about to suspend (hypridle's `before_sleep_cmd`) |
| `idle.lockOnLockSignal` | `true` | lock on logind's `Session.Lock` — this is what makes `loginctl lock-session`, lid scripts and power managers work |
| `idle.lockOnLidClose` | `true` | lock when the lid closes, even if logind is not going to suspend (skipped when an external screen is attached) |

`cornice ipc idle inhibit 3600` holds the idle chain off for an hour (and
`cornice ipc idle release` ends it early) — for long downloads, presentations,
or a test run that should not trip the lock screen.

## Themes

Themes are `themes/<name>/theme.json` (`colors` + `metrics`). Override any
theme with `~/.config/cornice/theme.json`; switch by name with
`cornice theme <name>` or `"theme": "<name>"` in your config.

## Plugins

A plugin is a directory with a `manifest.json` and QML:

```json
{
  "schemaVersion": 1,
  "id": "me.hello",
  "name": "Hello",
  "version": "0.1.0",
  "kinds": ["bar-widget", "panel"],
  "entryPoints": { "barWidget": "Widget.qml", "panel": "Panel.qml" }
}
```

Built-ins live in `shell/plugins/<group>/<id>/`, yours in
`~/.config/cornice/plugins/<id>/`. Entry points are instantiated with `host`
(the shell: `config`, `services`, `summon`, `toggle`) and `plugin` (the
manifest). Bar widgets additionally receive `widgetConfig` (their entry in
`config.json`). Run `cornice reload-plugins` after adding one.

**Full guide: [docs/plugin-api.md](docs/plugin-api.md)** — kinds, the service
pattern, `PanelFrame`, `ShellIpc`, theming rules and the traps that have already
bitten this codebase (five-digit glyph escapes, anchors on plugin roots, …).

## Idle

`cn.idle` replaces hypridle: three `IdleMonitor`s for dim, display-off and lock,
with separate AC and battery timeouts (see the configuration table). It uses the
backlight for dimming — like the `idle.sh` it replaced — and restores the
previous level at startup, so a crash cannot leave the screen dim.

logind wiring (it replaced hypridle's `before_sleep_cmd`/`after_sleep_cmd` and its
own lock handler, so nothing else would do this):

- `PrepareForSleep(true)` → lock the session before it suspends;
- `PrepareForSleep(false)` → display on and un-dim (the panel is often still off
  when the session comes back);
- `Session.Lock` → lock, which is what `loginctl lock-session` and most power
  managers actually call;
- `LidClosed` → lock, and this one matters more than it looks: a plugged-in
  laptop with the default `HandleLidSwitch` never suspends, so there is no
  `PrepareForSleep` at all — only the lid property change. Skipped while a second
  screen is attached, because then the lid is being used as a "close the panel"
  gesture rather than "I am leaving".

The monitor is a `gdbus monitor --system --dest org.freedesktop.login1` child; if
it dies the shell restarts it every 15s. `cornice ipc idle feed "<signal line>"`
injects a line into the parser — that is how the test suites cover suspend
without suspending your machine.

Events worth knowing:

- any input un-dims and turns the display back on;
- `cornice ipc idle status` reports `dimmed`, `screenOff`, `inhibited`, the
  effective timeouts and whether the lock service is loaded;
- the lock step refuses to run when the compositor already reports a locked
  session (acquiring a second lock used to kill the whole shell).

## Wallpaper

The background layer ships enabled with a built-in default wallpaper (so a fresh
install is never a flat colour) and steps aside for any other wallpaper tool —
mpvpaper, hyprpaper, swaybg, swww-daemon, wbg. To use your own images:

```json
{
  "background": {
    "enabled": true,
    "dir": "~/Pictures/wallpapers",
    "mode": "fill",
    "perWorkspace": { "1": "~/Pictures/one.png" },
    "force": false
  }
}
```

```bash
cornice background status        # what is drawn right now
cornice background next          # cycle through `dir`
cornice background set ~/x.png   # one-off override
cornice background clear         # back to dir/path
```

`force: true` draws even while another wallpaper tool runs (they will overlap, so
pick one). Without a `path`/`dir`, the shipped `wallpapers/default.png` is used.

## Resources

Measured with `./test/benchmark.sh --compare` on a 3072x1920 eDP-1 session (PSS,
12s window, all 23 plugins loaded):

| Stack | Memory | CPU (idle) |
| --- | --- | --- |
| cornice | ~200 MiB | ~0.1% |
| waybar + mako + hypridle | ~46 MiB | ~0.2% |

Cornice is the bigger process, and it should be reported plainly: it is a Qt
Quick runtime, and it also replaces more than those three daemons (lock screen,
polkit agent, launcher, clipboard history, emoji picker, notification centre and
seven panels, weather, media control). Attribution, measured the same way:

| Part | Cost |
| --- | --- |
| bare Quickshell + one layer surface | 62 MiB |
| each additional layer surface | ~5.5 MiB, and only while it is visible |
| the wallpaper layer | ~15 MiB |
| all bar widgets together | ~1 MiB |
| the plugin tree, service singletons (PipeWire, BlueZ, NetworkManager, MPRIS, tray) and font caches | the remainder |

So the floor is the runtime, not a leak or a single plugin: making the audio and
media panels lazy was measured and saved nothing, so they stay warm for instant
opening. `./test/benchmark.sh` reproduces these numbers; `--json` prints them for
a script.

## Taking over from other daemons

Cornice replaces mako/dunst/swaync (notifications), hypridle (idle), waybar
(bar) and a polkit agent. Running those next to it gives duplicate popups, two
bars, or notifications that never reach the shell, so:

```bash
cornice takeover            # plan only: what would change, and why
cornice takeover --apply    # comment those lines out, stop the units
cornice takeover --undo     # restore the newest backup
```

What it does, exactly:

- finds `exec-once`/`exec` lines whose **command name** matches a competitor
  (a path that merely mentions `mako`, like a log helper, is left alone);
- finds matching **systemd user units** (`mako.service`, `hypridle.service`, …)
  and stops + disables them;
- comments the lines out with a `# cornice takeover:` marker — it never deletes
  a line, and a second run changes nothing;
- writes every touched file plus the unit states to
  `~/.local/state/cornice/takeover/<timestamp>/` before touching anything;
- leaves alone what cornice yields to (hyprpaper/swaybg/swww/mpvpaper),
  night-light daemons, and cliphist (which cornice uses).

Then reload: `hyprctl reload` (or `cornice takeover --reload`).

## If a lock client dies

Hyprland keeps the session locked and shows its "lockscreen app died" failsafe when
the lock client disappears (e.g. the shell was killed while locked). On a **Lua**
Hyprland config you can clear it in place:

```bash
hyprctl eval 'hl.clear_crashed_lockscreen()'
```

On a **hyprlang** config (`hyprland.conf`) that command does not exist, so the only
way out is restarting the compositor — `hyprctl dispatch exit` — and logging back
in. `cornice stop` therefore refuses to kill the shell while the session is locked;
pass `--force` if you know what you are doing.

## Support hooks

Some read-only IPC targets exist so a problem can be diagnosed from outside the
shell instead of guessing:

| Target | Shows |
| --- | --- |
| `cornice ipc tray dump` | every StatusNotifier item, its icon name and how it resolved |
| `cornice ipc netinfo dump` | backend, connectivity, devices, the icon the network widget picked |
| `cornice ipc audioinfo dump` | PipeWire readiness, default sink, per-node volumes |
| `cornice ipc shell debug` | plugin instances and which panels are open |

`test/inject-click.py` injects a real mouse click through `/dev/uinput` (needs
write access, no root) with feedback-controlled positioning — the only way to
verify pointer interactions such as "clicking the bar opens the panel".

## Verify without touching your desktop

`test/headless-verify.sh` starts a private headless Hyprland in a temporary
`XDG_RUNTIME_DIR`, runs the shell there, asserts IPC answers, screenshots the
bar with `grim`, and tears everything down. Your session, your config and your
running bar are untouched.

Everything above is also available as one command:

```bash
cornice test            # takeover sandbox + headless + lock + live
cornice test --quick    # only the suites that need no private compositor
```

The suites deliberately fail loudly on the checks that have historically been
wrong (a plugin that does not load, a panel that opens empty, a sidebar that
paints nothing, a takeover that comments the wrong line).
