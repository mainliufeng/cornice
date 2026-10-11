#!/usr/bin/env bash
# install.sh — put cornice on this machine without sudo (by default).
#
#   ./install.sh                 symlink the CLI into ~/.local/bin, check deps
#   ./install.sh --copy          copy instead of symlink (no dev-tree coupling)
#   ./install.sh --desktop       also build/install optional desktop native components
#   ./install.sh --prefix /usr/local
#   ./install.sh --takeover      also hand the session over (mako/hypridle/…)
#   ./install.sh --service       install + enable the systemd user service
#   ./install.sh --rollback     atomically restore the previous copy install
#   ./install.sh --uninstall     remove what was installed
#
# Leaves compositor config alone; --service backs up an existing user unit.
# Needs no root unless you choose a protected prefix. Remove installed helpers
# with `./install.sh --uninstall`; restore the reported unit backup separately.
set -euo pipefail

repo=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
prefix="$HOME/.local"
copy=0
takeover=0
service=0
uninstall=0
desktop=0
rollback=0
# NB: a `for arg in "$@"` loop cannot consume its own arguments — `shift` inside
# it has no effect, so --prefix would swallow nothing and its value would be
# treated as an unknown option.
while (($#)); do
  arg="$1"
  shift
  case "$arg" in
    --copy) copy=1 ;;
    --prefix) prefix="${1:?--prefix needs a path}"; shift ;;
    --prefix=*) prefix="${arg#*=}" ;;
    --takeover) takeover=1 ;;
    --service) service=1 ;;
    --uninstall) uninstall=1 ;;
    --desktop) desktop=1 ;;
    --rollback) rollback=1 ;;
    -h | --help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "install.sh: unknown option '$arg'" >&2; exit 2 ;;
  esac
done

prefix=$(realpath -m -- "$prefix")
if ((service)) && [[ $prefix == *$'\n'* || $prefix == *$'\r'* || $prefix == *$'\t'* ]]; then
  echo "install.sh: --service requires a prefix without newlines or tabs" >&2
  exit 2
fi

bindir="$prefix/bin"
libdir="$prefix/share/cornice"
# The internal executor is retired. Upgrades must not leave its old entry point.
retired_helpers=(cornice-agent-runtime)
acquire_install_lock() {
  # The service and takeover configuration are shared even across prefixes.
  # Keep the whole user-level operation serial, including failure restoration.
  local install_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cornice"
  local previous_umask
  previous_umask=$(umask)
  umask 077
  mkdir -p "$install_state_dir"
  exec 9>"$install_state_dir/install.lock"
  umask "$previous_umask"
  flock 9
}
if ((rollback)); then
  acquire_install_lock
  exec python3 "$repo/bin/cornice-install-tree" rollback "$libdir"
