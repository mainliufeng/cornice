#!/usr/bin/env bash
# Real pointer/keyboard interactions in the private compositor, with the
# geocoder fixture already provided by headless-verify.sh.
section "weather and clock panel UI"
cp "$XDG_CONFIG_HOME/cornice/config.json" "$runtime/panels-config-before.json"
read -r pointer_width pointer_height <<<"$(hyprctl monitors -j | jq -r '[(map(.x + (.width / .scale)) | max), (map(.y + (.height / .scale)) | max)] | map(ceil) | join(" ")')"
coproc PANELS_POINTER { exec "$runtime/hover-pointer" 0 0 "$pointer_width" "$pointer_height" interactive; }
hover_pointer_pid=$PANELS_POINTER_PID
exec {pointer_in}>&"${PANELS_POINTER[1]}"
exec {pointer_out}<&"${PANELS_POINTER[0]}"
panel_pointer() {
  printf '%s %s %s\n' "$1" "$2" "${3:-click}" >&"$pointer_in"
  read -r -t 3 pointer_reply <&"$pointer_out"
  sleep 0.5
}
panel_state() { cornice ipc "${1}Panel" state; }
panel_action() {
  local name="$1" action="$2" state px py x y
  state=$(panel_state "$name")
  read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | [.x,.y] | join(" ")')"
  read -r x y <<<"$(jq -r --arg action "$action" '.actions[] | select(.name == $action) | [.x,.y] | map(round) | join(" ")' <<<"$state")"
  panel_pointer "$((px + x))" "$((py + y))"
}
panel_pick_first() {
  local name="$1" state px py x y
  state=$(panel_state "$name")
  read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | [.x,.y] | join(" ")')"
  read -r x y <<<"$(jq -r '.picker.first | [.x,.y] | map(round) | join(" ")' <<<"$state")"
  panel_pointer "$((px + x))" "$((py + y))"
}
panel_capture() {
  local name="$1" label="$2" region
  hyprctl dismissnotify -1 >/dev/null
  sleep .1
  region=$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | "\(.x),\(.y) \(.w)x\(.h)"')
  grim -g "$region" "$runtime/ui-$label.png"
}
cornice language zh-CN >/dev/null
cornice ipc shell toggle cn.clock '{}' >/dev/null
sleep .5
state=$(panel_state clock)
month_before=$(jq -r '.month' <<<"$state")
panel_action clock next
expect_eq "large next-month button advances the actual calendar" "$(((month_before + 1) % 12))" "$(panel_state clock | jq -r '.month')"
panel_action clock prev
expect_eq "previous-month button restores the calendar" "$month_before" "$(panel_state clock | jq -r '.month')"
panel_action clock next
panel_action clock today
expect_eq "Today returns to the current month" "$month_before" "$(panel_state clock | jq -r '.month')"
panel_capture clock clock
panel_action clock edit
expect_eq "world-clock editor opens with calendar hidden" true "$(panel_state clock | jq -r '.editing')"
wtype 东京
for _ in $(seq 1 30); do
  [[ $(panel_state clock | jq -r '.picker.count') -gt 0 ]] && break
  sleep .1
done
expect_eq "zone editor receives a real geocoder result" 1 "$(panel_state clock | jq -r '.picker.count')"
panel_capture clock clock-editor
panel_pick_first clock
for _ in $(seq 1 30); do
  [[ $(cornice ipc clock status | jq -r '.zones[0].name') == 东京 ]] && break
  sleep .1
done
expect_eq "picking the city saves its actual timezone" 东京 "$(cornice ipc clock status | jq -r '.zones[0].name')"
panel_action clock edit
expect_eq "Done restores the calendar" false "$(panel_state clock | jq -r '.editing')"
cornice ipc shell hide cn.clock >/dev/null
sleep .3

cornice ipc shell toggle cn.weather '{}' >/dev/null
sleep .5
state=$(panel_state weather)
printf '%s\n' "$state" >"$runtime/ui-weather-state.json"
expect_eq "every daily temperature range fits inside the larger panel" true \
  "$(jq '.width as $width | all(.forecasts[]; .x >= 0 and .x + .width <= $width)' <<<"$state")"
expect_eq "normal weather content fits without clipping" true "$(jq '.contentHeight <= .viewportHeight + 1' <<<"$state")"
panel_capture weather weather
panel_action weather edit
expect_eq "place editor opens" true "$(panel_state weather | jq -r '.editing')"
wtype 上海
for _ in $(seq 1 30); do
  [[ $(panel_state weather | jq -r '.picker.count') -gt 0 ]] && break
  sleep .1
done
expect_eq "place editor receives a geocoder result" 1 "$(panel_state weather | jq -r '.picker.count')"
panel_capture weather weather-editor
panel_pick_first weather
for _ in $(seq 1 30); do
  [[ $(cornice ipc shell config | jq -r '.weather.place.name') == 上海 ]] && break
  sleep .1
done
expect_eq "picking a city persists the selected real coordinates" 上海 "$(cornice ipc shell config | jq -r '.weather.place.name')"
expect_eq "a coordinates-based place keeps its readable panel title" 上海 "$(panel_state weather | jq -r '.place')"
panel_action weather edit
expect_eq "Done restores the forecasts" false "$(panel_state weather | jq -r '.editing')"
panel_action weather refresh
expect_eq "refresh leaves the weather panel usable" true "$(panel_state weather | jq -r '.open')"
for _ in $(seq 1 30); do
  [[ $(cornice ipc weather status | jq -r '.status') == ready ]] && break
  sleep .1
done
cornice ipc shell hide cn.weather >/dev/null
kill "$hover_pointer_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
cp "$runtime/panels-config-before.json" "$XDG_CONFIG_HOME/cornice/config.json"
cornice reload >/dev/null
for _ in $(seq 1 30); do
  [[ $(cornice ipc weather status | jq -r '.locatedBy') == city ]] && break
  cornice ipc weather refresh >/dev/null
  sleep .2
done
