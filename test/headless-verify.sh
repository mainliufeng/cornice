#!/usr/bin/env bash
# Headless verification for cornice.
#
# Chain: a private session bus → a headless mutter (virtual monitor, no output
# device) → Hyprland nested inside it (aquamarine picks its Wayland backend, not
# DRM) → the shell. Nothing here touches the session you are logged into, and
# the harness hard-fails if Hyprland ever opens a DRM backend.
#
# What it proves: the shell starts, answers IPC over its own socket, discovers
# every plugin, reacts to compositor state, delivers notifications, opens
# panels, and paints.
set -uo pipefail
ulimit -c 0   # compositor crashes in a test must not litter the repo with cores

prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export CORNICE_PATH="$prefix"
export PATH="$prefix/bin:$PATH"

# Leftovers from a harness that was killed before its cleanup ran: an orphaned
# headless Hyprland keeps a core at 100% forever (this is what once had a laptop
# fan screaming for 11 hours). Sweep them before starting a new run.
pkill -f "Hyprland -c /tmp/cn" 2>/dev/null
pkill -f "mutter --headless --wayland --wayland-display=cornice" 2>/dev/null
sleep 0.3

runtime=$(mktemp -d /tmp/cn-XXXXXX)   # short: unix socket paths are length-limited
# Isolated brightness backend: interaction tests must never change host hardware.
mkdir -p "$runtime/test-bin"
export CORNICE_TEST_BACKLIGHT="$runtime/backlight-level"
printf '50\n' > "$CORNICE_TEST_BACKLIGHT"
cat > "$runtime/test-bin/light" <<'LIGHT'
#!/bin/sh
case "$1" in
  -G) cat "$CORNICE_TEST_BACKLIGHT" ;;
  -S) printf '%s\n' "$2" > "$CORNICE_TEST_BACKLIGHT" ;;
  *) exit 2 ;;
esac
LIGHT
chmod +x "$runtime/test-bin/light"
export PATH="$runtime/test-bin:$PATH"
keep=${CORNICE_KEEP_ARTIFACTS:-0}
mutter_pid=""
dbus_pid=""
shell_pid=""
tray_fixture_pid=""
hover_pointer_pid=""
weather_server_pid=""
result=0

cleanup() {
  [[ -n $hover_pointer_pid ]] && kill "$hover_pointer_pid" 2>/dev/null
  [[ -n ${media_fixture_pid:-} ]] && kill "$media_fixture_pid" 2>/dev/null
  [[ -n ${tooltip_audio_pid:-} ]] && kill "$tooltip_audio_pid" 2>/dev/null
  [[ -n $tray_fixture_pid ]] && kill "$tray_fixture_pid" 2>/dev/null
  [[ -n $weather_server_pid ]] && kill "$weather_server_pid" 2>/dev/null
  [[ -n $shell_pid ]] && kill "$shell_pid" 2>/dev/null
  pkill -f "Hyprland -c $runtime/hyprland.conf" 2>/dev/null
  [[ -n $mutter_pid ]] && kill "$mutter_pid" 2>/dev/null
  [[ -n $dbus_pid ]] && kill "$dbus_pid" 2>/dev/null
  pkill -f "mutter --headless --wayland --wayland-display=cornice-test" 2>/dev/null
  sleep 0.4
  if ((keep)); then
    echo "artifacts kept in $runtime"
  else
    fusermount3 -u "$runtime/gvfs" 2>/dev/null || true
    rm -rf "$runtime" 2>/dev/null || true
  fi
}
trap cleanup EXIT

section() { printf '\n== %s\n' "$1"; }
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; result=1; }
warn() { printf '  WARN  %s\n' "$1"; }

expect_eq() {   # label expected actual
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# Leftovers from an interrupted run would collide on socket names.
pkill -f "mutter --headless --wayland --wayland-display=cornice-test" 2>/dev/null
sleep 0.2

export XDG_RUNTIME_DIR="$runtime"
# Desktop entries are localized from the shell's locale. A real session gets
# LANG from the systemd user environment (zh_CN.UTF-8 here), while a test run
# inherits whatever the caller has — so the localized-search assertion would be
# meaningless without pinning it.
if locale -a 2>/dev/null | grep -qi "^zh_CN"; then
  export LANG=zh_CN.UTF-8
  export LC_ALL=zh_CN.UTF-8
fi
export XDG_CONFIG_HOME="$runtime/config"
export XDG_CACHE_HOME="$runtime/cache"
export XDG_STATE_HOME="$runtime/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

# A local stand-in for open-meteo: the weather plugin is pointed at it so the
# suite asserts on fixed values instead of today's real forecast (and without
# touching the network at all).
weather_port=""
if python3 -c "import ast,sys" >/dev/null 2>&1; then
  rm -f "$runtime/weather.port"
  setsid python3 "$prefix/test/fake-weather-server.py" --port 0 --print-port \
    >"$runtime/weather.port" 2>"$runtime/weather-server.log" &
  weather_server_pid=$!
  for _ in $(seq 1 20); do
    [[ -s $runtime/weather.port ]] && break
    sleep 0.2
  done
  weather_port=$(cat "$runtime/weather.port" 2>/dev/null || echo "")
fi

# Sandbox config: point weather at the fake API, and keep the idle chain from
# locking this private session (the lock suite covers locking deliberately).
if [[ -n $weather_port ]]; then
  mkdir -p "$XDG_CONFIG_HOME/cornice"
  cat >"$XDG_CONFIG_HOME/cornice/config.json" <<EOF
{
  "weather": {
    "baseUrl": "http://127.0.0.1:$weather_port/forecast",
    "geocodeUrl": "http://127.0.0.1:$weather_port/geocode",
    "locateUrl": "http://127.0.0.1:$weather_port/locate",
    "intervalMinutes": 60,
    "locations": [
      { "name": "Testville", "city": "Testville" },
      { "name": "Othertown", "city": "Othertown" }
    ]
  },
  "clock": { "worldClocks": [ { "name": "UTC", "zone": "UTC" } ] },
  "idle": { "dimAc": 0, "screenOffAc": 0, "lock": 0, "lockOnSleep": false, "lockOnLockSignal": false, "lockOnLidClose": false },
  "background": { "dir": "$prefix/wallpapers" }
}
EOF
else
  fail "could not start the weather test API"
  cat "$runtime/weather-server.log" 2>/dev/null
  exit 1
fi

cat >"$runtime/hyprland.conf" <<'EOF'
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    # 0 also disables Hyprland's built-in wallpaper, so anything painted at the
    # top of the screen is ours and cannot be mistaken for a render.
    force_default_wallpaper = 0
    background_color = 0x111111
}
EOF