fi
ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mfail\033[0m  %s\n' "$1"; }
step() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
step "Uninstall"
if ((uninstall)); then
  acquire_install_lock
  removed=0
  for src in "$repo"/bin/cornice*; do
    name=$(basename "$src")
    target="$bindir/$name"
    if [[ -L $target || -f $target ]]; then
      rm -f "$target"
      ok "removed $target"
      removed=1
    fi
  done
  for name in "${retired_helpers[@]}"; do
    if [[ -e $bindir/$name || -L $bindir/$name ]]; then
      rm -f -- "$bindir/$name"
      ok "removed retired helper $name"
      removed=1
    fi
  done
  # A --copy install also created a private tree; a symlink install left the
  # repo alone (never delete the repo).
  if [[ -d $libdir && $(readlink -f "$libdir") != "$repo" ]]; then
    rm -rf "$libdir"
    ok "removed $libdir"
    removed=1
  fi
  ((removed)) || warn "nothing found in $bindir"
  echo
  echo "Config and state were left alone:"
  echo "  ~/.config/cornice/          your configuration"
  echo "  ~/.local/state/cornice/     takeover backups, health reports"
  echo "Remove the 'exec-once = cornice-launch' line from your Hyprland config to finish."
  exit 0
fi

# ---------------------------------------------------------------------------
step "Checking dependencies"
missing=0
if command -v quickshell >/dev/null 2>&1; then
  ok "quickshell: $(quickshell --version 2>/dev/null | head -1)"
elif [[ -x ${CORNICE_QS:-} ]]; then
  ok "quickshell: $CORNICE_QS (CORNICE_QS)"
else
  bad "quickshell not found — sudo pacman -S quickshell (Arch extra)"
  missing=1
fi
command -v jq >/dev/null 2>&1 && ok "jq: $(jq --version)" \
  || { bad "jq not found — install jq for IPC routing and configuration"; missing=1; }
command -v python3 >/dev/null 2>&1 && ok "python3: primary session endpoint publication" \
  || { bad "python3 not found — install python for primary session endpoint publication"; missing=1; }
command -v hyprctl >/dev/null 2>&1 && ok "hyprctl: $(command -v hyprctl)" \
  || { bad "hyprctl not found (cornice targets Hyprland)"; missing=1; }
command -v flock >/dev/null 2>&1 && ok "flock: serialized window focus" \
  || { bad "flock not found — install util-linux"; missing=1; }
command -v socat >/dev/null 2>&1 && ok "socat: $(command -v socat)" \
  || { bad "socat not found — install socat for CLI-to-plugin communication"; missing=1; }
[[ -x ${HOME}/.local/bin/wf-recorder ]] || command -v wf-recorder >/dev/null 2>&1 && ok "wf-recorder: screen recording" \
  || { bad "wf-recorder not found — install wf-recorder for screen recording"; missing=1; }
command -v ffprobe >/dev/null 2>&1 && ok "ffmpeg: recording validation" \
  || { bad "ffprobe not found — install ffmpeg for video validation"; missing=1; }
command -v grim >/dev/null 2>&1 && ok "grim: screenshots for 'cornice verify'" \
  || warn "no grim — 'cornice verify' will skip its visual checks"
command -v fc-list >/dev/null 2>&1 && {
  if fc-list 2>/dev/null | grep -qi "nerd"; then ok "Nerd Font installed";
  else warn "no Nerd Font found — bar glyphs will look wrong (nerd-fonts-symbols)"; fi
}
if ((missing)); then
  echo
  echo "Install the missing packages and re-run. Nothing was changed."
  exit 1
fi

# ---------------------------------------------------------------------------
step "Installing"
acquire_install_lock
# The core shell module uses Qt already required by Quickshell. Packaged builds
# ship it; source installs build it independently of optional desktop tooling.
platform_prebuilt="$repo/native/qml/Cornice/Platform"
if [[ ! -f $platform_prebuilt/libcornice_platform.so ]]; then
  cmake -S "$repo/native/platform" -B "$repo/native/platform-build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
  cmake --build "$repo/native/platform-build" -j2
fi
if ((desktop)); then
  command -v pkg-config >/dev/null 2>&1 && pkg-config --exists atspi-2 \
    || { bad "at-spi2-core is required for native application trees"; exit 1; }
  command -v npm >/dev/null 2>&1 || { bad "npm is required for desktop browser tools"; exit 1; }
  npm ci --prefix "$repo/native/agent" --omit=dev --ignore-scripts --no-audit --no-fund
  cmake -S "$repo/native/desktop" -B "$repo/native/build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
  cmake --build "$repo/native/build" -j2
fi
mkdir -p "$bindir"
for name in "${retired_helpers[@]}"; do
  if [[ -e $bindir/$name || -L $bindir/$name ]]; then
    rm -f -- "$bindir/$name"
    ok "removed retired helper $name"
  fi
done
installed=0
installation_pending=0
unit_published=0
unit=""
unit_backup=""
service_activation_attempted=0
service_enabled_before=""
service_running_before=0
staging=""
rollback_on_failure() {
  local result=$?
  trap - EXIT
  if ((result != 0)); then
    if ((unit_published)); then
      if ((service_activation_attempted)); then
        # enable --now can enable a unit and then fail to start it. Restore
        # autostart state separately, without stopping a pre-existing service.
        if ((!service_running_before)); then
          systemctl --user stop cornice.service >/dev/null 2>&1 || warn "could not stop the service started by this install"
        fi
        systemctl --user disable cornice.service >/dev/null 2>&1 || warn "could not remove this install's service enablement"
      fi
      if [[ -n $unit_backup ]]; then
        cp -a -- "$unit_backup" "$unit" || warn "could not restore the previous unit from $unit_backup"
      else
        rm -f -- "$unit" || warn "could not remove the new service unit"
      fi
      systemctl --user daemon-reload >/dev/null 2>&1 || warn "could not reload the restored service unit"
      if ((service_activation_attempted)); then
        case "$service_enabled_before" in
          enabled) systemctl --user enable cornice.service >/dev/null 2>&1 || warn "could not restore previous service enablement" ;;
          enabled-runtime) systemctl --user enable --runtime cornice.service >/dev/null 2>&1 || warn "could not restore previous runtime service enablement" ;;
        esac
      fi
    fi
    if ((installation_pending)); then
      python3 "$repo/bin/cornice-install-tree" rollback "$libdir" --if-activated "$staging" >&2 || warn "could not restore the previous installation; use install.sh --rollback"
    fi
  fi
  exit "$result"
}
trap rollback_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ((copy)); then
  # A self-contained layout: the tree lives in $prefix/share/cornice and the CLI
  # entries in $bindir are symlinks into it. The CLI resolves its own prefix by
  # following the symlink, so shell/, themes/, config/ must sit under libdir —
  # copying only bin/ would leave it looking for $prefix/shell.
  mkdir -p "$(dirname "$libdir")"
  staging=$(mktemp -d "${libdir}.generation.XXXXXX")
  for dir in bin shell i18n themes wallpapers config docs plugins; do
    [[ -d $repo/$dir ]] && cp -r "$repo/$dir" "$staging/"
  done
  mkdir -p "$staging/native"
  cp -r "$repo/native/agent" "$staging/native/"
  if [[ -f $platform_prebuilt/libcornice_platform.so ]]; then
    mkdir -p "$staging/native/qml/Cornice"
    cp -r "$platform_prebuilt" "$staging/native/qml/Cornice/"
  else
    cmake --install "$repo/native/platform-build" --prefix "$staging"
  fi
  if ((desktop)); then cmake --install "$repo/native/build" --prefix "$staging"; fi
  find "$staging" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  chmod +x "$staging"/bin/* 2>/dev/null || true
  installation_pending=1
  python3 "$repo/bin/cornice-install-tree" activate "$libdir" "$staging"
  ok "installed the tree to $libdir"
  source_dir="$libdir/bin"
else
  source_dir="$repo/bin"
  ok "using the working tree at $repo"
fi

for src in "$source_dir"/cornice*; do
  name=$(basename "$src")
  target="$bindir/$name"
  ln -sfn "$src" "$target"
  ok "linked $name → $target"
  installed=$((installed + 1))
done
((installed)) || { bad "no cornice binaries found in $source_dir"; exit 1; }

# Every shipped helper must resolve after install: a missing link used to fail
# silently at runtime (the tray menu simply did nothing until the next install).
broken=0
for src in "$source_dir"/cornice*; do
  name=$(basename "$src")
  target="$bindir/$name"
  if [[ -L $target && -e $target ]] || [[ -x $target && ! -L $target ]]; then
    :
  else
    bad "$name does not resolve at $target"
    broken=$((broken + 1))
  fi
done
if ((broken == 0)); then
  ok "every helper resolves ($(ls "$source_dir"/cornice* | wc -l) installed)"
else
  bad "$broken helper(s) missing — runtime features that call them will not work"
  exit 1
fi

case ":$PATH:" in
  *":$bindir:"*) ok "$bindir is on PATH" ;;
  *) warn "$bindir is NOT on your PATH — add: export PATH=\"$bindir:\$PATH\"" ;;
esac

# Only enable the service after dependency checks and a complete installation.
# The unit must launch from the selected prefix, including paths with spaces or
# systemd specifier characters. Preserve any existing unit before replacing it.
step "Systemd user service"
if ((service)); then
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"
  unit="$unit_dir/cornice.service"
  service_enabled_before=$(systemctl --user is-enabled cornice.service 2>/dev/null || true)
  service_active_before=$(systemctl --user is-active cornice.service 2>/dev/null || true)
  case "$service_enabled_before" in
    enabled|enabled-runtime|disabled|static|indirect|linked|linked-runtime|alias|masked|masked-runtime|not-found) : ;;
    *) bad "could not determine previous cornice.service enablement; no service changes were made"; exit 1 ;;
  esac
  case "$service_active_before" in
    active|activating|reloading|deactivating) service_running_before=1 ;;
    inactive|failed|unknown) : ;;
    *) bad "could not determine previous cornice.service activity; no service changes were made"; exit 1 ;;
  esac
  service_executable="$bindir/cornice-launch"
  service_executable=${service_executable//\\/\\\\}
  service_executable=${service_executable//\"/\\\"}
  service_executable=${service_executable//%/%%}
  unit_staging=$(mktemp "$unit_dir/.cornice.service.XXXXXX")
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == ExecStart=* ]]; then
      # systemd restricts characters in the executable token. env execs the
      # launcher as a quoted argument; ':' keeps dollar signs literal.
      printf 'ExecStart=:/usr/bin/env -- "%s"\n' "$service_executable"
    else
      printf '%s\n' "$line"
    fi
  done <"$repo/config/cornice.service" >"$unit_staging"
  chmod 644 "$unit_staging"
  if [[ -e $unit || -L $unit ]]; then
    unit_backup=$(mktemp "$unit_dir/cornice.service.backup.XXXXXX")
    cp -a -- "$unit" "$unit_backup"
    ok "previous unit backed up to $unit_backup"
  fi
  mv -f -- "$unit_staging" "$unit"
  unit_published=1
  ok "installed $unit"
  if ! systemctl --user daemon-reload >/dev/null 2>&1; then
    bad "could not enable cornice.service — check: systemctl --user status cornice"
    exit 1
  fi
  service_activation_attempted=1
  if ! systemctl --user enable --now cornice.service >/dev/null 2>&1; then
    bad "could not enable cornice.service — check: systemctl --user status cornice"
    exit 1
  fi
  ok "enabled and started cornice.service (Restart=always)"
  echo "  status: systemctl --user status cornice"
else
  echo "  Running under systemd is recommended: it restarts the shell if it dies."
  echo "  Add --service to this script."
fi

# ---------------------------------------------------------------------------
step "Hyprland"
conf="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"
if [[ -f $conf ]] && grep -qE "^[[:space:]]*exec-once[[:space:]]*=.*cornice-launch" "$conf"; then
  ok "exec-once = cornice-launch already present in $conf"
else
  echo "  Add this line to $conf (cornice never edits it for you):"
  echo
  echo "      exec-once = cornice-launch"
  echo
  echo "  Optional keybinds live in $repo/config/snippet.hyprland.conf"
fi

# ---------------------------------------------------------------------------
step "First run"
if command -v quickshell >/dev/null 2>&1; then
  echo "  Start it in this session:   cornice start"
  echo "  Or log out and back in (exec-once picks it up)"
  echo
  echo "  Then check it:              cornice doctor && cornice verify"
else
  echo "  Install quickshell first."
fi

if ((takeover)); then
  step "Taking over from the old daemons"
  if ! "$repo/bin/cornice-takeover" --apply --reload; then
    bad "requested takeover failed; installation and service changes will be restored"
    echo "  Any takeover configuration backup can be restored with: cornice takeover --undo" >&2
    exit 1
  fi
else
  echo
  echo "  If you currently run mako/hypridle/waybar/polkit-gnome, hand over with:"
  echo "      cornice takeover          # shows the plan, changes nothing"
  echo "      cornice takeover --apply  # comments the lines out, keeps backups"
fi

echo
ok "done"

# All validation and requested setup completed: retain the previous generation
# for an explicit install.sh --rollback instead of deleting it during upgrade.
installation_pending=0
