#!/usr/bin/env bash
# benchmark — what did consolidating into one shell actually save?
#
# Measures resident memory (PSS, which counts shared pages proportionally) and
# CPU over a window, for:
#
#   legacy : waybar + mako + hypridle — the three daemons cornice replaces
#   cornice: the cornice shell (bar, notifications, idle, lock, panels, …)
#
# Usage:
#   ./test/benchmark.sh            # measure the running cornice
#   ./test/benchmark.sh --compare  # stop cornice, measure the legacy daemons,
#                                  # then restore cornice (touches your session!)
#   ./test/benchmark.sh --seconds 30 --json
#
# `--compare` refuses to run while the session is locked, and always tries to
# bring cornice back, even when interrupted.
set -uo pipefail

self=$(readlink -f "${BASH_SOURCE[0]}")
test_dir=$(dirname "$self")
prefix="${CORNICE_PATH:-$(cd "$test_dir/.." && pwd)}"
export CORNICE_PATH="$prefix"
export PATH="$prefix/bin:$PATH"

# The environment of a TTY is not the session's.
# shellcheck source=/dev/null
source "$prefix/bin/cornice-env.sh"

seconds=30
json=0
compare=0
while (($#)); do
  case "$1" in
    --seconds) shift; seconds="${1:-30}" ;;
    --json) json=1 ;;
    --compare) compare=1 ;;
    --legacy) compare=1 ;;
    -h | --help) sed -n '2,18p' "$self" | sed 's/^# \?//'; exit 0 ;;
    *) echo "benchmark: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift || true
done

have_proc=()
for name in waybar mako hypridle; do
  command -v "$name" >/dev/null 2>&1 && have_proc+=("$name")
done

# ---- measuring -------------------------------------------------------------
proc_tree() {
  # The process plus every descendant (a shell spawns helpers: gdbus, hyprctl).
  local root="$1" child
  printf '%s\n' "$root"
  for child in $(pgrep -P "$root" 2>/dev/null); do proc_tree "$child"; done
}