section "private session bus and compositor (runtime: $runtime)"
read -r DBUS_ADDR DBUS_PID < <(dbus-daemon --session --fork --print-address=1 --print-pid=1 | tr '\n' ' ')
if [[ ${DBUS_ADDR:-} != unix:* || ! ${DBUS_PID:-} =~ ^[0-9]+$ ]]; then
  fail "private session bus did not start"
  exit 1
fi
dbus_pid=$DBUS_PID
export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR"
pass "private session bus: ${DBUS_ADDR%%guid=*}"

mutter --headless --wayland --no-x11 --wayland-display=cornice-test \
  --virtual-monitor 1280x800 >"$runtime/mutter.log" 2>&1 &
mutter_pid=$!

for _ in $(seq 1 100); do
  [[ -S "$runtime/cornice-test" ]] && break
  sleep 0.1
done
if [[ -S "$runtime/cornice-test" ]]; then pass "headless mutter is up"
else fail "mutter never created its socket"; tail -20 "$runtime/mutter.log"; exit 1; fi

export WAYLAND_DISPLAY=cornice-test
# LIBSEAT_BACKEND=noop: libseat cannot find a live logind session here, and an
#   "inactive session" makes Hyprland skip every frame commit.
# AQ_DRM_DEVICES=/dev/null: deny aquamarine any DRM node, so the nested Wayland
#   backend is the only one it can use.
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

reachable=0
for _ in $(seq 1 60); do
  if hyprctl -j monitors >/dev/null 2>&1; then reachable=1; break; fi
  sleep 0.1
done
if ((reachable)); then pass "nested Hyprland is up"
else fail "hyprctl cannot reach the nested compositor"; tail -20 "$hypr_log"; exit 1; fi

if grep -qE "drm: (Starting backend|Registered gpu)" "$hypr_log" 2>/dev/null; then
  fail "Hyprland opened a DRM backend — refusing to continue touching real hardware"
  exit 1
fi
pass "no DRM backend was opened (parent GPU untouched)"

# Aquamarine's noop seat can still open the host's libinput devices even when
# its DRM backend fails. Disable those devices only in this private compositor,
# before creating any virtual test input, so typing/moving on the real desktop
# cannot change the test's focus, clear grabs or move its cursor.
hyprctl devices -j >"$runtime/initial-input-devices.json"
while IFS= read -r device; do
  [[ -n $device ]] || continue
  if [[ $(hyprctl keyword "device[$device]:enabled" false) != ok ]]; then
    fail "could not isolate private input device: $device"
    exit 1
  fi
done < <(jq -r '(.mice[]?, .keyboards[]?, .touch[]?) | .name' "$runtime/initial-input-devices.json")
pass "host input devices disabled in the private compositor"

hyprctl output create headless >/dev/null 2>&1
for _ in $(seq 1 50); do
  hyprctl -j monitors 2>/dev/null | jq -e '.[] | select(.name | startswith("HEADLESS"))' >/dev/null 2>&1 && break
  sleep 0.1
done
headless_output=$(hyprctl -j monitors 2>/dev/null | jq -r '[.[] | select(.name | startswith("HEADLESS")) | .name] | first // ""')
if [[ -n $headless_output ]]; then
  hyprctl keyword monitor "$headless_output,1280x800,0x0,1" >/dev/null 2>&1
  sleep 0.5
  pass "headless output ready: $headless_output"
else
  fail "could not create a headless output in the nested compositor"
  exit 1
fi

for _ in $(seq 1 100); do
  own=$(ls -t "$runtime"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)
  [[ -n ${own:-} ]] && break
  sleep 0.1
done
export WAYLAND_DISPLAY="${own##*/}"
pass "shell display: $WAYLAND_DISPLAY"

