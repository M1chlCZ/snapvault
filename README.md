# snapvault

A zero-dependency, non-root shell toolkit that makes verified snapshots of a
PostgreSQL database and a media directory.

`snapvault.sh` writes one timestamped snapshot directory. `snapvault-verify.sh`
verifies that snapshot later, on the same host or on a different host. The
snapshot format is plain files, so any user can inspect it without this
toolkit.

## What it is

`snapvault.sh` takes a PostgreSQL connection target and a media directory. It
produces one snapshot directory with these properties:

- The directory name contains a UTC timestamp.
- The database is a custom-format `pg_dump`.
- The media is one gzip tarball. With GNU tar it is byte-deterministic. With
  BSD tar the member order and the owner are normalized; entry modification
  times stay as they are.
- A per-file `media-index.sha256` and a top-level `SHA256SUMS` cover the data.
- A `COMPLETE` marker shows that the snapshot passed verification.

The script writes to a temporary directory first. It verifies the temporary
directory. Then it renames the directory into place. The rename is atomic. A
failed run leaves no final snapshot.

`snapvault-verify.sh` verifies the checksums, rejects absolute member names
and members that contain `..`, extracts the media archive to a temporary
directory, and verifies the media index again.

## Why

A backup daemon adds a service that you must install, monitor, and upgrade.
This toolkit uses the tools that a PostgreSQL host usually has. A cron job is
sufficient. You do not need the root user.

The snapshot is self-describing. A reviewer can verify it with standard tools,
even without this toolkit. The `COMPLETE` marker and the strict name pattern
make retention safe.

## Install

1. Copy `snapvault.sh` and `snapvault-verify.sh` into one directory.
2. Make both files executable.

Requirements:

- bash 3.2 or later
- `pg_dump` (version equal to or newer than the database server)
- `tar`
- one SHA-256 tool: `sha256sum`, `gsha256sum`, or `shasum`
- `findmnt` (optional, Linux only, for the mount check)

Do not run the toolkit with the root user.

## Usage

### Make a snapshot

```sh
export SNAPVAULT_DATABASE_URL='postgres://backup@localhost/app_db'
export SNAPVAULT_MEDIA_ROOT=/mnt/app/media
export SNAPVAULT_BACKUP_DESTINATION=/mnt/backups/app

./snapvault.sh
```

The script prints the path of the final snapshot:

```
/mnt/backups/app/snapshot-20260101T030000Z
```

### Verify a snapshot

```sh
./snapvault-verify.sh /mnt/backups/app/snapshot-20260101T030000Z
```

A successful verification prints:

```
verified=/mnt/backups/app/snapshot-20260101T030000Z
```

To verify a snapshot that has no `COMPLETE` marker, add the
`--allow-incomplete` option. The backup script uses this option internally.

### Restore a snapshot

Extract the media archive and run `pg_restore` on the database dump:

```sh
tar -xzf media.tar.gz -C /mnt/app/media
pg_restore --dbname=app_db_restore database.dump
```

### Retention

Set `SNAPVAULT_RETENTION_DAYS` to delete old snapshots after each successful
run:

```sh
SNAPVAULT_RETENTION_DAYS=14 ./snapvault.sh
```

### Cron

Put the environment variables into a small wrapper script. Then call the
wrapper from cron:

```sh
15 3 * * * /opt/snapvault/run-backup.sh >>/var/log/snapvault.log 2>&1
```

## Snapshot layout

```
snapshot-20260101T030000Z/
├── COMPLETE
├── SHA256SUMS
├── database.dump
├── media-index.sha256
└── media.tar.gz
```

- `COMPLETE` contains one line: `completed_at=<timestamp>`.
- `database.dump` is a custom-format `pg_dump`.
- `media-index.sha256` lists the relative path and the SHA-256 of each media
  file.
- `media.tar.gz` contains the same media files.
- `SHA256SUMS` covers `database.dump`, `media.tar.gz`, and
  `media-index.sha256`.

During a run, the temporary directory is inside the destination. Its name is
`.<snapshot-name>.incomplete.XXXXXX`.

