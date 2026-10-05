#!/usr/bin/env bash
# Real layer-shell surfaces and native pointer events on the private compositor.
section "fixed bar icons and passive status tooltips"
cp "$XDG_CONFIG_HOME/cornice/config.json" "$runtime/tooltip-config-before.json"
cornice bar show cn.brightness --section right >/dev/null
sleep 2
expect_eq "audio widget uses the isolated virtual sink" "cornice-tooltip-output" \
  "$(cornice ipc audioinfo dump | jq -r '.defaultSink.name')"
hyprctl dispatch exec 'kitty --override confirm_os_window_close=0 --title Cornice-hover-focus sleep 180' >/dev/null
for _ in $(seq 1 30); do
  [[ $(hyprctl activewindow -j | jq -r '.title') == Cornice-hover-focus ]] && break
  sleep .1
done
expect_eq "a real application is focused before the hover checks" Cornice-hover-focus "$(hyprctl activewindow -j | jq -r '.title')"
tooltip_focus_window=$(hyprctl activewindow -j | jq -r '.address')
read -r pointer_width pointer_height <<<"$(hyprctl monitors -j | jq -r '[(map(.x + (.width / .scale)) | max), (map(.y + (.height / .scale)) | max)] | map(ceil) | join(" ")')"
coproc TOOLTIP_POINTER { exec "$runtime/hover-pointer" 0 0 "$pointer_width" "$pointer_height" interactive; }
hover_pointer_pid=$TOOLTIP_POINTER_PID
exec {pointer_in}>&"${TOOLTIP_POINTER[1]}"
exec {pointer_out}<&"${TOOLTIP_POINTER[0]}"
tooltip_pointer() {
  printf '%s %s %s\n' "$1" "$2" "${3:-hover}" >&"$pointer_in"
  read -r -t 3 pointer_reply <&"$pointer_out"
}
tooltip_layers() {
  hyprctl layers -j | jq '[.. | objects | select(.namespace? == "cornice-status-tooltip")]'
}
tooltip_bar_shape() {
  cornice ipc bar geometry | jq -c '[.[] | {id,x,y,width,height,section}]'
}
tooltip_hover_widget() {
  local id="$1" geometry
  geometry=$(cornice ipc bar geometry)
  read -r bar_x bar_y bar_height <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-bar")][0] | [.x,.y,.h] | join(" ")')"
  read -r hover_x hover_y <<<"$(jq -r --arg id "$id" --argjson bx "$bar_x" --argjson by "$bar_y" '.[] | select(.id == $id) | [(.x + .width/2 + $bx),(.y + .height/2 + $by)] | map(round) | join(" ")' <<<"$geometry")"
  tooltip_pointer "$hover_x" "$hover_y"
}
for position in top bottom; do
  jq --arg position "$position" '.bar.position = $position' "$XDG_CONFIG_HOME/cornice/config.json" >"$runtime/tooltip-config-next.json"
  cp "$runtime/tooltip-config-next.json" "$XDG_CONFIG_HOME/cornice/config.json"
  cornice reload >/dev/null
  sleep .7
  for widget in audio power brightness; do
    tooltip_pointer 640 400
    before=$(tooltip_bar_shape)
    focus_before=$(hyprctl activewindow -j | jq -r '.address // "none"')
    tooltip_hover_widget "cn.$widget"
    expect_eq "$position $widget does not pop up on a quick pass" 0 "$(tooltip_layers | jq length)"
    sleep .5
    layers=$(tooltip_layers)
    expect_eq "$position $widget shows one delayed tooltip" 1 "$(jq length <<<"$layers")"
    expect_eq "$position $widget leaves every bar widget in place" "$before" "$(tooltip_bar_shape)"
    expect_eq "$position $widget does not take focus" "$focus_before" "$(hyprctl activewindow -j | jq -r '.address // "none"')"
    expect_eq "$position $widget leaves the pointer on the icon" "$hover_x $hover_y" "$(hyprctl cursorpos -j | jq -r '[.x,.y] | join(" ")')"
    if [[ $position == top ]]; then
      expect_eq "$widget tooltip is below the top bar" true "$(jq --argjson bottom "$((bar_y+bar_height))" 'all(.[]; .y >= $bottom)' <<<"$layers")"
    else
      expect_eq "$widget tooltip is above the bottom bar" true "$(jq --argjson top "$bar_y" 'all(.[]; .y + .h <= $top)' <<<"$layers")"
    fi
    expect_eq "$position $widget tooltip stays inside the screen" true "$(jq --argjson w "$pointer_width" --argjson h "$pointer_height" 'all(.[]; .x >= 0 and .y >= 0 and .x+.w <= $w and .y+.h <= $h)' <<<"$layers")"
    region=$(jq -r '.[0] | "\(.x),\(.y) \(.w)x\(.h)"' <<<"$layers")
    hyprctl dismissnotify -1 >/dev/null
    grim -g "$region" "$runtime/tooltip-$position-$widget.png"
    if [[ $widget == audio ]]; then
      cornice ipc osd show volume 0.42 '' >/dev/null
      # IPC returns before the compositor commits the visibility change.
      for _ in $(seq 1 10); do
        [[ $(tooltip_layers | jq length) == 0 ]] && break
        sleep .05
      done
      expect_eq "$position audio tooltip hides while OSD is visible" 0 "$(tooltip_layers | jq length)"
      sleep 2.2
      expect_eq "$position audio tooltip returns after OSD and hover delay" 1 "$(tooltip_layers | jq length)"
    fi
    tooltip_pointer 640 400
    expect_eq "$position $widget closes immediately on exit" 0 "$(tooltip_layers | jq length)"
  done
done

section "hover preserves existing bar actions"
tooltip_hover_widget cn.audio
before=$(tooltip_bar_shape)
muted_before=$(cornice ipc audioinfo dump | jq '.sinks[0].muted')
tooltip_pointer "$hover_x" "$hover_y" click
sleep .5
expect_eq "audio left click opens its interactive panel" true "$(cornice ipc audioPanel state | jq -r '.open')"
expect_eq "opening audio does not mute the sink" "$muted_before" "$(cornice ipc audioinfo dump | jq '.sinks[0].muted')"
expect_eq "opening audio dismisses the status tooltip" 0 "$(tooltip_layers | jq length)"
cornice ipc shell hide cn.audio >/dev/null
volume_before=$(cornice ipc audioinfo dump | jq '.defaultSink.volume')
tooltip_pointer "$hover_x" "$hover_y" 'scroll:120'
sleep .5
expect_eq "audio scrolling still lowers the real sink volume" true \
  "$(cornice ipc audioinfo dump | jq --argjson before "$volume_before" '.defaultSink.volume < $before')"
expect_eq "mute and volume changes keep bar geometry stable" "$before" "$(tooltip_bar_shape)"
sleep 2.2
tooltip_hover_widget cn.power
sleep .5
tooltip_pointer "$hover_x" "$hover_y" click
sleep .5
expect_eq "power click still opens its full panel" true "$(cornice ipc shell windows | jq '[.[] | select(.id == "cn.power")][0].open')"
expect_eq "opening a panel dismisses the status tooltip" 0 "$(tooltip_layers | jq length)"
cornice ipc shell hide cn.power >/dev/null
tooltip_pointer 640 400
hyprctl dispatch closewindow "address:$tooltip_focus_window" >/dev/null
cp "$runtime/tooltip-config-before.json" "$XDG_CONFIG_HOME/cornice/config.json"
cornice reload >/dev/null
kill "$hover_pointer_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
