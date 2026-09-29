# Publishing to the AUR

The in-repo `PKGBUILD` packages the working tree, which is what `makepkg -si`
inside a clone needs. The AUR is different: it builds in a **clean chroot**, so
everything must be fetched from a URL and nothing may be copied from
`$startdir`. This file has the AUR-ready variant and the exact procedure.

## How the AUR works

- One package = one git repository at `ssh://aur@aur.archlinux.org/<pkgname>.git`.
- You push `PKGBUILD` and a generated `.SRCINFO`; the web page appears within a
  minute. There is no review queue and no binary hosting.
- Builds happen on the user's machine from your `source=()`, so the sources must
  be publicly fetchable (GitHub raw/tarball or `git+https://`).
- Registration is periodically closed to fight spam. If
  <https://aur.archlinux.org/register> says "Registration temporarily closed",
  wait and retry.
- You need an SSH key uploaded to your **AUR account** (Account → SSH Public Key).
  That is separate from the key in your GitHub account.

## Which package to publish

| Package | Source | When |
| --- | --- | --- |
| `cornice-git` | `git+https://github.com/mainliufeng/cornice.git` | now: tracks `main`, no releases needed |
| `cornice` | a tagged tarball + `sha256sums` | later, once you tag releases — this is the one AUR users prefer |

Check the names are free before starting:

```bash
curl -s "https://aur.archlinux.org/rpc/v5/info?arg[]=cornice&arg[]=cornice-git" | jq '.results'
# [] means nobody has them
```

## AUR-ready PKGBUILD (`cornice-git`)

```bash
pkgname=cornice-git
pkgver=r1.0000000
pkgrel=1
pkgdesc="General-purpose Hyprland shell: bar, panels, notifications, launcher, lock, idle"
arch=('any')
url="https://github.com/mainliufeng/cornice"
license=('MIT')
depends=('quickshell' 'hyprland' 'jq' 'glib2' 'curl')
optdepends=(
  'socat: CLI talks to the shell over its own socket'
  'grim: screenshots for `cornice verify`'
  'wireplumber: volume and microphone panels'
  'bluez: bluetooth panel'
  'brightnessctl: brightness keys and OSD'
  'cliphist: clipboard history overlay'
  'light: idle dimming'
  'networkmanager: network panel'
  'ttf-nerd-fonts-symbols: bar glyphs'
)
provides=('cornice')
conflicts=('cornice')
source=('cornice::git+https://github.com/mainliufeng/cornice.git')
sha256sums=('SKIP')
options=('!strip')

pkgver() {
  cd cornice
  printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

package() {
  cd cornice
  install -dm755 "$pkgdir/usr/share/cornice"
  for dir in bin shell themes wallpapers config docs; do
    cp -r "$dir" "$pkgdir/usr/share/cornice/"
  done
  find "$pkgdir/usr/share/cornice" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  find "$pkgdir/usr/share/cornice" -name '*.qmlc' -delete 2>/dev/null || true

  install -dm755 "$pkgdir/usr/bin"
  local f name
  for f in "$pkgdir"/usr/share/cornice/bin/cornice*; do
    name=$(basename "$f")
    chmod 755 "$f"
    ln -s "/usr/share/cornice/bin/$name" "$pkgdir/usr/bin/$name"
  done

  install -Dm644 README.md "$pkgdir/usr/share/doc/cornice/README.md"
  install -Dm644 DESIGN.md "$pkgdir/usr/share/doc/cornice/DESIGN.md"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
```

The `pkgver` here is a placeholder: `pkgver()` overwrites it on the first build.

## Procedure

```bash
# 1. one-time: create the AUR ssh remote
git clone ssh://aur@aur.archlinux.org/cornice-git.git
cd cornice-git

# 2. drop in the PKGBUILD from above (or copy this repo's and edit source/pkgver)
cp ~/Code/self/cornice/PKGBUILD .
$EDITOR PKGBUILD

# 3. check it builds and is compliant
makepkg -f            # builds the package
namcap PKGBUILD       # common packaging mistakes
makepkg --printsrcinfo > .SRCINFO

# 4. publish
git add PKGBUILD .SRCINFO
git commit -m "cornice-git: initial upload"
git push
```

To update later: `git pull`, bump `pkgrel` only if the PKGBUILD itself changed
(`pkgver()` handles the version for VCS packages), regenerate `.SRCINFO`, commit,
push. Never push a package file — the AUR stores metadata only.

## Rules worth remembering

- The build must work in a clean chroot (`makechrootpkg -c -r "$CHROOT"` with
  `devtools` if you want to verify exactly what users get).
- No `sudo`, no network access during `build()`/`package()`, no writing to
  `$HOME`.
- `license` must be an SPDX id (`MIT` here) and the licence file must be
  installed to `/usr/share/licenses/$pkgname/`.
- `arch=('any')` is correct: the payload is QML, shell scripts and images.
- Keep `depends` honest — a missing runtime dependency is the most common reason
  a package "does not work" for someone else.
