#!/usr/bin/env bash
#
# publish-repo.sh — publish an Arch package into the Aelum pacman repository.
#
# The repository is the repo/<arch>/ prefix of the release bucket (same R2
# bucket + CDN as the ISOs, see docker/RELEASE.md):
#
#   repo/x86_64/aelum.db(.sig)             ← repo-add database, signed
#   repo/x86_64/aelum.db.tar.gz(.sig)      ← same bytes, older-pacman name
#   repo/x86_64/aelum.files(.sig)          ← file index for pacman -F
#   repo/x86_64/<pkg>.pkg.tar.zst(.sig)    ← this publisher keeps every upload
#                                             (nothing here deletes); a release
#                                             run prunes the superseded one
#   repo/aelum.gpg                         ← public key, non-Aelum bootstrap
#
# (pacman 7.1 requests the extensionless "<repo>.db"; older libalpm the
# ".db.tar.gz" name. Both are served, same bytes, like Arch's own mirrors.)
#
# Users enable it with:
#   [aelum]
#   SigLevel = Required DatabaseRequired
#   Server = https://cdn.aelum.dev/repo/$arch
#   (Aelum installs get that block + the trusted key from the installer.)
#
# It:
#   1. Downloads the current aelum.db.tar.gz from R2 (fresh DB on first run).
#   2. repo-add --prevent-downgrade merges the package in: a newer version of
#      a name replaces it, an older one is refused — warm dist/ dirs keep
#      every build ever made, the DB must not drift backwards.
#   3. Signs the DB, the .files DB, and the package with the release key.
#      Binary .sig (makepkg's form — what pacman's SigLevel checks); the
#      .asc from build-pkg.sh stays the human-verification convention.
#      repo-add -s only signs the databases, never the packages, so the
#      package .sig is produced here.
#   4. Uploads everything. (R2 does not persist per-object Cache-Control via
#      the S3 API — cache policy for the DB URL is a Cloudflare Cache Rule;
#      see REPO.md. Package files are version-named and immutable.)
#   5. Verifies: signatures locally, then re-downloads the DB from R2 and
#      asserts the entry is there.
#
# Credentials use the same env conventions as docker/scripts/publish-iso.sh
# (R2_ACCOUNT_ID / R2_ACCESS_KEY / R2_SECRET_KEY, throwaway rclone config)
# and video-player/scripts/build-pkg.sh (AELUM_GPG_KEY, optional
# AELUM_GPG_PRIVATE_KEY_B64 + GPG_PASSPHRASE for headless signing).
#
# Usage:
#   ./scripts/publish-repo.sh [package-path]     # default: newest video-player/dist pkg
#   ./scripts/publish-repo.sh --no-sign [pkg]    # unsigned (local testing only)
#
# Test knobs (used by fake-repo.sh; never combine with a real publish):
#   WORK_DIR=<dir>    use this dir as the work dir (skip the R2 DB download)
#   SKIP_UPLOAD=1     stop after local signing + verification
#   KEEP_WORK=1       keep the work dir and print it
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# Local secrets (gitignored) if present — same shape as docker/release.env.
# NO_LOCAL_ENV=1 keeps the run hermetic (fake-repo.sh supplies its own env).
if [ -f "$ROOT_DIR/release.env" ] && [[ -z "${NO_LOCAL_ENV:-}" ]]; then
    set -a; . "$ROOT_DIR/release.env"; set +a
fi

R2_BUCKET="${R2_BUCKET:-aelum}"
R2_PUBLIC_BASE="${R2_PUBLIC_BASE:-https://cdn.aelum.dev}"
REPO_NAME="aelum"
REPO_ARCH="${REPO_ARCH:-x86_64}"

NO_SIGN=false
PKG_PATH=""
for arg in "$@"; do
    case "$arg" in
        --no-sign) NO_SIGN=true ;;
        -*) echo "Usage: $0 [--no-sign] [package-path]" >&2; exit 2 ;;
        *) PKG_PATH="$arg" ;;
    esac
done

# ── Package to publish ────────────────────────────────────────────────────────
if [[ -z "$PKG_PATH" ]]; then
    PKG_PATH="$(ls -1t "$ROOT_DIR/../video-player/dist/"*.pkg.tar.zst 2>/dev/null | head -1)"
fi
if [[ -z "$PKG_PATH" || ! -f "$PKG_PATH" ]]; then
    echo "Error: package not found (pass a path or build video-player/dist first)." >&2
    exit 1
fi
BASE="$(basename "$PKG_PATH")"
# The DB entry is <pkgbase>-<pkgver> — the filename minus .pkg.tar.zst and the
# -<arch> suffix (verified against repo-add 7.1.0).
DB_ENTRY="${BASE%.pkg.tar.zst}"
DB_ENTRY="${DB_ENTRY%-$REPO_ARCH}"
echo "==> Package: $BASE (db entry: $DB_ENTRY)"

