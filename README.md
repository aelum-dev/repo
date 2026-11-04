# Aelum package repository

The tooling for the `[aelum]` pacman repository — the `repo/` prefix of the
Aelum release bucket, serving the distro's own applications (currently
`aelum-video-player`) over `cdn.aelum.dev`.

- **[REPO.md](REPO.md)** — user install docs, maintainer runbook, measured caveats.
- `publish-repo.sh` — the only publisher (DB + packages + signatures → R2).
- `fake-repo.sh` — offline fixture; run it after every publisher change.

License: GPL-3.0 (see `LICENSE`).
