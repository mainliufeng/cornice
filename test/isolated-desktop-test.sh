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
  desktop-handoff-verify.py|native-accessibility-response-verify.py|native-accessibility-verify.py|desktop-acquire-verify.py|generic-seat-controller-verify.py|desktop-harness-verify.py|agent-product-verify.py|desktop-switcher-verify.py|desktop-preview-verify.py|desktop-recovery-verify.py|agent-desktop-verify.py|human-lock-verify.py|desktop-demo-record.py|capture-lock-race-verify.py|session-trial-verify.py|ime-session-verify.py|presentation-pacing-verify.py|agent-launcher-verify.py|workspace-response-verify.py|voice-seat-verify.py|layout-shortcuts-verify.py|seat-focus-lifecycle-verify.py|seat-action-routing-verify.py|seat-foreign-activation-verify.py) ;;
  *) echo 'Unknown isolated suite' >&2; exit 2 ;;
esac
product_mount=()
if [[ -n ${CORNICE_TEST_PRODUCT:-} ]]; then
  product_mount=(--ro-bind "$CORNICE_TEST_PRODUCT" "$CORNICE_TEST_PRODUCT")
fi
voice_mount=()
if [[ $suite == voice-seat-verify.py ]]; then
  : "${CORNICE_TEST_VOICE_PROBE:?Set the built Hyprvoice seat_input_probe}"
  voice_mount=(--ro-bind "$CORNICE_TEST_VOICE_PROBE" /tmp/voice-seat-probe --setenv CORNICE_TEST_VOICE_PROBE /tmp/voice-seat-probe)
fi
artifacts=$(mktemp -d /tmp/cornice-agent-test.XXXXXX)
mkdir -m700 "$artifacts/home"
if [[ $suite == native-accessibility-verify.py ]]; then
  c++ -std=c++20 -fPIC -pie "$prefix/test/native-accessibility-qt.cpp" $(pkg-config --cflags --libs Qt6Widgets) -o "$artifacts/native-accessibility-qt"
fi
echo "Isolated artifacts: $artifacts"
# No host /dev/input, DRM card nodes, X11/Wayland sockets, systemd or system D-Bus.
# Separate PID/network namespaces also isolate abstract sockets and cleanup.
# Child processes cannot write to the real HOME, even through a legacy path.
exec nice -n 15 bwrap --unshare-all --die-with-parent --new-session \
  --ro-bind / / --dev /dev --proc /proc --tmpfs /run --tmpfs /tmp \
  --dir /dev/dri --dev-bind /dev/dri/renderD128 /dev/dri/renderD128 \
  --bind "$artifacts" /tmp/t "${product_mount[@]}" "${voice_mount[@]}" \
  --setenv HOME /tmp/t/home --setenv TMPDIR /tmp/t \
  --setenv XDG_RUNTIME_DIR /tmp/t \
  --unsetenv LIBGL_ALWAYS_SOFTWARE --unsetenv GALLIUM_DRIVER \
  --setenv AQ_DRM_DEVICES /dev/null --setenv LIBSEAT_BACKEND noop \
  --setenv DBUS_SYSTEM_BUS_ADDRESS unix:path=/run/no-system-bus \
  --setenv CORNICE_TEST_SANDBOX 1 --setenv PYTHONDONTWRITEBYTECODE 1 \
  --unsetenv WAYLAND_DISPLAY --unsetenv WAYLAND_SOCKET --unsetenv DISPLAY \
  --unsetenv HYPRLAND_INSTANCE_SIGNATURE --unsetenv DBUS_SESSION_BUS_ADDRESS \
  --unsetenv HYPRLAND_ACTION_ID --unsetenv HYPRLAND_SEAT_NAME --unsetenv HYPRLAND_SEAT_ID \
  --unsetenv HYPRLAND_SEAT_GENERATION --unsetenv HYPRLAND_SEAT_OUTPUT \
  --unsetenv CORNICE_TRIAL_STATE_DIR \
  -- /usr/bin/python3 "$prefix/test/$suite"
