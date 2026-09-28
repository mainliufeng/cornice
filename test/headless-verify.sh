#!/usr/bin/env bash
# Headless verification: prove the shell starts, answers IPC and paints a bar —
# without touching the session you are logged into, and without touching your
# GPU.
#
# Chain: a private dbus session runs a headless mutter (a virtual monitor, no
# output device) → Hyprland is started *nested* inside it, so aquamarine picks
# its Wayland backend instead of DRM → the shell runs inside that Hyprland.
#
# The harness hard-fails if Hyprland ever opens a DRM backend, so a test run
# can never take over the screen you are using.
set -uo pipefail

prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export CORNICE_PATH="$prefix"
export PATH="$prefix/bin:$PATH"

runtime=$(mktemp -d /tmp/cn-XXXXXX)   # short: unix socket paths are length-limited
keep=${CORNICE_KEEP_ARTIFACTS:-0}
mutter_pid=""
shell_pid=""
result=0

cleanup() {
  [[ -n $shell_pid ]] && kill "$shell_pid" 2>/dev/null
  pkill -f "Hyprland -c $runtime/hyprland.conf" 2>/dev/null
  [[ -n $mutter_pid ]] && kill "$mutter_pid" 2>/dev/null
  pkill -f "mutter --headless --wayland --wayland-display=cornice-test" 2>/dev/null
  sleep 0.4
  if ((keep)); then
    echo "artifacts kept in $runtime"
  else
    # mutter spawns a gvfs fuse mount that must be unmounted before rm.
    fusermount3 -u "$runtime/gvfs" 2>/dev/null || true
    rm -rf "$runtime" 2>/dev/null || true
  fi
}

# Leftovers from an interrupted run would collide on the socket name.
pkill -f "mutter --headless --wayland --wayland-display=cornice-test" 2>/dev/null
sleep 0.2
trap cleanup EXIT

section() { printf '\n== %s\n' "$1"; }
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; result=1; }
warn() { printf '  WARN  %s\n' "$1"; }

export XDG_RUNTIME_DIR="$runtime"
export XDG_CONFIG_HOME="$runtime/config"
export XDG_CACHE_HOME="$runtime/cache"
export XDG_STATE_HOME="$runtime/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

cat >"$runtime/hyprland.conf" <<'EOF'
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    # 0 also disables Hyprland's built-in anime wallpaper, so anything painted
    # at the top of the screen is ours and cannot be mistaken for a render.
    force_default_wallpaper = 0
    background_color = 0x111111
}
debug {
    disable_logs = false
}
EOF

section "private compositor stack (runtime: $runtime)"
dbus-run-session -- mutter --headless --wayland --no-x11 \
  --wayland-display=cornice-test --virtual-monitor 1280x800 \
  >"$runtime/mutter.log" 2>&1 &
mutter_pid=$!

for _ in $(seq 1 100); do
  [[ -S "$runtime/cornice-test" ]] && break
  sleep 0.1
done
if [[ -S "$runtime/cornice-test" ]]; then pass "headless mutter is up"
else fail "mutter never created its socket"; tail -20 "$runtime/mutter.log"; exit 1; fi

export WAYLAND_DISPLAY=cornice-test
# Two deliberate env choices:
#   LIBSEAT_BACKEND=noop     — libseat cannot find a live logind session here,
#                              and an "inactive session" makes Hyprland skip
#                              every frame commit (nothing would render).
#   AQ_DRM_DEVICES=/dev/null — deny aquamarine any DRM node, so even with an
#                              "active" seat the only usable backend is the
#                              nested Wayland one. The harness refuses to go on
#                              if a DRM backend still shows up in the log.
LIBSEAT_BACKEND=noop AQ_DRM_DEVICES=/dev/null \
  Hyprland -c "$runtime/hyprland.conf" >"$runtime/hyprland.log" 2>&1 &
hypr_pid=$!

for _ in $(seq 1 150); do
  sig=$(ls -t "$runtime/hypr" 2>/dev/null | head -1)
  [[ -n ${sig:-} && -S "$runtime/hypr/$sig/.socket.sock" ]] && break
  sleep 0.1
done
if [[ -z ${sig:-} ]]; then fail "Hyprland did not come up"; tail -20 "$runtime/hyprland.log"; exit 1; fi

export HYPRLAND_INSTANCE_SIGNATURE="$sig"
hypr_log="$runtime/hypr/$sig/hyprland.log"


# The IPC socket appearing is not the same as the compositor answering yet.
reachable=0
for _ in $(seq 1 60); do
  if hyprctl -j monitors >/dev/null 2>&1; then reachable=1; break; fi
  sleep 0.1
done

if ((reachable)); then
  outputs=$(hyprctl -j monitors | jq -r '[.[] | "\(.name) \(.width)x\(.height)"] | join(", ")')
  pass "nested Hyprland is up (outputs: $outputs)"
else
  fail "hyprctl cannot reach the nested compositor"
  echo "  hyprctl says: $(hyprctl -j monitors 2>&1 | head -2 | tr '\n' ' ')"
  echo "  env: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR sig=$HYPRLAND_INSTANCE_SIGNATURE"
  ls -la "$runtime/hypr/$sig" 2>/dev/null | sed 's/^/  /'
  tail -20 "$hypr_log" 2>/dev/null
  exit 1
fi

# Safety rail: the Wayland backend must be the one in use. If Hyprland opened
# DRM, this run was touching real hardware and the rest must not continue.
if grep -qE "drm: (Starting backend|Registered gpu)" "$hypr_log" 2>/dev/null; then
  fail "Hyprland opened a DRM backend — refusing to continue touching real hardware"
  exit 1
