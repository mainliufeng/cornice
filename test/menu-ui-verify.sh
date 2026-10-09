#!/usr/bin/env bash
# Sourced inside headless-verify.sh: real Wayland input and real DBusMenu data.
section "persistent cascading menus: native pointer and keyboard"
python3 "$prefix/test/fake-tray-menu.py" >"$runtime/tray-fixture.log" 2>&1 &
tray_fixture_pid=$!
for _ in $(seq 1 40); do
  cornice ipc tray dump | jq -e '.[] | select(.id == "cornice-menu-test")' >/dev/null && break
  sleep .1
done
wayland-scanner client-header "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.h"
wayland-scanner private-code "$prefix/test/wlr-virtual-pointer-unstable-v1.xml" "$runtime/virtual-pointer.c"
cc "$prefix/test/hover-pointer.c" "$runtime/virtual-pointer.c" -I"$runtime" \
  $(pkg-config --cflags --libs wayland-client) -o "$runtime/hover-pointer"
read -r pointer_width pointer_height <<<"$(hyprctl monitors -j | jq -r '[(map(.x + (.width / .scale)) | max), (map(.y + (.height / .scale)) | max)] | map(ceil) | join(" ")')"
coproc MENU_POINTER { exec "$runtime/hover-pointer" 0 0 "$pointer_width" "$pointer_height" interactive; }
hover_pointer_pid=$MENU_POINTER_PID
exec {pointer_in}>&"${MENU_POINTER[1]}"
exec {pointer_out}<&"${MENU_POINTER[0]}"
menu_state() { cornice ipc tray menuState; }
menu_pointer() {
  printf '%s %s %s\n' "$1" "$2" "${3:-click}" >&"$pointer_in"
  read -r -t 3 pointer_reply <&"$pointer_out"
}
menu_row() {
  local level="$1" label="$2" action="${3:-click}" state px py x y
  state=$(menu_state)
  read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-menu")][0] | [.x,.y] | join(" ")')"
  read -r x y <<<"$(jq -r --argjson l "$level" --arg t "$label" '.columns[$l].rows[] | select(.text == $t) | [.x,.y] | join(" ")' <<<"$state")"
  menu_pointer "$((px+x))" "$((py+y))" "$action"
}
menu_open() {
  cornice ipc tray invoke cornice-menu-test menu >/dev/null
  sleep .4
}
menu_key() { wtype -k "$1"; sleep .15; }
# Opening click must survive its own release and focus-grab arming.
sleep .3
read -r bx by <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-bar")][0] | [.x,.y] | join(" ")')"
read -r tx ty <<<"$(cornice ipc bar geometry | jq -r '.[] | select(.id == "cn.tray") | [(.x+.width/2),(.y+.height/2)] | map(round) | join(" ")')"
menu_pointer "$((bx+tx))" "$((by+ty))"
sleep .4
menu_state > "$runtime/menu-initial.json"
expect_eq "the real tray icon click opens the root menu" true "$(menu_state | jq -r '.opened')"
menu_row 0 'First submenu' hover
sleep .6
expect_eq "hover opens only one level" 1 "$(menu_state | jq '.depth')"
expect_eq "parent rows remain visible beside child rows" true "$(menu_state | jq '.columns | length == 2 and .[0].rows[1].text == "First submenu" and .[1].rows[0].text == "Nested submenu"')"
sleep .6
expect_eq "stationary pointer never enters a second level" 1 "$(menu_state | jq '.depth')"
menu_row 0 'First submenu'
sleep .3
expect_eq "clicking an already expanded parent is idempotent" 1 "$(menu_state | jq '.depth')"
# Same physical coordinates, with no IPC navigation and no delay between clicks.
state=$(menu_state)
read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-menu")][0] | [.x,.y] | join(" ")')"
read -r x y <<<"$(jq -r '.columns[0].rows[] | select(.text == "First submenu") | [.x,.y] | join(" ")' <<<"$state")"
for _ in $(seq 1 6); do menu_pointer "$((px+x))" "$((py+y))"; done
expect_eq "six rapid stationary clicks cannot advance the child" 1 "$(menu_state | jq '.depth')"
menu_row 1 'Nested submenu' hover
sleep .6
expect_eq "moving into the new column opens the intended next level" 2 "$(menu_state | jq '.depth')"
menu_row 2 'Third submenu'
sleep .2
expect_eq "click enters one third-level submenu" 3 "$(menu_state | jq '.depth')"
menu_row 3 'Fourth submenu'
sleep .2
expect_eq "four submenu levels preserve five columns" 5 "$(menu_state | jq '.columns | length')"
menu_state > "$runtime/ui-menu-deep-state.json"
hyprctl dismissnotify -1 >/dev/null
 grim "$runtime/ui-menu-deep.png"
