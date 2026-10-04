#!/usr/bin/env bash
# Lock-screen display-off verification in a private compositor stack.
#
# Regression: the panel stayed lit for a long time after locking. The lock screen
# now has its own display-off deadline (`idle.lockScreenOff`, default 10s):
#   1. a lock that follows a long idle period must NOT blank the panel instantly
#   2. no input for the deadline turns the panel off
#   3. input on the lock screen wakes the panel and restarts the countdown
#   4. unlocking cancels the countdown and restores the panel, even mid-DPMS
#   5. a manual `idle inhibit` does not keep a locked screen lit
#   6. the normal unlocked idle display-off policy still works
#   7. automatic idle locking arms the same countdown
#
# Never touches the live session, the live DPMS state or the live PAM config.
set -uo pipefail
ulimit -c 0   # compositor crashes in a test must not litter the repo with cores

prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export CORNICE_PATH="$prefix"
export PATH="$prefix/bin:$PATH"

# Sweep orphaned headless compositors from a previously killed run.
pkill -f "Hyprland -c /tmp/cni" 2>/dev/null
pkill -f "mutter --headless --wayland --wayland-display=cornice-idle" 2>/dev/null
sleep 0.3

runtime=$(mktemp -d /tmp/cni-XXXXXX)
keep=${CORNICE_KEEP_ARTIFACTS:-0}
mutter_pid=""; dbus_pid=""; shell_pid=""; idle_pointer_pid=""
result=0

cleanup() {
  [[ -n ${idle_pointer_pid:-} ]] && kill "$idle_pointer_pid" 2>/dev/null
  [[ -n $shell_pid ]] && kill "$shell_pid" 2>/dev/null
  pkill -f "Hyprland -c $runtime/hyprland.conf" 2>/dev/null
  [[ -n $mutter_pid ]] && kill "$mutter_pid" 2>/dev/null
  [[ -n $dbus_pid ]] && kill "$dbus_pid" 2>/dev/null
  pkill -f "mutter --headless --wayland --wayland-display=cornice-idle-test" 2>/dev/null
  sleep 0.4
  if ((keep)); then echo "artifacts kept in $runtime"; else rm -rf "$runtime" 2>/dev/null || true; fi
}
trap cleanup EXIT

section() { printf '\n== %s\n' "$1"; }
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; result=1; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

pkill -f "mutter --headless --wayland --wayland-display=cornice-idle-test" 2>/dev/null
sleep 0.2

export XDG_RUNTIME_DIR="$runtime"
export XDG_CONFIG_HOME="$runtime/config" XDG_CACHE_HOME="$runtime/cache" XDG_STATE_HOME="$runtime/state"
mkdir -p "$XDG_CONFIG_HOME/cornice" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

# Test PAM: a permissive service so lock/unlock is testable without a password.
mkdir -p "$runtime/pam"
cat >"$runtime/pam/cornice-test" <<'EOF'
auth sufficient pam_permit.so
account required pam_permit.so
session required pam_permit.so
EOF

# A hyprctl wrapper that makes `dispatch dpms off` slow, so the race test can
# deliver input while the off command is still in flight. Only the race suite
# puts it on PATH; every other call passes straight through.
mkdir -p "$runtime/bin"
cat >"$runtime/bin/hyprctl" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == dispatch && \${2:-} == dpms && \${3:-} == off ]]; then
  : >"$runtime/dpms-off-inflight"
  sleep 2
fi
exec /usr/bin/hyprctl "\$@"
EOF
chmod +x "$runtime/bin/hyprctl"

write_config() { # lockSeconds lockScreenOff screenOffAc screenOffBattery
  cat >"$XDG_CONFIG_HOME/cornice/config.json" <<JSON
{ "language": "en", "background": { "dir": "$prefix/wallpapers" },
  "lock": { "pamService": "cornice-test", "pamDirectory": "$runtime/pam", "showUser": false },
  "idle": { "dimAc": 0, "dimBattery": 0,
            "screenOffAc": $3, "screenOffBattery": $4,
            "lock": $1, "lockScreenOff": $2,
            "lockOnSleep": false, "lockOnLidClose": false, "lockOnLockSignal": false } }
JSON
}

