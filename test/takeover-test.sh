#!/usr/bin/env bash
# takeover-test — prove `cornice takeover` does the right thing in a sandbox.
#
# Runs against a synthetic Hyprland config directory (never the real one), and
# asserts: plan finds the competitors, --apply comments exactly those lines and
# writes a backup, --undo restores the file byte for byte.
set -uo pipefail
ulimit -c 0   # compositor crashes in a test must not litter the repo with cores

self=$(readlink -f "${BASH_SOURCE[0]}")
test_dir=$(dirname "$self")
prefix="${CORNICE_PATH:-$(cd "$test_dir/.." && pwd)}"
takeover="$prefix/bin/cornice-takeover"

pass=0
failures=0
ok() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  failures=$((failures + 1))
}
check() { # check <description> <expected> <actual>
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
contains() { # contains <description> <haystack> <needle>
  if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 (missing: $3)"; fi
}
not_contains() {
  if grep -qF -- "$3" <<<"$2"; then bad "$1 (unexpectedly present: $3)"; else ok "$1"; fi
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
conf_dir="$sandbox/hypr"
mkdir -p "$conf_dir"
state_dir="$sandbox/state"
export XDG_STATE_HOME="$state_dir"

cat >"$conf_dir/hyprland.conf" <<'EOF'
$cornice = sh -c 'exec "$HOME/.local/bin/cornice" "$@"' cornice
exec-once = mako -c ~/.config/mako/config
exec-once = hypridle
exec-once = waybar
exec-once = hyprpaper
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = wl-paste --type text --watch cliphist store
exec-once = hyprsunset -t 4000
exec-once = /usr/bin/lxqt-policykit-agent
exec-once = ~/dotfiles/linux/desktop/mako/notify-log.py
bind = SUPER, R, exec, $cornice launcher
source = ~/dotfiles/linux/desktop/hypr/extra.conf
EOF

cat >"$conf_dir/extra.conf" <<'EOF'
exec-once = dunst
exec-once = swaybg -i /tmp/wall.png
EOF

mkdir -p "$sandbox/orig"
cp "$conf_dir/hyprland.conf" "$sandbox/orig/hyprland.conf"
cp "$conf_dir/extra.conf" "$sandbox/orig/extra.conf"
before_hyprland=$(cat "$conf_dir/hyprland.conf")
before_extra=$(cat "$conf_dir/extra.conf")

echo "takeover sandbox: $sandbox"

# ---- plan ------------------------------------------------------------------
plan=$("$takeover" --conf-dir "$conf_dir" --no-kill 2>&1)
contains "plan finds mako" "$plan" "mako -c ~/.config/mako/config"
contains "plan finds hypridle" "$plan" "hypridle"
contains "plan finds waybar" "$plan" "waybar"
contains "plan finds polkit-gnome" "$plan" "polkit-gnome-authentication-agent-1"
contains "plan reads sourced files" "$plan" "dunst"
not_contains "plan does not touch cliphist" "$plan" "do    "
contains "plan yields to hyprpaper" "$plan" "cornice yields to it"
contains "plan keeps hyprsunset" "$plan" "cornice uses it"
contains "plan sees cornice keybinds as wired" "$plan" "the cornice snippet is sourced"
not_contains "plan ignores paths that merely mention mako" "$plan" "notify-log.py"
contains "plan finds lxqt-policykit-agent" "$plan" "lxqt-policykit-agent"
not_contains "plan-only does not modify files" "$(cat "$conf_dir/hyprland.conf")" "cornice takeover:"

# ---- apply -----------------------------------------------------------------
apply=$("$takeover" --conf-dir "$conf_dir" --no-kill --apply 2>&1)
after=$(cat "$conf_dir/hyprland.conf")
after_extra=$(cat "$conf_dir/extra.conf")
contains "commented mako" "$after" "# cornice takeover: replaced by cornice — Notifications"
contains "commented hypridle" "$after" "# cornice takeover: replaced by cornice — Idle handling"
contains "commented waybar" "$after" "# cornice takeover: replaced by cornice — Bar"
contains "commented polkit agent" "$after" "# cornice takeover: replaced by cornice — Polkit agent"
not_contains "mako is no longer active" "$(grep -v '^#' <<<"$after")" "mako -c"
not_contains "hypridle is no longer active" "$(grep -v '^#' <<<"$after")" "exec-once = hypridle"
not_contains "waybar is no longer active" "$(grep -v '^#' <<<"$after")" "exec-once = waybar"
not_contains "polkit-gnome is no longer active" "$(grep -v '^#' <<<"$after")" "polkit-gnome-authentication-agent-1"
not_contains "lxqt-policykit-agent is no longer active" "$(grep -v '^#' <<<"$after")" "lxqt-policykit-agent"
contains "notify-log.py untouched" "$after" "exec-once = ~/dotfiles/linux/desktop/mako/notify-log.py"
contains "commented sourced file too" "$after_extra" "cornice takeover"
contains "kept cliphist line active" "$after" "exec-once = wl-paste --type text --watch cliphist store"
contains "kept hyprsunset active" "$after" "exec-once = hyprsunset -t 4000"
contains "kept hyprpaper active" "$after" "exec-once = hyprpaper"
contains "kept keybinds" "$after" "bind = SUPER, R, exec, \$cornice launcher"
contains "kept source line" "$after" "source = ~/dotfiles/linux/desktop/hypr/extra.conf"
# Nothing is lost: drop the marker lines, un-comment what we commented, and the
# file must be identical to the original (the sandbox has no pre-existing
# comments, so stripping one leading "# " is unambiguous).
restore_view() { grep -v '^# cornice takeover:' "$1" | sed 's/^# //'; }
if diff -q <(restore_view "$conf_dir/hyprland.conf") "$sandbox/orig/hyprland.conf" >/dev/null; then
  ok "no line lost or duplicated by commenting"
else
  bad "commenting changed the file content"
  diff <(restore_view "$conf_dir/hyprland.conf") "$sandbox/orig/hyprland.conf" | head -5
fi
check "one marker per takeover in the main file" "$(grep -c '^# cornice takeover:' "$conf_dir/hyprland.conf")" "5"

# idempotent: a second apply changes nothing
again=$("$takeover" --conf-dir "$conf_dir" --no-kill --apply 2>&1)
check "apply is idempotent" "$(cat "$conf_dir/hyprland.conf")" "$after"
contains "second apply reports nothing to do" "$again" "nothing to take over"

# backup written
stamp_dir=$(find "$state_dir/cornice/takeover" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
if [[ -f $stamp_dir/manifest.json ]]; then ok "manifest written"; else bad "manifest missing"; fi
if diff -q "$stamp_dir/files/hyprland.conf" "$sandbox/orig/hyprland.conf" >/dev/null; then
  ok "backup matches the original file"
else
  bad "backup differs from the original file"
fi

# ---- undo ------------------------------------------------------------------
undo=$("$takeover" --undo 2>&1)
check "undo restores hyprland.conf" "$(cat "$conf_dir/hyprland.conf")" "$before_hyprland"
check "undo restores sourced file" "$(cat "$conf_dir/extra.conf")" "$before_extra"
contains "undo reports the restore" "$undo" "restored"

# ---- units (fake systemd, so the real user manager is never touched) --------
echo
echo "unit handling (stub systemctl)"

stub_dir="$sandbox/stub"
mkdir -p "$stub_dir"
export STUB_LOG="$sandbox/systemctl.log"
: >"$STUB_LOG"
cat >"$stub_dir/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LOG:?}"
case "$*" in
  *list-units*)
    echo "  mako.service loaded active running Lightweight Wayland notification daemon"
    echo "  unrelated.service loaded active running Something else"
    ;;
  *is-enabled*mako.service*) echo enabled ;;
  *is-active*mako.service*) echo active ;;
  *is-enabled*unrelated.service*) echo enabled ;;
  *is-active*unrelated.service*) echo active ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$stub_dir/systemctl"

