# Changelog

## 0.2.6 — 2026-11-18

### Added

- Independent desktops for a person and their agents. A task takes a secondary
  desktop; agent clicks and typing stay there while the human desktop keeps
  working. The observer is read-only. Explicit takeover routes human input to
  that desktop and pauses the agent. The agent can ask for a step with a title
  and concrete instructions; leaving takeover does not resume the task until it
  is authorized again.
- Two lock modes. A previously authorized task set to continue can keep working
  while only the human desktop is locked. A full-session lock revokes agent
  control.
- One-shot login trials. `cornice session-trial` prepares an immutable snapshot
  of the paired Hyprland and Cornice, arms only the next Hyprland login, and
  falls back if that login does not become ready. Keeping a snapshot for later
  logins is a separate `select`.
- Paired source installation for the Cornice Hyprland fork and the native
  desktop service (`docs/source-install.md`). The default installer builds the
  native desktop and the locked MCP and browser dependencies.
- Screenshots stay inside Cornice. The bar camera button, `cornice screenshot`
  and `cornice screenshot screen` capture a region or the current monitor, save
  a PNG under Pictures/Screenshots and copy it. Escape or right-click cancels;
  no editor opens.
- Screen recording from the bar. The button records that screen to
  `~/Videos/Cornice` as a silent MP4 and shows the saved path. Locking the
  session or removing the output stops the recording.
- Per-desktop launch rules and existing application profiles, so each desktop
  can keep its own browser and application setup.
- Shared desktop tools for Pi and Codex: task-owned desktops, a native window
  tree, and the same MCP.
- `cornice-session-repair` recovers a paired session after a system upgrade. It
  keeps the previous compositor, Cornice, configuration and autostart, and
  prepares a new **unselected** snapshot with a fresh baseline and the libraries
  that snapshot needs. It does not log out, restart services, install packages
  or change the desktop in use, and its checks are not a physical login. See
  `docs/session-upgrade-repair.md`.

### Changed

- The lock screen uses the Cornice prompt (wallpaper, clock, theme) on the
  native surface, drawn at the output scale. Unlock is auth-only PAM, matching
  the Quickshell lock, so an auth-only stack is not rejected by an account
  rule. The shell reports unlock only after Wayland confirms it.
- Bar menus keep their parent open through a cascade. Pointer hits stay on the
  surface that was clicked, and a held activation key does not fall through
  into the next control.
- Native desktop views keep the full bar, including workspace dots and hover
  access to the menu. Application tray icons stay inactive while a desktop is
  only being observed; a verified human takeover can still use them.
- Composed Chinese input works for task text, and the native input method stays
  available while observing.

### Fixed

- A stale logind lock signal is no longer replayed as a new lock. Lid-close
  sleep retries are bounded and can be cancelled.
- Clipboard transfers are dropped when the session locks. Named Wayland
  connections stay on the seat that selected them. Fullscreen focus cycles stay
  in order. A daily lock no longer drops a running task.
- An application already open on another desktop is explained instead of failing
  quietly, and an action failure names the desktop it came from. Tray activation
  without a binding is refused before it is dispatched.
- A runtime command error no longer ends the desktop. Recovery of a ready trial
  stays inside the session, with a bounded number of attempts, and applications
  survive a broker restart. After the broker exits, each desktop comes back with
  one bar and agent input stays paused until an explicit resume.
- The launcher follows the native input seat. Cooperation notices stay out of
  manual control and hide during takeover.

## 0.2.5

- The network panel now turns the Wi-Fi scanner on while it is open. Quickshell
  keeps it off by default, so the panel only ever listed the connected network
  and there was nothing else to switch to. The password field also focuses
  itself when it appears, and the panel says it is scanning meanwhile.
- Twelve new built-in themes (Catppuccin Mocha/Latte, Gruvbox Dark/Light, Nord,
  Tokyo Night, Rosé Pine and Rosé Pine Dawn, Everforest Dark, Dracula, Kanagawa,
  One Dark), and the bar menu's theme row now opens a picker list instead of
  cycling through them. The theme icon was a glyph Hack Nerd Font does not ship
  and rendered as a box, so it now uses one that does.
- The bar menu is keyboard-navigable: up/down and Ctrl-j/k move the highlight,
  Enter/Space acts on it, and moving no longer closes the menu. Browsing the
  theme list previews each theme live; Esc cancels back to the one you had.