## Environment variables

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `SNAPVAULT_DATABASE_URL` | yes | none | PostgreSQL connection string. The script passes it to `pg_dump` as `PGDATABASE`. |
| `SNAPVAULT_MEDIA_ROOT` | yes | none | Media directory to archive. |
| `SNAPVAULT_BACKUP_DESTINATION` | yes | none | Parent directory for snapshots. |
| `SNAPVAULT_PREFIX` | no | `snapshot` | Snapshot name prefix. Lowercase letters, digits, and dashes only. |
| `SNAPVAULT_PG_DUMP_BIN` | no | `pg_dump` | Path or name of the `pg_dump` binary. |
| `SNAPVAULT_TIMESTAMP` | no | current UTC time | Snapshot timestamp in `YYYYMMDDTHHMMSSZ` form. |
| `SNAPVAULT_RETENTION_DAYS` | no | unset (keep all) | Delete complete snapshots older than this number of days. |
| `SNAPVAULT_TAR_BIN` | no | `tar` | Path or name of the `tar` binary. |
| `SNAPVAULT_SHA256SUM_BIN` | no | auto-detected | Path or name of the SHA-256 tool. |

`snapvault-verify.sh` uses `SNAPVAULT_TAR_BIN` and `SNAPVAULT_SHA256SUM_BIN`.

## Path validation

Both scripts reject unsafe paths:

- The path must be absolute.
- No path component can be a symbolic link.
- The path cannot be `/` or `$HOME`.
- The media root and the backup destination must be different directories.
- The backup destination must point inside a mount, not at the mount root.
  This check runs only when `findmnt` exists.

## Retention semantics

Retention runs only when `SNAPVAULT_RETENTION_DAYS` is set. The value must be a
non-negative integer of at most five digits. A value of `0` deletes snapshots
older than one day.

The script deletes a candidate only when all conditions are true:

- The directory is a direct child of `SNAPVAULT_BACKUP_DESTINATION`.
- The name matches `<prefix>-YYYYMMDDTHHMMSSZ` exactly.
- The directory is not a symbolic link.
- The directory contains a `COMPLETE` marker.
- The modification time is older than the given number of days.

Any other candidate stops the run with an error. The script never deletes the
new snapshot.

## Exit codes

| Program | Code | Meaning |
| --- | --- | --- |
| `snapvault.sh` | 0 | The snapshot is complete and verified. |
| `snapvault.sh` | 1 | A validation error occurred. |
| `snapvault.sh` | other | A tool failed. The exit code comes from that tool, for example `pg_dump`. |
| `snapvault-verify.sh` | 0 | The snapshot passed all checks. |
| `snapvault-verify.sh` | 1 | The snapshot failed a check or the arguments are wrong. |

## Limitations

- This toolkit does not replace pgBackRest, restic, or Borg for large
  installations. It has no WAL archiving, no point-in-time recovery, no
  incremental backup, no encryption, no remote storage, and no parallelism.
- The media directory can change during the run. The toolkit takes no lock and
  no filesystem snapshot. Stop the writers first, or use a filesystem snapshot.
- Every run makes a full `pg_dump` and a full media tarball.
- The mount check needs `findmnt`. On other systems the check is absent.
- GNU tar normalizes the file order, the modification times, and the owner.
  BSD tar has no `--mtime` and no `--sort` option. On BSD tar, the script
  normalizes the owner and uses its own sorted file list. The entry
  modification times stay as they are.
- The `shasum` fallback has no GNU `--strict` mode.
- `SNAPVAULT_DATABASE_URL`, `SNAPVAULT_MEDIA_ROOT` and
  `SNAPVAULT_BACKUP_DESTINATION` must not contain `$`, `${` or `}` so that
  an unresolved variable fails the run. Percent-encode those characters in
  a connection string.
- The toolkit does not encrypt the snapshot. Use an encrypted filesystem or an
  encrypted transport.

## Development

Run the syntax check on all scripts:

```sh
bash -n snapvault.sh
bash -n snapvault-verify.sh
bash -n test/snapvault.test.sh
```

Run the test suite:

```sh
bash test/snapvault.test.sh
```

The test suite injects a fake `pg_dump` through `SNAPVAULT_PG_DUMP_BIN` and
uses temporary directories. It
does not touch a real database. It covers tampering, failed dumps, retention,
path traversal, and the rejection of root, symlink, and unresolved-variable
destinations.

The CI workflow runs the same commands on Ubuntu 24.04.

## License

MIT. See [LICENSE](LICENSE).
