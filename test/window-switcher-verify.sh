#!/usr/bin/env bash
# Sourced by headless-verify.sh; every window and pointer stays in its private
# compositor. Real kitty windows cover duplicate apps, focus and overflow.
section "current workspace window switcher"
if ! command -v kitty >/dev/null; then
  fail "kitty is required for the window switcher integration check"
  return
fi
wayland-scanner client-header "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.h"
wayland-scanner private-code "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.c"
cc "$prefix/test/hover-pointer.c" "$runtime/virtual-pointer.c" -I"$runtime" \
  $(pkg-config --cflags --libs wayland-client) -o "$runtime/hover-pointer"
extent=$(hyprctl monitors -j | jq -r '[(map(.x + (.width / .scale)) | max), (map(.y + (.height / .scale)) | max)] | map(ceil) | join(" ")')
read -r pointer_width pointer_height <<<"$extent"
coproc WINDOWS_POINTER { exec "$runtime/hover-pointer" 0 0 "$pointer_width" "$pointer_height" interactive; }
hover_pointer_pid=$WINDOWS_POINTER_PID
exec {pointer_in}>&"${WINDOWS_POINTER[1]}"
exec {pointer_out}<&"${WINDOWS_POINTER[0]}"
window_pointer() {
  printf '%s %s %s\n' "$1" "$2" "${3:-click}" >&"$pointer_in"
  read -r -t 3 pointer_reply <&"$pointer_out"
  sleep 0.6
}
window_state() { cornice ipc windows state; }

hyprctl dispatch exec 'kitty --override confirm_os_window_close=0 --title Cornice-first sleep 180' >/dev/null
sleep 0.5
hyprctl dispatch exec 'kitty --override confirm_os_window_close=0 --title Cornice-second sleep 180' >/dev/null
for _ in $(seq 1 30); do
  [[ $(window_state | jq '[.windows[] | select(.title | startswith("Cornice-"))] | length') == 2 ]] && break
  sleep 0.1
done
state=$(window_state)
expect_eq "same application has two separate window entries" "2" \
  "$(jq '[.windows[] | select(.title | startswith("Cornice-"))] | length' <<<"$state")"
original_order=$(jq -c '[.windows[].address]' <<<"$state")
target=$(jq -r '. as $state | .buttons[] | select(.address != $state.focused) | .address' <<<"$state" | head -1)
read -r click_x click_y <<<"$(jq -r --arg address "$target" '.buttons[] | select(.address == $address) | [.x,.y] | join(" ")' <<<"$state")"
if [[ -z $target || -z $click_x ]]; then fail "no clickable non-focused window icon: $state"; return; fi
before=$(hyprctl activewindow -j | jq -r '.address')
window_pointer "$click_x" "$click_y" hover
expect_eq "hover displays the window title tooltip" "true" "$(window_state | jq -r '.tooltipVisible')"
expect_eq "hover does not change the focused window" "$before" "$(hyprctl activewindow -j | jq -r '.address')"
grim "$runtime/window-tooltip.png"
window_pointer "$click_x" "$click_y"
sleep 0.2
expect_eq "one click focuses the selected real window" "$target" "$(hyprctl activewindow -j | jq -r '.address')"
expect_eq "focused highlight tracks the compositor" "$target" "$(window_state | jq -r '.focused')"
expect_eq "focusing preserves icon order" "$original_order" "$(window_state | jq -c '[.windows[].address]')"
expect_eq "normal focus leaves the cursor on the clicked icon" "$click_x $click_y" \
  "$(hyprctl cursorpos -j | jq -r '[.x,.y] | join(" ")')"

section "window switcher preserves maximized and fullscreen mode"
hyprctl keyword cursor:no_warps 0 >/dev/null
hyprctl keyword misc:on_focus_under_fullscreen 2 >/dev/null
original_warps=$(hyprctl -j getoption cursor:no_warps | jq -cS .)
original_fullscreen_policy=$(hyprctl -j getoption misc:on_focus_under_fullscreen | jq -cS .)
for mode in 1 2; do
  hyprctl dispatch fullscreenstate "$mode $mode" >/dev/null
  state=$(window_state)
  target=$(hyprctl clients -j | jq -r --arg active "$(hyprctl activewindow -j | jq -r '.address')" '.[] | select(.workspace.id == 1 and .address != $active) | .address' | head -1)
  if [[ $mode == 1 ]]; then
    read -r click_x click_y <<<"$(jq -r --arg address "$target" '.buttons[] | select(.address == $address) | [.x,.y] | join(" ")' <<<"$state")"
    window_pointer "$click_x" "$click_y"
    expected_cursor="$click_x $click_y"
  else
    # True fullscreen covers a Top-layer bar; exercise the same real focusing
    # helper directly, without inventing a visible/clickable bar in that mode.
    expected_cursor=$(hyprctl cursorpos -j | jq -r '[.x,.y] | join(" ")')
    "$prefix/bin/cornice-focus-window" "$target" 1
    sleep 0.3
  fi
  expect_eq "mode $mode focuses the selected real window" "$target" "$(hyprctl activewindow -j | jq -r '.address')"
  expect_eq "mode $mode remains on the selected window" "$mode" "$(hyprctl activewindow -j | jq -r '.fullscreen')"
  expect_eq "mode $mode does not warp the cursor" "$expected_cursor" "$(hyprctl cursorpos -j | jq -r '[.x,.y] | join(" ")')"
  expect_eq "mode $mode restores the original cursor policy" "$original_warps" "$(hyprctl -j getoption cursor:no_warps | jq -cS .)"
  expect_eq "mode $mode restores the original fullscreen policy" "$original_fullscreen_policy" "$(hyprctl -j getoption misc:on_focus_under_fullscreen | jq -cS .)"
