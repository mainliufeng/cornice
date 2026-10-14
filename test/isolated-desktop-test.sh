#!/usr/bin/env bash
# Headless nested compositors inside a device, PID, network and bus sandbox.
# The host checkout/configuration and desktop sockets remain read-only/hidden.
set -euo pipefail
ulimit -c 0
prefix=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${CORNICE_TEST_RESOURCE_SCOPE:-} != 1 ]]; then
  exec "$prefix/test/resource-scope.sh" "$0" "$@"
fi
: "${CORNICE_TEST_HYPRLAND_SOURCE:?Set the fork checkout}"
export CORNICE_TEST_HYPRLAND=${CORNICE_TEST_HYPRLAND:-$CORNICE_TEST_HYPRLAND_SOURCE/build-agent-session/Hyprland}
[[ -x $CORNICE_TEST_HYPRLAND ]] || { echo 'Built fork missing' >&2; exit 1; }
suite=${1:-desktop-recovery-verify.py}
case "$suite" in
  session-ui-cold-update-verify.py|session-ui-update-verify.py|headless-verify.sh|install-verify.sh|screenshot-controller-verify.py|desktop-clipboard-verify.py|core-lifecycle-verify.py|browser-recovery-verify.py|desktop-product-ui-verify.py|session-services-verify.py|desktop-state-contract-verify.py|desktop-context-verify.py|launcher-native-seat-verify.py|screen-recording-verify.py|application-launch-config-verify.py|voice-overlay-verify.py|launcher-seat-regression.py|desktop-handoff-verify.py|native-accessibility-response-verify.py|native-accessibility-verify.py|desktop-acquire-verify.py|generic-seat-controller-verify.py|desktop-harness-verify.py|agent-product-verify.py|desktop-switcher-verify.py|desktop-preview-verify.py|desktop-recovery-verify.py|agent-desktop-verify.py|human-lock-verify.py|desktop-lock-continuity-verify.py|desktop-demo-record.py|capture-lock-race-verify.py|session-trial-verify.py|ime-session-verify.py|presentation-pacing-verify.py|agent-launcher-verify.py|workspace-response-verify.py|voice-seat-verify.py|layout-shortcuts-verify.py|seat-focus-lifecycle-verify.py|seat-action-routing-verify.py|seat-foreign-activation-verify.py|keyboard-capability-focus-verify.py) ;;
  *) echo 'Unknown isolated suite' >&2; exit 2 ;;
esac
# The selected binary may live under /tmp, which is hidden below. Bind only
# that executable read-only, rather than falling back to an older host build.
hyprland_mount=(--ro-bind "$CORNICE_TEST_HYPRLAND" "$CORNICE_TEST_HYPRLAND")
product_mount=()
if [[ -n ${CORNICE_TEST_PRODUCT:-} ]]; then
  product_mount=(--ro-bind "$CORNICE_TEST_PRODUCT" "$CORNICE_TEST_PRODUCT")
fi
if [[ -n ${CORNICE_TEST_UI_BASELINE:-} ]]; then
  product_mount+=(--ro-bind "$CORNICE_TEST_UI_BASELINE" "$CORNICE_TEST_UI_BASELINE")
fi
voice_mount=()
if [[ $suite == voice-seat-verify.py ]]; then
  : "${CORNICE_TEST_VOICE_PROBE:?Set the built Hyprvoice seat_input_probe}"
  voice_mount=(--ro-bind "$CORNICE_TEST_VOICE_PROBE" /tmp/voice-seat-probe --setenv CORNICE_TEST_VOICE_PROBE /tmp/voice-seat-probe)
fi
if [[ $suite == voice-overlay-verify.py ]]; then
  : "${CORNICE_TEST_VOICE_BINARY:?Set the built Hyprvoice binary}"
  voice_mount=(--ro-bind "$CORNICE_TEST_VOICE_BINARY" /tmp/voice-overlay-binary --setenv CORNICE_TEST_VOICE_BINARY /tmp/voice-overlay-binary)