# ── Work dir: fetch the current DB unless one was supplied ────────────────────
if [[ -n "${WORK_DIR:-}" ]]; then
    WORK="$WORK_DIR"
    CLEAN_WORK=false
else
    WORK="$(mktemp -d)"
    CLEAN_WORK=true
fi
# An if-form, not `&&`: a bare `$CLEAN_WORK && rm` returns false when cleaning
# is off, and an EXIT trap's status overrides the script's exit code.
cleanup() { if $CLEAN_WORK; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

DB="$WORK/$REPO_NAME.db.tar.gz"
FILES_DB="$WORK/$REPO_NAME.files.tar.gz"

# ── R2 remote (throwaway rclone config, same pattern as publish-iso.sh) ──────
if [[ "${SKIP_UPLOAD:-0}" != "1" ]]; then
    R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
    R2_ACCESS_KEY="${R2_ACCESS_KEY:-}"
    R2_SECRET_KEY="${R2_SECRET_KEY:-}"
    if [[ -z "${R2_ACCOUNT_ID}${R2_ACCESS_KEY}${R2_SECRET_KEY}" ]]; then
        echo "Error: R2 credentials not set. Copy release.env.example to release.env (see REPO.md)." >&2
        exit 1
    fi
    R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"
    RCLONE_CONF="$(mktemp)"
    cat > "$RCLONE_CONF" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
# The API token is bucket/Object-scoped, so rclone must skip its bucket check.
no_check_bucket = true
acl = public-read
EOF
    trap 'cleanup; rm -f "$RCLONE_CONF"' EXIT
    RCLONE=(rclone --config "$RCLONE_CONF")
    REMOTE="r2:${R2_BUCKET}/repo/${REPO_ARCH}"

    if [[ -z "${WORK_DIR:-}" ]]; then
        # First run: the prefix does not exist yet, so probe the object instead
        # of copying a directory that may be missing (a bare `|| true` would
        # also hide auth errors).
        if "${RCLONE[@]}" lsjson "r2:${R2_BUCKET}/repo/${REPO_ARCH}/${REPO_NAME}.db.tar.gz" >/dev/null 2>&1; then
            echo "==> Fetching current ${REPO_NAME}.db.tar.gz from R2..."
            "${RCLONE[@]}" copyto "r2:${R2_BUCKET}/repo/${REPO_ARCH}/${REPO_NAME}.db.tar.gz" "$DB"
            "${RCLONE[@]}" copyto "r2:${R2_BUCKET}/repo/${REPO_ARCH}/${REPO_NAME}.files.tar.gz" "$FILES_DB" 2>/dev/null \
                || echo "    (no .files DB yet — repo-add will create one)"
        else
            echo "==> No repository yet — creating a fresh database."
        fi
    fi
fi

# ── Merge into the database ───────────────────────────────────────────────────
echo "==> repo-add --prevent-downgrade $BASE"
repo-add --prevent-downgrade "$DB" "$PKG_PATH"

# pacman 7.1 requests the extensionless "<repo>.db" (what Arch's own mirrors
# serve); older libalpm asks for "<repo>.db.tar.gz". repo-add leaves that name
# as a compatibility symlink — turn it into a real copy (same bytes): rclone
# cannot use a symlink as a copy source, and a plain file works everywhere.
DB_EXT="$WORK/$REPO_NAME.db"
FILES_EXT="$WORK/$REPO_NAME.files"
rm -f "$DB_EXT" "$FILES_EXT"
cp "$DB" "$DB_EXT"
cp "$FILES_DB" "$FILES_EXT"

# ── Signatures (binary .sig — the form pacman checks) ────────────────────────
if ! $NO_SIGN; then
    if [[ -z "${AELUM_GPG_KEY:-}" ]]; then
        echo "Error: set AELUM_GPG_KEY (key id or 'Name <email>'), or use --no-sign." >&2
        exit 1
    fi
    command -v gpg >/dev/null 2>&1 || { echo "Error: gpg not found (or use --no-sign)." >&2; exit 1; }

    # Headless signing: import the private key from the env (same as
    # video-player/scripts/build-pkg.sh).
    if [[ -n "${AELUM_GPG_PRIVATE_KEY:-}" || -n "${AELUM_GPG_PRIVATE_KEY_B64:-}" ]]; then
        KEY_ARMOR="${AELUM_GPG_PRIVATE_KEY:-}"
        if [[ -n "${AELUM_GPG_PRIVATE_KEY_B64:-}" ]]; then
            KEY_ARMOR="$(printf '%s' "$AELUM_GPG_PRIVATE_KEY_B64" | base64 -d)"
        fi
        echo "==> Importing signing key..."
        printf '%s' "$KEY_ARMOR" | gpg --import --batch 2>&1 | tail -2
    fi
    GPG_EXTRA=()
    if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
        GPG_EXTRA=(--pinentry-mode loopback --passphrase "$GPG_PASSPHRASE")
    fi
    sign_file() {
        gpg --batch --yes --local-user "$AELUM_GPG_KEY" \
            --detach-sign --digest-algo=SHA512 "${GPG_EXTRA[@]}" \
            --output "$1.sig" "$1"
        gpg --verify "$1.sig" "$1" >/dev/null && echo "    sig OK: $(basename "$1").sig"
    }
    echo "==> Signing..."
    cp "$PKG_PATH" "$WORK/$BASE"   # sign next to the DB so verification is local
    sign_file "$WORK/$BASE"
    sign_file "$DB"
    sign_file "$FILES_DB"
    # Same bytes → same signature; pacman looks for
    # "<requested db filename>.sig", so both names need one.
    [[ -e "$DB_EXT.sig" ]] || cp "$DB.sig" "$DB_EXT.sig"
    [[ -e "$FILES_EXT.sig" ]] || cp "$FILES_DB.sig" "$FILES_EXT.sig"
else
    cp "$PKG_PATH" "$WORK/$BASE"
fi

# ── Local verification ────────────────────────────────────────────────────────
echo "==> Verifying the database..."
tar --zstd -tf "$DB" | grep -q "^${DB_ENTRY}/desc$" \
    || { echo "Error: $DB_ENTRY is not in the database." >&2; exit 1; }
echo "    db entry OK: $DB_ENTRY"

if [[ "${SKIP_UPLOAD:-0}" == "1" ]]; then
    echo "==> SKIP_UPLOAD=1 — stopping after local verification."
    [[ "${KEEP_WORK:-0}" == "1" ]] && echo "    work dir kept: $WORK"
    exit 0
fi

# ── Upload ────────────────────────────────────────────────────────────────────
# Note: R2's S3 API does not persist a per-object Cache-Control (measured
# against rclone 1.75 + R2, Nov 2026: --metadata-set cache-control=... is sent
# but never stored or served). The edge applies Cloudflare's default policy
# (~4h for these types). That makes a republished DB visible to users with up
# to that staleness — harmless for a personal repo, and package files are
# version-named and immutable anyway. For instant DB visibility, add a
# Cloudflare Cache Rule (no cache / edge TTL 0) for /repo/*/*.db* — see REPO.md.
echo "==> Uploading $BASE (+ .sig)..."
"${RCLONE[@]}" copy "$WORK/$BASE" "$REMOTE/"
if ! $NO_SIGN; then
    "${RCLONE[@]}" copy "$WORK/$BASE.sig" "$REMOTE/"
fi

echo "==> Uploading ${REPO_NAME}.db(.tar.gz) + ${REPO_NAME}.files(.tar.gz) (+ .sig)..."
for f in "$DB" "$FILES_DB" "$DB_EXT" "$FILES_EXT"; do
    "${RCLONE[@]}" copy "$f" "$REMOTE/"
    $NO_SIGN || "${RCLONE[@]}" copy "$f.sig" "$REMOTE/"
done

# The public key, for the one-time pacman-key bootstrap of non-Aelum users
# (Aelum installs get the key from the installer instead). Refreshed every
# publish so it can never drift from what actually signed the DB.
if ! $NO_SIGN; then
    echo "==> Publishing the public key -> repo/aelum.gpg..."
    KEYFILE="$WORK/aelum.gpg"
    gpg --batch --export "$AELUM_GPG_KEY" > "$KEYFILE"
    "${RCLONE[@]}" copy "$KEYFILE" "r2:${R2_BUCKET}/repo/"
fi

# ── Verify what the CDN will actually serve ───────────────────────────────────
# Fetch the extensionless name — that is what pacman 7.1 will request.
echo "==> Re-downloading the database from R2 and verifying..."
VERIFY_DB="$WORK/verify.db.tar.gz"
"${RCLONE[@]}" copyto "$REMOTE/${REPO_NAME}.db" "$VERIFY_DB"
tar --zstd -tf "$VERIFY_DB" | grep -q "^${DB_ENTRY}/desc$" \
    || { echo "Error: the uploaded database does not contain $DB_ENTRY." >&2; exit 1; }

# The pacman package name comes from the package's own .PKGINFO — deriving it
# from the filename is guesswork, since names contain dashes.
PKG_INSTALL_NAME="$(tar --zstd -xOf "$PKG_PATH" .PKGINFO | awk -F' = ' '/^pkgname = /{print $2; exit}')"

cat <<EOF

Published: $BASE
  $R2_PUBLIC_BASE/repo/${REPO_ARCH}/${BASE}

Install (repo already enabled on Aelum installs):
  sudo pacman -Sy && pacman -S ${PKG_INSTALL_NAME}

EOF
