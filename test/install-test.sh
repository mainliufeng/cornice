#!/usr/bin/env bash
# Installer regressions in temporary prefixes; never start a real service.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d /tmp/cornice-installer-XXXXXX)
install_a=""
install_b=""
cleanup() {
  [[ -z ${gate:-} ]] || printf 'release\n' >"$gate.release" || true
  for child in "$install_a" "$install_b"; do
    [[ -z $child ]] && continue
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  done
  rm -rf "$sandbox"
}
trap cleanup EXIT
tools="$sandbox/tools"
mkdir -p "$tools" "$sandbox/config/systemd/user"
for cmd in bash dirname readlink realpath basename mkdir cp chmod find rm mv ln ls wc mktemp grep head install jq python3 flock socat cmake ninja sleep; do
  ln -s "$(command -v "$cmd")" "$tools/$cmd"
done
cat >"$tools/quickshell" <<'EOF'
#!/usr/bin/bash
echo 'quickshell installer fixture'
EOF
cat >"$tools/hyprctl" <<'EOF'
#!/usr/bin/bash
exit 0
EOF
cat >"$tools/systemctl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >>"$CORNICE_TEST_SYSTEMCTL_LOG"
enabled=disabled
active=inactive
[[ ! -f $CORNICE_TEST_SYSTEMCTL_STATE ]] || source "$CORNICE_TEST_SYSTEMCTL_STATE"
save() { printf 'enabled=%s\nactive=%s\n' "$enabled" "$active" >"$CORNICE_TEST_SYSTEMCTL_STATE"; }
case "$*" in
  *'is-enabled cornice.service') printf '%s\n' "$enabled"; [[ $enabled == enabled* ]]; exit ;;
  *'is-active cornice.service') printf '%s\n' "$active"; [[ $active == active ]]; exit ;;
esac
[[ ${CORNICE_TEST_SYSTEMCTL_FAIL:-0} == 0 ]] || exit 1
case "$*" in
  *' enable '*|*' enable')
    if [[ $* == *'--runtime'* ]]; then enabled=enabled-runtime; else enabled=enabled; fi
    save
    if [[ $* == *'--now'* ]]; then
      [[ -x $CORNICE_TEST_LAUNCHER ]] || exit 9
      if [[ -n ${CORNICE_TEST_SYSTEMCTL_GATE:-} ]]; then
        printf 'waiting\n' >"$CORNICE_TEST_SYSTEMCTL_GATE.ready"
        while [[ ! -f $CORNICE_TEST_SYSTEMCTL_GATE.release ]]; do sleep 0.05; done
      fi
      if [[ ${CORNICE_TEST_SYSTEMCTL_FAIL_START:-0} == 1 ]]; then
        [[ $active == active ]] || active=failed
        save; exit 1
      fi
      active=active; save
    fi ;;
  *' disable '*) enabled=disabled; save ;;
  *' stop '*) active=inactive; save ;;
esac
EOF
for cmd in wf-recorder ffprobe; do
  printf '#!/usr/bin/bash\nexit 0\n' >"$tools/$cmd"
  chmod +x "$tools/$cmd"
done
chmod +x "$tools/quickshell" "$tools/hyprctl" "$tools/systemctl"
export HOME="$sandbox/home"
export XDG_STATE_HOME="$sandbox/state"
mkdir -p "$HOME" "$XDG_STATE_HOME"
export XDG_CONFIG_HOME="$sandbox/config"
export CORNICE_QS=""
export CORNICE_TEST_SYSTEMCTL_LOG="$sandbox/systemctl.log"
export CORNICE_TEST_SYSTEMCTL_STATE="$sandbox/service-state"
export CORNICE_TEST_LAUNCHER="$sandbox/install % prefix/bin/cornice-launch"
unit="$XDG_CONFIG_HOME/systemd/user/cornice.service"
printf 'existing owner unit\n' >"$unit"
cp "$unit" "$sandbox/original.service"

check() {
  if "$@"; then printf '  PASS  %s\n' "$description";
  else printf '  FAIL  %s\n' "$description"; exit 1; fi
}
if PATH="$tools" "$repo/test/install-verify.sh" --package >"$sandbox/package.log" 2>&1; then
  echo 'FAIL: missing makepkg accepted'; exit 1
