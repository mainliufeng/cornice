#!/usr/bin/env bash
# Installer regressions in temporary prefixes; never start a real service.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d /tmp/cornice-installer-XXXXXX)
trap 'rm -rf "$sandbox"' EXIT
tools="$sandbox/tools"
mkdir -p "$tools" "$sandbox/config/systemd/user"
for cmd in bash dirname readlink realpath basename mkdir cp chmod find rm mv ln ls wc mktemp grep head install jq python3 flock socat cmake ninja; do
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
[[ ${CORNICE_TEST_SYSTEMCTL_FAIL:-0} == 0 ]] || exit 1
if [[ $* == *'enable --now'* ]]; then
  [[ -x $CORNICE_TEST_LAUNCHER ]] || exit 9
fi
EOF
for cmd in wf-recorder ffprobe; do
  printf '#!/usr/bin/bash\nexit 0\n' >"$tools/$cmd"
  chmod +x "$tools/$cmd"
done
chmod +x "$tools/quickshell" "$tools/hyprctl" "$tools/systemctl"
export XDG_CONFIG_HOME="$sandbox/config"
export CORNICE_QS=""
export CORNICE_TEST_SYSTEMCTL_LOG="$sandbox/systemctl.log"
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

export CORNICE_TEST_SYSTEMCTL_FAIL=1
if PATH="$tools" "$repo/install.sh" --copy --service --prefix "$sandbox/failed-service" >"$sandbox/failed.log" 2>&1; then
  echo 'FAIL: failed systemctl reported success'; exit 1
fi
description='service failure still leaves a complete installation'; check test -x "$sandbox/failed-service/bin/cornice-launch"
description='service failure reports the actual failure'; check grep -q 'could not enable cornice.service' "$sandbox/failed.log"
for file in config/session-services.json shell/Commons/SessionServices.qml shell/plugins/notifications/Model.qml; do
  description="copy installation includes $file"
  check test -f "$sandbox/failed-service/share/cornice/$file"
done
# Use the actual packaging declaration, rather than mirroring the installer.
package_dependencies=$(startdir="$repo" bash -c 'source "$1"; printf "%s\n" "${depends[@]}"' shell "$repo/PKGBUILD")
description='package declares Python as an installed runtime dependency'; check grep -qx python <<<"$package_dependencies"
description='package declares jq independently of Python'; check grep -qx jq <<<"$package_dependencies"
echo 'install-test: all checks passed'