rm -rf "$runtime/shell"
cp -r "$prefix/shell" "$runtime/shell"

cat >"$runtime/hyprland.conf" <<'EOF'
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
    background_color = 0x111111
}
EOF

section "private stack (runtime: $runtime)"
read -r DBUS_ADDR DBUS_PID < <(dbus-daemon --session --fork --print-address=1 --print-pid=1 | tr '\n' ' ')
if [[ ${DBUS_ADDR:-} != unix:* || ! ${DBUS_PID:-} =~ ^[0-9]+$ ]]; then
  fail "private session bus did not start"; exit 1
fi
dbus_pid=$DBUS_PID
export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR"
pass "private session bus"

mutter --headless --wayland --no-x11 --wayland-display=cornice-idle-test \
  --virtual-monitor 1280x800 >"$runtime/mutter.log" 2>&1 &
mutter_pid=$!
for _ in $(seq 1 100); do [[ -S "$runtime/cornice-idle-test" ]] && break; sleep 0.1; done
[[ -S "$runtime/cornice-idle-test" ]] && pass "headless mutter up" || { fail "mutter did not start"; exit 1; }

export WAYLAND_DISPLAY=cornice-idle-test
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

# Ignore host input in this private compositor.
while IFS= read -r device; do
  [[ -n $device ]] || continue
  [[ $(hyprctl keyword "device[$device]:enabled" false) == ok ]] \
    || { fail "could not isolate private input device: $device"; exit 1; }
done < <(hyprctl devices -j | jq -r '(.mice[]?, .keyboards[]?, .touch[]?) | .name')
pass "host input devices disabled in the private compositor"

hyprctl output create headless >/dev/null 2>&1
for _ in $(seq 1 50); do
  hyprctl -j monitors 2>/dev/null | jq -e '.[] | select(.name | startswith("HEADLESS"))' >/dev/null 2>&1 && break
  sleep 0.1
done
hyprctl keyword monitor "HEADLESS-1,1280x800,0x0,1" >/dev/null 2>&1
own=$(ls -t "$runtime"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)
export WAYLAND_DISPLAY="${own##*/}"
pass "headless output ready (display ${WAYLAND_DISPLAY})"

# Real pointer events for the private compositor (idle-notify needs a seat).
wayland-scanner client-header "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.h" || exit 1
wayland-scanner private-code "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.c" || exit 1
cc "$prefix/test/hover-pointer.c" "$runtime/virtual-pointer.c" -I"$runtime" \
  $(pkg-config --cflags --libs wayland-client) -o "$runtime/hover-pointer" || exit 1
coproc IDLE_POINTER { exec "$runtime/hover-pointer" 100 100 1280 800 interactive; }
idle_pointer_pid=$IDLE_POINTER_PID
exec {idle_pointer_in}>&"${IDLE_POINTER[1]}"
exec {idle_pointer_out}<&"${IDLE_POINTER[0]}"
pointer() { printf '100 100 hover\n' >&"$idle_pointer_in"; read -r -t 3 _ <&"$idle_pointer_out" || true; }
pointer
pass "virtual pointer ready"

start_shell() {
  "$prefix/bin/cornice-qs" -n -p "$runtime/shell" >>"$runtime/shell.log" 2>&1 &
  shell_pid=$!
  for _ in $(seq 1 150); do cornice ping >/dev/null 2>&1 && return 0; sleep 0.1; done
  return 1
}
restart_shell() { timeout 30 cornice restart >/dev/null 2>&1; for _ in $(seq 1 150); do cornice ping >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }

idle_json() { timeout 6 cornice ipc idle status 2>/dev/null || echo '{}'; }
lock_json() { timeout 6 cornice ipc lock status 2>/dev/null || echo '{}'; }
idle_field() { idle_json | jq -r "$1"; }
lock_field() { lock_json | jq -r "$1"; }

suite=${CORNICE_IDLE_SUITE:-all}

poll_field() { # fn jqexpr expected timeout desc
  local fn=$1 expr=$2 expected=$3 timeout=$4 desc=$5
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    [[ $("$fn" "$expr") == "$expected" ]] && { pass "$desc"; return 0; }
    sleep 0.1
  done
  fail "$desc (expected $expr=$expected, got $("$fn" "$expr"))"
  return 1
}

