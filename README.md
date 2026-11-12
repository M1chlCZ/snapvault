# snapvault

A set of shell scripts that make verified snapshots of a PostgreSQL database
and a media directory. It runs without root access and without a background
service.

`snapvault.sh` writes one timestamped snapshot. `snapvault-verify.sh` checks it
later, on the same host or another one. `snapvault-restore.sh` verifies the
snapshot, extracts the media into a target directory, and optionally restores
the database with `pg_restore`.

A snapshot is either a directory or a single transport tarball, encrypted or
plain. The plain format is just files, so anyone can inspect it without this
toolkit.

## What it is

`snapvault.sh` takes a PostgreSQL connection target and a media directory. It
produces one snapshot with these properties:

- The name contains a UTC timestamp.
- The database is a custom-format `pg_dump`.
- The media is one gzip tarball. With GNU tar it is byte-deterministic. With
  BSD tar the member order and the owner are normalised; entry modification
  times stay as they are.
- A per-file `media-index.sha256` and a top-level `SHA256SUMS` cover the data.
- A `COMPLETE` marker shows that the snapshot passed verification.

The script writes to a temporary directory, verifies it, then publishes it. A
failed run leaves no final snapshot.

Two optional features change the published form:

- With `SNAPVAULT_AGE_RECIPIENT`, the script packs the verified snapshot
  directory into one `snapshot-<timestamp>.tar.gz.age` artifact and removes
  the plain directory. The published artifact is the encrypted tarball.
- With `SNAPVAULT_REMOTE`, the script publishes the transport tarball, plain
  or encrypted, on a remote host with the staging protocol below. Nothing
  stays in the local destination. A remote failure fails the run.

`snapvault-verify.sh` verifies the checksums, rejects absolute member names
and members that contain `..`, extracts the media archive to a temporary
directory and checks the media index again. For an artifact, it decrypts or
extracts into a private temporary directory first and cleans up afterwards.

## Why

A backup daemon adds a service you have to install, monitor and upgrade. This
toolkit uses tools a PostgreSQL host usually has, so a cron job is enough and
you don't need root.

The snapshot describes itself. A reviewer can verify it with standard tools,
even without this toolkit. The `COMPLETE` marker and the strict name pattern
make retention safe.

## Install

1. Copy `snapvault.sh`, `snapvault-verify.sh` and `snapvault-restore.sh` into
   one directory.
2. Make the files executable.

Requirements:

- bash 3.2 or later
- `pg_dump` (version equal to or newer than the database server)
- `tar`
- one SHA-256 tool: `sha256sum`, `gsha256sum` or `shasum`
- `pg_restore` (optional, only for `snapvault-restore.sh --database`)
- `age` (optional, only for encryption)
- `ssh` and a strict SSH setup (optional, only for remote publication)
- `sha256sum` on the remote host (optional, only for remote publication)
- `findmnt` (optional, Linux only, for the mount check)

Don't run the toolkit as root.

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