pss_kb() { # resident memory, shared pages counted proportionally
  local total=0 pid value
  for pid in $(proc_tree "$1"); do
    value=$(awk '/^Pss:/ {sum += $2} END {print sum + 0}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo 0)
    total=$((total + value))
  done
  printf '%s' "$total"
}

cpu_ticks() {
  local total=0 pid
  for pid in $(proc_tree "$1"); do
    [[ -r /proc/$pid/stat ]] || continue
    total=$((total + $(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0)))
  done
  printf '%s' "$total"
}

# measure <label> <pid...> → "label|rss_kb|cpu_percent"
measure() {
  local label="$1"
  shift
  local hertz first_ticks last_ticks ticks rss pids=("$@")
  hertz=$(getconf CLK_TCK 2>/dev/null || echo 100)

  local sum_first=0
  for pid in "${pids[@]}"; do sum_first=$((sum_first + $(cpu_ticks "$pid"))); done
  sleep "$seconds"
  local sum_last=0
  for pid in "${pids[@]}"; do sum_last=$((sum_last + $(cpu_ticks "$pid"))); done
  ticks=$((sum_last - sum_first))

  rss=0
  for pid in "${pids[@]}"; do rss=$((rss + $(pss_kb "$pid"))); done

  local cpu
  cpu=$(awk -v t="$ticks" -v h="$hertz" -v s="$seconds" 'BEGIN {printf "%.2f", (t / h) / s * 100}')
  printf '%s|%s|%s\n' "$label" "$rss" "$cpu"
}

running_pids() {
  local pid
  for name in "$@"; do
    for pid in $(pgrep -x "$name" 2>/dev/null); do printf '%s\n' "$pid"; done
  done
}

# ---- the two measurements --------------------------------------------------
declare -a results=()
restore_needed=0
legacy_started=0

restore_cornice() {
  ((restore_needed)) || return 0
  restore_needed=0
  if ((legacy_started)); then
    pkill -x waybar 2>/dev/null || true
    pkill -x mako 2>/dev/null || true
    pkill -x hypridle 2>/dev/null || true
    sleep 1
  fi
  echo "  restoring cornice…" >&2
  cornice start >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    cornice ping >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "  WARNING: cornice did not come back — run: cornice start" >&2
}
trap restore_cornice EXIT INT TERM

cornice_pid=$(pgrep -x quickshell | head -1)
if [[ -n $cornice_pid ]]; then
  echo "measuring cornice for ${seconds}s (pid $cornice_pid)…" >&2
  results+=("$(measure "cornice" "$cornice_pid")")
else
  echo "cornice is not running — start it, or use --compare to measure the legacy stack" >&2
fi

if ((compare)); then
  if [[ $(hyprctl locked 2>/dev/null || echo false) == "true" ]]; then
    echo "benchmark: refusing to swap shells while the session is locked" >&2
    exit 1
  fi
  if ((${#have_proc[@]} == 0)); then
    echo "benchmark: none of waybar/mako/hypridle are installed" >&2
    exit 1
  fi

  echo "stopping cornice and starting the legacy stack: ${have_proc[*]}" >&2
  cornice stop >/dev/null 2>&1 || true
  restore_needed=1
  for name in "${have_proc[@]}"; do
    setsid "$name" >/dev/null 2>&1 &
    disown || true
  done
  legacy_started=1
  sleep 4

  legacy_pids=()
  while IFS= read -r pid; do [[ -n $pid ]] && legacy_pids+=("$pid"); done < <(running_pids "${have_proc[@]}")
  if ((${#legacy_pids[@]} == 0)); then
    echo "benchmark: the legacy stack did not start" >&2
    exit 1
  fi
  echo "measuring ${have_proc[*]} for ${seconds}s (${#legacy_pids[@]} processes)…" >&2
  results+=("$(measure "legacy" "${legacy_pids[@]}")")
  restore_cornice
fi

# ---- report ----------------------------------------------------------------
if ((json)); then
  printf '['
  first=1
  for row in "${results[@]:-}"; do
    [[ -n $row ]] || continue
    IFS='|' read -r label rss cpu <<<"$row"
    ((first)) || printf ','
    first=0
    printf '{"name":"%s","pssMiB":%.1f,"cpuPercent":%s,"seconds":%s}' \
      "$label" "$(awk -v k="$rss" 'BEGIN {print k/1024}')" "$cpu" "$seconds"
  done
  printf ']\n'
  exit 0
fi

echo
printf '%-10s %12s %10s\n' "stack" "memory" "cpu (${seconds}s)"
printf '%-10s %12s %10s\n' "-----" "------" "---------"
for row in "${results[@]:-}"; do
  [[ -n $row ]] || continue
  IFS='|' read -r label rss cpu <<<"$row"
  printf '%-10s %9.1f MiB %9s%%\n' "$label" "$(awk -v k="$rss" 'BEGIN {print k/1024}')" "$cpu"
done

if ((${#results[@]} == 2)); then
  cornice_rss=$(awk -F'|' '$1=="cornice" {print $2}' <<<"${results[0]}")
  legacy_rss=$(awk -F'|' '$1=="legacy" {print $2}' <<<"${results[1]}")
  cornice_cpu=$(awk -F'|' '$1=="cornice" {print $3}' <<<"${results[0]}")
  legacy_cpu=$(awk -F'|' '$1=="legacy" {print $3}' <<<"${results[1]}")
  awk -v c="$cornice_rss" -v l="$legacy_rss" -v cc="$cornice_cpu" -v lc="$legacy_cpu" 'BEGIN {
    printf "\ncornice: %.0f MiB, %.2f%% cpu\n", c/1024, cc
    printf "legacy : %.0f MiB, %.2f%% cpu  (%d processes)\n", l/1024, lc, 3
    if (c < l) printf "→ cornice uses %.0f MiB less memory (%.0f%% of the legacy stack)\n", (l-c)/1024, (c/l)*100
    else printf "→ cornice uses %.0f MiB more memory (%.0f%% of the legacy stack)\n", (c-l)/1024, (c/l)*100
    if (cc < lc) printf "→ and %.2f%% less cpu\n", lc-cc
  }'
fi
