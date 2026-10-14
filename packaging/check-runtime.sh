#!/usr/bin/env bash
# Validate real built outputs without starting a compositor or touching a seat.
set -euo pipefail
if [[ $# != 1 && $# != 2 ]] || [[ $# == 2 && $2 != --no-desktop ]]; then
  echo 'usage: check-runtime.sh ROOT [--no-desktop]' >&2; exit 2
fi
root=$(realpath -- "$1")
desktop=1
[[ ${2:-} != --no-desktop ]] || desktop=0
check_library() {
  local dependencies
  dependencies=$(ldd "$1") || { echo "invalid native artifact: $1" >&2; exit 1; }
  if grep -q 'not found' <<<"$dependencies"; then
    echo "native artifact has an unresolved shared library: $1" >&2; exit 1
  fi
}
modules=(Platform)
if ((desktop)); then
  modules+=(Desktop)
  for helper in cornice-desktop-runtime cornice-human-lock cornice-session-guard cornice-native-accessibility cornice-browser-runtime cornice-application-guard; do
    [[ -x $root/native/bin/$helper ]] || { echo "runtime is missing native helper: $helper" >&2; exit 1; }
    check_library "$root/native/bin/$helper"
  done
fi
for module in "${modules[@]}"; do
  directory="$root/native/qml/Cornice/$module"
  [[ -f $directory/qmldir ]] || { echo "runtime is missing QML module: $module" >&2; exit 1; }
  case "$module" in Platform) library=cornice_platform ;; Desktop) library=cornice_desktop_qml ;; esac
  for name in "lib$library.so" "lib${library}plugin.so"; do
    [[ -f $directory/$name ]] || { echo "runtime is missing QML library: $name" >&2; exit 1; }
    check_library "$directory/$name"
  done
done
if ((desktop)); then
  (cd "$root/native/agent" && node --input-type=module -e 'await import("@modelcontextprotocol/sdk/server/mcp.js"); await import("@playwright/mcp");')
  echo '  all six native helpers, both QML modules and locked MCP/browser dependencies resolve'
else
  echo '  core QML module resolves'
fi
