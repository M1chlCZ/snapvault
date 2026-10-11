# Changelog

All notable changes to snapvault are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-10-17

### Added

- `snapvault-restore.sh` restores the media archive of a verified snapshot
  into a target directory. A non-empty target requires `--force`.
- `snapvault-restore.sh --database URL` restores `database.dump` with
  `pg_restore`. Use `SNAPVAULT_PG_RESTORE_BIN` to select the binary.
- Tests for the restore round trip, `--force`, missing `COMPLETE` markers,
  tampered snapshots and the `pg_restore` invocation.
- README documentation for the restore command, its exit codes, and the
  restored modification-time limitation.