fi
description='requested package validation fails when makepkg is missing'; check grep -q -- '--package requires makepkg' "$sandbox/package.log"
if "$repo/test/install-verify.sh" --packages >"$sandbox/arguments.log" 2>&1; then
  echo 'FAIL: unknown release-gate argument accepted'; exit 1
fi
description='unknown release-gate arguments fail before running'; check grep -q 'usage:' "$sandbox/arguments.log"

mv "$tools/quickshell" "$sandbox/quickshell"
if PATH="$tools" "$repo/install.sh" --service --prefix "$sandbox/missing" >"$sandbox/missing.log" 2>&1; then
  echo 'FAIL: missing quickshell accepted'; exit 1
fi
description='missing dependencies preserve the existing unit'; check cmp "$unit" "$sandbox/original.service"
description='missing dependencies never call systemctl'; check test ! -e "$CORNICE_TEST_SYSTEMCTL_LOG"
description='missing dependencies never install helpers'; check test ! -d "$sandbox/missing/bin"
mv "$sandbox/quickshell" "$tools/quickshell"

# A missing runtime dependency must be reported before any install or service
# change. Keeping jq installed proves Python is not a manifest-reader fallback.
mv "$tools/python3" "$sandbox/python3"
if PATH="$tools" "$repo/install.sh" --service --prefix "$sandbox/missing-python" >"$sandbox/missing-python.log" 2>&1; then
  echo 'FAIL: missing Python accepted'; exit 1
fi
description='Python is independently required for the primary endpoint'; check grep -q 'python3 not found' "$sandbox/missing-python.log"
description='missing Python preserves the existing unit'; check cmp "$unit" "$sandbox/original.service"
description='missing Python never calls systemctl'; check test ! -e "$CORNICE_TEST_SYSTEMCTL_LOG"
description='missing Python never installs helpers'; check test ! -d "$sandbox/missing-python/bin"
if PATH="$tools" HYPRLAND_INSTANCE_SIGNATURE=installer-fixture XDG_RUNTIME_DIR="$sandbox/runtime" "$repo/bin/cornice-doctor" >"$sandbox/doctor-python.log" 2>&1; then
  echo 'FAIL: doctor accepted missing Python'; exit 1
fi
description='doctor reports the missing primary endpoint dependency'; check grep -q 'python3 not found' "$sandbox/doctor-python.log"
mv "$sandbox/python3" "$tools/python3"
# The doctor fixture never talks to the real user manager. Clear its read-only
# diagnostic entries before proving the following install service operations.
rm -f "$CORNICE_TEST_SYSTEMCTL_LOG"

mkdir -p "$sandbox/install % prefix/bin"
ln -s "$repo/bin/cornice-agent-runtime" "$sandbox/install % prefix/bin/cornice-agent-runtime"
PATH="$tools" "$repo/install.sh" --service --prefix "$sandbox/install % prefix" >"$sandbox/service.log" 2>&1
description='upgrade removes a retired internal-agent helper even when its old symlink is broken'; check test ! -L "$sandbox/install % prefix/bin/cornice-agent-runtime"
description='the service starts only after the launcher exists'; check grep -q 'enable --now' "$CORNICE_TEST_SYSTEMCTL_LOG"
description='the service uses the selected prefix and escapes percent signs'; check grep -qF "ExecStart=:/usr/bin/env -- \"$sandbox/install %% prefix/bin/cornice-launch\"" "$unit"
backups=("$XDG_CONFIG_HOME"/systemd/user/cornice.service.backup.*)
description='the previous unit is backed up byte for byte'; check cmp "${backups[0]}" "$sandbox/original.service"
if command -v systemd-analyze >/dev/null 2>&1; then
  description='systemd accepts the generated service'; check systemd-analyze --user verify "$unit"
fi

special_prefix="$sandbox/special \"quote\" \\ \$value % prefix"
export CORNICE_TEST_LAUNCHER="$special_prefix/bin/cornice-launch"
PATH="$tools" "$repo/install.sh" --service --prefix "$special_prefix" >"$sandbox/special.log" 2>&1
if command -v systemd-analyze >/dev/null 2>&1; then
  description='systemd accepts arguments containing quotes, backslashes and dollars'; check systemd-analyze --user verify "$unit"
