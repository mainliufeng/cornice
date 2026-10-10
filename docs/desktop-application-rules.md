# Desktop application launch rules

Cornice's Desktop Broker reads `desktopApplications` from the shipped
`config/default.json`, merged with `${XDG_CONFIG_HOME:-~/.config}/cornice/config.json`.
The same rules apply to nonterminal launches from the secondary launcher and to
CLI/MCP application launches. Terminal-wrapped launcher commands retain the
existing compositor dispatch path.
The desktop's compositor identity and permission checks remain Broker responsibilities.
Primary native launches outside the Broker do not use this policy.

Defaults include Chrome/Chromium, Firefox, and ChatGPT/Codex launcher aliases.
These executable names, startup arguments and environment variables live in JSON;
there are no application-name branches in the Broker or application policy module.

## Configure an application

Add this section to your existing Cornice config (preserve its other sections):

```json
{
  "desktopApplications": {
    "rules": {
      "my-electron-app": {
        "executables": ["my-electron-app"],
        "scope": "secondary",
        "profile": "my-electron-app",
        "arguments": ["--user-data-dir={profile}"],
        "environment": {
          "MY_APP_USER_DATA_PATH": "{profile}"
        },
        "reservedArguments": ["--user-data-dir"]
      }
    }
  }
}
```

Use only flags/environment variables supported by the application being configured.
Apps with a singleton need application-specific startup support for separate profiles;
a rule cannot add that capability to an application that does not implement it.
Arguments are argv entries, not shell commands. No shell expansion is performed.

`{profile}` expands to
`${XDG_DATA_HOME:-~/.local/share}/cornice/desktops/<desktop>/<profile>`;
`{desktop}` expands to the explicit desktop name. Cornice creates the profile
folder. `profile` accepts one directory name, not an absolute path or `..` traversal.

| Field | Meaning |
| --- | --- |
| `executables` | Exact, case-sensitive executable basenames, including aliases. |
| `scope` | `all` (default) or `secondary`; primary is skipped for secondary rules. |
| `profile` | Folder name inside this desktop's data directory. Optional for ordinary apps. |
| `arguments` | Arguments prepended to the caller's argv; supports the two templates above. |
| `environment` | String-valued environment additions; supports the same templates. |
| `reservedArguments` | Option prefixes the caller may not override. |
| `enabled` | Defaults to true. False disables that rule. A rule may also be set to null. |
| `backend` | `process` (default) or `chromium`, the managed CDP pipe driver. |

Fields merge by rule ID and environment variable; arrays replace the corresponding
array. Changing a single default field does not require copying the entire rule:

```json
{
  "desktopApplications": {
    "rules": {
      "chatgpt": { "profile": "chatgpt-custom" },
      "firefox": { "enabled": false }
    }
  }
}
```

Disabling a rule removes its profile/argv adaptation. A singleton app can then
forward the launch to an existing instance on another desktop. There must be only
one enabled matching rule for any launch; overlapping matches return an error.
Unmatched apps launch normally through the target desktop's compositor connection.

## Managed browser selection

`desktopApplications.browser` selects the rule ID used by `desktop_browser_connect`.
The default is `chrome`. To select an alternative Chromium executable, add an
enabled rule with `backend: "chromium"` and set `browser` to its ID. Its executable
list is tried in order using the local user's `~/.local/bin` and PATH. Explicit
browser executable requests must also match an enabled Chromium rule.

A Chromium rule requires a `profile` and exactly one
`--user-data-dir={profile}` argument. The Broker supplies the authenticated debug
pipe; raw `--remote-debugging*` flags and caller-supplied profile paths are rejected.
Firefox has an ordinary process rule; it is not an implementation of the Chromium
CDP driver.

All rules reject environment overrides for `WAYLAND_DISPLAY`, `WAYLAND_SOCKET`,
`DISPLAY`, and `HYPRLAND_INSTANCE_SIGNATURE`. These must always come from the
explicit target desktop. The rules are trusted local product configuration;
application launch is not an OS sandbox.

## Reload and errors

The next application launch/browser connect rereads the configuration, without a
Broker restart. Existing apps retain their startup environment and profile. When
a managed browser is open, changing its rule returns an explicit configuration
change error instead of restarting the browser or silently ignoring new settings.
Close that desktop's browser and reconnect to apply the new rule. Restoring the
previous configuration reconnects to the existing browser.

Malformed JSON, invalid rule fields, conflicting matches and invalid profiles
return launch errors; they do not crash the Broker or restart unrelated apps.
Other Broker operations such as desktop state remain available.

## Verification

`application-launch-config-verify.py` uses real kitty/Chrome processes in an
isolated compositor. It checks custom argv/environment/profile templates,
inheritance of defaults, live-browser configuration changes, an executable alias
unknown to the source, forbidden identity/debug/profile overrides, malformed JSON,
disabling rules and preservation of the primary desktop. Existing real launcher
and MCP browser regressions cover the shipped default experience.
