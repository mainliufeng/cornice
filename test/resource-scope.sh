#!/usr/bin/env bash
# One bounded test/build at a time. Failure to create the scope is a hard error.
set -euo pipefail
[[ $# -gt 0 ]] || { echo "Usage: resource-scope.sh COMMAND [ARG...]" >&2; exit 2; }
command -v systemd-run >/dev/null
command -v flock >/dev/null
# Multiple real Chromium desktops need more threads while retaining the same
# CPU/memory/device limits. Keep the ordinary default and bound explicit overrides.
task_limit=${CORNICE_TEST_TASKS_MAX:-512}
if [[ ! $task_limit =~ ^[0-9]+$ || ${#task_limit} -gt 4 ]] || ((10#$task_limit < 32 || 10#$task_limit > 1024)); then
  echo 'CORNICE_TEST_TASKS_MAX must be an integer between 32 and 1024' >&2
  exit 2
fi
unit="cornice-isolated-test-${UID}-$$"
exec flock "/tmp/cornice-isolated-test-${UID}.lock" \
  systemd-run --user --scope --quiet --collect --expand-environment=no \
  --unit="$unit" --description="Isolated Cornice validation" \
  --property=CPUQuota=200% --property=MemoryMax=3G \
  --property=MemorySwapMax=0 --property=TasksMax="$task_limit" \
  --property=RuntimeMaxSec=20min \
  /usr/bin/env CORNICE_TEST_RESOURCE_SCOPE=1 "$@"
