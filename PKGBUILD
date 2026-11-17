# Full Cornice desktop package, built from this checkout with makepkg.
# Native code and locked browser/MCP dependencies are rebuilt under $srcdir;
# source-tree build directories and node_modules are never packaged.
# The CLI resolves its tree through /usr/bin symlinks into /usr/share/cornice.
# AUR publication needs a fetchable source declaration; see docs/aur.md.

pkgname=cornice-git
pkgver=r$(git -C "$startdir" rev-list --count HEAD 2>/dev/null || echo 1).$(git -C "$startdir" rev-parse --short HEAD 2>/dev/null || echo local)
pkgrel=1
pkgdesc="General-purpose Hyprland shell: bar, panels, notifications, launcher, lock, idle"
arch=('x86_64' 'aarch64')
url="https://github.com/mainliufeng/cornice"
license=('MIT')
# glib2 provides gdbus (the logind monitor for suspend/lid locking) and curl is
# what the weather plugin fetches with — both are used by default plugins, so
# they are hard dependencies, not optional ones. Python publishes the atomic
# primary-session endpoint used by native shortcuts and secondary shells.
depends=('quickshell' 'hyprland' 'jq' 'python' 'glib2' 'curl' 'util-linux' 'qt6-base' 'qt6-declarative' 'qt6-websockets' 'wayland' 'libxkbcommon' 'pam' 'at-spi2-core' 'nodejs>=20' 'socat' 'wf-recorder' 'ffmpeg')
makedepends=('cmake' 'ninja' 'pkgconf' 'npm')
optdepends=(
  'grim: screenshots for `cornice verify`'
  'wireplumber: volume/microphone panels'
  'bluez: bluetooth panel'
  'brightnessctl: brightness keys and OSD'
  'cliphist: clipboard history overlay'
  'light: idle dimming'
  'networkmanager: network panel'
  'ttf-nerd-fonts-symbols: bar glyphs'
)
provides=('cornice')
conflicts=('cornice')

# Local checkout build. package() installs only build()'s complete runtime.
source=()
options=('!strip')

build() {
  local runtime_build
  runtime_build=$(mktemp -d "$srcdir/runtime-build.XXXXXX")
  rm -rf -- "$srcdir/runtime"
  "$startdir/packaging/build-runtime.sh" "$startdir" "$runtime_build" "$srcdir/runtime"
}

package() {
  install -dm755 "$pkgdir/usr/share/cornice"
  for dir in bin shell i18n themes wallpapers config docs; do
    [[ -d $startdir/$dir ]] || continue
    cp -r "$startdir/$dir" "$pkgdir/usr/share/cornice/"
  done
  find "$pkgdir/usr/share/cornice" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "$pkgdir/usr/share/cornice" -name '*.qmlc' -delete 2>/dev/null || true

  cp -r "$srcdir/runtime/native" "$pkgdir/usr/share/cornice/"
  cp -r "$startdir/plugins" "$pkgdir/usr/share/cornice/"
  install -dm755 "$pkgdir/usr/bin"
  local f name
  for f in "$pkgdir"/usr/share/cornice/bin/cornice*; do
    [[ -f $f ]] || continue
    name=$(basename "$f")
    chmod 755 "$f"
    ln -s "/usr/share/cornice/bin/$name" "$pkgdir/usr/bin/$name"
  done


  # Documentation and the licence (once the repo has one).
  install -Dm644 "$startdir/README.md" "$pkgdir/usr/share/doc/cornice/README.md"
  install -Dm644 "$startdir/README.zh-CN.md" "$pkgdir/usr/share/doc/cornice/README.zh-CN.md"
  install -Dm644 "$startdir/DESIGN.md" "$pkgdir/usr/share/doc/cornice/DESIGN.md"
  install -Dm644 "$startdir/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  return 0
}
