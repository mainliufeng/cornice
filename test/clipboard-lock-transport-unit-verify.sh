#!/usr/bin/env bash
# Actual ClipboardBridge + libwayland peer; QCoreApplication only, no compositor/GPU.
set -euo pipefail
ulimit -c 0
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${CORNICE_TEST_RESOURCE_SCOPE:-} != 1 ]]; then
  exec "$root/test/resource-scope.sh" "$0" "$@"
fi
# Fixture mounts must never restore a broad HOME, device or host socket tree.
fixture_directory() {
  local directory
  directory=$(realpath -e -- "$1")
  [[ -d $directory && -O $directory ]] || { echo 'Fixture directory must exist and be owned by the test user' >&2; exit 2; }
  case "$directory" in
    /|/home|/root|"$HOME"|/tmp|/run|/run/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/var/tmp|/var/tmp/*)
      echo 'Fixture directory may not restore a host HOME, device or socket namespace' >&2; exit 2 ;;
  esac
  printf '%s' "$directory"
}
root=$(fixture_directory "$root")
[[ -f $root/test/sandbox-exec.py ]] || { echo 'Ambient descriptor isolation launcher missing' >&2; exit 2; }
artifact_root=${CORNICE_TEST_ARTIFACT_ROOT:?Set CORNICE_TEST_ARTIFACT_ROOT to a task-owned disk directory}
source_dir=$(fixture_directory "${CORNICE_CLIPBOARD_TEST_SOURCE_DIR:-$root/native/desktop}")
test_user=$(/usr/bin/id -un)
test_uid=$(/usr/bin/id -u)
label=${CORNICE_CLIPBOARD_TEST_LABEL:-final}
[[ $artifact_root = /* && $label =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Absolute artifact directory and simple label required' >&2; exit 2; }
for file in ClipboardBridge.cpp ClipboardBridge.hpp HyprlandAdapter.cpp HyprlandAdapter.hpp; do
  [[ -f $source_dir/$file ]] || { echo "Missing actual source: $source_dir/$file" >&2; exit 2; }
done
mkdir -p "$artifact_root"
artifacts=$(mktemp -d "$artifact_root/$label.XXXXXX")
mkdir -m700 "$artifacts/home" "$artifacts/runtime" "$artifacts/tmp"
export TMPDIR="$artifacts/tmp"
date --iso-8601=ns > "$artifacts/start-time.txt"
cat /proc/self/cgroup > "$artifacts/cgroup.txt"
unit=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup)
unit=${unit##*/}
[[ $unit == cornice-isolated-test-*.scope ]] || { echo 'Required bounded Cornice test scope unavailable' >&2; exit 2; }
systemctl --user show "$unit" -p Id -p ActiveState -p CPUQuotaPerSecUSec -p MemoryMax -p MemorySwapMax -p TasksMax -p RuntimeMaxUSec -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent -p MemorySwapPeak -p CPUUsageNSec > "$artifacts/resource-before.txt"
sha256sum "$root/test/clipboard-lock-transport-unit.cpp" "$0" "$root/test/sandbox-exec.py" "$root/test/resource-scope.sh" "$source_dir/ClipboardBridge.cpp" "$source_dir/ClipboardBridge.hpp" "$source_dir/HyprlandAdapter.cpp" "$source_dir/HyprlandAdapter.hpp" "$root/native/desktop/protocols/wlr-data-control-unstable-v1.xml" > "$artifacts/source-sha256.txt"
cat > "$artifacts/build-run.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
cd /tmp/t
protocol="$TEST_ROOT/native/desktop/protocols/wlr-data-control-unstable-v1.xml"
{
  date --iso-8601=ns
  wayland-scanner client-header "$protocol" wlr-data-control-unstable-v1.h
  wayland-scanner client-header "$protocol" wlr-data-control-client.h
  wayland-scanner server-header "$protocol" wlr-data-control-server.h
  wayland-scanner private-code "$protocol" wlr-data-control-unstable-v1.c
  cc -fPIC -c wlr-data-control-unstable-v1.c $(pkg-config --cflags wayland-client) -o protocol.o
  c++ -std=c++20 -fPIC -O0 -g -c "$TEST_SOURCE/ClipboardBridge.cpp" -I"$TEST_SOURCE" -I/tmp/t $(pkg-config --cflags Qt6Core Qt6Network wayland-client) -o bridge.o
  c++ -std=c++20 -fPIC -O0 -g -c "$TEST_SOURCE/HyprlandAdapter.cpp" -I"$TEST_SOURCE" -I/tmp/t $(pkg-config --cflags Qt6Core Qt6Network wayland-client) -o adapter.o
  c++ -std=c++20 -fPIC -O0 -g -c "$TEST_ROOT/test/clipboard-lock-transport-unit.cpp" -I"$TEST_SOURCE" -I/tmp/t $(pkg-config --cflags Qt6Core Qt6Network wayland-client wayland-server) -o unit.o
  c++ bridge.o adapter.o unit.o protocol.o $(pkg-config --libs Qt6Core Qt6Network wayland-client wayland-server) -o clipboard-lock-transport-unit
  sha256sum clipboard-lock-transport-unit
  pkg-config --modversion Qt6Core Qt6Network wayland-client wayland-server
  date --iso-8601=ns
} 2>&1 | tee compile.log
timeout --signal=TERM --kill-after=2s 10s ./clipboard-lock-transport-unit /tmp/t/result.json 2>&1 | tee test.log
SCRIPT
# The launcher replaces stdin with /dev/null and closes every inherited fd
# above stderr before nice/taskset/timeout/bwrap. The serial lock stays owned by
# the outer resource-scope/flock process, not by a leaked child descriptor.
# Fixed read-only fixture mountpoints also work for historical sources in /tmp,
# after the entire host /tmp/HOME/socket namespaces have been hidden.
command=(/usr/bin/python3 "$root/test/sandbox-exec.py" /usr/bin/nice -n 15
  /usr/bin/taskset -c 0 /usr/bin/timeout --signal=TERM --kill-after=5s 120s
  /usr/bin/bwrap --unshare-all --die-with-parent --new-session --ro-bind / / --dev /dev --proc /proc
  --tmpfs /run --tmpfs /tmp --tmpfs /var/tmp --tmpfs /home --tmpfs /root --tmpfs /opt
  --dir /opt/clipboard-unit-root --dir /opt/clipboard-unit-source
  --ro-bind "$root" /opt/clipboard-unit-root --ro-bind "$source_dir" /opt/clipboard-unit-source
  --dir /dev/shm --tmpfs /dev/shm --bind "$artifacts" /tmp/t
  --clearenv --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8 --setenv TZ Asia/Shanghai
  --setenv USER "$test_user" --setenv LOGNAME "$test_user" --setenv UID "$test_uid"
  --setenv LP_NUM_THREADS 1 --setenv OMP_NUM_THREADS 1 --setenv PYTHONDONTWRITEBYTECODE 1
  --setenv HOME /tmp/t/home --setenv XDG_RUNTIME_DIR /tmp/t/runtime --setenv TMPDIR /tmp/t/tmp
  --setenv XDG_CONFIG_HOME /tmp/t/home/.config --setenv XDG_DATA_HOME /tmp/t/home/.local/share
  --setenv XDG_CACHE_HOME /tmp/t/home/.cache --setenv XDG_STATE_HOME /tmp/t/home/.local/state
  --setenv DBUS_SYSTEM_BUS_ADDRESS unix:path=/run/no-system-bus --setenv CORNICE_TEST_DEVICE_FREE 1
  --setenv TEST_ROOT /opt/clipboard-unit-root --setenv TEST_SOURCE /opt/clipboard-unit-source
  --chdir /tmp/t /usr/bin/bash /tmp/t/build-run.sh)
printf '%q ' "${command[@]}" > "$artifacts/command.txt"
printf '\n' >> "$artifacts/command.txt"
set +e
"${command[@]}" 2>&1 | tee "$artifacts/run.log"
code=${PIPESTATUS[0]}
set -e
printf '%s\n' "$code" > "$artifacts/exit-code.txt"
date --iso-8601=ns > "$artifacts/end-time.txt"
systemctl --user show "$unit" -p Id -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent -p MemorySwapPeak -p CPUUsageNSec > "$artifacts/resource-after.txt" || true
printf 'Artifacts: %s\n' "$artifacts"
exit "$code"