wait_for_pam() {
  for _ in $(seq 1 40); do [[ $(lock_field '.pamAvailable') == "true" ]] && return 0; sleep 0.25; done
  return 1
}

# One baseline shell for the selected suite, started unlocked (lock disabled);
# phase 6 restarts it with the automatic-lock config.
write_config 0 3 0 0
if start_shell; then pass "shell up"; else fail "shell did not start"; exit 1; fi
wait_for_pam && pass "PAM service readable" || fail "PAM probe never reported available"

if [[ $suite == all || $suite == manual ]]; then
section "phase 1: manual lock after a long idle does not blank instantly, then blanks on schedule"
poll_field idle_field '.lockScreenOffSeconds' 3 5 "config lockScreenOff=3 is loaded"
# Build up a long idle period (> lockScreenOff) before locking. A naive
# IdleMonitor would blank the panel the moment the lock engaged.
sleep 4
expect_eq "lock" "ok" "$(timeout 6 cornice ipc lock lock 2>/dev/null)"
poll_field lock_field '.secure' true 6 "lock is secure"
expect_eq "panel is still on right after locking" "false" "$(idle_field '.screenOff')"
poll_field idle_field '.screenOff' true 6 "panel turns off after the lock deadline"
expect_eq "the last action was display-off" "display-off" "$(idle_field '.lastAction')"

section "phase 2: input on the lock screen wakes the panel and restarts the countdown"
pointer
poll_field idle_field '.screenOff' false 4 "input wakes the locked panel"
expect_eq "the last action was display-on" "display-on" "$(idle_field '.lastAction')"
poll_field idle_field '.screenOff' true 6 "panel turns off again after input stops"

section "phase 3: unlocking cancels the countdown and restores the panel"
expect_eq "emergency unlock" "ok" "$(timeout 6 cornice ipc lock emergencyUnlock 2>/dev/null)"
poll_field lock_field '.locked' false 4 "session unlocked"
expect_eq "compositor lock released (phase 3)" "false" "$(hyprctl locked 2>/dev/null | head -1)"
poll_field idle_field '.screenOff' false 4 "panel is on after unlocking"
expect_eq "lock-screen countdown is disarmed" "false" "$(idle_field '.lockScreenOffArmed')"
sleep 2
expect_eq "panel stays on after unlocking" "false" "$(idle_field '.screenOff')"
# A DPMS command that is still in flight when the state flips must reconcile.
timeout 6 cornice ipc idle displayOff >/dev/null 2>&1
timeout 6 cornice ipc idle displayOn >/dev/null 2>&1
poll_field idle_field '.screenOff' false 4 "off/on race finishes with the panel on"
expect_eq "no pending DPMS request is left" "false" "$(idle_field '.screenOffRequested')"

section "phase 4: a manual idle inhibit does not keep a locked screen lit"
expect_eq "inhibit indefinitely" "inhibited until released" "$(timeout 6 cornice ipc idle inhibit 0 2>/dev/null)"
expect_eq "inhibit is reported" "true" "$(idle_field '.inhibited')"
expect_eq "lock" "ok" "$(timeout 6 cornice ipc lock lock 2>/dev/null)"
poll_field lock_field '.secure' true 6 "lock is secure while inhibited"
expect_eq "the normal screen-off monitor is disabled by the inhibit" "false" "$(idle_field '.monitorsEnabled.screenOff')"
poll_field idle_field '.screenOff' true 6 "the lock countdown still blanks the panel while inhibited"
expect_eq "emergency unlock" "ok" "$(timeout 6 cornice ipc lock emergencyUnlock 2>/dev/null)"
expect_eq "compositor lock released (phase 4)" "false" "$(hyprctl locked 2>/dev/null | head -1)"
timeout 6 cornice ipc idle release >/dev/null 2>&1
poll_field idle_field '.inhibited' false 4 "inhibit released"
poll_field idle_field '.screenOff' false 4 "panel restored after release"