The argument can be a snapshot directory, an encrypted `.tar.gz.age` artifact
or a plain `.tar.gz` artifact. An encrypted artifact requires
`SNAPVAULT_AGE_IDENTITY_FILE`; see [Encrypt a snapshot](#encrypt-a-snapshot).

To verify a snapshot that has no `COMPLETE` marker, add the
`--allow-incomplete` option. The backup script uses this option internally.

### Snapshot status

`snapvault-status.sh` lists the snapshots in a destination. It reads names,
sizes and metadata only; it hashes nothing:

```sh
./snapvault-status.sh /backups
./snapvault-status.sh /backups --json
./snapvault-status.sh /backups --retention-days 7
```

The text output has one row per entry with its kind (`plain`, `encrypted`,
`transport` or `incomplete`), its state (`complete` or `incomplete`), its size
in bytes, its age in days and its name. With `--retention-days DAYS`, entries
that retention would delete carry an `(expired)` marker. The `--json` output
carries the same fields plus `destination`, `retentionDays`, and each entry's
`expired` flag and `completedAt` value when it is known. The exit code is `0`
when at least one entry exists, `1` when the destination has no snapshots, and
`2` when the arguments or the destination are wrong.

Two flags turn the report into a monitoring check:

- `--max-age-days DAYS` fails when the newest complete snapshot is older than
  `DAYS` whole days, or when no complete snapshot exists.
- `--require-complete` fails when a plain snapshot directory has no `COMPLETE`
  marker.

```sh
./snapvault-status.sh /backups --max-age-days 2 --require-complete --json
```

Findings print to standard error after the table in text mode. The JSON output
gains `maxAgeDays`, `requireComplete`, `healthy` and `problems`. A backup one
day and 23 hours old reports `ageDays: 1`, so compare the limit with whole
days. A cron check can rely on the exit code:

```sh
0 3 * * * /opt/snapvault/snapvault-status.sh /backups \
  --max-age-days 2 --require-complete --json >>/var/log/snapvault.jsonl ||
  /usr/local/bin/alert
```

### Restore a snapshot

```sh
./snapvault-restore.sh /mnt/backups/app/snapshot-20260101T030000Z /mnt/app/media
```

The script verifies the snapshot, then extracts the media archive into the
target directory with `tar` and `--no-same-owner`, so the restoring user owns
the files. It creates the target directory when it is missing and refuses a
non-empty target unless you add `--force`. With `--force`, it extracts over the
existing contents and leaves unrelated files in place.

The first argument accepts the same three forms as `snapvault-verify.sh`: a
directory, an encrypted artifact or a plain artifact.

To restore the database as well, pass a connection string:

```sh
./snapvault-restore.sh /mnt/backups/app/snapshot-20260101T030000Z /mnt/app/media \
  --database 'postgres://app@localhost/app_db'
```

The script calls `pg_restore` on `database.dump` with the URL in `PGDATABASE`.
A successful restore prints:

```
restored_media=/mnt/app/media
restored_database=ok
```

Without `--database`, the second line is `restored_database=skipped`. The
script never prints the URL, so credentials stay out of the logs. The toolkit
makes no promises about restored entry modification times; see
[Limitations](#limitations).

### Encrypt a snapshot

Set one age public recipient. The script calls
`age --encrypt --recipient` after it verifies the snapshot:

```sh
export SNAPVAULT_AGE_RECIPIENT='age1...'
./snapvault.sh
```

The script prints the path of the encrypted artifact:

```
/mnt/backups/app/snapshot-20260101T030000Z.tar.gz.age
```

The artifact contains the complete snapshot directory as one gzip tarball.
The script removes the plain snapshot directory after the artifact is ready,
so only the encrypted artifact remains in the destination.

The script prints the recipient in a redacted form only, for example
`age1abcde...wxyz`.

To verify or restore the artifact, supply the private identity file:

```sh
export SNAPVAULT_AGE_IDENTITY_FILE="$HOME/.age/app.key"
./snapvault-verify.sh /mnt/backups/app/snapshot-20260101T030000Z.tar.gz.age
./snapvault-restore.sh /mnt/backups/app/snapshot-20260101T030000Z.tar.gz.age /mnt/app/media
```

The identity file is read-only input. The toolkit never copies it into a
snapshot and never uploads it. Without `SNAPVAULT_AGE_IDENTITY_FILE`,
`snapvault-verify.sh` and `snapvault-restore.sh` fail with an error on an
encrypted artifact. They don't skip verification.

Retention never deletes an encrypted artifact; see
[Retention semantics](#retention-semantics).

### Publish to a remote host

Set the remote target, the remote directory and the usual local variables:

```sh
export SNAPVAULT_DATABASE_URL='postgres://backup@localhost/app_db'
export SNAPVAULT_MEDIA_ROOT=/mnt/app/media
export SNAPVAULT_BACKUP_DESTINATION=/mnt/backups/app
export SNAPVAULT_REMOTE='backup@app-nas'
export SNAPVAULT_REMOTE_DIR='/volume1/backups/app'

./snapvault.sh
```

The script prints the remote artifact:

```
backup@app-nas:/volume1/backups/app/snapshot-20260101T030000Z.tar.gz.age
```

The remote directory must exist already. The script doesn't create it and
never deletes a remote file.

The transport tarball is encrypted when `SNAPVAULT_AGE_RECIPIENT` is set and a
plain `.tar.gz` otherwise. The local destination is only a staging area.
After a successful run nothing remains in it. If the remote step fails, the
run fails. There is no local fallback copy.

The remote host needs `sha256sum`. The connection uses strict SSH options:

- `BatchMode=yes`: no password or passphrase prompt.
- `StrictHostKeyChecking=yes`: only known hosts.
- `ConnectTimeout=10`: a bounded connect time.

Prepare the SSH key and the `known_hosts` entry before the first run.

### The remote staging protocol

The script publishes one remote artifact in four steps:

1. Upload the transport tarball to `.<artifact-name>.incomplete` in the remote
   directory.
2. Read the remote SHA-256 with `ssh` and `sha256sum`.
3. Compare the remote checksum with the local checksum. A mismatch fails the
   run.
4. Rename the `.incomplete` file to the final name. The rename is atomic.

It beats a plain `rsync` copy:

- A reader can never see a partial artifact under the final name. The final
  name appears only after the upload is complete and its checksum matches.
- The checksum detects a truncated or changed upload before publication.
- The atomic rename is the commit point. An interrupted run leaves only a
  dot-prefixed `.incomplete` file, never a broken final artifact.

The toolkit never renames a `.incomplete` file that failed the checksum, and
it never deletes a remote file. A failed or interrupted run can leave a stale
`.incomplete` file; remove it on the remote host.

### Retention

Set `SNAPVAULT_RETENTION_DAYS` to delete old snapshots after each successful
run:

```sh
SNAPVAULT_RETENTION_DAYS=14 ./snapvault.sh
```

Retention works on plain snapshot directories in the local destination only.
See [Retention semantics](#retention-semantics).

Set `SNAPVAULT_RETENTION_DRY_RUN=1` to print the candidates that retention
would delete without deleting them. The candidates go to standard error, so
standard output still reports the new snapshot path:

```sh
SNAPVAULT_RETENTION_DAYS=14 SNAPVAULT_RETENTION_DRY_RUN=1 ./snapvault.sh
```

### Cron

Put the environment variables into a small wrapper script. Then call the
wrapper from cron:

```sh
15 3 * * * /opt/snapvault/run-backup.sh >>/var/log/snapvault.log 2>&1
```

## Snapshot layout

A plain snapshot is one directory:

```
snapshot-20260101T030000Z/
├── COMPLETE
├── SHA256SUMS
├── database.dump
├── media-index.sha256
└── media.tar.gz
```

An encrypted or remote snapshot is one transport tarball with the same files:

```
snapshot-20260101T030000Z.tar.gz.age
```

- `COMPLETE` contains one line: `completed_at=<timestamp>`.
- `database.dump` is a custom-format `pg_dump`.
- `media-index.sha256` lists the relative path and the SHA-256 of each media
  file.
- `media.tar.gz` contains the same media files.
- `SHA256SUMS` covers `database.dump`, `media.tar.gz` and
  `media-index.sha256`.

The transport tarball is a gzip tarball of the snapshot directory contents.
With `SNAPVAULT_AGE_RECIPIENT` the outer file is an age-encrypted tarball.
Without it the outer file is a plain `.tar.gz` with the name
`snapshot-<timestamp>.tar.gz`.

During a run, the temporary directory and the temporary transport directory
are inside the destination. Their names start with a dot:
`.<snapshot-name>.incomplete.XXXXXX` and
`.<snapshot-name>.transport.XXXXXX`.

## Environment variables

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `SNAPVAULT_DATABASE_URL` | yes | none | PostgreSQL connection string. The script passes it to `pg_dump` as `PGDATABASE`. |
| `SNAPVAULT_MEDIA_ROOT` | yes | none | Media directory to archive. |
| `SNAPVAULT_BACKUP_DESTINATION` | yes | none | Local staging directory for snapshots and artifacts. |
| `SNAPVAULT_PREFIX` | no | `snapshot` | Snapshot name prefix. Lowercase letters, digits and dashes only. |
| `SNAPVAULT_PG_DUMP_BIN` | no | `pg_dump` | Path or name of the `pg_dump` binary. |
| `SNAPVAULT_PG_RESTORE_BIN` | no | `pg_restore` | Path or name of the `pg_restore` binary. |
| `SNAPVAULT_TIMESTAMP` | no | current UTC time | Snapshot timestamp in `YYYYMMDDTHHMMSSZ` form. |
| `SNAPVAULT_RETENTION_DAYS` | no | unset (keep all) | Delete complete snapshots older than this number of days. Local plain directories only. |
| `SNAPVAULT_RETENTION_DRY_RUN` | no | unset | `1` prints the retention candidates to standard error without deleting them. |
| `SNAPVAULT_TAR_BIN` | no | `tar` | Path or name of the `tar` binary. |
| `SNAPVAULT_SHA256SUM_BIN` | no | auto-detected | Path or name of the SHA-256 tool. |
| `SNAPVAULT_AGE_RECIPIENT` | no | unset | One age public key (`age1...`). Enables encryption. |
| `SNAPVAULT_AGE_BIN` | no | `age` | Path or name of the `age` binary. |
| `SNAPVAULT_AGE_IDENTITY_FILE` | no | unset | Private age identity file. `snapvault-verify.sh` and `snapvault-restore.sh` need it for encrypted artifacts. |
| `SNAPVAULT_REMOTE` | no | unset | Remote target as `[user@]host`. Enables remote publication. |
| `SNAPVAULT_REMOTE_DIR` | no | unset | Absolute remote directory. Required with `SNAPVAULT_REMOTE`. |
| `SNAPVAULT_SSH_BIN` | no | `ssh` | Path or name of the `ssh` binary. |

`snapvault-verify.sh` and `snapvault-restore.sh` use `SNAPVAULT_TAR_BIN`,
`SNAPVAULT_SHA256SUM_BIN`, `SNAPVAULT_AGE_BIN` and
`SNAPVAULT_AGE_IDENTITY_FILE`. `snapvault-restore.sh` also uses
`SNAPVAULT_PG_RESTORE_BIN`.

## Path validation

All three scripts reject unsafe paths:

- The path must be absolute.
- No path component can be a symbolic link.
- The path cannot be `/` or `$HOME`.
- The media root and the backup destination must be different directories.
- The snapshot and the target directory must be different.
- The backup destination must point inside a mount, not at the mount root.
  This check runs only when `findmnt` exists.
- The snapshot input must exist. It can be a directory, a `.tar.gz` artifact
  or a `.tar.gz.age` artifact.
- The snapshot must contain a `COMPLETE` marker. For an artifact, the marker
  is inside the transport tarball.
- The target directory can be missing; the script creates it. A non-empty
  target requires `--force`.

`snapvault.sh` validates the remote settings before it connects:

- `SNAPVAULT_REMOTE` must be `[user@]host`. The user and host parts accept
  letters, digits, dots, dashes and underscores.
- `SNAPVAULT_REMOTE_DIR` must be an absolute path without empty, `.` or `..`
  components and without shell characters.

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

Retention covers plain snapshot directories only:

- The script never deletes an encrypted `.tar.gz.age` artifact or a plain
  `.tar.gz` artifact. Remove old artifacts yourself.
- The script never deletes a remote file. Remove old remote artifacts on the
  remote host yourself.
- In remote mode the script skips retention and prints a warning when
  `SNAPVAULT_RETENTION_DAYS` is set.

## Exit codes

| Program | Code | Meaning |
| --- | --- | --- |
| `snapvault.sh` | 0 | The snapshot is complete, verified and published. |
| `snapvault.sh` | 1 | A validation error occurred. |
| `snapvault.sh` | other | A tool failed. The exit code comes from that tool, for example `pg_dump`, `age` or `ssh`. |
| `snapvault-verify.sh` | 0 | The snapshot passed all checks. |
| `snapvault-verify.sh` | 1 | The snapshot failed a check or the arguments are wrong. |
| `snapvault-verify.sh` | other | A tool failed, for example `age` or `tar`. |
| `snapvault-restore.sh` | 0 | The media and the requested database restore completed. |
| `snapvault-restore.sh` | 1 | A validation error occurred, including a failed snapshot verification. |
| `snapvault-restore.sh` | other | A tool failed. The exit code comes from that tool, for example `tar`, `age` or `pg_restore`. |
| `snapvault-status.sh` | 0 | The report is healthy: at least one entry exists and no monitoring check failed. |
| `snapvault-status.sh` | 1 | The destination has no entries, or `--max-age-days` or `--require-complete` found a problem. |
| `snapvault-status.sh` | 2 | The arguments or the destination are wrong. |

## Limitations

- This toolkit does not replace pgBackRest, restic or Borg for large
  installations. It has no WAL archiving, no point-in-time recovery, no
  incremental backup and no parallelism.
- The media directory can change during the run. The toolkit takes no lock and
  no filesystem snapshot. Stop the writers first, or use a filesystem snapshot.
- Every run makes a full `pg_dump` and a full media tarball.
- The mount check needs `findmnt`. On other systems the check is absent.
- GNU tar normalises file order, modification times and owner. BSD tar has no
  `--mtime` or `--sort`, so the script normalises the owner and supplies its
  own sorted file list; entry modification times stay as they are.
- The toolkit makes no promises about restored entry modification times.
  Snapshots from GNU tar normalise entry modification times to 1970-01-01;
  BSD tar keeps the original times. Modes follow tar extraction semantics.
- The `shasum` fallback has no GNU `--strict` mode.
- `SNAPVAULT_DATABASE_URL`, `SNAPVAULT_MEDIA_ROOT` and
  `SNAPVAULT_BACKUP_DESTINATION` must not contain `$`, `${` or `}` so that
  an unresolved variable fails the run. Percent-encode those characters in
  a connection string.
- Encryption needs the `age` binary and one public recipient. The snapshot
  stays unencrypted in the staging directory while the run is in progress. A
  crash can leave the plain staging directory behind; remove it yourself.
- The identity file is read-only input. The toolkit never writes, copies or
  uploads it, and it prints the recipient in a redacted form only.
- Remote publication needs `ssh` and a reachable remote directory. The toolkit
  never creates or deletes remote files.
- Remote retention is not available. The toolkit never deletes a remote
  artifact and it skips `SNAPVAULT_RETENTION_DAYS` in remote mode.
- A failed or interrupted remote run can leave a dot-prefixed `.incomplete`
  file on the remote host. It is never a published artifact.
- The remote host must provide `sha256sum`.
- The toolkit encrypts the transport tarball, not the individual media files.
  The media inside `media.tar.gz` stays byte-identical.

## Development

Run the syntax check on all scripts:

```sh
bash -n snapvault.sh
bash -n snapvault-verify.sh
bash -n snapvault-restore.sh
bash -n test/snapvault.test.sh
```

Run the test suite:

```sh
bash test/snapvault.test.sh
```

The test suite injects fake `pg_dump`, `pg_restore`, `age` and `ssh` binaries
through the `SNAPVAULT_*_BIN` variables and uses temporary directories. It
does not touch a real database or a real remote host. It covers tampering,
failed dumps, retention, path traversal, and the rejection of root, symlink and
unresolved-variable destinations. It also covers the restore round trip,
`--force`, missing `COMPLETE` markers, the `pg_restore` invocation, encrypted
publication, artifact verification and restore with and without an identity,
remote staging with a checksum and an atomic rename, a checksum mismatch, a
remote failure without a local fallback, and plain remote publication.

The CI workflow runs the same commands on Ubuntu 24.04.

## Licence

MIT. See [LICENSE](LICENSE).
