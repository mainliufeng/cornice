# Changelog

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