done
hyprctl dispatch fullscreenstate '0 0' >/dev/null

# Enough real windows to exhaust the bar's available width.
for i in $(seq 3 9); do
  window_title="Cornice-$i"
  [[ $i == 9 ]] && window_title="Cornice-9 a long window title remains fully readable in the scrollable window picker"
  hyprctl dispatch exec "kitty --override confirm_os_window_close=0 --title '$window_title' sleep 180" >/dev/null
  sleep 0.15
done
for _ in $(seq 1 40); do
  [[ $(window_state | jq '.windows | length') -ge 9 ]] && break
  sleep 0.1
done
state=$(window_state)
if [[ $(jq '.overflow | length' <<<"$state") -gt 0 ]]; then pass "extra windows produce a More button"
else fail "no overflow despite nine windows: $state"; fi
expect_eq "window widget fits its actual width budget" "true" "$(jq '.width <= .budget' <<<"$state")"
window_pointer "$(jq -r '.moreX' <<<"$state")" "$(jq -r '.buttons[0].y // 19' <<<"$state")" hover
expect_eq "hovering More does not open the list" "false" "$(window_state | jq -r '.pickerOpen')"
window_pointer "$(jq -r '.moreX' <<<"$state")" "$(jq -r '.buttons[0].y // 19' <<<"$state")"
sleep 0.2
state=$(window_state)
expect_eq "More opens only on click" "true" "$(jq -r '.pickerOpen' <<<"$state")"
grim "$runtime/window-overflow.png"
origin=$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")] | first | [.x,.y] | join(" ")')
read -r panel_x panel_y <<<"$origin"
read -r row_x row_y <<<"$(jq -r '.pickerRows[0] | [.x,.y] | join(" ")' <<<"$state")"
target=$(jq -r '.pickerRows[0].address' <<<"$state")
if [[ $row_x =~ ^[0-9]+$ && $row_y =~ ^[0-9]+$ ]]; then
  # Scroll with the real pointer, then select the last (long title) entry.
  window_pointer "$((panel_x + row_x))" "$((panel_y + row_y))" scroll
  for _ in $(seq 1 30); do
    [[ $(window_state | jq -r '.pickerMoving') == false ]] && break
    sleep 0.1
  done
  state=$(window_state)
  grim "$runtime/window-overflow-scrolled.png"
  read -r row_x row_y <<<"$(jq -r '.pickerRows[-1] | [.x,.y] | join(" ")' <<<"$state")"
  target=$(jq -r '.pickerRows[-1].address' <<<"$state")
  expect_eq "scrolling reaches the last long-title window" "true" "$(jq '.pickerRows[-1].title | startswith("Cornice-9 ")' <<<"$state")"
  window_pointer "$((panel_x + row_x))" "$((panel_y + row_y))"
  sleep 0.2
  expect_eq "overflow click focuses the real selected window" "$target" "$(hyprctl activewindow -j | jq -r '.address')"
  expect_eq "overflow selection closes the popup" "false" "$(window_state | jq -r '.pickerOpen')"
else fail "overflow rows did not become interactive: $state"; fi

grim "$runtime/window-strip.png"
before_close=$(window_state | jq -c --arg address "$target" '[.windows[].address | select(. != $address)]')
hyprctl dispatch closewindow "address:$target" >/dev/null
for _ in $(seq 1 30); do
  [[ $(window_state | jq -c '[.windows[].address]') == "$before_close" ]] && break
  sleep 0.1
done
expect_eq "closing a window removes only its entry without reordering" "$before_close" "$(window_state | jq -c '[.windows[].address]')"
hyprctl dispatch workspace 2 >/dev/null
hyprctl dispatch exec 'kitty --override confirm_os_window_close=0 --title Other-workspace sleep 180' >/dev/null
sleep 1
state=$(window_state)
expect_eq "another workspace has its own window list" "1" "$(jq '.windows | length' <<<"$state")"
expect_eq "windows from the previous workspace are absent" "Other-workspace" "$(jq -r '.windows[0].title' <<<"$state")"
hyprctl dispatch workspace 42 >/dev/null
sleep 0.4
state=$(window_state)
expect_eq "empty workspace has no stale window entries" "0" "$(jq '.windows | length' <<<"$state")"
expect_eq "empty workspace has no stale focused title" "" "$(jq -r '.title' <<<"$state")"
# Remove only this fixture's windows before the other integration suites run.
while read -r address; do
  [[ -n $address ]] && hyprctl dispatch closewindow "address:$address" >/dev/null
 done < <(hyprctl clients -j | jq -r '.[] | select((.title | startswith("Cornice-")) or .title == "Other-workspace") | .address')
hyprctl dispatch workspace 1 >/dev/null
sleep 0.3
kill "$hover_pointer_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
