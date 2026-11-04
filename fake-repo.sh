#!/usr/bin/env bash
#
# fake-repo.sh — host fixture for publish-repo.sh: no root, no network, no R2.
#
# Builds two dummy packages and a throwaway passphrase-protected GPG key, runs
# publish-repo.sh offline (WORK_DIR + SKIP_UPLOAD + NO_LOCAL_ENV), and asserts
# the DB mechanics as measured against repo-add 7.1.0:
#   - the entry is added, and a version bump replaces it (never duplicates)
#   - an older version is refused (--prevent-downgrade)
#   - superseded package files are kept (downgrades stay live on the CDN)
#   - the DB, the .files DB, and the package signatures verify
#
# Run it after every change to publish-repo.sh; it is the cheapest thing that
# can falsify the publisher.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
DIST="$(mktemp -d)"
export GNUPGHOME="$(mktemp -d)"
trap 'rm -rf "$WORK" "$DIST" "$GNUPGHOME"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── Fixture packages: a real .PKGINFO is what repo-add reads ─────────────────
make_pkg() { # make_pkg <version>
    local ver="$1"
    {
        echo "pkgname = dummy-pkg"
        echo "pkgver = $ver-1"
        echo "pkgdesc = fixture package"
        echo "size = 100"
        echo "arch = x86_64"
    } > "$DIST/.PKGINFO"
    tar --zstd -C "$DIST" -cf "$DIST/dummy-pkg-$ver-1-x86_64.pkg.tar.zst" .PKGINFO
}
make_pkg 1.0.0
make_pkg 1.0.1

# ── Throwaway signing key, with a passphrase: exercises the headless path ────
gpg --batch --pinentry-mode loopback --passphrase 'fixture-pass' \
    --quick-gen-key "Aelum Fixture Key" ed25519 sign never 2>/dev/null
KEY_FP="$(gpg --with-colons --list-keys 'Aelum Fixture Key' | awk -F: '/^fpr:/{print $10; exit}')"
[[ -n "$KEY_FP" ]] || fail "could not create the fixture key"

publish() { # publish <package-file> — the exact offline path of a real run
    NO_LOCAL_ENV=1 WORK_DIR="$WORK" SKIP_UPLOAD=1 \
    AELUM_GPG_KEY="$KEY_FP" GPG_PASSPHRASE='fixture-pass' \
    "$SCRIPT_DIR/publish-repo.sh" "$1"
}

db_entries() { tar --zstd -tf "$WORK/aelum.db.tar.gz" | grep '/desc$'; }

# ── 1. First publish creates the DB with the entry and all signatures ────────
publish "$DIST/dummy-pkg-1.0.0-1-x86_64.pkg.tar.zst"
db_entries | grep -qx 'dummy-pkg-1.0.0-1/desc' || fail "1.0.0 entry missing from the DB"
[[ -f "$WORK/aelum.db.tar.gz.sig" && -f "$WORK/aelum.files.tar.gz" && -f "$WORK/aelum.files.tar.gz.sig" ]] \
    || fail "DB/.files signatures missing"
# pacman 7.1 requests the extensionless name; both names must carry the same
# bytes and a valid signature.
cmp -s "$WORK/aelum.db" "$WORK/aelum.db.tar.gz" || fail "aelum.db and aelum.db.tar.gz differ"
cmp -s "$WORK/aelum.files" "$WORK/aelum.files.tar.gz" || fail "aelum.files and aelum.files.tar.gz differ"
[[ -f "$WORK/aelum.db.sig" && -f "$WORK/aelum.files.sig" ]] || fail "extensionless DB signatures missing"
gpg --verify "$WORK/aelum.db.sig" "$WORK/aelum.db" >/dev/null 2>&1 || fail "aelum.db signature does not verify"
[[ -f "$WORK/dummy-pkg-1.0.0-1-x86_64.pkg.tar.zst.sig" ]] || fail "package .sig missing"
for f in aelum.db.tar.gz aelum.files.tar.gz dummy-pkg-1.0.0-1-x86_64.pkg.tar.zst; do
    gpg --verify "$WORK/$f.sig" "$WORK/$f" >/dev/null 2>&1 || fail "signature does not verify: $f"
done

# ── 2. A version bump replaces the entry, and the old file stays on disk ─────
publish "$DIST/dummy-pkg-1.0.1-1-x86_64.pkg.tar.zst"
db_entries | grep -qx 'dummy-pkg-1.0.1-1/desc' || fail "1.0.1 entry missing after upgrade"
db_entries | grep -q 'dummy-pkg-1.0.0-1/desc' && fail "1.0.0 entry was not replaced"
db_entries | grep -c 'dummy-pkg' | grep -qx 1 || fail "duplicate entries for dummy-pkg"
[[ -f "$WORK/dummy-pkg-1.0.0-1-x86_64.pkg.tar.zst" ]] || fail "superseded package file was removed"

# ── 3. An older version is refused: the publish fails loudly, the DB is intact ─
if publish "$DIST/dummy-pkg-1.0.0-1-x86_64.pkg.tar.zst" >/dev/null 2>&1; then
    fail "a refused downgrade must make the publish fail, not pretend success"
fi
db_entries | grep -qx 'dummy-pkg-1.0.1-1/desc' || fail "downgrade overwrote the newer entry"
db_entries | grep -q 'dummy-pkg-1.0.0-1/desc' && fail "downgrade entered the DB despite --prevent-downgrade"

# ── 4. Re-publishing the same version is a no-op, not a duplicate ────────────
publish "$DIST/dummy-pkg-1.0.1-1-x86_64.pkg.tar.zst"
db_entries | grep -c 'dummy-pkg' | grep -qx 1 || fail "re-publish duplicated the entry"

echo "PASS: fake-repo — add, replace, refuse-downgrade, idempotent re-publish, all signatures verify"
