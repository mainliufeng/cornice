#!/usr/bin/env bash
# Never use the installed/active compositor; this suite requires a built fork.
set -euo pipefail
ulimit -c 0
prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${CORNICE_TEST_HYPRLAND_SOURCE:?Set CORNICE_TEST_HYPRLAND_SOURCE to the fork checkout}"
export CORNICE_TEST_HYPRLAND=${CORNICE_TEST_HYPRLAND:-$CORNICE_TEST_HYPRLAND_SOURCE/build-multiseat/Hyprland}
[[ -x $CORNICE_TEST_HYPRLAND ]] || { echo 'built fork missing' >&2; exit 1; }
exec /usr/bin/python3 "$prefix/test/agent-desktop-verify.py"
