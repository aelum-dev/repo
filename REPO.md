# Aelum package repository

The `[aelum]` pacman repository — applications shipped by the distro, starting
with `aelum-video-player`. It is the `repo/` prefix of the existing release
bucket: same R2 bucket, same `cdn.aelum.dev`, same release key as the ISOs
(see `docker/RELEASE.md`). Nothing new to operate.

```
https://cdn.aelum.dev/repo/x86_64/aelum.db(.sig)        ← repo-add DB, signed
https://cdn.aelum.dev/repo/x86_64/aelum.db.tar.gz(.sig) ← same bytes, older-pacman name
https://cdn.aelum.dev/repo/x86_64/aelum.files(.sig)     ← file index (pacman -F)
https://cdn.aelum.dev/repo/x86_64/<pkg>.pkg.tar.zst(.sig) ← immutable, kept forever
https://cdn.aelum.dev/repo/aelum.gpg                    ← public key (non-Aelum bootstrap)
```

pacman 7.1 requests the extensionless `aelum.db`; older libalpm asks for
`aelum.db.tar.gz`. Both names are published, same bytes, same signature —
exactly what Arch's own mirrors do.

Package files are never deleted; the DB points at the newest, old URLs and
downgrades keep working.

**Caching (measured, 2026-11-04):** R2's S3 API does not persist a
per-object `Cache-Control` — rclone's `--metadata-set cache-control=…` is
sent but never stored or served. The edge applies Cloudflare's default
policy (~4 h for these types), so a republished DB is visible to users with
up to that staleness. Package files are version-named and immutable, so this
only ever affects how fast a *new version* shows up. If instant visibility
ever matters, add a Cloudflare Cache Rule for `uri path contains "/repo/"
and ends with ".tar.gz"` (or `.db*`) → skip cache / edge TTL 0; nothing in
the scripts changes.

## For users

**Aelum installs already have it.** The installer enables the repo and trusts
the signing key at install time (`installer/…/configure/pacman_repo.go`):

```ini
# /etc/pacman.conf, appended by the installer
[aelum]
SigLevel = Required DatabaseRequired
Server = https://cdn.aelum.dev/repo/$arch
```

```bash
sudo pacman -Sy && sudo pacman -S aelum-video-player
```

(`-Sy` syncs every enabled repo — pacman 7.1 has no per-repository `-Sy <name>`
form; a bare `-Sy` followed by `-S` is the documented way to pick up a newly
enabled repository.)

**Other Arch systems** add the block above themselves and import the key once
(`pacman-key` cannot follow WKD, hence the copy next to the repo):

```bash
curl -O https://cdn.aelum.dev/repo/aelum.gpg
sudo pacman-key --add aelum.gpg
sudo pacman-key --lsign-key 728F5F59FB2F5A88C6EE28D4930A672A3A1B5B60
```

The key is the Aelum release key (`release@aelum.dev`, also published via WKD
at `aelum.dev/.well-known/openpgpkey/`).

## Maintainer runbook

Publish a built package (the only publisher):

```bash
cd repo
cp release.env.example release.env   # gitignored; same variable names as docker/release.env
./publish-repo.sh                    # default: newest video-player/dist package
./publish-repo.sh path/to/pkg.pkg.tar.zst
```

`publish-repo.sh` fetches the current DB from R2, merges with
`repo-add --prevent-downgrade` (a version bump replaces; an older version is
refused and the publish fails loudly), signs DB + `.files` DB + package with
binary `.sig` (what pacman's `SigLevel` checks — `repo-add -s` signs only the
databases, never packages), uploads, then re-downloads the DB and asserts the
entry.

Signing conventions are shared with the rest of the project: `AELUM_GPG_KEY`,
optional `AELUM_GPG_PRIVATE_KEY_B64` + `GPG_PASSPHRASE` for headless signing.
The `.asc`/`.sha256` from `video-player/scripts/build-pkg.sh` stay the
human-verification convention; the binary `.sig` is the machine-checked one.

## Testing

```bash
./fake-repo.sh    # host fixture: no root, no network, no R2
```

It asserts the DB mechanics against repo-add 7.1.0: add → replace on version
bump (never duplicate) → refuse downgrade (publish fails) → idempotent
re-publish, and that every signature verifies. Run it after every change to
`publish-repo.sh`.

End-to-end proof lives in the QEMU matrix: `docker/scripts/verify-installed.sh`
asserts a fresh install has the `[aelum]` block and the trusted key, and a
freshly installed system can `pacman -S aelum-video-player` with no
hand-editing.

## Design notes

- The DB entry name is `<pkgbase>-<pkgver>` (filename minus `.pkg.tar.zst`
  and `-<arch>`) — measured against repo-add 7.1.0, used by the verifier.
- The live session does **not** get the repo: it is offline-first
  (`aelum-offline`). The repo is an installed-system thing. The ISO *build*,
  however, does resolve the repo once: `aelum-video-player` is listed in
  `live-iso/packages.x86_64` and `docker/scripts/build-iso.sh` pulls it through
  an `[aelum]` block — so the package is baked into the offline mirror, the
  live session ships it, and the installer installs it into every system
  from the mirror (no network). The enabled repo then serves *updates*.
- `SigLevel = Required DatabaseRequired` from day one, so the installer seeds
  the key into the target keyring (`pacman-key --add` + `--lsign-key`) —
  without it a fresh install could not use the repo at all.
- `pacman -Syu` on a fresh install reaches `cdn.aelum.dev`; offline *install*
  is untouched (the embedded mirror still serves the install itself). A repo
  DB failure without network behaves like any dead mirror.
