#!/usr/bin/env bash
# Native input against real notification and MPRIS protocols in the private bus.
section "device and utility panel interactions"
read -r pointer_width pointer_height <<<"$(hyprctl monitors -j | jq -r '[(map(.x + (.width / .scale)) | max), (map(.y + (.height / .scale)) | max)] | map(ceil) | join(" ")')"
coproc COMPONENT_POINTER { exec "$runtime/hover-pointer" 0 0 "$pointer_width" "$pointer_height" interactive; }
hover_pointer_pid=$COMPONENT_POINTER_PID
exec {pointer_in}>&"${COMPONENT_POINTER[1]}"
exec {pointer_out}<&"${COMPONENT_POINTER[0]}"
component_action() {
  local target="$1" action="$2" state px py x y
  state=$(cornice ipc "$target" state)
  read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | [.x,.y] | join(" ")')"
  read -r x y <<<"$(jq -r --arg action "$action" '.actions[] | select(.name == $action) | [.x,.y] | map(round) | join(" ")' <<<"$state")"
  printf '%s %s click\n' "$((px+x))" "$((py+y))" >&"$pointer_in"
  read -r -t 3 pointer_reply <&"$pointer_out"
  sleep .5
}
cornice ipc notifications setDnd false >/dev/null
notify-send -a cornice-ui-test "操作验证" "独立桌面中的真实通知"
cornice ipc shell summon cn.notifications '{}' >/dev/null
sleep .5
component_action notificationPanel dnd
expect_eq "the larger DND button changes the notification service" true "$(cornice ipc notifications status | jq -r '.dnd')"
component_action notificationPanel dnd
expect_eq "DND can be turned off with the same button" false "$(cornice ipc notifications status | jq -r '.dnd')"
component_action notificationPanel clear
expect_eq "the larger Clear button clears actual notification history" 0 "$(cornice ipc notifications history | jq length)"
cornice ipc shell hide cn.notifications >/dev/null

python3 "$prefix/test/fake-mpris-player.py" --name cornice_ui_test --identity "UI verification player" \
  --title "A long track title for the native media panel" --artist "Cornice UI test" \
  --log "$runtime/ui-mpris-calls.log" --seconds 30 >"$runtime/ui-mpris.log" 2>&1 &
media_fixture_pid=$!
for _ in $(seq 1 40); do
  [[ $(cornice ipc media status | jq -r '.title') == "A long track title for the native media panel" ]] && break
  sleep .1
