#!/usr/bin/env bash
# Test fixtures keep one set of interaction assertions across compositor APIs.
# This is sourced only by private-compositor tests, never by the product.
hyprctl() {
  if [[ ${CORNICE_TEST_HYPRLAND_CONFIG_FORMAT:-legacy} != lua ]]; then
    command hyprctl "$@"
    return
  fi
  local translated operation
  case "${1:-}" in
    dispatch|keyword) ;;
    *) command hyprctl "$@"; return ;;
  esac
  translated=$(python3 "$prefix/test/hyprctl-test-adapter.py" "$@") || return
  operation=${translated%%$'\n'*}
  command hyprctl "$operation" "${translated#*$'\n'}"
}