- The launcher's single-instance lock no longer leaks into the processes the
  shell starts. Inheriting it meant any app (or watchdog child) that outlived a
  restart kept the lock, the next start refused with "another launcher is already
  starting", and systemd hit its start limit — leaving the session with no bar.
- Clicking a notification now acts on it instead of only dismissing it: the
  client's `default` action is invoked when it has one, and otherwise the window
  of the app that sent it is focused (switching workspace when needed). Apps that
  send no actions at all — Paseo, Grok Bot, satty — still work through the D-Bus
  sender hints, and the same click works on entries in the notification centre.
- Bar menu button: one click reaches the launcher, clipboard, emoji picker,
  notifications, bar layout editor, theme, wallpaper, do-not-disturb, lock
  screen and power, so nothing requires a keybinding. The optional snippet now
  lists only the binds that add something a click cannot.

## 0.2.4

- Left-click audio to open its interactive slider panel; right-click toggles
  mute. Audio and brightness panels both follow the bar position.
- Suppress the bottom volume OSD while adjusting the audio panel.

## 0.2.3

- Give locked screens their own display-off countdown, wake on input/unlock,
  and cancel in-flight display-off requests. Do not turn off the unlocked
  screen early when an automatic lock deadline is configured.

- Open an interactive brightness panel from the bar, with a shared slider/value
  and backlight write error feedback; follow top/bottom bar placement instead
  of opening the bottom OSD on click.

- Fade the desktop before the automatic idle lock; input cancels the warning
  without changing the lock deadline. Manual, lid and suspend locks stay immediate.
- Use ISO language codes for geocoding so Chinese searches return Chinese city,
  region and country names; localize saved weather/world-clock place names.

## 0.2.2

- Compare world clocks against system times bracketing the IPC query to avoid
  false release-test failures at minute boundaries.

- Keep bar icons and widths fixed on hover; show values in delayed, passive
  status tooltips without taking application focus.
- Unify typography, spacing and controls across device and utility panels.

- Check dependencies and finish installing helpers before enabling the user
  service. Use the selected prefix, escape service command paths, back up an
  existing unit and return failure if service activation fails.
- Build release-test packages from the same committed snapshot as the copy
  install, compare installed files against that snapshot, and reject missing
  package tools or invalid test arguments.
- Fail headless verification when its weather fixture, private D-Bus or
  screenshot is unavailable; clean up the weather fixture on early exits.
- Add installer regressions to the default and quick test suites and repair
  the installation/configuration command layout in both READMEs.

## 0.2.1

First GitHub Release. Earlier development and fixes were delivered on `main`
without release tags; this release includes that history.

### Fixes

- Keep bar sections and window titles within the available width, align clock
  and weather text, and preserve the selected window display mode.
- Let every bar widget choose a left, centre or right position in the layout
  editor.
- Keep tray menus on screen with scrolling, support submenus, and prevent
  hover from jumping repeatedly between them.
- Keep the Wi-Fi password field visible when expanding the network panel.
- Correct brightness glyphs, accumulate wheel steps, and show feedback when
  the brightness value is unavailable.
- Recover the Wayland environment when starting from a user service.
- Invalidate weather caches after location changes and preserve configured
  place names instead of replacing them with API timezone names.
- Harden startup and restart against duplicate shell instances; improve
  notification ownership, configuration reloads and lock-screen recovery.
- Make the install release gate test the package just built even when older
  package files are still present.

### Included features and UI updates

- Current-workspace window switching from the bar.
- Larger weather, calendar and lock-screen layouts with clearer information
  hierarchy.
- Searchable location and timezone pickers, world clocks and language-aware
  place names.
- Bar, panels, notifications, OSD, launcher, clipboard and emoji picker,
  PAM-backed session lock, idle handling, polkit agent and wallpaper layer.
- User-local installation, systemd user service, Arch packaging and reversible
  takeover of existing desktop services.

### Install this release

```bash
git clone --branch v0.2.1 --depth 1 https://github.com/mainliufeng/cornice.git
cd cornice
./install.sh
```

Requirements and optional integrations are documented in
[README.md](README.md) and [README.zh-CN.md](README.zh-CN.md).
