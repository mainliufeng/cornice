#!/usr/bin/env bash
# Sourced by headless-verify.sh: UI clicks save real layouts in the private config.
section "bar editor placement"
cp "$XDG_CONFIG_HOME/cornice/config.json" "$runtime/bar-before.json"
layout=$(cornice ipc shell config | jq -c '.bar.layout')
jq --argjson layout "$layout" '.bar.layout = $layout | .bar.layout.right |= map(if .id == "cn.weather" then . + {format: "{place}: {temp}", showPlace: true} else . end)'   "$runtime/bar-before.json" >"$XDG_CONFIG_HOME/cornice/config.json"
cornice reload >/dev/null
sleep 0.5
expected_entry=$(jq -c '.bar.layout.right[] | select(.id == "cn.weather")' "$XDG_CONFIG_HOME/cornice/config.json")
cornice language zh-CN >/dev/null
sleep 0.3
wayland-scanner client-header "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.h"
wayland-scanner private-code "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.c"
cc "$prefix/test/hover-pointer.c" "$runtime/virtual-pointer.c" -I"$runtime"   $(pkg-config --cflags --libs wayland-client) -o "$runtime/hover-pointer"
read -r pointer_width pointer_height <<<"$(hyprctl monitors -j | jq -r '[(map(.x + (.width / .scale)) | max), (map(.y + (.height / .scale)) | max)] | map(ceil) | join(" ")')"
coproc BAR_EDITOR_POINTER { exec "$runtime/hover-pointer" 0 0 "$pointer_width" "$pointer_height" interactive; }
hover_pointer_pid=$BAR_EDITOR_POINTER_PID
exec {pointer_in}>&"${BAR_EDITOR_POINTER[1]}"
exec {pointer_out}<&"${BAR_EDITOR_POINTER[0]}"
editor_pointer() {
  printf '%s %s %s\n' "$1" "$2" "${3:-click}" >&"$pointer_in"
  read -r -t 3 pointer_reply <&"$pointer_out"
  sleep 0.5
}
editor_state() { cornice ipc barEditor state; }
editor_click() {
  local id="$1" suffix="$2" state row x y panel_x panel_y section viewport_y viewport_bottom
  for _ in $(seq 1 12); do
    state=$(editor_state)
    row=$(jq -c --arg id "$id" '.rows[] | select(.id == $id)' <<<"$state" | head -1)
    [[ -n $row ]] || { fail "editor row missing: $id"; return 1; }
    read -r panel_x panel_y <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")] | first | [.x,.y] | join(" ")')"
    x=$(jq -r '.menu.x' <<<"$row"); y=$(jq -r '.menu.y' <<<"$row")
    section=$(jq -r '.section' <<<"$row")
    if [[ $section != hidden ]]; then
      viewport_y=$(jq --arg section "$section" '.columns[] | select(.section == $section) | .viewport.y | floor' <<<"$state")
      viewport_bottom=$(jq --arg section "$section" '.columns[] | select(.section == $section) | .viewport | .y + .height | floor' <<<"$state")
      if (( y < viewport_y || y >= viewport_bottom )); then
        if (( y < viewport_y )); then delta=-100; else delta=100; fi
        editor_pointer "$((panel_x + x - 80))" "$((panel_y + viewport_y + 60))" "scroll:$delta"
        sleep 0.5
        continue
      fi
    fi
    editor_pointer "$((panel_x + x))" "$((panel_y + y))"
    state=$(editor_state)
    [[ -f $runtime/bar-editor-menu.png ]] || grim "$runtime/bar-editor-menu.png"
    action=$(jq -c --arg suffix "$suffix" '.menu[] | select(.command | endswith($suffix))' <<<"$state")
    [[ -n $action ]] || { fail "editor menu action missing: $id $suffix ($state)"; return 1; }
    x=$(jq -r '.x' <<<"$action"); y=$(jq -r '.y' <<<"$action")
    editor_pointer "$((panel_x + x))" "$((panel_y + y))"
    return
  done
  fail "editor row could not be scrolled into view: $id"
}
expect_placement() {
  local id="$1" section="$2"
  for _ in $(seq 1 30); do
    [[ $(cornice ipc shell config | jq -r --arg id "$id" --arg section "$section" '.bar.layout[$section] | any(.id == $id)') == true ]] && break
    sleep 0.1
  done
  expect_eq "$id renders in $section after an editor click" "$section"     "$(cornice ipc bar geometry | jq -r --arg id "$id" '.[] | select(.id == $id) | .section')"
  expect_eq "$id remains a single widget" "1"     "$(cornice ipc shell config | jq --arg id "$id" '[.bar.layout[][] | select(.id == $id)] | length')"
}
cornice bar edit >/dev/null
sleep 0.4
state=$(editor_state)
expect_eq "the editor mirrors the three actual bar sections" '["left","center","right"]' "$(jq -c '[.columns[].section]' <<<"$state")"
expect_eq "visible and hidden widgets each have one menu entry" "true" "$(jq '.rows | all(.menu.x > 0 and .menu.y > 0)' <<<"$state")"
grim "$runtime/bar-editor-before.png"
for destination in center left right; do
  editor_click cn.weather " $destination"
  expect_placement cn.weather "$destination"
  expect_eq "weather options survive moving to $destination" "$expected_entry"     "$(cornice ipc shell config | jq -c --arg section "$destination" '.bar.layout[$section][] | select(.id == "cn.weather")')"
  grim "$runtime/bar-editor-$destination.png"