done
cornice ipc shell summon cn.media '{}' >/dev/null
sleep .5
expect_eq "the redesigned media panel reads the real MPRIS track" "A long track title for the native media panel" "$(cornice ipc mediaPanel state | jq -r '.title')"
expect_eq "media controls fit inside the panel" true "$(cornice ipc mediaPanel state | jq '.width as $w | .height as $h | all(.actions[]; .x > 0 and .x < $w and .y > 0 and .y < $h)')"
component_action mediaPanel playPause
expect_eq "the enlarged playback button pauses through MPRIS" 1 "$(rg -c ' Player\.(Pause|PlayPause)$' "$runtime/ui-mpris-calls.log")"
expect_eq "the player pauses after a native click" false "$(cornice ipc media status | jq -r '.playing')"
component_action mediaPanel playPause
expect_eq "the same button resumes playback through MPRIS" true "$(cornice ipc media status | jq -r '.playing')"
component_action mediaPanel next
expect_eq "the enlarged Next button reaches the player" 1 "$(rg -c 'Next' "$runtime/ui-mpris-calls.log")"
component_action mediaPanel previous
expect_eq "the enlarged Previous button reaches the player" 1 "$(rg -c 'Previous' "$runtime/ui-mpris-calls.log")"
hyprctl dismissnotify -1 >/dev/null
region=$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | "\(.x),\(.y) \(.w)x\(.h)"')
grim -g "$region" "$runtime/ui-media-playing.png"
cornice ipc shell hide cn.media >/dev/null
kill "$media_fixture_pid" 2>/dev/null
wait "$media_fixture_pid" 2>/dev/null || true
media_fixture_pid=""
section "audio slider and shared panel placement"
cornice ipc shell summon cn.audio '{}' >/dev/null
sleep .5
state=$(cornice ipc audioPanel state)
expect_eq "audio follows the top bar" top "$(jq -r '.edge' <<<"$state")"
read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | [.x,.y] | join(" ")')"
read -r x y <<<"$(jq -r '.sliders[0] | [(.x+.width*0.63),(.y+.height/2)] | map(round) | join(" ")' <<<"$state")"
printf '%s %s click\n' "$((px+x))" "$((py+y))" >&"$pointer_in"
read -r -t 3 pointer_reply <&"$pointer_out"
sleep .5
expect_eq "dragging the audio slider changes the real virtual sink" true "$(cornice ipc audioinfo dump | jq '(.defaultSink.volume - 0.63) | fabs < 0.02')"
expect_eq "audio panel adjustments do not create a second bottom OSD" false "$(cornice ipc shell windows | jq '[.[] | select(.id == "cn.osd")][0].open')"
region=$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | "\(.x),\(.y) \(.w)x\(.h)"')
grim -g "$region" "$runtime/ui-audio.png"
cornice ipc shell hide cn.audio >/dev/null
section "brightness panel placement and interactive control"
cornice bar show cn.brightness --section right >/dev/null
sleep .5
state=$(cornice ipc bar geometry)
read -r bx by <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-bar")][0] | [.x,.y] | join(" ")')"
read -r x y <<<"$(jq -r --argjson bx "$bx" --argjson by "$by" '.[] | select(.id == "cn.brightness") | [(.x+.width/2+$bx),(.y+.height/2+$by)] | map(round) | join(" ")' <<<"$state")"
printf '%s %s click\n' "$x" "$y" >&"$pointer_in"
read -r -t 3 pointer_reply <&"$pointer_out"
sleep .5
state=$(cornice ipc brightnessPanel state)
expect_eq "clicking the brightness icon opens an interactive panel" true "$(jq -r '.open' <<<"$state")"
expect_eq "brightness follows the top bar instead of the bottom OSD" top "$(jq -r '.edge' <<<"$state")"
read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | [.x,.y] | join(" ")')"
read -r x y <<<"$(jq -r '.slider | [(.x+.width*0.72),(.y+.height/2)] | map(round) | join(" ")' <<<"$state")"
printf '%s %s click\n' "$((px+x))" "$((py+y))" >&"$pointer_in"
read -r -t 3 pointer_reply <&"$pointer_out"
sleep .5
expect_eq "the actual slider writes the selected backlight level" 72 "$(cat "$CORNICE_TEST_BACKLIGHT")"
expect_eq "panel and widget share the updated brightness value" 72 "$(cornice ipc brightness status | jq -r '.percent')"
region=$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | "\(.x),\(.y) \(.w)x\(.h)"')
grim -g "$region" "$runtime/ui-brightness.png"
cornice ipc shell hide cn.brightness >/dev/null
cp "$XDG_CONFIG_HOME/cornice/config.json" "$runtime/brightness-config-before.json"
jq '.bar.position = "bottom"' "$runtime/brightness-config-before.json" > "$XDG_CONFIG_HOME/cornice/config.json"
cornice ipc shell reloadConfig >/dev/null
sleep .5
cornice ipc shell summon cn.brightness '{}' >/dev/null
sleep .3
expect_eq "brightness follows a bottom bar as well" bottom "$(cornice ipc brightnessPanel state | jq -r '.edge')"
cornice ipc shell hide cn.brightness >/dev/null
cornice ipc shell summon cn.audio '{}' >/dev/null
sleep .3
expect_eq "audio and brightness share bottom-bar placement" bottom "$(cornice ipc audioPanel state | jq -r '.edge')"
cornice ipc shell hide cn.audio >/dev/null
cp "$runtime/brightness-config-before.json" "$XDG_CONFIG_HOME/cornice/config.json"
cornice ipc shell reloadConfig >/dev/null
sleep .5

section "notification click reaches the sender"
# Clicking a notification must act on it, not just delete it: invoke the
# client's default action when it has one, otherwise focus the window of the
# app that sent it. These fixtures are the only writers of the log lines the
# assertions look for, so the click is the only thing that can produce them.
cornice ipc notifications setDnd false >/dev/null 2>&1

wait_for_notification_id() {  # wait_for_notification_id <log>
  local id=""
  for _ in $(seq 1 20); do
    id=$(grep -o 'sent id=[0-9]*' "$1" 2>/dev/null | tail -1 | cut -d= -f2)
    [[ -n $id ]] && { echo "$id"; return 0; }
    sleep 0.3
  done
  return 1
}

click_popup() {  # click_popup — click the middle of the newest popup
  local pop_x="" pop_y pop_w pop_h geometry previous="" ready=0
  for _ in $(seq 1 25); do
    geometry=$(hyprctl layers -j \
      | jq -r '[.. | objects | select(.namespace? == "cornice-notification-popups")][0] | [.x,.y,.w,.h] | join(" ")')
    read -r pop_x pop_y pop_w pop_h <<<"$geometry"
    # A newly mapped layer can precede the Repeater/card's first layout.
    # Require an actual card-sized surface across two compositor reads, rather
    # than clicking an empty initial layer. Keep the real sender/action checks.
    if [[ $pop_w =~ ^[0-9]+$ && $pop_h =~ ^[0-9]+$ ]] && ((pop_w >= 200 && pop_h >= 50)) && [[ $geometry == "$previous" ]]; then
      ready=1
      break
    fi
    previous=$geometry
    sleep 0.2
  done
  ((ready)) || return 1
  printf '%s\n' "$geometry" >>"$runtime/notification-click-geometry.log"
  grim "$runtime/notification-click-before.png" || return 1
  # The card lives inside the surface's padding, so the exact top edge is not
  # reliably clickable; the middle always is.
  printf '%s %s click\n' "$((pop_x + pop_w / 2))" "$((pop_y + pop_h / 2))" >&"$pointer_in"
  read -r -t 3 pointer_reply <&"$pointer_out"
  sleep 0.6
}

