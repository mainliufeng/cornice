# Cornice

**English** · [中文](README.zh-CN.md)

A general-purpose **Hyprland shell** built on [Quickshell](https://quickshell.org):
one process that gives you the bar, panels, notifications, the launcher, the
lock screen, idle handling and a polkit agent — instead of waybar + mako +
hypridle + hyprlock + polkit-gnome + a launcher, each with its own config file.

![the desktop](docs/screenshots/desktop.png)

---

## Features

| | |
| --- | --- |
| ![the bar](docs/screenshots/bar.png) | ![the weather panel](docs/screenshots/panel-weather.png) |
| **Bar** — workspaces, focused window, media, clock, indicators, system tray, network, bluetooth, audio, battery, keyboard layout, weather, power | **Weather** — current conditions and a forecast from open-meteo (no API key), located by city, coordinates, timezone or IP |
| ![the launcher](docs/screenshots/launcher.png) | ![the notification centre](docs/screenshots/panel-notifications.png) |
| **Launcher** — desktop entries, live filtering, `>` for a command line | **Notifications** — owns `org.freedesktop.Notifications`: popups, history, DND, action buttons, inline reply |
| ![the media panel](docs/screenshots/panel-media.png) | ![the audio panel](docs/screenshots/panel-audio.png) |
| **Media** — cover, progress, transport, volume, several players | **Audio** — sink and microphone volume, device list |
| ![the OSD](docs/screenshots/osd.png) | ![the emoji picker](docs/screenshots/emoji.png) |
| **OSD** — volume, microphone, brightness; follows hardware keys | **Emoji picker** — searchable, Enter copies |
| ![the lock screen](docs/screenshots/lock.png) | |
| **Lock screen** — PAM-backed, wallpaper background, no account name unless you want it | |

More, without screenshots:

- **Menu** — a bar button that opens everything by click: applications, the
  clipboard, the emoji picker, notifications, the bar layout editor, the theme
  and wallpaper, do-not-disturb, the lock screen and power. It exists so that no
  surface depends on remembering a keybinding.
- **Panels** — clock/calendar, network (Wi-Fi list and connect), bluetooth
  (scan, pair, connect), power (battery, profiles, session actions).
- **Clipboard** — cliphist-backed history: type to filter, Enter copies, images
  previewed.
- **Lock screen** — PAM-backed session lock, releases itself on graceful
  shutdown, refuses to lock when PAM is unusable, and documents the TTY recovery
  path if a lock client ever dies.
- **Idle** — dim, display-off and lock with separate AC/battery timeouts; locks
  on suspend, on `loginctl lock-session` and on lid close.
- **Polkit agent** — the authentication dialog lives in the shell.
- **Wallpaper** — static background layer with per-workspace overrides that
  steps aside for mpvpaper/hyprpaper/swaybg/swww/wbg.
- **Themes** — `mono` (dark) and `dawn` (light), switchable at runtime.
- **IPC** — the shell serves its own socket, so plugins keep their own targets
  and every panel is scriptable.

## Requirements

- Hyprland (Wayland session)
- Quickshell — `sudo pacman -S quickshell` (Arch `extra`)
- `jq` (or `python3`) to read plugin manifests, `glib2` (the logind monitor),
  `curl` (weather)
- A Nerd Font for the bar glyphs (`ttf-nerd-fonts-symbols`)
- Optional, one per feature: `socat` (CLI → runtime plugins), `grim`
  (screenshots in `cornice verify`), `wpctl`/WirePlumber (audio), `bluez`
  (bluetooth), `brightnessctl` (brightness OSD), `cliphist` (clipboard history),
  `light` (idle dimming), `NetworkManager` (network panel)

## Install

```bash
git clone https://github.com/mainliufeng/cornice.git ~/Code/self/cornice
cd ~/Code/self/cornice
./install.sh                 # symlinks the CLI into ~/.local/bin, checks deps
```

`./install.sh` defaults to a user-local install and leaves compositor config alone:

```bash
./install.sh --copy              # self-contained tree in ~/.local/share/cornice
./install.sh --prefix /usr/local # somewhere else
./install.sh --takeover          # also hand over from mako/hypridle/waybar/…
./install.sh --uninstall         # remove the binaries (config and state stay)
make install                     # same as ./install.sh
```

Arch users can build a package: `make pkg` (`makepkg -si`, installs to
`/usr/share/cornice` with the CLI in `/usr/bin`). [docs/aur.md](docs/aur.md) has
the AUR-ready PKGBUILD and the upload procedure.

Then start it — as a systemd user service, so it comes back if it ever dies:

```bash
./install.sh --service       # installs + enables cornice.service (Restart=always)
systemctl --user status cornice
```

With `--service`, dependency checks and helper installation finish before the
service is enabled. The unit uses the selected `--prefix`; an existing user unit
is backed up next to it as `cornice.service.backup.*` before replacement. To
restore it, copy the reported backup over `cornice.service` and run
`systemctl --user daemon-reload`.

or add one line to `~/.config/hypr/hyprland.conf`:

```conf
exec-once = cornice-launch
```


Optional keybindings live in [`config/snippet.hyprland.conf`](config/snippet.hyprland.conf).
Cornice leaves your compositor config, `~/.config/hypr/*` and system packages
alone. Explicit `--service` installs the backed-up user unit described above;
`cornice takeover --apply` changes the desktop startup config with backups and
supports `cornice takeover --undo`.

## Hand over from the old daemons

```bash
cornice takeover            # plan only: what would change, and why
cornice takeover --apply    # comment those lines out, stop the units
cornice takeover --undo     # restore the newest backup
```

It finds `exec-once` lines and systemd user units for the components cornice
replaces (mako/dunst/swaync, hypridle, waybar, a polkit agent), comments them out
with a marker, backs up every file it touches to
`~/.local/state/cornice/takeover/<timestamp>/`, and leaves alone what cornice
cooperates with (cliphist, hyprsunset, mpvpaper/hyprpaper/swaybg). Then
`hyprctl reload`.

## Commands

```bash
# lifecycle
cornice start | stop | restart | status | logs | health
cornice launch                       # foreground, with a watchdog

# inspecting the running shell
cornice ping | version | plugins | widgets | targets | socket | path
cornice config | theme [list|toggle|<name>] | reload | reload-plugins
cornice ipc <target> <method> [args] # raw IPC, e.g. cornice ipc idle status

# configuration (the panels run these same commands)
cornice bar list | show <id> | hide <id> | move <id> up|down|left|center|right
cornice weather place use <name> [--city C | --lat L --lon N] | clear
cornice clock zone use <name> <zone> | clear
cornice language [list|<code>]

# what you bind to keys
cornice launcher | clipboard | emojis | notifications | dnd [on|off]
cornice panel <plugin-id> [json]     # toggle any panel
cornice osd volume | microphone | brightness | hide
cornice lock [status|try <pw>|emergency-unlock]
cornice background [status|set <path>|next|prev|clear|reload]

# machine
cornice doctor                       # dependencies, compositor, conflicts
cornice verify                       # the shell you are looking at
cornice takeover [--apply|--undo]
cornice test [--quick|installer|takeover|headless|lock|install|live]
cornice session-env                  # compositor env exports for TTYs/stale shells
```

## Weather place and world clock


Both take exactly one selection — a place for the weather, a timezone for the
clock — and you pick it from a list instead of typing it: the weather panel and
the clock panel each have a search box that filters real results (city lookup for
the weather, the same lookup for the clock since every city carries its
timezone), and clicking a row sets it.

```json
{
  "weather": { "place": { "name": "Beijing", "latitude": 39.9075, "longitude": 116.39723 } },
  "clock":   { "zone":  { "name": "東京", "timezone": "Asia/Tokyo" } }
}
```

The name comes from the search result, and the search is made in the configured
language — so the same place is `Beijing` in an English shell and `北京` in a
Chinese one. The bar shows that name next to the value: `☁ 北京 20°` for the
weather, `東京 00:03` for the clock (with no zone configured the clock widget
just shows the local time).

```bash
cornice weather place use "北京" --lat 39.9075 --lon 116.39723   # or --city 北京
cornice weather place clear
cornice clock zone use "東京" Asia/Tokyo
cornice clock zone clear
cornice clock zones            # every installed timezone, for reference
```

Older configs keep working: a `weather.locations` list or a `clock.worldClocks`
list is read by taking its first entry. Writing is guarded — the shell backs up
`config.json`, refuses a write that fails to parse or that would drop top-level
keys, and reuses the CLI as the only writer (the panels call the same commands,
so what you click and what you script cannot drift apart).

## Language

```bash
cornice language          # current language (default: en)
cornice language list     # available translations
cornice language zh-CN    # switch, persist, reload
```

Translations live in `i18n/<code>.json`; English is also the fallback table, so a
missing key degrades to English rather than to an empty label. Weekday, month and
calendar names follow the language too. To add a language, copy `i18n/en.json`,
translate the values, and run `cornice language <code>` — the test suite fails if
the tables disagree, or if the shell asks for a key that does not exist.

## Configuration

`~/.config/cornice/config.json` is deep-merged over [`config/default.json`](config/default.json),
so write only what differs. Arrays are replaced, objects are merged;
`cornice config` prints the result.

| Key | Default | Meaning |
| --- | --- | --- |
| `theme` | `"mono"` | `mono` (dark) or `dawn` (light) |
| `background.enabled` | `true` | paint the wallpaper layer |
| `background.dir` | `~/Pictures/wallpapers` | directory scanned for images |
| `background.mode` | `"fill"` | `fill` / `fit` / `stretch` / `center` / `tile` |
| `background.perWorkspace` | `{}` | `{"2": "/path/to.png"}` overrides |
| `background.force` | `false` | take over even with mpvpaper/hyprpaper running |
| `notifications.takeover` | `true` | reclaim `org.freedesktop.Notifications` when free |
| `notifications.inlineReply` | `true` | advertise inline reply to clients |
| `weather.city` | `""` | city name to geocode (beats everything else) |
| `weather.latitude`/`longitude` | `null` | explicit coordinates |
| `weather.autoLocate` | `true` | locate by timezone, then by IP |
| `weather.useTimezone` | `true` | prefer the system timezone over the IP (VPN-safe) |
| `weather.unit` | `"metric"` | `metric` or `imperial` |
| `weather.intervalMinutes` | `15` | refresh cadence |
| `idle.dimAc` / `dimBattery` | `60` / `0` | seconds before the backlight dims |
| `idle.screenOffAc` / `screenOffBattery` | `120` / `300` | seconds before display-off |
| `idle.lock` | `300` | seconds before locking |
| `idle.lockWarning` | `5` | fade warning before automatic locking; input cancels it, `0` disables it; manual, lid and sleep locks remain immediate |
| `idle.respectInhibitors` | `false` | honour apps' idle inhibitors too |
| `idle.lockOnSleep` | `true` | lock when logind is about to suspend |
| `idle.lockOnLockSignal` | `true` | lock on `loginctl lock-session` |
| `idle.lockOnLidClose` | `true` | lock when the lid closes (skipped when docked) |
| `idle.lockScreenOff` | `10` | seconds after the session locks before the panel turns off; input on the lock screen restarts the countdown, `0` disables it, and a manual idle inhibit does not keep a locked screen lit |
| `lock.showUser` | `true` | show the account name on the lock screen |
| `lock.background` | `"wallpaper"` | `wallpaper`, `screenshot` or `none` |
| `lock.blur` / `lock.scrim` | `1.0` / `1.0` | lock background blur and darkening |

`cornice ipc idle inhibit 3600` holds the idle chain off for an hour (long
downloads, presentations, test runs) and `cornice ipc idle release` ends it.

## Plugins

A plugin is a directory with a `manifest.json` and QML; built-ins live in
`shell/plugins/`, yours in `~/.config/cornice/plugins/<id>/`. Entry points receive
`host` (the shell: `config`, `services`, `summon`, `toggle`) and `plugin` (the
manifest); bar widgets also get `widgetConfig`.

**Full guide: [docs/plugin-api.md](docs/plugin-api.md)** — kinds, the service
pattern, `PanelFrame`, `ShellIpc`, theming rules, and the traps that have already
bitten this codebase.

## Resources

Measured with `./test/benchmark.sh --compare` on a 3072x1920 session (PSS, 12s
window, all 23 plugins loaded):

| Stack | Memory | CPU (idle) |
| --- | --- | --- |
| cornice | ~200 MiB | ~0.1% |
| waybar + mako + hypridle | ~46 MiB | ~0.2% |

Cornice is the bigger process, and it is worth saying plainly why: it is a Qt
Quick runtime, and it replaces more than those three daemons (lock screen, polkit
agent, launcher, clipboard history, emoji picker, notification centre and seven
panels, weather, media control). Attribution, measured the same way:

| Part | Cost |
| --- | --- |
| bare Quickshell + one layer surface | 62 MiB |
| each additional layer surface | ~5.5 MiB, only while it is visible |
| the wallpaper layer | ~15 MiB |
| all bar widgets together | ~1 MiB |
| the plugin tree, service singletons (PipeWire, BlueZ, NetworkManager, MPRIS, tray) and font caches | the remainder |

So the floor is the runtime, not a leak or one plugin: making the audio and media
panels lazy was measured and saved nothing, so they stay warm for instant
opening. `./test/benchmark.sh` reproduces these numbers; `--json` prints them for
a script.

## Testing

```bash
cornice test                 # every suite (a few minutes)
cornice test --quick         # the fast ones only
./test/install-verify.sh --package   # does a *fresh install* work?
```

| Suite | What it covers |
| --- | --- |
| `test/headless-verify.sh` | private compositor (headless mutter → nested Hyprland): startup, every plugin, every bar widget, every panel, notifications over D-Bus, inline reply, weather against a local fake API, the logind signals, painting |
| `test/lock-verify.sh` | private compositor: lock, refusal to restart while locked, emergency unlock, a real PAM stack with a wrong password, the logind lock signal, lid-close locking |
| `test/takeover-test.sh` | sandbox: takeover plan/apply/idempotence/backup/undo, including a stub systemctl |
| `test/install-verify.sh` | exports the *tracked* tree, installs it, runs the headless suite against it — the "fresh install" gate |
| `test/install-test.sh` | temporary prefixes and a stub service manager: dependency failures, service startup order, custom prefixes and unit backups |
| `cornice verify` | the session you are actually looking at |

The headless suite also needs `pipewire`, `wpctl` and `pw-metadata`. It starts
a private PipeWire server with one virtual sink and no hardware devices to check
bar tooltip timing, stable widget positions, mute and scrolling on both bar edges.

A plugin that fails to load, a panel that opens empty, a takeover that comments
the wrong line and a fresh install that is missing a file all fail these suites —
each of those has happened here, which is why they exist.

## When something silently does nothing

The usual cause is an **outdated install**: the shell calls helpers from
`~/.local/bin`, so a helper added since your last install is simply missing and
the feature it backs (tray menu clicks, for instance) does nothing at all.

`cornice doctor` checks every helper the shell and the CLI invoke, and says when
the install looks stale:

```
cornice doctor        # cornice-tray-activate: missing — re-run ./install.sh
cornice logs          # the shell logs the exact command when it calls a helper
```

`./install.sh` verifies its own links afterwards, and the release gate
(`./test/install-verify.sh`) fails when a shipped helper is not installed.

## Design notes

[DESIGN.md](DESIGN.md) (Chinese) records the architecture decisions, the
comparison against omarchy/Caelestia, and what was deliberately left out.

## License

MIT — see [LICENSE](LICENSE). The wallpaper shipped in `wallpapers/` is generated
for this project (see [wallpapers/CREDITS.md](wallpapers/CREDITS.md)); cornice
ships no photographs.