empty_conf="$sandbox/empty-hypr"
mkdir -p "$empty_conf"

unit_plan=$(PATH="$stub_dir:$PATH" "$takeover" --conf-dir "$empty_conf" --no-kill 2>&1)
contains "plan finds the mako systemd unit" "$unit_plan" "unit mako.service"
not_contains "plan ignores unrelated units" "$unit_plan" "unrelated.service"

PATH="$stub_dir:$PATH" "$takeover" --conf-dir "$empty_conf" --no-kill --apply >/dev/null 2>&1
if grep -q -- "disable --now mako.service" "$STUB_LOG"; then
  ok "apply disables the unit"
else
  bad "apply did not disable the unit"
fi
if grep -q -- "unrelated.service" "$STUB_LOG"; then
  bad "apply touched an unrelated unit"
else
  ok "apply leaves unrelated units alone"
fi

PATH="$stub_dir:$PATH" "$takeover" --undo >/dev/null 2>&1
if grep -q -- "enable --now mako.service" "$STUB_LOG"; then
  ok "undo re-enables the unit"
else
  bad "undo did not re-enable the unit"
fi

echo
if ((failures == 0)); then
  printf '\033[32mtakeover-test: %d/%d PASS\033[0m\n' "$pass" "$pass"
  exit 0
fi
printf '\033[31mtakeover-test: %d passed, %d FAILED\033[0m\n' "$pass" "$failures"
exit 1