cornice ipc notifications dismissAll >/dev/null 2>&1
rm -f "$runtime/click-default.log"
setsid python3 "$prefix/test/fake-notify-reply.py" --timeout 20 --default-action \
  --app-name cornice-click-default --expire 20000 --summary "Click me" \
  --body "the body click should invoke the default action" \
  --log "$runtime/click-default.log" >"$runtime/click-default.out" 2>&1 &
click_default_pid=$!
if wait_for_notification_id "$runtime/click-default.log" >/dev/null; then
  if click_popup; then
    if grep -q 'key=default' "$runtime/click-default.log"; then
      pass "a popup click invokes the client's default action"
    else
      fail "the default action was not invoked ($(tr '\n' ' ' <"$runtime/click-default.log"))"
    fi
    expect_eq "the clicked popup is gone" "0" "$(cornice ipc notifications status | jq -r '.popups')"
  else
    fail "no notification popup layer was found to click"
  fi
else
  fail "the default-action client never sent a notification"
fi
kill "$click_default_pid" 2>/dev/null || true
cornice ipc notifications dismissAll >/dev/null 2>&1

# Two throwaway windows of our own: the window-switcher fixtures sleep 180s and
# may already be gone by this point in the suite.
hyprctl dispatch exec 'kitty --override confirm_os_window_close=0 --title Cornice-notify-A sleep 90' >/dev/null
hyprctl dispatch exec 'kitty --override confirm_os_window_close=0 --title Cornice-notify-B sleep 90' >/dev/null
for _ in $(seq 1 40); do
  [[ $(hyprctl clients -j | jq '[.[] | select((.class|ascii_downcase) == "kitty" and (.title|startswith("Cornice-notify-")))] | length') -ge 2 ]] && break
  sleep 0.2
done
readarray -t notify_windows < <(hyprctl clients -j | jq -r '[.[] | select((.class|ascii_downcase) == "kitty" and (.title|startswith("Cornice-notify-")))] | .[].address')
if ((${#notify_windows[@]} >= 2)); then
  focus_target="${notify_windows[0]}"
  focus_other="${notify_windows[1]}"
  focus_pid=$(hyprctl clients -j | jq -r --arg a "$focus_target" '.[] | select(.address == $a) | .pid')

  # 1. the helper on its own
  hyprctl dispatch focuswindow "address:$focus_other" >/dev/null
  sleep 0.3
  "$prefix/bin/cornice-focus-app" --pid "$focus_pid" >/dev/null 2>&1
  sleep 0.3
  expect_eq "cornice-focus-app focuses the window that matches the sender pid" "$focus_target" \
    "$(hyprctl activewindow -j | jq -r '.address')"
  hyprctl dispatch focuswindow "address:$focus_target" >/dev/null
  sleep 0.3
  if "$prefix/bin/cornice-focus-app" --desktop kitty.desktop >/dev/null 2>&1; then
    focused=$(hyprctl activewindow -j | jq -r '.address')
    if [[ " ${notify_windows[*]} " == *" $focused "* ]]; then
      pass "cornice-focus-app matches by desktop entry too"
    else
      fail "desktop matching focused '$focused', not a kitty window"
    fi
  else
    fail "cornice-focus-app could not match by desktop entry"
  fi

  # 2. the whole path: a client with no actions, clicked in its popup
  hyprctl dispatch focuswindow "address:$focus_other" >/dev/null
  sleep 0.3
  rm -f "$runtime/click-focus.log"
  setsid python3 "$prefix/test/fake-notify-reply.py" --timeout 20 --bare \
    --app-name cornice-click-focus --desktop-entry kitty.desktop --sender-pid "$focus_pid" \
    --expire 20000 --summary "Focus me" --body "the body click should focus kitty" \
    --log "$runtime/click-focus.log" >"$runtime/click-focus.out" 2>&1 &
  click_focus_pid=$!
  if focus_notif_id=$(wait_for_notification_id "$runtime/click-focus.log"); then
    expect_eq "the sender pid hint survives into the history entry" "$focus_pid" \
      "$(cornice ipc notifications history | jq -r --arg id "$focus_notif_id" '.[] | select(.id == ($id|tonumber)) | .senderPid')"
    if click_popup; then
      expect_eq "a popup click focuses the window of the sending app" "$focus_target" \
        "$(hyprctl activewindow -j | jq -r '.address')"
    else
      fail "no notification popup layer was found to click"
    fi
    expect_eq "the focused popup is gone" "0" "$(cornice ipc notifications status | jq -r '.popups')"
  else
    fail "the no-action client never sent a notification"
  fi
  kill "$click_focus_pid" 2>/dev/null || true
else
  fail "could not open two kitty windows for the focus check"
fi
for address in "${notify_windows[@]:-}"; do
  [[ -n $address ]] && hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1
done
cornice ipc notifications dismissAll >/dev/null 2>&1

kill "$hover_pointer_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