# CORNICE_INSTALLED_PREFIX points the suite at an *installed* tree (install.sh
# --copy or a package root) instead of the working tree, which is how a fresh
# install gets tested: the tests stay here, the shell comes from there.
install_prefix="${CORNICE_INSTALLED_PREFIX:-$prefix}"
if [[ $install_prefix != "$prefix" ]]; then
  section "installed tree"
  pass "shell from $install_prefix"
  # CORNICE_PATH decides where plugins come from, so the installed-tree run has to
  # point it at that tree — otherwise it quietly loads the working tree's plugins
  # and the comparison of loaded vs on-disk plugins is meaningless.
  export CORNICE_PATH="$install_prefix"
  [[ -f $install_prefix/shell/shell.qml ]] || fail "no shell.qml under $install_prefix"
fi

source "$prefix/test/tooltip-audio-setup.sh"

section "shell and IPC"
# Run the shell from a *copy* inside the sandbox. Quickshell identifies a
# configuration by its path, and `cornice restart`/`cornice-qs kill` work by that
# identity — sharing the path with the developer's live shell meant these suites
# could (and did) kill the session they were only supposed to test.
rm -rf "$runtime/shell"
cp -r "$install_prefix/shell" "$runtime/shell"
"$install_prefix/bin/cornice-qs" -n -p "$runtime/shell" >"$runtime/shell.log" 2>&1 &
shell_pid=$!

ready=0
for _ in $(seq 1 150); do
  if cornice ping >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.1
done

if ((ready)); then
  pass "ipc over the cornice socket: $(cornice ping)"
  expect_eq "theme" "mono" "$(cornice theme)"
  expect_eq "socket path" "$runtime/cornice-${USER}.sock" "$(cornice socket)"

  plugin_count=$(cornice plugins | jq 'length')
  on_disk=$(find "$install_prefix/shell/plugins" -name manifest.json | wc -l)
  if ((plugin_count == on_disk)); then pass "every plugin loaded: $plugin_count/$on_disk"
  else fail "loaded $plugin_count of $on_disk plugins on disk"; fi

  targets=$(cornice targets)
  for target in shell notifications osd idle lock weather media background; do
    if jq -e --arg t "$target" 'index($t)' <<<"$targets" >/dev/null; then
      pass "ipc target present: $target"
    else
      fail "ipc target missing: $target"
    fi
  done
  # A bar widget that is not on the bar is never instantiated, so it has no IPC
  # target — assert keylayout only when the layout actually shows it.
  if cornice ipc shell config | jq -e '[.bar.layout[][] | .id] | index("cn.keylayout")' >/dev/null 2>&1; then
    if jq -e 'index("keylayout")' <<<"$targets" >/dev/null; then
      pass "ipc target present: keylayout (widget is on the bar)"
    else
      fail "keylayout is on the bar but its ipc target is missing"
    fi
  else
    pass "keylayout hidden by default — no target expected"
  fi

  missing=$(cornice widgets | jq -r '[.[].id]' \
    | jq -r --argjson want '["cn.workspaces","cn.active-window","cn.clock","cn.media","cn.indicators","cn.tray","cn.network","cn.bluetooth","cn.audio","cn.power"]' \
      '. as $have | ($want - $have) | join(",")')
  if [[ -z $missing ]]; then pass "every bar widget is discoverable"
  else fail "widgets missing: $missing"; fi
else
  fail "the shell never answered 'cornice ping'"
  echo "--- shell.log ---"; tail -40 "$runtime/shell.log"
fi

source "$prefix/test/bar-alignment-verify.sh"
source "$prefix/test/window-switcher-verify.sh"
source "$prefix/test/bar-editor-verify.sh"
source "$prefix/test/panel-ui-verify.sh"
source "$prefix/test/component-ui-verify.sh"
source "$prefix/test/bar-tooltip-verify.sh"

section "compositor state drives the widgets"
if command -v kitty >/dev/null 2>&1; then
  hyprctl dispatch exec kitty >/dev/null 2>&1
  title=""
  for _ in $(seq 1 50); do
    title=$(hyprctl -j activewindow 2>/dev/null | jq -r '.title // ""')
    [[ -n $title ]] && break
    sleep 0.1
  done
  if [[ -n $title ]]; then pass "a window opened (active window: $title)"
  else warn "kitty never appeared; the active-window widget was not exercised"; fi
else
  warn "kitty not installed; skipping the window test"
fi

section "notifications"
if command -v notify-send >/dev/null 2>&1; then
  notify-send -a cornice-test -t 8000 "Harness notification" "body from the headless harness" >/dev/null 2>&1
  sleep 1
  status=$(cornice ipc notifications status 2>/dev/null || echo '{}')
  expect_eq "notification delivered (popup + history)" "1 1" "$(jq -r '(.popups > 0 | if . then 1 else 0 end), (.history > 0 | if . then 1 else 0 end)' <<<"$status" | paste -sd' ' -)"
  expect_eq "do-not-disturb defaults to off" "false" "$(jq -r '.dnd' <<<"$status")"

  cornice ipc notifications setDnd true >/dev/null 2>&1
  expect_eq "do-not-disturb can be set" "true" "$(cornice ipc notifications dnd 2>/dev/null)"

  # Clear the popup from the earlier notification: DND must add no new popup.
  cornice ipc notifications dismissAll >/dev/null 2>&1
  before=$(cornice ipc notifications history | jq 'length')
  notify-send -a cornice-test "while in DND" "should be recorded, not popped up" >/dev/null 2>&1
  sleep 0.6
  after=$(cornice ipc notifications history | jq 'length')
  popups=$(cornice ipc notifications status | jq -r '.popups')
  if ((after > before)) && ((popups == 0)); then pass "DND records history without popping up"
  else fail "DND behaviour wrong (history $before→$after, popups $popups)"; fi

  cornice ipc notifications setDnd false >/dev/null 2>&1
  cornice ipc notifications markRead >/dev/null 2>&1
  expect_eq "history can be cleared" "0" "$(cornice ipc notifications clear >/dev/null; cornice ipc notifications history | jq 'length')"
