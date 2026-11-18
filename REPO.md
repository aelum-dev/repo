# Aelum package repository

The `[aelum]` pacman repository — applications shipped by the distro, starting
with `aelum-video-player`. It is the `repo/` prefix of the existing release
bucket: same R2 bucket, same `cdn.aelum.dev`, same release key as the ISOs
(see `docker/RELEASE.md`). Nothing new to operate.

```
https://cdn.aelum.dev/repo/x86_64/aelum.db(.sig)        ← repo-add DB, signed
https://cdn.aelum.dev/repo/x86_64/aelum.db.tar.gz(.sig) ← same bytes, older-pacman name
https://cdn.aelum.dev/repo/x86_64/aelum.files(.sig)     ← file index (pacman -F)
https://cdn.aelum.dev/repo/x86_64/<pkg>.pkg.tar.zst(.sig) ← version-named; newest kept
https://cdn.aelum.dev/repo/aelum.gpg                    ← public key (non-Aelum bootstrap)
```

pacman 7.1 requests the extensionless `aelum.db`; older libalpm asks for
`aelum.db.tar.gz`. Both names are published, same bytes, same signature —
exactly what Arch's own mirrors do.

**One artifact per package (measured, 2026-11-18):** the release scripts delete
the superseded package from R2 once the new DB entry has verified
(`bump-version.sh`, `--keep-old` to skip the deletion), so only the newest of
each package is on the bucket — `0.7.0-1` answers 200 while `0.6.1-1`, `0.6.0-1`
and `0.5.12-1` answer 404. Old URLs therefore do **not** keep working and a
downgrade needs a file you still hold. The ordering is what makes the deletion
safe: it happens after the new DB is verified, so the *served* DB never names a
missing file. What can still name one is a **client's own stale database** — a
machine that has not synced lists the old version, and a bare `pacman -S` then
404s. Syncing is the whole fix, and `pacman -Syu` and the app's Update press
both sync first.

**Caching (measured, 2026-11-18):** R2's S3 API does not persist a
per-object `Cache-Control` — rclone's `--metadata-set cache-control=…` is sent
but never stored or served. Nor does a default TTL stand in for it: the DBs and
the package files answer `cf-cache-status: DYNAMIC` with no `Cache-Control` and
no `Age` on back-to-back requests, so the edge does not cache them and a
republished DB is visible to the next `pacman -Sy` — the 0.7.0 database was
being served fresh, at its own upload `last-modified`, under three minutes
after the publish. No purge step is needed or used. If a response ever comes
back `HIT`, the lever is a Cloudflare Cache Rule on `uri path contains
"/repo/"` → skip cache; no script changes.

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
  however, does resolve the repo once: `aelum-video-player` and
  `aelum-package-installer` are listed in
  `live-iso/packages.x86_64` and `docker/scripts/build-iso.sh` pulls them through
  an `[aelum]` block — so the packages are baked into the offline mirror, the
  live session ships them, and the installer installs them into every system
  from the mirror (no network). The enabled repo then serves *updates*.
- `SigLevel = Required DatabaseRequired` from day one, so the installer seeds
  the key into the target keyring (`pacman-key --add` + `--lsign-key`) —
  without it a fresh install could not use the repo at all.
- `pacman -Syu` on a fresh install reaches `cdn.aelum.dev`; offline *install*
  is untouched (the embedded mirror still serves the install itself). A repo
  DB failure without network behaves like any dead mirror.
