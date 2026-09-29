# PKGBUILD for cornice — a general-purpose Hyprland shell on Quickshell.
#
# Builds from this working tree, so it works today (the repo has no public
# remote yet):
#
#     cd ~/Code/self/cornice
#     makepkg -si          # or: make pkg
#
# When a remote exists, replace `source=()` with the usual
#     source=("$pkgname::git+https://…/cornice.git")
# and the package() body can keep using "$srcdir"/cornice.
#
# Layout note: the CLI resolves its own prefix by following its symlink, so the
# tree must live in /usr/share/cornice with /usr/bin entries pointing into it.
#
# The `source=()` below packages this working tree, which is what a local
# `makepkg -si` in a clone needs. For an AUR upload the source has to be
# fetchable instead — see `docs/aur.md`.

pkgname=cornice-git
pkgver=r$(git -C "$startdir" rev-list --count HEAD 2>/dev/null || echo 1).$(git -C "$startdir" rev-parse --short HEAD 2>/dev/null || echo local)
pkgrel=1
pkgdesc="General-purpose Hyprland shell: bar, panels, notifications, launcher, lock, idle"
arch=('any')
url="https://github.com/mainliufeng/cornice"
license=('MIT')
# glib2 provides gdbus (the logind monitor for suspend/lid locking) and curl is
# what the weather plugin fetches with — both are used by default plugins, so
# they are hard dependencies, not optional ones.
depends=('quickshell' 'hyprland' 'jq' 'glib2' 'curl')
optdepends=(
  'socat: CLI talks to the shell over its own socket (needed for runtime plugins)'
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

# The package is built from the tree you are standing in. `makepkg` complains
# about an empty source array only when it has to fetch something — it does not
# here, because package() copies from $startdir.
source=()
options=('!strip')

package() {
  install -dm755 "$pkgdir/usr/share/cornice"
  for dir in bin shell themes wallpapers config docs; do
    [[ -d $startdir/$dir ]] || continue
    cp -r "$startdir/$dir" "$pkgdir/usr/share/cornice/"
  done
  find "$pkgdir/usr/share/cornice" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "$pkgdir/usr/share/cornice" -name '*.qmlc' -delete 2>/dev/null || true

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
  install -Dm644 "$startdir/DESIGN.md" "$pkgdir/usr/share/doc/cornice/DESIGN.md"
  install -Dm644 "$startdir/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  return 0
}
