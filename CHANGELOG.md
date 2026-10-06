# Changelog

## 0.2.5

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
