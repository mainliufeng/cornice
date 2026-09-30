#!/usr/bin/env bash
# Sourced by headless-verify.sh: compare actual rendered font baselines, including
# Chinese fallback fonts and the weather widget's smaller place-name font.
section "clock and weather text alignment"
cp "$XDG_CONFIG_HOME/cornice/config.json" "$runtime/alignment-config-before.json"
layout=$(cornice ipc shell config | jq -c '.bar.layout')
jq --argjson layout "$layout" '.bar.layout = $layout | .bar.layout.right |= map(if .id == "cn.weather" then . + {showPlace: true} else . end)' \
  "$runtime/alignment-config-before.json" >"$XDG_CONFIG_HOME/cornice/config.json"
cornice reload >/dev/null
for _ in $(seq 1 30); do
  [[ $(cornice ipc weather status | jq -r '.status') == ready ]] && break
  sleep 0.1
done
for language in zh-CN en; do
  cornice language "$language" >/dev/null
  for destination in center left right; do
    cornice bar show cn.clock --section "$destination" --index 0 >/dev/null
    cornice bar show cn.weather --section "$destination" --index 1 >/dev/null
    sleep 0.5
    geometry=$(cornice ipc bar geometry)
    labels=$(jq -c '[.[] | select(.id == "cn.clock" or .id == "cn.weather") | .text[]]' <<<"$geometry")
    expect_eq "$language $destination exposes clock, weather icon, temperature and place" 4 "$(jq length <<<"$labels")"
    expect_eq "$language $destination shares one text baseline" true \
      "$(jq 'map(.baseline) | (max - min) < 0.01' <<<"$labels")"
    expect_eq "$language $destination keeps every text line within the bar" true \
      "$(jq --argjson height "$(hyprctl layers -j | jq '[.. | objects | select(.namespace? == "cornice-bar")][0].h')" 'all(.y >= 0 and .y + .height <= $height)' <<<"$labels")"
    grim "$runtime/alignment-$language-$destination.png"
    printf '%s\n' "$geometry" >"$runtime/alignment-$language-$destination.json"
  done
done
cp "$runtime/alignment-config-before.json" "$XDG_CONFIG_HOME/cornice/config.json"
cornice reload >/dev/null
sleep 0.5
# Leave the next independent suite on a freshly focused workspace after these
# layout changes rebuilt the empty workspace/window widgets.
hyprctl dispatch workspace 2 >/dev/null
hyprctl dispatch workspace 1 >/dev/null
sleep 0.3