section "phase 5: the normal unlocked idle policy is unchanged"
write_config 0 0 2 2
if restart_shell; then pass "shell restarted with the normal policy"; else fail "shell did not restart"; exit 1
fi
poll_field idle_field '.screenOffSeconds' 2 5 "normal screenOffAc=2 is loaded"
expect_eq "lock-screen countdown disabled by config" "false" "$(idle_field '.lockScreenOffArmed')"
poll_field idle_field '.screenOff' true 6 "unlocked idle still blanks the panel"
pointer
poll_field idle_field '.screenOff' false 4 "input still wakes the unlocked panel"

fi

# The automatic-lock phase needs a compositor whose session lock has never been
# engaged: Hyprland keeps reporting `hyprctl locked` after an emergency unlock in
# a nested stack, which makes the lock service refuse to lock again. Run it in a
# fresh compositor instead of failing on that environment artifact.
if [[ $suite == all ]]; then
  cleanup
  trap - EXIT
  CORNICE_IDLE_SUITE=auto "$0" || result=1
  CORNICE_IDLE_SUITE=race "$0" || result=1
fi

if [[ $suite == race ]]; then
section "phase 7: input while a DPMS-off command is in flight cancels it"
write_config 0 2 0 0
# Restart the shell directly (not through the watchdog) so it inherits the
# delayed hyprctl wrapper on PATH.
"$prefix/bin/cornice-qs" kill -p "$runtime/shell" --any-display >/dev/null 2>&1 || true
for _ in $(seq 1 50); do "$prefix/bin/cornice-qs" ipc -p "$runtime/shell" call shell ping >/dev/null 2>&1 || break; sleep 0.1; done
export PATH="$runtime/bin:$PATH"
if start_shell; then pass "shell up with the delayed DPMS wrapper"; else fail "shell did not start"; exit 1; fi
wait_for_pam && pass "PAM service readable" || fail "PAM probe never reported available"
poll_field idle_field '.lockScreenOffSeconds' 2 5 "lockScreenOff=2 is loaded"
sleep 3
expect_eq "lock" "ok" "$(timeout 6 cornice ipc lock lock 2>/dev/null)"
poll_field lock_field '.secure' true 6 "lock is secure"
poll_field idle_field '.screenOffRequested' true 6 "DPMS off is in flight"
expect_eq "panel is still on while off is in flight" "false" "$(idle_field '.screenOff')"
# Real input arrives before the off command finishes.
pointer
poll_field idle_field '.screenOffRequested' false 4 "in-flight input withdraws the off request"
poll_field idle_field '.screenOff' false 4 "panel is on after the in-flight off exits"
sleep 1
expect_eq "panel stays on after the race" "false" "$(idle_field '.screenOff')"
# With no further input the normal countdown still turns it off.
poll_field idle_field '.screenOff' true 8 "panel turns off again once input stops"
expect_eq "emergency unlock" "ok" "$(timeout 6 cornice ipc lock emergencyUnlock 2>/dev/null)"
poll_field idle_field '.screenOff' false 4 "panel restored after unlock"
fi

if [[ $suite == auto ]]; then
section "phase 6: automatic idle locking arms the lock-screen countdown"
write_config 2 2 0 0
if restart_shell; then pass "shell restarted for the automatic-lock test"; else fail "shell did not restart"; exit 1
fi
pointer
poll_field lock_field '.locked' true 8 "automatic idle locking fires"
poll_field lock_field '.secure' true 6 "automatic lock is secure"
poll_field idle_field '.screenOff' true 6 "automatic lock blanks the panel on schedule"
expect_eq "emergency unlock" "ok" "$(timeout 6 cornice ipc lock emergencyUnlock 2>/dev/null)"
poll_field idle_field '.screenOff' false 4 "panel restored after the automatic lock"
fi

if [[ -f "$runtime/shell.log" ]]; then
section "shell log"
problems=$(sed 's/\x1b\[[0-9;]*m//g' "$runtime/shell.log" 2>/dev/null \
  | grep -iE "is not a type|ReferenceError|TypeError|RangeError|Cannot assign|plugin failed" || true)
if [[ -z $problems ]]; then pass "no QML errors in the shell log"; else fail "QML problems:"; echo "$problems" | head -5; fi
fi

echo
((result == 0)) && echo "RESULT: all idle lock-screen checks passed" || echo "RESULT: failures above"
exit "$result"
