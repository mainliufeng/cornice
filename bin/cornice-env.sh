#!/usr/bin/env bash
# cornice session environment — make hyprctl/hyprland tools work from a TTY, an
# agent shell, or anything else that did not inherit the compositor's variables.
#
# Two failure modes are common:
#   1. the variables are missing entirely (SSH, a bare TTY, systemd units)
#   2. the variables are *stale* — a shell that survived a Hyprland restart still
#      points at the old instance signature, and hyprctl then fails with
#      "Couldn't connect to Hyprland" even though a session is running.
#
# So: verify, don't just check for existence. Sourced by cornice-verify,
# cornice-doctor and cornice-takeover.

cornice_session_env() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

  local valid=0
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null 2>&1; then
    if timeout 3 hyprctl version >/dev/null 2>&1; then valid=1; fi
  fi

  if ((valid == 0)); then
    while IFS= read -r line; do
      case "$line" in
        HYPRLAND_INSTANCE_SIGNATURE=* | WAYLAND_DISPLAY=* | DBUS_SESSION_BUS_ADDRESS=* | XDG_CURRENT_DESKTOP=*)
          export "${line?}"
          ;;
      esac
    done < <(systemctl --user show-environment 2>/dev/null || true)
  fi

  # systemd services can inherit a session environment that has no
  # WAYLAND_DISPLAY (Hyprland does not export it into the user manager unless
  # something asks it to), even though the compositor is alive. Take it from the
  # socket the compositor created, so a service start does not fail with
  # "a shell started now would come up with no display".
  if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
    local socket
    for socket in "$XDG_RUNTIME_DIR"/wayland-*; do
      [[ -S $socket ]] || continue
      export WAYLAND_DISPLAY="${socket##*/}"
      break
    done
  fi

  # Still unusable? Say so rather than letting every later check fail obscurely.
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null 2>&1; then
    if ! timeout 3 hyprctl version >/dev/null 2>&1; then
      echo "cornice: hyprctl cannot reach the compositor (HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE})" >&2
      echo "  started from a TTY or a stale shell? try: eval \"\$(cornice session-env)\"" >&2
    fi
  fi
}

# Print `export …` lines, so `eval "$(cornice session-env)"` works too.
cornice_session_env_print() {
  cornice_session_env
  local name
  for name in XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS; do
    [[ -n ${!name:-} ]] && printf 'export %s=%q\n' "$name" "${!name}"
  done
}

# When executed (not sourced), behave like a command.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  cornice_session_env_print
else
  cornice_session_env
fi