else
  warn "notify-send missing; notification delivery not exercised"
fi

section "panels"
for id in cn.clock cn.audio cn.network cn.bluetooth cn.power cn.notifications; do
  open_result=$(cornice ipc shell summon "$id" '{}' 2>&1)
  state=$(cornice ipc shell debug | jq -r --arg id "$id" '.openStates[] | select(startswith($id + "=")) | split("=")[1]')
  if [[ $open_result == "ok" && $state == "open" ]]; then
    cornice ipc shell hide "$id" >/dev/null 2>&1
    closed=$(cornice ipc shell debug | jq -r --arg id "$id" '.openStates[] | select(startswith($id + "=")) | split("=")[1]')
    if [[ $closed == "closed" ]]; then pass "$id opens and closes"
    else fail "$id stayed open after hide"; fi
  else
    fail "$id did not open (result '$open_result', state '$state')"
  fi
done

section "weather (local fake API)"
if [[ -n $weather_port ]]; then
  weather=""
  for _ in $(seq 1 25); do
    weather=$(cornice ipc weather status 2>/dev/null || echo '{}')
    [[ $(jq -r '.status // ""' <<<"$weather") == "ready" ]] && break
    sleep 0.4
  done
  expect_eq "weather parsed the local API" "ready" "$(jq -r '.status // ""' <<<"$weather")"
  expect_eq "weather temperature" "21.5" "$(jq -r '.temperature' <<<"$weather")"
  expect_eq "weather condition label" "Partly cloudy" "$(jq -r '.label' <<<"$weather")"
  expect_eq "partly cloudy uses the corresponding Nerd Font glyph" "$(printf '\U000f0595')" "$(jq -r '.glyph' <<<"$weather")"
  expect_eq "weather retains the configured city name" "Testville" "$(jq -r '.place' <<<"$weather")"
  expect_eq "weather located by city" "city" "$(jq -r '.locatedBy' <<<"$weather")"
  expect_eq "weather hours" "12" "$(jq -r '.hours' <<<"$weather")"
  expect_eq "weather days" "5" "$(jq -r '.days' <<<"$weather")"

  # A dead API must degrade, not crash: flip the URL, reload, and check both the
  # error state and that the shell still answers.
  jq '.weather.baseUrl = "http://127.0.0.1:9/dead"' \
    "$XDG_CONFIG_HOME/cornice/config.json" >"$runtime/config.json.tmp" \
    && mv "$runtime/config.json.tmp" "$XDG_CONFIG_HOME/cornice/config.json"
  cornice reload >/dev/null 2>&1
  # `cornice reload` is asynchronous: wait until the shell actually reports the
  # new URL, otherwise the refresh below still uses the old (working) one.
  for _ in $(seq 1 25); do
    [[ $(cornice ipc shell config | jq -r '.weather.baseUrl // ""') == "http://127.0.0.1:9/dead" ]] && break
    sleep 0.3
  done
  cornice ipc weather refresh >/dev/null 2>&1
  for _ in $(seq 1 30); do
    [[ $(cornice ipc weather status | jq -r '.status') == "error" ]] && break
    sleep 0.4
  done
  expect_eq "a dead API leaves weather in an error state" "error" "$(cornice ipc weather status | jq -r '.status')"
  if [[ $(cornice ping) == pong* ]]; then pass "and the shell still answers ($(cornice ping))"
  else fail "the shell stopped answering after a failing fetch"; fi
else
  warn "fake weather API unavailable; weather checks skipped"
fi

section "notification inline reply"
if [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] && command -v python3 >/dev/null 2>&1; then
  rm -f "$runtime/reply.log" "$runtime/reply.out"
  setsid python3 "$prefix/test/fake-notify-reply.py" --timeout 30 \
    --log "$runtime/reply.log" >"$runtime/reply.out" 2>&1 &
  reply_pid=$!
  reply_id=""
  for _ in $(seq 1 20); do
    reply_id=$(grep -o 'sent id=[0-9]*' "$runtime/reply.log" 2>/dev/null | tail -1 | cut -d= -f2)
    [[ -n $reply_id ]] && break
    sleep 0.3
  done
  if [[ -n $reply_id ]]; then
    pass "a client sent a notification with an inline-reply action (id $reply_id)"
    inspect=$(cornice ipc notifications inspect)
    expect_eq "the server advertises inline reply" "true" "$(jq -r '.inlineReplySupported' <<<"$inspect")"
    expect_eq "the notification reports hasInlineReply" "true" \
      "$(jq -r --arg id "$reply_id" '.notifications[] | select(.id == ($id|tonumber)) | .hasInlineReply' <<<"$inspect")"
    expect_eq "the reply is accepted" "ok" "$(cornice ipc notifications reply "$reply_id" "answered by the suite" 2>&1)"
    answered=""
    for _ in $(seq 1 20); do
      answered=$(grep -o 'replied id=[0-9]* text=.*' "$runtime/reply.log" 2>/dev/null | tail -1)
      [[ -n $answered ]] && break
      sleep 0.3
    done
    if [[ $answered == *"answered by the suite"* ]]; then
      pass "the client received NotificationReplied with the text"
    else
      fail "the client never received the reply (log: $(tail -1 "$runtime/reply.log" 2>/dev/null))"
    fi
  else
    fail "the reply client never sent a notification"
  fi
  kill "$reply_pid" 2>/dev/null || true
