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
kill "$hover_pointer_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
