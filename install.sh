#!/usr/bin/env bash
# install.sh — put cornice on this machine without sudo (by default).
#
#   ./install.sh                 symlink the CLI into ~/.local/bin, check deps
#   ./install.sh --copy          copy instead of symlink (no dev-tree coupling)
#   ./install.sh --prefix /usr/local
#   ./install.sh --takeover      also hand the session over (mako/hypridle/…)
#   ./install.sh --service       install + enable the systemd user service
#   ./install.sh --uninstall     remove what was installed
#
# Never edits a config file and never needs root unless you choose a prefix
# outside your home. Rollback is `./install.sh --uninstall`.
set -euo pipefail

repo=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
prefix="$HOME/.local"
copy=0
takeover=0
service=0
uninstall=0
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
    -h | --help) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "install.sh: unknown option '$arg'" >&2; exit 2 ;;
  esac
done

bindir="$prefix/bin"
libdir="$prefix/share/cornice"
ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mfail\033[0m  %s\n' "$1"; }
step() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
step "Uninstall"
if ((uninstall)); then
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
step "Systemd user service"
if ((service)); then
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"
  install -m644 "$repo/config/cornice.service" "$unit_dir/cornice.service"
  ok "installed $unit_dir/cornice.service"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if systemctl --user enable --now cornice.service >/dev/null 2>&1; then
    ok "enabled and started cornice.service (Restart=always)"
    echo "  status: systemctl --user status cornice"
  else
    warn "could not enable cornice.service — start it manually: systemctl --user enable --now cornice"
  fi
else
  echo "  Running under systemd is recommended: it restarts the shell if it dies."
  echo "  Add --service to this script, or:"
  echo "      install -Dm644 $repo/config/cornice.service ~/.config/systemd/user/cornice.service"
  echo "      systemctl --user daemon-reload && systemctl --user enable --now cornice.service"
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
if command -v jq >/dev/null 2>&1; then
  ok "jq: $(jq --version)"
elif command -v python3 >/dev/null 2>&1; then
  warn "no jq; python3 will be used to read plugin manifests (slower)"
else
  bad "need jq or python3"
  missing=1
fi
command -v hyprctl >/dev/null 2>&1 && ok "hyprctl: $(command -v hyprctl)" \
  || { bad "hyprctl not found (cornice targets Hyprland)"; missing=1; }
command -v socat >/dev/null 2>&1 && ok "socat: $(command -v socat)" \
  || warn "no socat — the CLI falls back to 'qs ipc', which cannot see runtime plugins"
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
mkdir -p "$bindir"
installed=0

if ((copy)); then
  # A self-contained layout: the tree lives in $prefix/share/cornice and the CLI
  # entries in $bindir are symlinks into it. The CLI resolves its own prefix by
  # following the symlink, so shell/, themes/, config/ must sit under libdir —
  # copying only bin/ would leave it looking for $prefix/shell.
  staging="$libdir.new.$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  for dir in bin shell themes wallpapers config docs; do
    [[ -d $repo/$dir ]] && cp -r "$repo/$dir" "$staging/"
  done
  find "$staging" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  chmod +x "$staging"/bin/* 2>/dev/null || true
  rm -rf "$libdir"
  mkdir -p "$(dirname "$libdir")"
  mv "$staging" "$libdir"
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

case ":$PATH:" in
  *":$bindir:"*) ok "$bindir is on PATH" ;;
  *) warn "$bindir is NOT on your PATH — add: export PATH=\"$bindir:\$PATH\"" ;;
esac

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
  "$repo/bin/cornice-takeover" --apply --reload || warn "takeover reported a problem"
else
  echo
  echo "  If you currently run mako/hypridle/waybar/polkit-gnome, hand over with:"
  echo "      cornice takeover          # shows the plan, changes nothing"
  echo "      cornice takeover --apply  # comments the lines out, keeps backups"
fi

echo
ok "done"
