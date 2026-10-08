#!/usr/bin/env bash
# Headless nested compositors inside a device, PID, network and bus sandbox.
# The host checkout/configuration and desktop sockets remain read-only/hidden.
set -euo pipefail
ulimit -c 0
prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${CORNICE_TEST_HYPRLAND_SOURCE:?Set the fork checkout}"
export CORNICE_TEST_HYPRLAND=${CORNICE_TEST_HYPRLAND:-$CORNICE_TEST_HYPRLAND_SOURCE/build-agent-session/Hyprland}
[[ -x $CORNICE_TEST_HYPRLAND ]] || { echo 'Built fork missing' >&2; exit 1; }
suite=${1:-desktop-recovery-verify.py}
case "$suite" in
  desktop-recovery-verify.py|agent-desktop-verify.py|human-lock-verify.py|desktop-demo-record.py|capture-lock-race-verify.py) ;;
  *) echo 'Unknown isolated suite' >&2; exit 2 ;;
esac
artifacts=$(mktemp -d /tmp/cornice-agent-test.XXXXXX)
mkdir -m700 "$artifacts/home"
echo "Isolated artifacts: $artifacts"
# No host /dev/input, DRM card nodes, X11/Wayland sockets, systemd or system D-Bus.
# Separate PID/network namespaces also isolate abstract sockets and cleanup.
# Child processes cannot write to the real HOME, even through a legacy path.
exec nice -n 15 bwrap --unshare-all --die-with-parent --new-session \
  --ro-bind / / --dev /dev --proc /proc --tmpfs /run --tmpfs /tmp \
  --dir /dev/dri --dev-bind /dev/dri/renderD128 /dev/dri/renderD128 \
  --bind "$artifacts" /tmp/t \
  --setenv HOME /tmp/t/home --setenv TMPDIR /tmp/t \
  --setenv XDG_RUNTIME_DIR /tmp/t \
  --unsetenv LIBGL_ALWAYS_SOFTWARE --unsetenv GALLIUM_DRIVER \
  --setenv AQ_DRM_DEVICES /dev/null --setenv LIBSEAT_BACKEND noop \
  --setenv DBUS_SYSTEM_BUS_ADDRESS unix:path=/run/no-system-bus \
  --setenv CORNICE_TEST_SANDBOX 1 --setenv PYTHONDONTWRITEBYTECODE 1 \
  --unsetenv WAYLAND_DISPLAY --unsetenv WAYLAND_SOCKET --unsetenv DISPLAY \
  --unsetenv HYPRLAND_INSTANCE_SIGNATURE --unsetenv DBUS_SESSION_BUS_ADDRESS \
  -- /usr/bin/python3 "$prefix/test/$suite"