fi

cp "$unit" "$sandbox/before-failed-service"
export CORNICE_TEST_SYSTEMCTL_FAIL=1
if PATH="$tools" "$repo/install.sh" --copy --service --prefix "$sandbox/failed-service" >"$sandbox/failed.log" 2>&1; then
  echo 'FAIL: failed systemctl reported success'; exit 1
fi
description='service failure still leaves a complete installation'; check test -x "$sandbox/failed-service/bin/cornice-launch"
description='service failure reports the actual failure'; check grep -q 'could not enable cornice.service' "$sandbox/failed.log"
description='service failure restores the previous user unit'; check cmp "$unit" "$sandbox/before-failed-service"
for file in config/session-services.json shell/Commons/SessionServices.qml shell/plugins/notifications/Model.qml; do
  description="copy installation includes $file"
  check test -f "$sandbox/failed-service/share/cornice/$file"
done
# A failed start can leave enablement changed. Exercise the complete upgrade
# rollback with a real temporary tree and a stateful, fake user manager.
unset CORNICE_TEST_SYSTEMCTL_FAIL
upgrade_prefix="$sandbox/failed-upgrade"
PATH="$tools" "$repo/install.sh" --copy --prefix "$upgrade_prefix" >"$sandbox/upgrade-old.log" 2>&1
printf 'previous installed tree\n' >"$upgrade_prefix/share/cornice/old-marker"
export CORNICE_TEST_LAUNCHER="$upgrade_prefix/bin/cornice-launch"
cp "$unit" "$sandbox/unit-before-partial"
for prior in disabled enabled-runtime; do
  printf 'enabled=%s\nactive=inactive\n' "$prior" >"$CORNICE_TEST_SYSTEMCTL_STATE"
  export CORNICE_TEST_SYSTEMCTL_FAIL_START=1
  if PATH="$tools" "$repo/install.sh" --copy --service --prefix "$upgrade_prefix" >"$sandbox/partial-$prior.log" 2>&1; then
    echo 'FAIL: partial enable/start failure reported success'; exit 1
  fi
  description="failed start restores prior $prior service enablement"; check grep -qx "enabled=$prior" "$CORNICE_TEST_SYSTEMCTL_STATE"
  description='failed start restores the previous complete installed tree'; check test -f "$upgrade_prefix/share/cornice/old-marker"
  description='failed start restores the previous unit'; check cmp "$unit" "$sandbox/unit-before-partial"
done
unset CORNICE_TEST_SYSTEMCTL_FAIL_START

# Use a private source fixture so the takeover request can fail without ever
# scanning or stopping real desktop daemons. All service operations remain fake.
fixture="$sandbox/takeover-source"
mkdir -p "$fixture/bin" "$fixture/native/qml/Cornice/Platform"
cp "$repo/install.sh" "$fixture/install.sh"
cp -r "$repo/bin/." "$fixture/bin/"
for directory in shell i18n themes wallpapers config docs plugins; do
  [[ ! -d $repo/$directory ]] || ln -s "$repo/$directory" "$fixture/$directory"
done
ln -s "$repo/native/agent" "$fixture/native/agent"
ln -s "$repo/native/platform-build/libcornice_platform.so" "$fixture/native/qml/Cornice/Platform/libcornice_platform.so"
cat >"$fixture/bin/cornice-takeover" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >"$CORNICE_TEST_TAKEOVER_LOG"
exit 42
EOF
chmod +x "$fixture/bin/cornice-takeover"
export CORNICE_TEST_TAKEOVER_LOG="$sandbox/takeover.log"
for prior_active in inactive active; do
  if [[ $prior_active == active ]]; then prior_enabled=enabled; else prior_enabled=disabled; fi
  printf 'enabled=%s\nactive=%s\n' "$prior_enabled" "$prior_active" >"$CORNICE_TEST_SYSTEMCTL_STATE"
  : >"$CORNICE_TEST_SYSTEMCTL_LOG"
  if PATH="$tools" "$fixture/install.sh" --copy --service --takeover --prefix "$upgrade_prefix" >"$sandbox/takeover-$prior_active.log" 2>&1; then
    echo 'FAIL: explicit takeover failure reported success'; exit 1
  fi
  description='the explicitly requested takeover failure is reported'; check grep -q 'requested takeover failed' "$sandbox/takeover-$prior_active.log"
  description='takeover receives only the requested apply/reload arguments'; check grep -qx -- '--apply --reload' "$CORNICE_TEST_TAKEOVER_LOG"
  description='takeover failure restores the installed tree'; check test -f "$upgrade_prefix/share/cornice/old-marker"
  description='takeover failure restores service activity'; check grep -qx "active=$prior_active" "$CORNICE_TEST_SYSTEMCTL_STATE"
  description='takeover failure restores service enablement'; check grep -qx "enabled=$prior_enabled" "$CORNICE_TEST_SYSTEMCTL_STATE"
  if [[ $prior_active == active ]]; then
    description='rollback never stops the previously running service'; check bash -c '! grep -q "stop cornice.service" "$1"' shell "$CORNICE_TEST_SYSTEMCTL_LOG"
  else
    description='rollback stops only the newly started service'; check grep -q 'stop cornice.service' "$CORNICE_TEST_SYSTEMCTL_LOG"
  fi
