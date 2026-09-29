#!/usr/bin/env bash
# install-verify — does a *fresh* install actually work?
#
# The other suites test the working tree. This one installs cornice the way a
# user would (install.sh --copy, or the built package), then runs the headless
# suite against that tree — with an empty sandbox config, so the shipped
# defaults, the shipped wallpaper and the plugin manifests are what gets tested.
#
#   ./test/install-verify.sh            # install.sh --copy into a temp prefix
#   ./test/install-verify.sh --package  # also build the PKGBUILD and test that
#
# Exit code is the suite's, so it works as a release gate.
set -uo pipefail

self=$(readlink -f "${BASH_SOURCE[0]}")
test_dir=$(dirname "$self")
prefix="${CORNICE_PATH:-$(cd "$test_dir/.." && pwd)}"
export CORNICE_PATH="$prefix"

with_package=0
[[ ${1:-} == "--package" ]] && with_package=1

tmp=$(mktemp -d /tmp/cornice-install-XXXXXX)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

failures=0

# What a user gets is what git tracks — not the working tree. Testing the working
# tree hid a real bug once: `*.png` in .gitignore meant the shipped default
# wallpaper was never in the repository, so a fresh clone had no background.
echo "== 0/… export the tracked tree (what a clone contains)"
mkdir -p "$tmp/source"
git -C "$prefix" archive HEAD | tar -x -C "$tmp/source"
if [[ ! -f $tmp/source/wallpapers/default.png ]]; then
  echo "  FAIL: wallpapers/default.png is not tracked (a fresh clone would have no default wallpaper)"
  failures=$((failures + 1))
fi
if [[ ! -f $tmp/source/LICENSE ]]; then
  echo "  FAIL: LICENSE is not tracked"
  failures=$((failures + 1))
fi

run_against() {
  local label="$1" root="$2"
  echo
  echo "──────────────────────────────────────────────────────────────"
  echo "installed tree: $label"
  echo "  root: $root"
  if [[ ! -f $root/shell/shell.qml ]]; then
    echo "  FAIL: no shell.qml under $root"
    failures=$((failures + 1))
    return 1
  fi
  CORNICE_INSTALLED_PREFIX="$root" "$test_dir/headless-verify.sh"
  local status=$?
  if ((status != 0)); then failures=$((failures + 1)); fi
  return "$status"
}

echo "  tracked files: $(git -C "$prefix" ls-files | wc -l), exported: $(find "$tmp/source" -type f | wc -l)"
echo "== 1/… install.sh --copy (from the exported tree)"
"$tmp/source/install.sh" --copy --prefix "$tmp/prefix" >"$tmp/install.log" 2>&1 \
  || { echo "install.sh failed:"; tail -5 "$tmp/install.log"; exit 1; }
# Every helper the repo ships must be installed and resolve: a stale install once
# left a helper out, and the shell then failed to act on tray menu clicks.
missing_helpers=()
while IFS= read -r helper; do
  [[ -n $helper ]] || continue
  [[ -x "$tmp/prefix/bin/$helper" ]] || missing_helpers+=("$helper")
done < <(find "$tmp/source/bin" -maxdepth 1 -name 'cornice*' ! -name '*.sh' -printf '%f\n' | sort)
if ((${#missing_helpers[@]} == 0)); then
  echo "  all shipped helpers are installed"
else
  echo "  FAIL: not installed: ${missing_helpers[*]}"
  failures=$((failures + 1))
fi

run_against "install.sh --copy" "$tmp/prefix/share/cornice"

if ((with_package)); then
  echo
  echo "== 2/… PKGBUILD"
  if ! command -v makepkg >/dev/null 2>&1; then
    echo "  makepkg not available; skipping the package test"
  else
    (cd "$prefix" && makepkg -f --nodeps >"$tmp/makepkg.log" 2>&1) \
      || { echo "makepkg failed:"; tail -10 "$tmp/makepkg.log"; exit 1; }
    package=$(find "$prefix" -maxdepth 1 -name 'cornice-*.pkg.tar.zst' | head -1)
    if [[ -z $package ]]; then
      echo "  FAIL: makepkg produced no package"
      failures=$((failures + 1))
    else
      echo "  package: $(basename "$package")"
      mkdir -p "$tmp/root"
      bsdtar -xf "$package" -C "$tmp/root"
      run_against "$(basename "$package")" "$tmp/root/usr/share/cornice"
    fi
  fi
fi

echo
if ((failures == 0)); then
  echo "install-verify: a fresh install works (including the shipped defaults)"
  exit 0
fi
echo "install-verify: $failures installed-tree run(s) failed"
exit 1
