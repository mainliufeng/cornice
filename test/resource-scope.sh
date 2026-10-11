#!/usr/bin/env bash
# One bounded test/build at a time. Failure to create the scope is a hard error.
set -euo pipefail
[[ $# -gt 0 ]] || { echo "Usage: resource-scope.sh COMMAND [ARG...]" >&2; exit 2; }
command -v systemd-run >/dev/null
command -v flock >/dev/null
unit="cornice-isolated-test-${UID}-$$"
exec flock "/tmp/cornice-isolated-test-${UID}.lock" \
  systemd-run --user --scope --quiet --collect --expand-environment=no \
  --unit="$unit" --description="Isolated Cornice validation" \
  --property=CPUQuota=200% --property=MemoryMax=3G \
  --property=MemorySwapMax=0 --property=TasksMax=512 \
  --property=RuntimeMaxSec=20min \
  /usr/bin/env CORNICE_TEST_RESOURCE_SCOPE=1 "$@"
