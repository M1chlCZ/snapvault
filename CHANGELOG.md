# Changelog

All notable changes to snapvault are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0] - 2026-11-12

### Added

- `snapvault-status.sh` lists the snapshots in a destination with their kind,
  state, size and age. `--json` prints the same data for scripts, and
  `--retention-days DAYS` marks the entries that retention would delete.
- `SNAPVAULT_RETENTION_DRY_RUN=1` prints the retention candidates to standard
  error without deleting them.
- `snapvault-status.sh --max-age-days DAYS` and `--require-complete` turn the
  report into a monitoring check. Findings exit with status 1; usage and I/O
  errors keep status 2.
- The `--json` report gains `maxAgeDays`, `requireComplete`, `healthy` and
  `problems`.

## [0.3.0] - 2026-10-19

### Added

- Optional age encryption: `SNAPVAULT_AGE_RECIPIENT` packs the verified
  snapshot into a single `snapshot-<timestamp>.tar.gz.age` artifact and
  removes the plain snapshot directory from the destination. Use
  `SNAPVAULT_AGE_BIN` to select the `age` binary.
- `snapvault-verify.sh` and `snapvault-restore.sh` accept snapshot artifacts.
  An encrypted `.tar.gz.age` artifact requires `SNAPVAULT_AGE_IDENTITY_FILE`.
  A plain transport `.tar.gz` artifact needs no identity. The identity file is
  read-only input; it is never copied into a snapshot or uploaded.
- Remote publication: `SNAPVAULT_REMOTE` and `SNAPVAULT_REMOTE_DIR` upload the
  transport tarball to a dot-prefixed `.incomplete` name, compare the remote
  SHA-256 with the local one, and rename the file atomically. The toolkit
  never deletes a remote file. Use `SNAPVAULT_SSH_BIN` to select the `ssh`
  binary.
- Tests for encrypted publication, artifact verification and restore, remote
  staging, a checksum mismatch, a remote failure without a local fallback, a
  plain remote publication, and the new validation rules, with fake `age` and
  `ssh` binaries.
- README sections for encryption, remote publication, and the staging
  protocol.

### Fixed

- Corrected the `[0.2.0]` release date from 2026-10-17 to 2026-10-11, the day
  the tag was created.

## [0.2.0] - 2026-10-11

### Added

- `snapvault-restore.sh` restores the media archive of a verified snapshot
  into a target directory. A non-empty target requires `--force`.
- `snapvault-restore.sh --database URL` restores `database.dump` with
  `pg_restore`. Use `SNAPVAULT_PG_RESTORE_BIN` to select the binary.
- Tests for the restore round trip, `--force`, missing `COMPLETE` markers,
  tampered snapshots and the `pg_restore` invocation.
- README documentation for the restore command, its exit codes, and the
  restored modification-time limitation.