done
state=$(editor_state)
read -r panel_x panel_y <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")] | first | [.x,.y] | join(" ")')"
editor_drag() {
  local id="$1" destination="$2" position="$3" state row sx sy dx dy section viewport_y viewport_bottom delta
  for _ in $(seq 1 12); do
    state=$(editor_state)
    row=$(jq -c --arg id "$id" '.rows[] | select(.id == $id)' <<<"$state" | head -1)
    [[ -n $row ]] || { fail "editor row missing: $id"; return 1; }
    read -r sx sy <<<"$(jq -r '[.drag.x,.drag.y] | join(" ")' <<<"$row")"
    section=$(jq -r '.section' <<<"$row")
    viewport_y=$(jq --arg section "$section" '.columns[] | select(.section == $section) | .viewport.y | floor' <<<"$state")
    viewport_bottom=$(jq --arg section "$section" '.columns[] | select(.section == $section) | .viewport | .y + .height | floor' <<<"$state")
    read -r panel_x panel_y <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")] | first | [.x,.y] | join(" ")')"
    if (( sy >= viewport_y && sy < viewport_bottom )); then break; fi
    if (( sy < viewport_y )); then delta=-100; else delta=100; fi
    editor_pointer "$((panel_x + sx + 70))" "$((panel_y + viewport_y + 60))" "scroll:$delta"
  done
  (( sy >= viewport_y && sy < viewport_bottom )) || { fail "editor drag row could not be scrolled into view: $id"; return 1; }
  if [[ $destination == outside ]]; then dx=30; dy=30
  else
    read -r dx dy <<<"$(jq -r --arg section "$destination" --arg position "$position" '.columns[] | select(.section == $section) | [.viewport.x + 70, (if $position == "start" then .viewport.y + 4 else .viewport.y + .viewport.height - 10 end)] | map(floor) | join(" ")' <<<"$state")"
  fi
  editor_pointer "$((panel_x + sx))" "$((panel_y + sy))" press
  editor_pointer "$((panel_x + sx - 20))" "$((panel_y + sy))" hover
  editor_pointer "$((panel_x + dx))" "$((panel_y + dy))" hover
  expect_eq "dragging $id displays a live drag preview" true "$(editor_state | jq -r '.dragActive')"
  grim "$runtime/bar-editor-drag.png"
  editor_pointer "$((panel_x + dx))" "$((panel_y + dy))" release
}
editor_drag cn.weather center start
expect_placement cn.weather center
expect_eq "dragging chooses the exact insertion position" "cn.weather" "$(cornice ipc shell config | jq -r '.bar.layout.center[0].id')"
expect_eq "dragging preserves the widget's inline options" "$expected_entry" "$(cornice ipc shell config | jq -c '.bar.layout.center[0]')"
editor_drag cn.weather center end
expect_eq "dragging within a column reorders its widgets" cn.weather "$(cornice ipc shell config | jq -r '.bar.layout.center[-1].id')"
before_cancel=$(cornice ipc shell config | jq -c '.bar.layout')
editor_drag cn.weather outside start
expect_eq "dropping outside the columns leaves the layout unchanged" "$before_cancel" "$(cornice ipc shell config | jq -c '.bar.layout')"
editor_drag cn.brightness left start
expect_placement cn.brightness left
expect_eq "dragging a hidden widget restores it at the requested position" cn.brightness "$(cornice ipc shell config | jq -r '.bar.layout.left[0].id')"
editor_click cn.brightness "cn.brightness'"
editor_click cn.network " center"
expect_placement cn.network center
editor_click cn.weather "cn.weather'"
grim "$runtime/bar-editor-hidden.png"
# The hide action ends in the quoted ID; hidden rows expose all three destinations.
expect_eq "weather becomes hidden in the editor" "hidden"   "$(editor_state | jq -r '.rows[] | select(.id == "cn.weather") | .kind')"
editor_click cn.weather " center"
expect_placement cn.weather center
expect_eq "saving the layout keeps a rollback file" "true"   "$(test -s "$XDG_CONFIG_HOME/cornice/config.json.previous" && echo true || echo false)"
# Back-to-back CLI moves also preserve the latest layout before reload completes.
cornice bar move cn.weather left >/dev/null
cornice bar move cn.network right >/dev/null
expect_eq "consecutive moves preserve both placements" "true"   "$(jq '(.bar.layout.left | any(.id == "cn.weather")) and (.bar.layout.right | any(.id == "cn.network"))' "$XDG_CONFIG_HOME/cornice/config.json")"
cornice bar show cn.weather --section center --index 0 >/dev/null
sleep 0.4
expect_eq "show respects an explicit section for an existing widget" "cn.weather"   "$(cornice ipc shell config | jq -r '.bar.layout.center[0].id')"
panel_region=$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")] | first | "\(.x),\(.y) \(.w)x\(.h)"')
grim -g "$panel_region" "$runtime/bar-editor-preview.png"
cornice ipc shell hide cn.bar-editor >/dev/null
kill "$hover_pointer_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
cp "$runtime/bar-before.json" "$XDG_CONFIG_HOME/cornice/config.json"
cornice reload >/dev/null
sleep 0.5
