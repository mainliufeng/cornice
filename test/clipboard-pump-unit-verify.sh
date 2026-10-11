#!/usr/bin/env bash
# Real Qt/Wayland transport regression; no compositor, application or GPU.
set -euo pipefail
prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${CORNICE_TEST_RESOURCE_SCOPE:-} != 1 ]]; then
  exec "$prefix/test/resource-scope.sh" "$0" "$@"
fi
artifacts=$(mktemp -d /tmp/cornice-clipboard-pump.XXXXXX)
trap 'rm -rf "$artifacts"' EXIT
protocol="$prefix/native/desktop/protocols/wlr-data-control-unstable-v1.xml"
wayland-scanner client-header "$protocol" "$artifacts/wlr-data-control-unstable-v1.h"
wayland-scanner private-code "$protocol" "$artifacts/wlr-data-control-unstable-v1.c"
cc -fPIC -c "$artifacts/wlr-data-control-unstable-v1.c" $(pkg-config --cflags wayland-client) -o "$artifacts/protocol.o"
c++ -std=c++20 -fPIC "$prefix/test/clipboard-pump-unit.cpp" "$prefix/native/desktop/ClipboardBridge.cpp" \
  "$artifacts/protocol.o" -I"$prefix/native/desktop" -I"$artifacts" \
  $(pkg-config --cflags --libs Qt6Core Qt6Network wayland-client) -o "$artifacts/verify"
timeout 5 "$artifacts/verify"
