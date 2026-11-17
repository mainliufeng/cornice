# Recover a paired session after a system upgrade

A package update can change the stable baseline checked by `cornice-session-trial`
and remove shared-library SONAMEs required by the selected, immutable Hyprland.
Refreshing the baseline alone does not fix missing libraries. Do not disable the
baseline checks or silently replace the paired compositor with `/usr/bin/Hyprland`.

`bin/cornice-session-repair` preserves the previous paired compositor, Cornice,
configuration and autostart. It prepares a **new, unselected** snapshot with a
fresh system baseline. It never logs out, restarts services, installs packages,
or changes the current desktop. `prepared.json` changes; the selected login does
not. Existing snapshots remain available. This is an Arch-specific recovery tool,
not a guarantee that every ABI upgrade is compatible.

Example (substitute the actual intact release and compatible cache packages):

```sh
bin/cornice-session-repair \
  --release "$HOME/.local/state/cornice/session-trial/releases/OLD_RELEASE" \
  --library-package /var/cache/pacman/pkg/aquamarine-VERSION-x86_64.pkg.tar.zst \
  --library-package /var/cache/pacman/pkg/hyprgraphics-VERSION-x86_64.pkg.tar.zst
```

Requires Python, bsdtar, patchelf and pacman-key. Each archive requires an adjacent
`.sig` accepted by the system Arch keyring. Only direct `usr/lib/lib*.so*` members
are extracted; library links are materialized and must resolve inside extraction.
Conflicting files and changed snapshot files are rejected. Libraries are stored
inside the new snapshot and included in its manifest. No private files or compiled
binaries belong in the repository. Existing RPATH entries are retained after the
snapshot-local library path.

The tool checks snapshot identity, executable loading and config parsing. These
checks are **not** physical login or graphics acceptance. Run the existing isolated
desktop regression harness against the resulting binary and product before:

```sh
python3 /path/to/NEW_RELEASE/runner select --release /path/to/NEW_RELEASE
```

Selection affects the next login only. Save work, log out normally, and choose
Hyprland to verify the physical session. Keep Plasma available as recovery; an
old snapshot can still have missing libraries after a system update, so do not
call it a validated fallback merely because its files remain. Future system
updates can require another fresh baseline. Never use this procedure to bypass
an unexplained change in the snapshot itself.

Unit checks: `python3 test/session-repair-unit.py`.
