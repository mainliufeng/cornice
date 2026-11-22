# Local Arch build of the shell for stock Hyprland. Build from a clean checkout
# at a recorded commit. Installation via pacman adds files only. For a separate
# multi-seat installation, see docs/source-install.md and docs/install-arch.md.

pkgname=cornice-git
_source_revision=$(git -C "$startdir" rev-parse --verify HEAD)
pkgver=r$(git -C "$startdir" rev-list --count "$_source_revision").${_source_revision:0:12}
pkgrel=1
pkgdesc="Cornice shell for stock Hyprland: bar, panels, notifications, launcher, lock, idle"
arch=('x86_64' 'aarch64')
url="https://github.com/mainliufeng/cornice"
license=('MIT')
# glib2 provides gdbus (the logind monitor for suspend/lid locking) and curl is
# what the weather plugin fetches with. Python handles local shell IPC.
depends=('bash' 'quickshell' 'hyprland' 'jq' 'python' 'glib2' 'curl' 'util-linux' 'procps-ng' 'qt6-base' 'qt6-declarative' 'socat')
makedepends=('cmake' 'git' 'ninja')
optdepends=(
  'grim: screenshots for `cornice verify`'
  'hyprlock: provides the default PAM service for lock and idle locking'
  'wireplumber: volume/microphone panels'
  'bluez: bluetooth panel'
  'brightnessctl: brightness keys and OSD'
  'cliphist: clipboard history overlay'
  'light: idle dimming'
  'networkmanager: network panel'
  'ttf-nerd-fonts-symbols: bar glyphs'
  'wf-recorder: screen recording backend'
  'ffmpeg: screen recording validation via ffprobe'
)
provides=('cornice')
conflicts=('cornice')

# The local Git checkout is the source. No downloads occur in build/package.
source=()
options=('!strip')

prepare() {
  local checkout="$srcdir/cornice-source"
  rm -rf -- "$checkout"
  mkdir -p "$checkout"
  git -C "$startdir" archive "$_source_revision" | bsdtar -xf - -C "$checkout"
  if ! cmp -s "$startdir/PKGBUILD" "$checkout/PKGBUILD"; then
    printf 'Build the committed PKGBUILD from a Git checkout.\n' >&2
    return 1
  fi
}

build() {
  cmake -S "$srcdir/cornice-source/native/platform" -B "$srcdir/platform-build" -G Ninja -DCMAKE_BUILD_TYPE=Release
  cmake --build "$srcdir/platform-build" --parallel "${CORNICE_BUILD_JOBS:-2}"
}

package() {
  local checkout="$srcdir/cornice-source"
  install -dm755 "$pkgdir/usr/share/cornice"
  for dir in bin shell i18n themes wallpapers config docs; do
    cp -r "$checkout/$dir" "$pkgdir/usr/share/cornice/"
  done
  find "$pkgdir/usr/share/cornice" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "$pkgdir/usr/share/cornice" -name '*.qmlc' -delete 2>/dev/null || true

  # Keep the optional desktop clients available to the separate native addon,
  # but never copy node_modules or generated files from a developer checkout.
  install -dm755 "$pkgdir/usr/share/cornice/native/agent"
  find "$checkout/native/agent" -maxdepth 1 -type f -exec cp -- {} "$pkgdir/usr/share/cornice/native/agent/" \;
  cp -r "$checkout/plugins" "$pkgdir/usr/share/cornice/"
  install -dm755 "$pkgdir/usr/bin"
  local f name
  for f in "$pkgdir"/usr/share/cornice/bin/cornice*; do
    [[ -f $f ]] || continue
    name=$(basename "$f")
    chmod 755 "$f"
    ln -s "/usr/share/cornice/bin/$name" "$pkgdir/usr/bin/$name"
  done

  cmake --install "$srcdir/platform-build" --prefix "$pkgdir/usr/share/cornice"
  "$checkout/packaging/check-runtime.sh" "$pkgdir/usr/share/cornice" --no-desktop

  install -Dm644 "$checkout/README.md" "$pkgdir/usr/share/doc/cornice/README.md"
  install -Dm644 "$checkout/README.zh-CN.md" "$pkgdir/usr/share/doc/cornice/README.zh-CN.md"
  install -Dm644 "$checkout/DESIGN.md" "$pkgdir/usr/share/doc/cornice/DESIGN.md"
  install -Dm644 "$checkout/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  return 0
}
