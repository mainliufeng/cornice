#!/usr/bin/env bash
# Lock-screen verification in a private compositor stack.
#
# Covers what can be covered without the user's password:
#   1. success path — a pam_permit service stands in for a correct password
#   2. failure path — the real hyprlock PAM stack with a wrong password must
#      keep the session locked
#   3. emergency release — the documented TTY recovery path
#
# Never touches the live session or the live PAM configuration.
set -uo pipefail

prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export CORNICE_PATH="$prefix"
export PATH="$prefix/bin:$PATH"

runtime=$(mktemp -d /tmp/cnl-XXXXXX)
keep=${CORNICE_KEEP_ARTIFACTS:-0}
mutter_pid=""; dbus_pid=""; shell_pid=""
result=0

cleanup() {
  [[ -n $shell_pid ]] && kill "$shell_pid" 2>/dev/null
  pkill -f "Hyprland -c $runtime/hyprland.conf" 2>/dev/null
  [[ -n $mutter_pid ]] && kill "$mutter_pid" 2>/dev/null
  [[ -n $dbus_pid ]] && kill "$dbus_pid" 2>/dev/null
  pkill -f "mutter --headless --wayland --wayland-display=cornice-lock-test" 2>/dev/null
  sleep 0.4
  if ((keep)); then echo "artifacts kept in $runtime"; else
    fusermount3 -u "$runtime/gvfs" 2>/dev/null || true
    rm -rf "$runtime" 2>/dev/null || true
  fi
}
trap cleanup EXIT

section() { printf '\n== %s\n' "$1"; }
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; result=1; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

pkill -f "mutter --headless --wayland --wayland-display=cornice-lock-test" 2>/dev/null
sleep 0.2

export XDG_RUNTIME_DIR="$runtime"
export XDG_CONFIG_HOME="$runtime/config" XDG_CACHE_HOME="$runtime/cache" XDG_STATE_HOME="$runtime/state"
mkdir -p "$XDG_CONFIG_HOME/cornice" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

cat >"$runtime/hyprland.conf" <<'EOF'
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
    background_color = 0x111111
}
EOF

# A permissive PAM service, so the "correct password" branch is testable without
# anyone's real password. Used only inside this sandbox.
mkdir -p "$runtime/pam"
cat >"$runtime/pam/cornice-test" <<'EOF'
auth sufficient pam_permit.so
account required pam_permit.so
session required pam_permit.so
EOF

section "private stack (runtime: $runtime)"
read -r DBUS_ADDR DBUS_PID < <(dbus-daemon --session --fork --print-address=1 --print-pid=1 | tr '\n' ' ')
dbus_pid=$DBUS_PID
export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR"
pass "private session bus"

mutter --headless --wayland --no-x11 --wayland-display=cornice-lock-test \
  --virtual-monitor 1280x800 >"$runtime/mutter.log" 2>&1 &
mutter_pid=$!
for _ in $(seq 1 100); do [[ -S "$runtime/cornice-lock-test" ]] && break; sleep 0.1; done
[[ -S "$runtime/cornice-lock-test" ]] && pass "headless mutter up" || { fail "mutter did not start"; exit 1; }

export WAYLAND_DISPLAY=cornice-lock-test
LIBSEAT_BACKEND=noop AQ_DRM_DEVICES=/dev/null \
  Hyprland -c "$runtime/hyprland.conf" >"$runtime/hyprland.log" 2>&1 &
for _ in $(seq 1 150); do
  sig=$(ls -t "$runtime/hypr" 2>/dev/null | head -1)
  [[ -n ${sig:-} && -S "$runtime/hypr/$sig/.socket.sock" ]] && break
  sleep 0.1
done
[[ -n ${sig:-} ]] || { fail "Hyprland did not start"; exit 1; }
export HYPRLAND_INSTANCE_SIGNATURE="$sig"
for _ in $(seq 1 60); do hyprctl -j monitors >/dev/null 2>&1 && break; sleep 0.1; done
pass "nested Hyprland up"

if grep -qE "drm: (Starting backend|Registered gpu)" "$runtime/hypr/$sig/hyprland.log" 2>/dev/null; then
  fail "Hyprland opened a DRM backend — aborting"; exit 1
fi
pass "no DRM backend (real hardware untouched)"

hyprctl output create headless >/dev/null 2>&1
for _ in $(seq 1 50); do
  hyprctl -j monitors 2>/dev/null | jq -e '.[] | select(.name | startswith("HEADLESS"))' >/dev/null 2>&1 && break
  sleep 0.1