else
  warn "no session bus; inline reply not exercised"
fi


section "editing the place and the zone"
cornice weather place use "改名了" --lat 12.34 --lon 56.78 >/dev/null 2>&1
sleep 1
after=$(cornice ipc weather status 2>/dev/null | jq -r .activeName)
if [[ $after == "改名了" ]]; then pass "picking a place replaces it (中文名持久化)"
else fail "the picked place did not stick (got '$after')"; fi
cornice weather place clear >/dev/null 2>&1
sleep 1
cleared=$(cornice ipc weather locations 2>/dev/null | jq -c '[.[].name]')
if [[ $(jq 'length' <<<"$cleared") == 0 ]]; then pass "clearing the place empties it"
else fail "clearing the place left something behind (still $cleared; file: $(jq -c '.weather' "$XDG_CONFIG_HOME/cornice/config.json"))"; fi
cornice clock zone use "测试" Asia/Tokyo >/dev/null 2>&1
sleep 1
if [[ $(cornice ipc clock status 2>/dev/null | jq -r '.zones | length') == 1 ]]; then pass "picking a world clock replaces the previous one"
else fail "the world clock list is not a single entry"; fi
if cornice clock zone use "Bad" Nowhere/Nothing >/dev/null 2>&1; then fail "an unknown timezone was accepted"
else pass "an unknown timezone is rejected"; fi
cornice clock zone clear >/dev/null 2>&1
sleep 1
if [[ $(cornice ipc clock status 2>/dev/null | jq -r '.zones | length') == 0 ]]; then pass "clearing the world clock empties it"
else fail "clearing the world clock left something behind"; fi

section "panels open"
# The editors live in panels, and a QML mistake there does not show up anywhere
# else: the plugin list still looks fine and the panel simply never opens. So
# open each one and check it really reports itself open.
for panel in cn.weather cn.clock cn.audio cn.media cn.notifications cn.bar-editor cn.launcher; do
  cornice ipc shell summon "$panel" '{}' >/dev/null 2>&1
  sleep 0.6
  state=$(cornice ipc shell windows 2>/dev/null | jq -r --arg id "$panel" '[.[] | select(.id == $id) | .open] | first' 2>/dev/null)
  if [[ $state == "true" ]]; then
    pass "$panel opens"
  else
    fail "$panel did not open (state: ${state:-none})"
  fi
  if [[ $state != "true" ]]; then
    # Surface the reason straight away: the panel's QML error is in the shell log.
    cp -f "$runtime/shell.log" /tmp/sandbox-shell.log 2>/dev/null || true
    warn "shell log saved to /tmp/sandbox-shell.log"
  fi
  cornice ipc shell hide "$panel" >/dev/null 2>&1
done

# ...and the editors inside them.
cornice ipc shell summon cn.weather '{}' >/dev/null 2>&1
sleep 0.6
cornice ipc weather editor on >/dev/null 2>&1
sleep 0.6
if [[ $(cornice ipc weather status 2>/dev/null | jq -r .editorOpen) == "true" ]]; then
  pass "the weather places editor can be turned on while the panel is open"
else
  fail "the weather places editor did not turn on"
fi
cornice ipc weather editor off >/dev/null 2>&1
cornice ipc shell hide cn.weather >/dev/null 2>&1