done
# Prefixes share the same user unit. Hold the first install in a fake service
# start, then prove the second has reached the installer but cannot publish or
# overwrite the unit while the first transaction rolls back.
printf 'enabled=disabled\nactive=inactive\n' >"$CORNICE_TEST_SYSTEMCTL_STATE"
concurrent_a="$sandbox/concurrent-a"
concurrent_b="$sandbox/concurrent-b"
gate="$sandbox/concurrent-gate"
CORNICE_TEST_LAUNCHER="$concurrent_a/bin/cornice-launch" CORNICE_TEST_SYSTEMCTL_GATE="$gate" CORNICE_TEST_SYSTEMCTL_FAIL_START=1 PATH="$tools" \
  "$repo/install.sh" --copy --service --prefix "$concurrent_a" >"$sandbox/concurrent-a.log" 2>&1 &
install_a=$!
python3 - "$gate.ready" "$install_a" <<'PYWAIT'
import os, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(200):
    if path.exists(): break
    os.kill(int(sys.argv[2]), 0); time.sleep(.05)
else: raise SystemExit('first installer did not reach private service gate')
PYWAIT
cp "$unit" "$sandbox/concurrent-held-unit"
CORNICE_TEST_LAUNCHER="$concurrent_b/bin/cornice-launch" PATH="$tools" \
  "$repo/install.sh" --copy --service --prefix "$concurrent_b" >"$sandbox/concurrent-b.log" 2>&1 &
install_b=$!
python3 - "$sandbox/concurrent-b.log" "$install_b" <<'PYWAIT'
import os, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(200):
    if path.exists() and 'Installing' in path.read_text(): break
    os.kill(int(sys.argv[2]), 0); time.sleep(.05)
else: raise SystemExit('second installer did not reach its install operation')
time.sleep(.2)
PYWAIT
description='a different prefix cannot replace the unit during another install transaction'; check cmp "$unit" "$sandbox/concurrent-held-unit"
description='a queued install does not publish helpers before the previous rollback'; check test ! -d "$concurrent_b/bin"
printf 'continue\n' >"$gate.release"
if wait "$install_a"; then install_a=""; echo 'FAIL: gated start failure reported success'; exit 1; fi
install_a=""
wait "$install_b"
install_b=""
description='the queued install succeeds after the previous transaction restores state'; check grep -qF "$concurrent_b/bin/cornice-launch" "$unit"
description='the succeeding transaction retains its enabled service state'; check grep -qx 'enabled=enabled' "$CORNICE_TEST_SYSTEMCTL_STATE"
description='the succeeding transaction retains its active service state'; check grep -qx 'active=active' "$CORNICE_TEST_SYSTEMCTL_STATE"
# Use the actual packaging declaration, rather than mirroring the installer.
package_dependencies=$(startdir="$repo" bash -c 'source "$1"; printf "%s\n" "${depends[@]}"' shell "$repo/PKGBUILD")
description='package declares Python as an installed runtime dependency'; check grep -qx python <<<"$package_dependencies"
description='package declares jq independently of Python'; check grep -qx jq <<<"$package_dependencies"
echo 'install-test: all checks passed'