done
hyprctl keyword monitor "HEADLESS-1,1280x800,0x0,1" >/dev/null 2>&1
own=$(ls -t "$runtime"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)
export WAYLAND_DISPLAY="${own##*/}"
pass "headless output ready (display ${WAYLAND_DISPLAY})"

start_shell() {
  "$prefix/bin/cornice-qs" -n -p "$prefix/shell" >>"$runtime/shell.log" 2>&1 &
  shell_pid=$!
  for _ in $(seq 1 150); do cornice ping >/dev/null 2>&1 && return 0; sleep 0.1; done
  return 1
}

lock_status() { timeout 6 cornice ipc lock status 2>/dev/null || echo '{}'; }
hypr_locked() { hyprctl locked 2>/dev/null | head -1; }

wait_for_pam() {
  for _ in $(seq 1 40); do
    [[ $(lock_status | jq -r '.pamAvailable') == "true" ]] && return 0
    sleep 0.25
  done
  return 1
}

section "phase 1: a wrong password must keep the session locked (real PAM stack)"
if start_shell; then pass "shell up with the real PAM service"; else fail "shell did not start"; exit 1; fi
wait_for_pam && pass "PAM service is readable" || fail "PAM probe never reported the service as available"
expect_eq "lock with the real PAM stack" "ok" "$(timeout 6 cornice ipc lock lock 2>/dev/null)"
sleep 1.5
status=$(lock_status)
expect_eq "lock reports locked" "true" "$(jq -r '.locked' <<<"$status")"
expect_eq "lock surface is secure" "true" "$(jq -r '.secure' <<<"$status")"
expect_eq "compositor reports the session locked" "true" "$(hypr_locked)"
if timeout 10 grim "$runtime/locked.png" >/dev/null 2>&1; then pass "locked screen captured"; else fail "grim failed while locked"; fi

timeout 25 cornice ipc lock attempt definitely-not-the-password >/dev/null 2>&1
# The stack may include a face-unlock module (Howdy) that takes seconds before
# it falls through to the password, so give the conversation time to finish.
state=""
for _ in $(seq 1 60); do
  state=$(lock_status | jq -r '.state')
  [[ $state == "failed" ]] && break
  sleep 0.5
done
status=$(lock_status)
expect_eq "still locked after a wrong password" "true" "$(jq -r '.locked' <<<"$status")"
expect_eq "state reports the failure" "failed" "$state"
expect_eq "compositor still holds the lock" "true" "$(hypr_locked)"

section "phase 2: restart is refused while locked, emergency release recovers"
restart_out=$(timeout 20 cornice restart 2>&1 || true)
if grep -q "refusing to restart" <<<"$restart_out"; then pass "restart refused while locked"
else fail "restart was not refused while locked: $restart_out"; fi
expect_eq "still locked after the refused restart" "true" "$(hypr_locked)"
expect_eq "emergency unlock returns ok" "ok" "$(timeout 6 cornice ipc lock emergencyUnlock 2>/dev/null)"
sleep 1.5
expect_eq "lock released" "false" "$(lock_status | jq -r '.locked')"
expect_eq "compositor lock released" "false" "$(hypr_locked)"

section "phase 3: a correct password unlocks (pam_permit stands in for it)"
cat >"$XDG_CONFIG_HOME/cornice/config.json" <<JSON
{ "lock": { "pamService": "cornice-test", "pamDirectory": "$runtime/pam" } }
JSON
timeout 30 cornice restart >/dev/null 2>&1
sleep 2.5
if cornice ping >/dev/null 2>&1; then pass "shell restarted with the test PAM service"; else fail "shell did not come back"; fi
if wait_for_pam; then
  pass "test PAM service is readable (custom configDirectory honoured)"
  expect_eq "lock" "ok" "$(timeout 6 cornice ipc lock lock 2>/dev/null)"
  sleep 1.5
  expect_eq "correct password unlocks" "ok" "$(timeout 20 cornice ipc lock attempt anything 2>/dev/null | head -1)"
  sleep 1.5
  expect_eq "lock released" "false" "$(lock_status | jq -r '.locked')"
  expect_eq "compositor lock released" "false" "$(hypr_locked)"
else
  fail "custom PAM configDirectory was not honoured (Quickshell may only use /etc/pam.d)"
fi

section "shell log"
problems=$(sed 's/\x1b\[[0-9;]*m//g' "$runtime/shell.log" 2>/dev/null \
  | grep -iE "is not a type|ReferenceError|TypeError|RangeError|Cannot assign|plugin failed" || true)
if [[ -z $problems ]]; then pass "no QML errors in the shell log"; else fail "QML problems:"; echo "$problems" | head -5; fi

echo
((result == 0)) && echo "RESULT: all lock checks passed" || echo "RESULT: failures above"
exit "$result"