expect_eq "deep menu surface stays within the output" true "$(hyprctl layers -j | jq --argjson w "$pointer_width" --argjson h "$pointer_height" '[.. | objects | select(.namespace? == "cornice-menu")][0] | .x >= 0 and .y >= 0 and (.x+.w) <= $w and (.y+.h) <= $h')"
# Back is also a real mouse target, not only a keyboard gesture.
state=$(menu_state)
read -r x y <<<"$(jq -r '.columns[4].back | [.x,.y] | map(round) | join(" ")' <<<"$state")"
read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-menu")][0] | [.x,.y] | join(" ")')"
menu_pointer "$((px+x))" "$((py+y))"
sleep .2
expect_eq "Back click returns exactly one level" 3 "$(menu_state | jq '.depth')"
menu_row 3 'Fourth submenu'
sleep .2
menu_key Left
expect_eq "Left returns one level while preserving ancestors" 3 "$(menu_state | jq '.depth')"
menu_key BackSpace
expect_eq "Backspace returns exactly one level" 2 "$(menu_state | jq '.depth')"
menu_row 0 'Second submenu'
sleep .4
expect_eq "switching a root parent removes the old descendants" true "$(menu_state | jq '.depth == 1 and .columns[1].rows[0].text == "Other leaf"')"
menu_row 1 'Other leaf'
sleep .5
expect_eq "leaf action closes the whole cascade" false "$(menu_state | jq '.opened')"
expect_eq "duplicate leaf labels resolve within their exact branch" 1 "$(rg -c '^event 9 clicked$' "$runtime/tray-fixture.log" || echo 0)"
menu_open
menu_key Home
menu_key Down
wtype -P Right -s 1100 -p Right
sleep .2
expect_eq "holding Right opens only the selected first level" 1 "$(menu_state | jq '.depth')"
wtype -P Return -s 1100 -p Return
sleep .2
expect_eq "holding Enter cannot cascade through descendants" 2 "$(menu_state | jq '.depth')"
menu_key Return
expect_eq "a fresh Enter may enter the next level" 3 "$(menu_state | jq '.depth')"
menu_key Return
expect_eq "a second fresh Enter reaches the fourth level" 4 "$(menu_state | jq '.depth')"
menu_key Down
menu_key Right
sleep .3
expect_eq "a tall sixth column scrolls instead of leaving the screen" true "$(menu_state | jq '.depth == 5 and .columns[5].contentHeight > .columns[5].viewportHeight')"
menu_key End
expect_eq "End makes the last deep menu row visible" true "$(menu_state | jq '.columns[5].contentY > 0 and .rows[-1].y > 0 and .rows[-1].y < .height')"
menu_key Left
menu_key Home
menu_key Return
sleep .5
expect_eq "deep checked leaf activates the actual DBusMenu item" 1 "$(rg -c '^event 5 clicked$' "$runtime/tray-fixture.log" || echo 0)"
menu_open
menu_key Escape
expect_eq "Escape closes and frees all child openers" true "$(menu_state | jq '.opened == false and .depth == 0')"
menu_open
menu_pointer 10 "$((pointer_height-10))"
sleep .3
expect_eq "an outside click closes the cascade" false "$(menu_state | jq '.opened')"
menu_open
expect_eq "reopening starts with a clean root" true "$(menu_state | jq '.opened and .depth == 0 and (.columns | length == 1)')"
menu_key Escape
menu_open
menu_key Home
menu_key Down
menu_key Down
menu_key Down
expect_eq "keyboard navigation skips disabled rows and separators" 0 "$(menu_state | jq '.columns[0].selection')"
menu_row 0 Disabled
sleep .2
expect_eq "a disabled menu item cannot activate or dismiss" true "$(menu_state | jq '.opened and .depth == 0')"
menu_key Escape
menu_pointer 10 "$((pointer_height-10))" hover
menu_open
menu_row 0 'First submenu' press
sleep .6
expect_eq "holding a pointer press never opens a hover child" 0 "$(menu_state | jq '.depth')"
menu_row 0 'First submenu' release
sleep .4
expect_eq "releasing one physical press opens exactly one child" 1 "$(menu_state | jq '.depth')"
menu_key Escape
# A smaller logical output exercises left-edge overflow and scroll/reveal.
monitor=$(hyprctl monitors -j | jq -r '.[0].name')
original_mode=$(hyprctl monitors -j | jq -r '.[0] | "\(.width)x\(.height)@\(.refreshRate),0x0,\(.scale)"')
hyprctl keyword monitor "$monitor,800x600@60,0x0,1" >/dev/null
sleep .5
read -r pointer_width pointer_height <<<"$(hyprctl monitors -j | jq -r '.[0] | [(.width/.scale),(.height/.scale)] | map(ceil) | join(" ")')"
menu_open
menu_key Home
menu_key Down
for _ in $(seq 1 4); do menu_key Right; done
menu_state > "$runtime/ui-menu-narrow-state.json"
grim "$runtime/ui-menu-narrow.png"
expect_eq "narrow test uses an 800-pixel logical output" 800 "$pointer_width"
expect_eq "five columns remain reachable on a narrow output" true "$(menu_state | jq --argjson w "$pointer_width" '.depth == 4 and .width <= $w')"
menu_key Left
expect_eq "return navigation remains usable at the screen edge" 3 "$(menu_state | jq '.depth')"
menu_key Escape
hyprctl keyword monitor "$monitor,$original_mode" >/dev/null
sleep .4
read -r pointer_width pointer_height <<<"$(hyprctl monitors -j | jq -r '.[0] | [(.width/.scale),(.height/.scale)] | map(ceil) | join(" ")')"
# Main menu: theme picker also keeps its parent and ignores activation repeats.
cornice ipc shell summon cn.menu '{}' >/dev/null
sleep .4
for _ in $(seq 1 40); do
  [[ $(cornice ipc menu state | jq '.themes | length') -ge 10 ]] && break
  sleep .1
