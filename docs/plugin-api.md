# Writing a Cornice plugin

A plugin is a directory with a `manifest.json` and one or more QML files. Cornice
loads it, gives it the shell contract, and (depending on its kinds) puts it in the
bar, on a summon, or in the shared service registry.

Two discovery roots:

| Origin | Path | Use |
| --- | --- | --- |
| built-in | `<prefix>/shell/plugins/<id>/manifest.json` | shipped plugins |
| user | `~/.config/cornice/plugins/<id>/manifest.json` | your own, no fork needed |

Nested one level is also supported (`plugins/<group>/<id>/manifest.json`), which
is how the built-ins are grouped.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "cn.hello",
  "name": "Hello",
  "version": "0.1.0",
  "author": "you",
  "description": "Shows the time since the last click and a small panel",
  "kinds": ["service", "bar-widget", "panel"],
  "keepLoaded": true,
  "entryPoints": {
    "service": "Service.qml",
    "barWidget": "Widget.qml",
    "panel": "Panel.qml"
  },
  "barWidget": {
    "displayName": "Hello",
    "category": "Utility",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": { "format": "{icon} hello" },
    "schema": [
      { "key": "format", "type": "string", "label": "Format: {icon} {title}" }
    ]
  }
}
```

Required: `id` (use a `cn.` prefix for first-party), `name`, `version`,
`kinds`, and `entryPoints` for every kind you declare.

| Field | Meaning |
| --- | --- |
| `kinds` | any of `service`, `bar-widget`, `panel`, `overlay`, `menu` |
| `keepLoaded` | services are always kept; for panels/overlays it means "mount at startup and open/close instead of remounting" (media, audio, notifications do this) |
| `entryPoints` | `service`, `barWidget`, `panel`, `overlay`, `menu` → path relative to the plugin dir |
| `barWidget.defaultSection` | `left`, `center` or `right` |
| `barWidget.allowMultiple` | can the user place several instances |
| `barWidget.defaults` | per-instance settings the bar writes (the widget reads `plugin.config`) |
| `barWidget.schema` | describes those settings for the widget editor |

## The contract

Every entry point is instantiated with two properties:

```qml
Item {
  property var host    // the shell
  property var plugin  // this plugin's manifest, plus `dir` and `origin`
}
```

`host` gives you:

| Member | What it does |
| --- | --- |
| `host.config` | effective configuration (defaults deep-merged with the user's file) |
| `host.services["cn.x"]` | another plugin's `service` entry point instance |
| `host.registerService(id, item)` | the shell calls this itself when a `service` entry loads — you never call it |
| `host.service(id)` | same as `host.services[id]`, null-safe |
| `host.summon(id, payload)` | open a summonable plugin, e.g. `host.summon("cn.hello", {})` |
| `host.hide(id)` | close it |
| `host.toggle(id, payload)` | close it if open, open it otherwise (what bar widgets call) |

A service is a plain `Item` that the shell mounts once at startup. Keep shared
state and actions there, then use it from a widget and a panel so both agree —
that is exactly how `cn.media`, `cn.audio` and `cn.notifications` are built:

```qml
// Service.qml
Item {
  property var host
  property var plugin
  readonly property var players: Mpris.players.values
  function playPause() { /* … */ }
}

// Widget.qml
Item {
  property var host
  readonly property var service: host ? host.services["cn.media"] : null
  MouseArea { onClicked: host.toggle("cn.media", {}) }
}

// Panel.qml
PanelFrame {
  readonly property var service: host ? host.services["cn.media"] : null
}
```

## Summonable plugins (panel / overlay / menu)

`PanelFrame` (in `qs.Ui`) is a `PanelWindow` that does the boring parts: layer
placement, click-outside dismissal, keyboard grab when `takesKeyboard` is set,
and the `open()`/`close()` lifecycle the shell drives.

```qml
import QtQuick
import qs.Commons
import qs.Ui

PanelFrame {
  id: root
  edge: "top"                  // top (under the bar) | bottom | center
  panelWidth: 420
  panelHeight: 320
  takesKeyboard: true          // set this if you have a TextField
  dismissOnClickAway: true

  onOpened: refresh()          // signals: opened, dismissed
  // `payload` (already parsed) holds whatever was passed to summon()

  Column { anchors.fill: parent /* … */ }
}
```

Pass data on summon:

```bash
cornice ipc shell summon cn.hello '{"word":"hi"}'
cornice panel cn.hello '{"word":"hi"}'      # same thing, from the CLI
```

`keepLoaded: true` panels are mounted at startup and only opened/closed, which
keeps their state warm and avoids a first-open flash. Panels that are cheap and
rarely used should leave it off.

## IPC: `ShellIpc`

Quickshell's own `qs ipc` only sees statically declared handlers, so runtime
plugins register their own targets:

```qml
ShellIpc {
  target: "hello"

  function status(): string {
    return JSON.stringify({ clicks: root.clicks })
  }

  function poke(times: string): string {
    root.clicks += Number(times)
    return "ok"
  }
}
```

Arguments arrive as strings (that is how they came over the socket) and you
return a string or JSON. From the shell:

```bash
cornice ipc hello status
cornice ipc hello poke 3
cornice targets                # every registered target
```

## Reading configuration

Never read the user's JSON by hand:

```qml
readonly property var settings: (host && host.config && host.config.hello) ? host.config.hello : ({})
readonly property int limit: Util.option(settings, "limit", 5)
```

Add your defaults to `config/default.json` so `cornice config` shows them, and
document the keys in the README's configuration table.

## Commons

| Import | Provides |
| --- | --- |
| `qs.Commons` | `Style` (sizes, fonts, icon font), `Color` (theme palette), `Theme`, `Util` (`option`, `clamp`, `list`, `exec`, `deepMerge`), `ShellIpc`, `IpcRegistry` |
| `qs.Ui` | `PanelFrame`, `Slider`, `TextField`, `Surface`, `BarSection` |

Rules that are easy to get wrong:

- **Theme through `Color`/`Style` only.** Hard-coded hex values break the light
  theme, which is generated from the same `theme.json` files.
- **Glyphs: always brace five-digit code points** — `"\u{F0925}"`, never
  `"\uf0925"`. The unbraced form is parsed as `\uf092` + `5` and renders as a
  random glyph (this shipped once and showed a coffee cup instead of a VPN icon).
- **Icon font**: `font.family: Style.iconFamily` and a Nerd Font installed.
- **No anchors on plugin roots** for Repeater delegates (the parent is a window
  object, not an Item) — that is why `PluginInstance.qml` sets none.
- **Bound every external call**: prefer `Process`/`Util.exec` with a timeout over
  anything that can hang the UI thread.

## Testing your plugin

```bash
cornice plugins                 # is it discovered?
cornice targets                 # did its ShellIpc target register?
cornice ipc hello status        # does it answer?
cornice test --quick            # sandbox suites + the live session
./test/headless-verify.sh       # private compositor: startup, plugins, panels
```

`test/headless-verify.sh` enumerates every plugin, checks that panels open, and
that the shell still answers IPC — so a plugin that crashes at load time fails
the suite instead of silently vanishing.

## Checklist for a first-party plugin

1. `manifest.json` with the kinds you actually implement
2. `Service.qml` if state is shared between a widget and a panel
3. `Widget.qml` renders from the service, never does its own DBus I/O
4. `Panel.qml` is a `PanelFrame` with `open`/`close` from the shell
5. `ShellIpc` target for anything the CLI or another plugin must drive
6. Defaults in `config/default.json`, documented in the README
7. `cornice verify` and `cornice test --quick` still pass
