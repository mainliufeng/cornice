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
kill "$hover_pointer_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