fi
pass "no DRM backend was opened (parent GPU untouched)"

# mutter's virtual monitor is not necessarily presented as a wl_output to the
# nested compositor, so give Hyprland a headless output of its own — still no
# DRM, still offscreen.
hyprctl output create headless >/dev/null 2>&1
for _ in $(seq 1 50); do
  if hyprctl -j monitors 2>/dev/null | jq -e '.[] | select(.name | startswith("HEADLESS"))' >/dev/null 2>&1; then break; fi
  sleep 0.1
done
headless_output=$(hyprctl -j monitors 2>/dev/null | jq -r '[.[] | select(.name | startswith("HEADLESS")) | .name] | first // ""')
if [[ -n $headless_output ]]; then
  hyprctl keyword monitor "$headless_output,1280x800,0x0,1" >/dev/null 2>&1
  sleep 0.5
  pass "headless output ready: $headless_output ($(hyprctl -j monitors | jq -r --arg n "$headless_output" '.[] | select(.name==$n) | "\(.width)x\(.height)"'))"
else
  fail "could not create a headless output in the nested compositor"
  exit 1
fi

# Quickshell talks to Hyprland's own socket, not mutter's.
for _ in $(seq 1 100); do
  own=$(ls -t "$runtime"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)
  [[ -n ${own:-} ]] && break
  sleep 0.1
done
if [[ -n ${own:-} ]]; then
  export WAYLAND_DISPLAY="${own##*/}"
  pass "shell display: $WAYLAND_DISPLAY"
else
  fail "Hyprland created no Wayland socket"; exit 1
fi

section "cornice"
"$prefix/bin/cornice-qs" -n -p "$prefix/shell" >"$runtime/shell.log" 2>&1 &
shell_pid=$!

ready=0
for _ in $(seq 1 150); do
  if cornice ping >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.1
done

if ((ready)); then
  pass "ipc: $(cornice ping)"
  pass "theme: $(cornice theme)"
  pass "plugins: $(cornice plugins | jq -r '[.[].id] | join(", ")')"
  pass "widgets: $(cornice widgets | jq -r '[.[].id] | join(", ")')"

  missing=$(cornice widgets | jq -r '[.[].id]' \
    | jq -r --argjson want '["cn.workspaces","cn.active-window","cn.clock","cn.battery","cn.audio"]' \
      '. as $have | ($want - $have) | join(",")')
  if [[ -z $missing ]]; then pass "every P0 widget was discovered"
  else fail "widgets missing: $missing"; fi

  if cornice config | jq -e '.bar.layout.center | length > 0' >/dev/null 2>&1; then
    pass "effective config carries a bar layout"
  else fail "effective config has no bar layout"; cornice config; fi

  if cornice config | jq -e '.bar.layout.right[0].id == "cn.audio"' >/dev/null 2>&1; then
    pass "config merging produced the expected right section"
  else warn "right section is not the default (a user config file exists?)"; fi
else
  fail "the shell never answered 'cornice ping'"
  echo "--- shell.log ---"; tail -40 "$runtime/shell.log"
fi

section "compositor state drives the widgets"
if command -v kitty >/dev/null 2>&1; then
  hyprctl dispatch exec kitty >/dev/null 2>&1
  title=""
  for _ in $(seq 1 50); do
    title=$(hyprctl -j activewindow 2>/dev/null | jq -r '.title // ""')
    [[ -n $title ]] && break
    sleep 0.1
  done
  if [[ -n $title ]]; then
    pass "a window opened in the nested compositor (active window: $title)"
    workspaces=$(hyprctl -j workspaces | jq -r '[.[].id] | join(",")')
    pass "workspaces reported by the compositor: $workspaces"
  else
    warn "kitty never appeared; the active-window widget was not exercised"
  fi
else
  warn "kitty not installed; skipping the window test"
fi

section "render"
sleep 2
shot="$runtime/cornice-bar.png"
if ((ready)) && timeout 15 grim "$shot" 2>"$runtime/grim.log"; then
  if python3 - "$shot" <<'PY'
import sys
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size

def mean(im):
    px = list(im.getdata())
    return tuple(sum(p[i] for p in px) // len(px) for i in range(3))

strip = img.crop((0, 0, w, 30))
below = img.crop((0, 30, w, 60))
sm, bm = mean(strip), mean(below)
distinct = len(strip.getcolors(maxcolors=1 << 22) or [])
print(f"  image {w}x{h}; bar strip mean {sm}, next strip mean {bm}, "
      f"{distinct} distinct colours in the bar area")

# The bar is an opaque, full-width strip painted in the theme's dark background.
# If it never mapped, the top rows match whatever is drawn below them.
painted = sm != bm and sum(sm) < 200
sys.exit(0 if painted else 1)
PY
  then pass "the bar painted content (screenshot: $shot)"
  else fail "the bar strip looks empty"; fi
  ((keep)) || cp "$shot" /tmp/cornice-bar.png 2>/dev/null || true
else
  warn "no screenshot: $(cat "$runtime/grim.log" 2>/dev/null)"
fi

section "log hygiene"
if grep -qiE "^.*(error|cannot|failed)" "$runtime/shell.log" 2>/dev/null; then
  warn "shell.log mentions errors:"; grep -inE "error|cannot|failed" "$runtime/shell.log" | head -10
else
  pass "shell.log is clean"
fi

echo
((result == 0)) && echo "RESULT: all checks passed" || echo "RESULT: failures above"
exit "$result"
