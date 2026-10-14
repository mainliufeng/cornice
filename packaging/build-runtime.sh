#!/usr/bin/env bash
# Build a self-contained runtime from source. BUILD_ROOT must be new and empty;
# never copy generated native artifacts or node_modules from the source tree.
set -euo pipefail
if [[ $# != 3 && $# != 4 ]] || [[ $# == 4 && $4 != --no-desktop ]]; then
  echo 'usage: build-runtime.sh SOURCE BUILD_ROOT DEST [--no-desktop]' >&2
  exit 2
fi
source_root=$(realpath -- "$1")
build_root=$(realpath -m -- "$2")
destination=$(realpath -m -- "$3")
desktop=1
[[ ${4:-} != --no-desktop ]] || desktop=0
[[ -d $build_root ]] || mkdir -p "$build_root"
if [[ -n $(find "$build_root" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo 'build-runtime: BUILD_ROOT must be empty; existing build artifacts are not reused' >&2
  exit 1
fi
jobs=${CORNICE_BUILD_JOBS:-2}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'CORNICE_BUILD_JOBS must be a positive integer' >&2; exit 2; }
for tool in cmake ninja; do
  command -v "$tool" >/dev/null || { echo "build-runtime: $tool is required" >&2; exit 1; }
done
if ((desktop)); then
  command -v pkg-config >/dev/null && pkg-config --exists atspi-2 \
    || { echo 'build-runtime: at-spi2-core and pkgconf are required' >&2; exit 1; }
  command -v npm >/dev/null || { echo 'build-runtime: npm is required to install locked browser dependencies' >&2; exit 1; }
  command -v node >/dev/null || { echo 'build-runtime: nodejs is required for MCP/browser tools' >&2; exit 1; }
  node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(1)' \
    || { echo 'build-runtime: nodejs >=20 is required' >&2; exit 1; }
fi
mkdir -p "$build_root/agent" "$destination/native/agent"
find "$source_root/native/agent" -maxdepth 1 -type f -exec cp -- {} "$build_root/agent/" \;
if ((desktop)); then
  npm ci --prefix "$build_root/agent" --omit=dev --ignore-scripts --no-audit --no-fund
  (cd "$build_root/agent" && node --input-type=module -e 'await import("@modelcontextprotocol/sdk/server/mcp.js"); await import("@playwright/mcp");')
fi
cmake -S "$source_root/native/platform" -B "$build_root/platform" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_root/platform" -j "$jobs"
cmake --install "$build_root/platform" --prefix "$destination"
if ((desktop)); then
  cmake -S "$source_root/native/desktop" -B "$build_root/desktop" -G Ninja -DCMAKE_BUILD_TYPE=Release
  cmake --build "$build_root/desktop" -j "$jobs"
  cmake --install "$build_root/desktop" --prefix "$destination"
fi
cp -r "$build_root/agent/." "$destination/native/agent/"

check_args=()
((desktop)) || check_args+=(--no-desktop)
"$source_root/packaging/check-runtime.sh" "$destination" "${check_args[@]}"