done
menu_key Home
for _ in $(seq 1 4); do menu_key Down; done
wtype -P Return -s 1100 -p Return
sleep .2
expect_eq "holding Enter in main menu preserves root and theme columns" true "$(cornice ipc menu state | jq '.open and .page == "themes" and .columns == 2')"
menu_key Left
expect_eq "return from the theme column restores parent selection" true "$(cornice ipc menu state | jq '.page == "root" and .selection == 5')"
# Fixed coordinates simulate the actual repeated physical click while expanding.
state=$(cornice ipc menu state)
read -r px py <<<"$(hyprctl layers -j | jq -r '[.. | objects | select(.namespace? == "cornice-panel")][0] | [.x,.y] | join(" ")')"
read -r x y <<<"$(jq -r '.panels[0][] | select(.page == "themes") | [.x,.y] | join(" ")' <<<"$state")"
for _ in $(seq 1 6); do menu_pointer "$((px+x))" "$((py+y))"; done
expect_eq "six rapid main-menu clicks keep the theme picker open" true "$(cornice ipc menu state | jq '.open and .page == "themes" and .columns == 2')"
grim "$runtime/ui-menu-themes.png"
initial_theme=$(cornice ipc menu state | jq -r '.theme')
menu_key Down
menu_key Escape
expect_eq "Escape restores the actual theme preview" "$initial_theme" "$(cornice ipc menu state | jq -r '.theme')"
expect_eq "Escape still cancels the live theme preview" false "$(cornice ipc menu state | jq '.open')"
# Verify keyboard focus really returns to a client after the menu closes.
cat > "$runtime/menu-focus-reader.sh" <<'FOCUS'
#!/bin/sh
stty -echo
read -r text
printf '%s\n' "$text" > "$CORNICE_MENU_FOCUS_LOG"
sleep 30
FOCUS
hyprctl dispatch exec "env CORNICE_MENU_FOCUS_LOG=$runtime/menu-focus.log kitty --title Cornice-menu-focus sh $runtime/menu-focus-reader.sh" >/dev/null
focus_address=""
for _ in $(seq 1 40); do
  focus_address=$(hyprctl clients -j | jq -r '.[] | select(.title == "Cornice-menu-focus") | .address')
  [[ -n $focus_address ]] && break
  sleep .1
done
if [[ -n $focus_address ]]; then
  hyprctl dispatch focuswindow "address:$focus_address" >/dev/null
  menu_open
  menu_key Escape
  wtype 'focus-return' -k Return
  sleep .3
  expect_eq "closing the cascade returns real typing focus to its client" focus-return "$(cat "$runtime/menu-focus.log" 2>/dev/null)"
  hyprctl dispatch closewindow "address:$focus_address" >/dev/null
else
  fail "focus regression client did not start"
fi
kill "$hover_pointer_pid" "$tray_fixture_pid" 2>/dev/null
wait "$hover_pointer_pid" 2>/dev/null || true
hover_pointer_pid=""; tray_fixture_pid=""
exec {pointer_in}>&-
exec {pointer_out}<&-