fi
# Software is the safest default. Current Aquamarine requires DMA-BUF v4
# from its parent compositor, which Mutter's software renderer cannot offer.
# Explicitly selected render-only nodes permit offscreen rendering, never
# physical modesetting; the serial CPU/memory/process scope still applies.
render_args=(--setenv LIBGL_ALWAYS_SOFTWARE 1 --setenv GALLIUM_DRIVER llvmpipe)
if [[ -n ${CORNICE_TEST_RENDER_NODE:-} ]]; then
  [[ $CORNICE_TEST_RENDER_NODE =~ ^/dev/dri/renderD[0-9]+$ && -c $CORNICE_TEST_RENDER_NODE ]] || {
    echo 'Only an existing DRM render node may be exposed to isolated tests' >&2; exit 2;
  }
  render_args=(--dir /dev/dri --dev-bind "$CORNICE_TEST_RENDER_NODE" "$CORNICE_TEST_RENDER_NODE"
    --unsetenv LIBGL_ALWAYS_SOFTWARE --unsetenv GALLIUM_DRIVER)
fi
artifacts_root=${CORNICE_TEST_ARTIFACT_ROOT:-/tmp}
if [[ -n ${CORNICE_TEST_ARTIFACT_ROOT:-} ]] && [[ $artifacts_root != /* || ! -d $artifacts_root || ! -O $artifacts_root ]]; then
  echo 'CORNICE_TEST_ARTIFACT_ROOT must be an existing absolute directory owned by the test user' >&2
  exit 2
fi
artifacts=$(mktemp -d "$artifacts_root/cornice-agent-test.XXXXXX")
mkdir -m700 "$artifacts/home"
if [[ $suite == native-accessibility-verify.py ]]; then
  c++ -std=c++20 -fPIC -pie "$prefix/test/native-accessibility-qt.cpp" $(pkg-config --cflags --libs Qt6Widgets) -o "$artifacts/native-accessibility-qt"
fi
echo "Isolated artifacts: $artifacts"
# No host input, DRM modesetting/card devices, desktop sockets or system bus.
# Separate PID/network namespaces also isolate abstract sockets and cleanup.
# Child processes cannot write to the real HOME, even through a legacy path.
interpreter=/usr/bin/python3
[[ $suite != *.sh ]] || interpreter=/usr/bin/bash
exec nice -n 15 bwrap --unshare-all --die-with-parent --new-session \
  --ro-bind / / --dev /dev --proc /proc --tmpfs /run --tmpfs /tmp \
  --bind "$artifacts" /tmp/t "${product_mount[@]}" "${hyprland_mount[@]}" "${voice_mount[@]}" \
  --setenv HOME /tmp/t/home --setenv TMPDIR /tmp/t \
  --setenv XDG_CONFIG_HOME /tmp/t/home/.config \
  --setenv XDG_DATA_HOME /tmp/t/home/.local/share \
  --setenv XDG_STATE_HOME /tmp/t/home/.local/state \
  --setenv XDG_RUNTIME_DIR /tmp/t --setenv CORNICE_PATH "$prefix" \
  "${render_args[@]}" \
  --setenv LP_NUM_THREADS 2 --setenv OMP_NUM_THREADS 2 \
  --setenv AQ_DRM_DEVICES /dev/null --setenv LIBSEAT_BACKEND noop \
  --setenv DBUS_SYSTEM_BUS_ADDRESS unix:path=/run/no-system-bus \
  --setenv CORNICE_TEST_SANDBOX 1 --setenv PYTHONDONTWRITEBYTECODE 1 \
  --setenv CORNICE_TEST_HYPRLAND_CONFIG_FORMAT lua \
  --unsetenv WAYLAND_DISPLAY --unsetenv WAYLAND_SOCKET --unsetenv DISPLAY \
  --unsetenv HYPRLAND_INSTANCE_SIGNATURE --unsetenv DBUS_SESSION_BUS_ADDRESS \
  --unsetenv HYPRLAND_ACTION_ID --unsetenv HYPRLAND_SEAT_NAME --unsetenv HYPRLAND_SEAT_ID \
  --unsetenv HYPRLAND_SEAT_GENERATION --unsetenv HYPRLAND_SEAT_OUTPUT \
  --unsetenv CORNICE_TRIAL_STATE_DIR --unsetenv CORNICE_DESKTOP_NAME \
  --unsetenv CORNICE_DESKTOP_OUTPUT --unsetenv CORNICE_SHELL_SOCKET \
  --unsetenv CORNICE_PRIMARY_SHELL_SOCKET \
  -- "$interpreter" "$prefix/test/$suite"