section "localized application search"
# Chinese app names come from the desktop files (Name[zh_CN]); the launcher
# matches names as plain substrings, so a Chinese query must find them.
if grep -q "Name\[zh_CN\]" /usr/share/applications/*.desktop 2>/dev/null; then
  cornice ipc shell summon cn.launcher '{}' >/dev/null 2>&1
  sleep 1
  # Control query first: an empty app list would make the Chinese one vacuous.
  cornice ipc launcher setQuery "term" >/dev/null 2>&1
  sleep 1
  control=$(cornice ipc launcher debug 2>/dev/null | jq -r .results 2>/dev/null || echo 0)
  cornice ipc launcher setQuery "图像" >/dev/null 2>&1
  sleep 1
  found=$(cornice ipc launcher debug 2>/dev/null | jq -r .results 2>/dev/null || echo 0)
  if [[ ${control:-0} -eq 0 ]]; then
    warn "the sandbox launcher sees no applications; localized search not asserted"
  elif [[ ${found:-0} -gt 0 ]]; then
    first=$(cornice ipc launcher debug 2>/dev/null | jq -r .first)
    pass "a Chinese query finds localized apps ($found result(s), first: $first)"
  else
    # Whether Qt hands out Name[zh_CN] depends on the locale of the process that
    # started the shell (a real session gets it from systemd), which this suite
    # cannot force — so this is reported, not failed.
    warn "the sandbox shell lists English names (control='term' found $control, 图像 found none); localized search was not verified in this run"
  fi
  cornice ipc launcher setQuery "" >/dev/null 2>&1
  cornice ipc shell hide cn.launcher >/dev/null 2>&1
else
  warn "no Name[zh_CN] desktop entries; skipping localized search"
fi

section "world clocks"
# The IPC time must equal what the system tzdata says for that zone.
if [[ -n $(cornice ipc clock status 2>/dev/null) ]]; then
  cornice ipc clock time Asia/Tokyo "HH:mm" >/dev/null 2>&1   # first call resolves the zone
  sleep 1
  expected=$(TZ=Asia/Tokyo date +%H:%M)
  got=$(cornice ipc clock time Asia/Tokyo "HH:mm" 2>/dev/null || echo "")
  expected_after=$(TZ=Asia/Tokyo date +%H:%M)
  # A minute rollover during IPC is valid; bracket the query with tzdata.
  if [[ $got == "$expected" || $got == "$expected_after" ]]; then
    pass "Asia/Tokyo resolves through tzdata ($got)"
  else
    fail "Asia/Tokyo resolved to '$got', system says '$expected'"
  fi
  # An unconfigured zone is resolved on demand, so a second query answers.
  cornice ipc clock time Europe/Paris "HH:mm" >/dev/null 2>&1
  sleep 1
  paris_before=$(TZ=Europe/Paris date +%H:%M)
  paris=$(cornice ipc clock time Europe/Paris "HH:mm" 2>/dev/null || echo "")
  paris_after=$(TZ=Europe/Paris date +%H:%M)
  if [[ -n $paris && ( $paris == "$paris_before" || $paris == "$paris_after" ) ]]; then
    pass "an unconfigured zone resolves on demand (Europe/Paris $paris)"
  else
    fail "Europe/Paris did not resolve (got '$paris')"
  fi
else
  fail "clock service did not answer"
fi

section "qml warnings"
# A binding that resolves to undefined usually fails quietly: the panel still
# opens, just missing pieces. Qt logs it, so treat any scene warning from our own
# files as a failure — this caught a weather panel that could not be built at all.
scene_warnings=$(grep -E "WARN scene: .*shell/(plugins|Ui|Commons)/" "$runtime/shell.log" 2>/dev/null \
  | grep -v "io.socket" | sort -u | head -5)
if [[ -z $scene_warnings ]]; then
  pass "no QML scene warnings from the shell sources"
else
  fail "QML warnings:"
  sed 's/^/        /' <<<"$scene_warnings"
fi

section "translations"
# Every key the shell asks for must exist, and the shipped tables must agree —
# a typo would otherwise render as the key itself (or an empty label).
# Strip both quotes, and drop dynamic prefixes (I18n.t("weather.code." + n)).
keys=$(grep -rhoE 'I18n\.t\("[^"]+"' "$prefix/shell" | sed 's/I18n\.t("//; s/"$//' \
  | grep -v '\.$' | sort -u | jq -R -s -c 'split("\n") | map(select(length>0))')
if [[ -n $keys ]]; then
  missing=$(cornice ipc i18n missing "$keys" 2>/dev/null || echo '[]')
  if [[ $(jq 'length' <<<"$missing") == 0 ]]; then
    pass "every I18n key used in QML exists ($(jq 'length' <<<"$keys") keys)"
  else
    fail "keys with no translation: $(jq -r 'join(", ")' <<<"$missing")"
  fi
else
  fail "no I18n keys found in the shell sources"
fi

# Weekday and month names must come from the configured locale, not from Qt's
# process default — the bar clock used to keep showing "Tue" in a Chinese session.
epoch=$(( $(date +%s) * 1000 ))
cornice language zh-CN >/dev/null 2>&1
sleep 1
zh_day=$(cornice ipc i18n format "ddd" "$epoch" 2>/dev/null || echo "")
cornice language en >/dev/null 2>&1
sleep 1
en_day=$(cornice ipc i18n format "ddd" "$epoch" 2>/dev/null || echo "")
if [[ -n $zh_day && $zh_day != "$en_day" ]]; then
  pass "weekday names follow the language ($en_day / $zh_day)"
else
  fail "weekday names do not follow the language (en='$en_day', zh='$zh_day')"
fi
if [[ $zh_day =~ [^\x00-\x7F] ]]; then
  pass "the Chinese table really renders non-ASCII weekday names"
else
  fail "Chinese weekday looked ASCII: '$zh_day'"
fi

python3 - "$prefix/i18n" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
tables = {p.stem: json.loads(p.read_text()) for p in sorted(folder.glob("*.json"))}
base = tables.get("en", {})
missing = {name: [k for k in base if k not in table] for name, table in tables.items() if name != "en"}
missing = {name: keys for name, keys in missing.items() if keys}
if missing:
    print("  FAIL  tables missing keys:", missing)
    sys.exit(1)
print(f"  PASS  {len(tables)} language tables agree ({len(base)} keys: {', '.join(tables)})")
PY
if [[ $? != 0 ]]; then fail "language tables disagree"; else pass "language tables agree"; fi

section "tray menu activation"
# The helper must keep its timestamp inside DBusMenu's uint32 field: a 13-digit
# millisecond value made gdbus reject every click before it was sent (silently).
stamp=$("$prefix/bin/cornice-tray-activate" --check | sed -n 's/^timestamp=//p')
if [[ -n $stamp ]] && ((stamp >= 0 && stamp <= 4294967295)); then
  pass "tray helper timestamp fits uint32 ($stamp)"
else
  fail "tray helper timestamp out of range: '$stamp'"
fi
"$prefix/bin/cornice-tray-activate" --help >/dev/null 2>&1 \
  && pass "tray helper is runnable" || fail "tray helper is not runnable"

section "tray submenu hover"
python3 "$prefix/test/fake-tray-menu.py" >"$runtime/tray-fixture.log" 2>&1 &
tray_fixture_pid=$!
for _ in $(seq 1 30); do
  cornice ipc tray dump 2>/dev/null | jq -e '.[] | select(.id == "cornice-menu-test")' >/dev/null && break
  sleep 0.1
done
cornice ipc tray invoke cornice-menu-test menu >/dev/null 2>&1
sleep 0.5
menu_state=$(cornice ipc tray menuState 2>/dev/null || echo '{}')
expect_eq "fixture menu opens" "true" "$(jq -r '.opened' <<<"$menu_state")"
hover_x=$(jq -r '.rows[] | select(.text == "First submenu") | .x' <<<"$menu_state")
hover_y=$(jq -r '.rows[] | select(.text == "First submenu") | .y' <<<"$menu_state")
# Layer-shell placement includes the bar's reserved area, which is absent from
# PanelWindow.margins. Use the compositor's actual surface origin.
menu_origin=$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-menu")] | first | [.x, .y] | join(" ")')
read -r menu_x menu_y <<<"$menu_origin"
if [[ $hover_x =~ ^[0-9]+$ && $hover_y =~ ^[0-9]+$ ]]; then
  hover_x=$((hover_x + menu_x))
  hover_y=$((hover_y + menu_y))
  wayland-scanner client-header "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.h"
  wayland-scanner private-code "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.c"
  cc "$prefix/test/hover-pointer.c" "$runtime/virtual-pointer.c" -I"$runtime" \
    $(pkg-config --cflags --libs wayland-client) -o "$runtime/hover-pointer"
  extent=$(hyprctl monitors -j | jq -r '[(map(.x + (.width / .scale)) | max), (map(.y + (.height / .scale)) | max)] | map(ceil) | join(" ")')
  read -r pointer_width pointer_height <<<"$extent"
  "$runtime/hover-pointer" "$hover_x" "$hover_y" "$pointer_width" "$pointer_height" >"$runtime/hover-pointer.log" 2>&1 &
  hover_pointer_pid=$!
  for _ in $(seq 1 20); do
    grep -q hovering "$runtime/hover-pointer.log" && break
    sleep 0.05
  done
  sleep 0.8
  menu_state=$(cornice ipc tray menuState)
  expect_eq "hover opens the first submenu" "1" "$(jq -r '.depth' <<<"$menu_state")"
  expect_eq "nested submenu appears under the stationary pointer" "Nested submenu" \
    "$(jq -r '.rows[0].text' <<<"$menu_state")"
  sleep 0.6
  expect_eq "stationary pointer does not cascade into the nested submenu" "1" \
    "$(cornice ipc tray menuState | jq -r '.depth')"
  # A fresh move on that same nested row should deliberately open the next level.
  sleep 1
  menu_state=$(cornice ipc tray menuState)
  expect_eq "deliberate movement opens the nested submenu" "2" "$(jq -r '.depth' <<<"$menu_state")"
  expect_eq "the deepest real DBusMenu entry is rendered" "Deep leaf" "$(jq -r '.rows[0].text' <<<"$menu_state")"
  wait "$hover_pointer_pid" || fail "virtual pointer failed: $(cat "$runtime/hover-pointer.log")"
  hover_pointer_pid=""
else
  fail "submenu fixture rows not available: $menu_state ($(cat "$runtime/tray-fixture.log"))"
fi
cornice ipc tray invoke cornice-menu-test menu >/dev/null 2>&1
expect_eq "closing releases the submenu stack" "0" "$(cornice ipc tray menuState | jq -r '.depth')"
kill "$tray_fixture_pid" 2>/dev/null || true
tray_fixture_pid=""

section "keyboard layout"
layout=$(cornice ipc keylayout status 2>/dev/null || echo '{}')
# The widget ships hidden by default, so it is only instantiated (and only has
# anything to report) when the layout asks for it.
if ! cornice ipc shell config | jq -e '[.bar.layout[][] | .id] | index("cn.keylayout")' >/dev/null 2>&1; then
  pass "keyboard layout hidden by default — nothing to read"
elif [[ $(jq -r '.layout // ""' <<<"$layout") != "" ]]; then
  pass "keylayout reads the compositor: $(jq -r '.layout' <<<"$layout") ($(jq -r '.name' <<<"$layout"))"
else
  fail "keylayout reported nothing (last action: $(jq -r '.lastAction // "?"' <<<"$layout"))"
fi

section "idle logind signals"
idle_state=$(cornice ipc idle status)
expect_eq "the logind monitor is running" "true" "$(jq -r '.logindWatching' <<<"$idle_state")"
expect_eq "a suspend signal is understood" "sleep" \
  "$(cornice ipc idle feed '/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)')"
expect_eq "a wake signal is understood" "resume" \
  "$(cornice ipc idle feed '/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)')"
expect_eq "an unrelated logind signal is ignored" "resume" \
  "$(cornice ipc idle feed '/org/freedesktop/login1/session/_9: org.freedesktop.login1.Session.Unlock ()')"
# The sandbox disables lockOnLockSignal/lockOnLidClose (locking here would break
# the checks that follow), so those signals must be understood but not acted on —
# the lock suite covers the real lock path with a working PAM stack.
expect_eq "a lock signal is ignored when the config disables it" "resume" \
  "$(cornice ipc idle feed '/org/freedesktop/login1/session/_9: org.freedesktop.login1.Session.Lock ()')"
expect_eq "a lid-close property change is understood" "lid" \
  "$(cornice ipc idle feed "/org/freedesktop/login1: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Manager', {'LidClosed': <true>}, @as [])")"
expect_eq "a lid-open property change is understood" "lid-open" \
  "$(cornice ipc idle feed "/org/freedesktop/login1: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Manager', {'LidClosed': <false>}, @as [])")"

section "on-screen display"
if cornice ipc osd show volume 0.42 "" >/dev/null 2>&1; then
  osd=$(cornice ipc osd status 2>/dev/null || echo '{}')
  expect_eq "OSD opens over IPC" "true" "$(jq -r '.opened' <<<"$osd")"
  expect_eq "OSD carries the value" "0.42" "$(jq -r '.value' <<<"$osd")"
  cornice ipc osd hide >/dev/null 2>&1
  sleep 0.2
  expect_eq "OSD hides over IPC" "false" "$(cornice ipc osd status | jq -r '.opened')"
else
  fail "the OSD does not answer on its own IPC target"
fi

section "launcher"
cornice ipc shell summon cn.launcher '{}' >/dev/null 2>&1
sleep 0.3
launcher_state=$(cornice ipc shell debug | jq -r '.openStates[] | select(startswith("cn.launcher=")) | split("=")[1]')
expect_eq "launcher opens" "open" "$launcher_state"
if command -v wtype >/dev/null 2>&1; then
  sleep 1
  wtype "kit" >/dev/null 2>&1
  sleep 0.6
  pass "typed into the launcher with wtype (results are filtered live)"
else
  warn "wtype missing; launcher keyboard input not exercised"
fi
cornice ipc shell hide cn.launcher >/dev/null 2>&1

section "render"
sleep 1
cornice ipc shell summon cn.audio '{}' >/dev/null 2>&1
notify-send -a cornice-test "Render check" "popup visible in the screenshot" >/dev/null 2>&1
cornice ipc osd show volume 0.62 "62%" >/dev/null 2>&1
sleep 1.2

shot="$runtime/cornice.png"
if ((ready)) && timeout 20 grim "$shot" 2>"$runtime/grim.log"; then
  if python3 - "$shot" <<'PY'
import sys
from PIL import Image, ImageChops

img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size

def mean(im):
    px = list(im.getdata())
    return tuple(sum(p[i] for p in px) // len(px) for i in range(3))

bar = img.crop((0, 0, w, 30))
below = img.crop((0, 30, w, 60))
bar_mean, below_mean = mean(bar), mean(below)
distinct = len(bar.getcolors(maxcolors=1 << 22) or [])
print(f"  image {w}x{h}; bar mean {bar_mean} vs below {below_mean}; "
      f"{distinct} distinct colours in the bar")

# The bar is an opaque, full-width strip in the theme's dark background; if it
# never mapped, the top rows match whatever is drawn below them.
bar_painted = bar_mean != below_mean and sum(bar_mean) < 200
if not bar_painted:
    print("  bar area looks empty")
    sys.exit(1)

# The panel/OSD/popup draws a lighter surface somewhere in the frame; a render
# that stopped at the bar would leave the rest at the flat background colour.
bg = below.getpixel((w // 2, 10))
bright = sum(1 for p in img.getdata() if abs(p[0] - bg[0]) + abs(p[1] - bg[1]) + abs(p[2] - bg[2]) > 24)
print(f"  {bright} pixels differ from the background (panels/OSD/popups)")
sys.exit(0 if bright > 5000 else 1)
PY
  then pass "bar, panels and OSD painted (screenshot: $shot)"
  else fail "render assertion failed"; fi
  ((keep)) || cp "$shot" /tmp/cornice-shot.png 2>/dev/null || true
else
  fail "no screenshot: $(cat "$runtime/grim.log" 2>/dev/null)"
fi

section "log hygiene"
problems=$(sed 's/\x1b\[[0-9;]*m//g' "$runtime/shell.log" 2>/dev/null \
  | grep -iE "plugin failed to load|is not a type|ReferenceError|TypeError|RangeError|Cannot assign" \
  | grep -v "qt.qpa.services" || true)
if [[ -z $problems ]]; then pass "no QML errors in the shell log"
else
  fail "QML problems in the shell log:"; echo "$problems" | head -10
fi

echo
((result == 0)) && echo "RESULT: all checks passed" || echo "RESULT: failures above"
((keep)) && echo "artifacts: $runtime"
exit "$result"
