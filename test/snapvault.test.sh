#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
backup_script="$repo_root/snapvault.sh"
verify_script="$repo_root/snapvault-verify.sh"
restore_script="$repo_root/snapvault-restore.sh"
test_root=$(mktemp -d)
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

assert_file() {
  test -f "$1" || fail "missing file: $1"
}

hash_command() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  elif command -v gsha256sum >/dev/null 2>&1; then
    gsha256sum "$@"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    return 1
  fi
}

set_mtime_days_ago() {
  local target=$1
  local days=$2
  local stamp
  if stamp=$(date -u -d "$days days ago" +%Y%m%d%H%M 2>/dev/null); then
    touch -t "$stamp" "$target"
    return 0
  fi
  if stamp=$(date -u -v-"${days}"d +%Y%m%d%H%M 2>/dev/null); then
    touch -t "$stamp" "$target"
    return 0
  fi
  return 1
}

craft_traversal_archive() {
  local target=$1
  local staging
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    payload = b"escape\n"
    member = tarfile.TarInfo("../escape.txt")
    member.size = len(payload)
    member.mtime = 0
    archive.addfile(member, io.BytesIO(payload))
PY
    return 0
  fi
  if tar --version 2>/dev/null | head -n 1 | grep -q 'GNU tar'; then
    staging=$(mktemp -d "$test_root/.traversal.XXXXXX")
    printf 'escape\n' >"$staging/escape.txt"
    (cd "$staging" && tar --transform='s|^|../|' --create --gzip --file="$target" escape.txt)
    rm -rf -- "$staging"
    return 0
  fi
  printf 'SKIP: cannot craft a traversal archive (python3 or GNU tar is required)\n'
  return 1
}

destination="$test_root/backups"
media_root="$test_root/media"
fake_bin="$test_root/bin"
mkdir -p "$destination" "$media_root/media-sources" "$media_root/media-derivatives" "$fake_bin"
printf 'source bytes\n' >"$media_root/media-sources/source.webp"
printf 'derivative bytes\n' >"$media_root/media-derivatives/derived.avif"

cat >"$fake_bin/pg_dump" <<'EOF'
#!/bin/sh
set -eu
test "${PGDATABASE:-}" = "postgres://backup-test"
test "${FAKE_PG_DUMP_FAIL:-0}" != "1" || exit 42
output=
for argument in "$@"; do
  case "$argument" in
    --file=*) output=${argument#--file=} ;;
  esac
done
test -n "$output"
printf 'database dump\n' >"$output"
EOF
chmod +x "$fake_bin/pg_dump"

cat >"$fake_bin/pg_restore" <<'EOF'
#!/bin/sh
set -eu
test "${PGDATABASE:-}" = "postgres://restore-test"
test "${FAKE_PG_RESTORE_FAIL:-0}" != "1" || exit 43
test "$#" -eq 1
printf '%s\n%s\n' "$PGDATABASE" "$1" >"${FAKE_PG_RESTORE_LOG:?}"
EOF
chmod +x "$fake_bin/pg_restore"

run_backup() {
  SNAPVAULT_BACKUP_DESTINATION="$destination" \
  SNAPVAULT_MEDIA_ROOT="$media_root" \
  SNAPVAULT_DATABASE_URL="postgres://backup-test" \
  SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
  SNAPVAULT_TIMESTAMP="$1" \
  "$backup_script"
}

snapshot=$(run_backup 20260829T120000Z)
expected="$destination/snapshot-20260829T120000Z"
test "$snapshot" = "$expected" || fail "backup did not report its final snapshot"
test -d "$expected" || fail "timestamped snapshot was not created"
assert_file "$expected/database.dump"
assert_file "$expected/media.tar.gz"
assert_file "$expected/media-index.sha256"
assert_file "$expected/SHA256SUMS"
assert_file "$expected/COMPLETE"
grep -q 'media-sources/source.webp' "$expected/media-index.sha256" ||
  fail "media index does not list the source media file"
grep -q 'media-derivatives/derived.avif' "$expected/media-index.sha256" ||
  fail "media index does not list the derived media file"
"$verify_script" "$expected" >/dev/null

printf 'tampered\n' >>"$expected/database.dump"
expect_failure "$verify_script" "$expected"

media_snapshot=$(run_backup 20260829T120050Z)
printf 'tampered\n' >>"$media_snapshot/media.tar.gz"
expect_failure "$verify_script" "$media_snapshot"

traversal_snapshot=$(run_backup 20260829T120150Z)
if craft_traversal_archive "$traversal_snapshot/media.tar.gz"; then
  (cd "$traversal_snapshot" && hash_command database.dump media.tar.gz media-index.sha256 >SHA256SUMS)
  if "$verify_script" "$traversal_snapshot" >/dev/null 2>"$test_root/traversal.err"; then
    fail "traversal archive was accepted"
  fi
  grep -q 'unsafe path' "$test_root/traversal.err" ||
    fail "traversal archive was rejected with the wrong error"
fi

FAKE_PG_DUMP_FAIL=1 \
SNAPVAULT_BACKUP_DESTINATION="$destination" \
SNAPVAULT_MEDIA_ROOT="$media_root" \
SNAPVAULT_DATABASE_URL="postgres://backup-test" \
SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
SNAPVAULT_TIMESTAMP=20260829T120100Z \
expect_failure "$backup_script"
test ! -e "$destination/snapshot-20260829T120100Z" ||
  fail "failed backup left a final snapshot"
if find "$destination" -maxdepth 1 -name '.snapshot-20260829T120100Z.incomplete.*' -print -quit | grep -q .; then
  fail "failed backup left an incomplete directory"
fi

old_snapshot="$destination/snapshot-20000101T000000Z"
mkdir "$old_snapshot"
touch "$old_snapshot/COMPLETE"
if set_mtime_days_ago "$old_snapshot" 4; then
  SNAPVAULT_RETENTION_DAYS=1 run_backup 20260829T120200Z >/dev/null
  test ! -e "$old_snapshot" || fail "expired snapshot was not pruned"
  test -d "$destination" || fail "retention removed the destination root"
  test -d "$destination/snapshot-20260829T120200Z" ||
    fail "retention removed the current snapshot"
else
  printf 'SKIP: cannot set a directory mtime; retention pruning is not exercised\n'
fi

incomplete_snapshot="$destination/snapshot-20000101T010000Z"
mkdir "$incomplete_snapshot"
if set_mtime_days_ago "$incomplete_snapshot" 4; then
  expect_failure env \
    SNAPVAULT_BACKUP_DESTINATION="$destination" \
    SNAPVAULT_MEDIA_ROOT="$media_root" \
    SNAPVAULT_DATABASE_URL="postgres://backup-test" \
    SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
    SNAPVAULT_TIMESTAMP=20260829T120250Z \
    SNAPVAULT_RETENTION_DAYS=1 \
    "$backup_script"
  test -d "$incomplete_snapshot" ||
    fail "retention deleted a snapshot without a COMPLETE marker"
  test -d "$destination/snapshot-20260829T120250Z" ||
    fail "retention failure removed the new snapshot"
else
  printf 'SKIP: cannot set a directory mtime; incomplete-snapshot retention safety is not exercised\n'
fi

expect_failure env \
  SNAPVAULT_BACKUP_DESTINATION=/ \
  SNAPVAULT_MEDIA_ROOT="$media_root" \
  SNAPVAULT_DATABASE_URL=postgres://backup-test \
  SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
  SNAPVAULT_TIMESTAMP=20260829T120300Z \
  "$backup_script"

expect_failure env \
  'SNAPVAULT_BACKUP_DESTINATION=$UNRESOLVED_DESTINATION' \
  SNAPVAULT_MEDIA_ROOT="$media_root" \
  SNAPVAULT_DATABASE_URL=postgres://backup-test \
  SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
  SNAPVAULT_TIMESTAMP=20260829T120400Z \
  "$backup_script"

symlink_destination="$test_root/symlink-backups"
ln -s "$destination" "$symlink_destination"
expect_failure env \
  SNAPVAULT_BACKUP_DESTINATION="$symlink_destination" \
  SNAPVAULT_MEDIA_ROOT="$media_root" \
  SNAPVAULT_DATABASE_URL=postgres://backup-test \
  SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
  SNAPVAULT_TIMESTAMP=20260829T120500Z \
  "$backup_script"

restore_source=$(run_backup 20260829T130000Z)
restored_media="$test_root/restored-media"
restore_output=$("$restore_script" "$restore_source" "$restored_media")
printf '%s\n' "$restore_output" | grep -q "^restored_media=$restored_media$" ||
  fail "restore did not report restored_media"
printf '%s\n' "$restore_output" | grep -q '^restored_database=skipped$' ||
  fail "restore without --database did not report restored_database=skipped"
cmp "$media_root/media-sources/source.webp" "$restored_media/media-sources/source.webp" ||
  fail "restored source media differs from the original"
cmp "$media_root/media-derivatives/derived.avif" "$restored_media/media-derivatives/derived.avif" ||
  fail "restored derived media differs from the original"
(cd "$restored_media" && hash_command -c "$restore_source/media-index.sha256") >/dev/null ||
  fail "restored media does not match the media index"

occupied_target="$test_root/occupied-restore-target"
mkdir "$occupied_target"
printf 'stale\n' >"$occupied_target/stale.txt"
expect_failure "$restore_script" "$restore_source" "$occupied_target"
test ! -e "$occupied_target/media-sources/source.webp" ||
  fail "refused restore extracted media into a non-empty target"
"$restore_script" "$restore_source" "$occupied_target" --force >/dev/null
cmp "$media_root/media-sources/source.webp" "$occupied_target/media-sources/source.webp" ||
  fail "--force restore did not extract the media"
test -f "$occupied_target/stale.txt" ||
  fail "--force restore deleted an unrelated file"

incomplete_source="$test_root/incomplete-restore-source"
cp -R "$restore_source" "$incomplete_source"
rm -- "$incomplete_source/COMPLETE"
missing_marker_target="$test_root/missing-marker-restore-target"
if "$restore_script" "$incomplete_source" "$missing_marker_target" \
  >/dev/null 2>"$test_root/incomplete-restore.err"; then
  fail "snapshot without a COMPLETE marker was accepted"
fi
grep -q 'COMPLETE marker' "$test_root/incomplete-restore.err" ||
  fail "missing COMPLETE marker was rejected with the wrong error"
test ! -e "$missing_marker_target" ||
  fail "rejected snapshot created the restore target"

tampered_source="$test_root/tampered-restore-source"
cp -R "$restore_source" "$tampered_source"
printf 'tampered\n' >>"$tampered_source/database.dump"
tampered_target="$test_root/tampered-restore-target"
if "$restore_script" "$tampered_source" "$tampered_target" \
  >/dev/null 2>"$test_root/tampered-restore.err"; then
  fail "tampered snapshot was accepted by restore"
fi
grep -q 'verification failed' "$test_root/tampered-restore.err" ||
  fail "tampered snapshot was rejected with the wrong error"
test ! -e "$tampered_target" ||
  fail "tampered snapshot created the restore target"

database_target="$test_root/restored-database-target"
pg_restore_log="$test_root/pg-restore.log"
database_output=$(env \
  SNAPVAULT_PG_RESTORE_BIN="$fake_bin/pg_restore" \
  FAKE_PG_RESTORE_LOG="$pg_restore_log" \
  "$restore_script" "$restore_source" "$database_target" --database 'postgres://restore-test')
test "$(sed -n '1p' "$pg_restore_log")" = 'postgres://restore-test' ||
  fail "pg_restore did not receive the database URL through PGDATABASE"
test "$(sed -n '2p' "$pg_restore_log")" = "$restore_source/database.dump" ||
  fail "pg_restore did not receive the snapshot database dump"
printf '%s\n' "$database_output" | grep -q "^restored_database=ok$" ||
  fail "restore with --database did not report success"
cmp "$media_root/media-sources/source.webp" "$database_target/media-sources/source.webp" ||
  fail "restore with --database did not extract the media"

pg_restore_status=0
env \
  SNAPVAULT_PG_RESTORE_BIN="$fake_bin/pg_restore" \
  FAKE_PG_RESTORE_LOG="$test_root/pg-restore-fail.log" \
  FAKE_PG_RESTORE_FAIL=1 \
  "$restore_script" "$restore_source" "$test_root/failed-database-target" \
  --database 'postgres://restore-test' ||
  pg_restore_status=$?
test "$pg_restore_status" -eq 43 ||
  fail "a failing pg_restore did not propagate its exit code"

missing_pg_restore_target="$test_root/missing-pg-restore-target"
if env \
  SNAPVAULT_PG_RESTORE_BIN="$fake_bin/pg_restore-missing" \
  "$restore_script" "$restore_source" "$missing_pg_restore_target" \
  --database 'postgres://restore-test' >/dev/null 2>"$test_root/missing-pg-restore.err"; then
  fail "restore with a missing pg_restore succeeded"
fi
grep -q 'PG_RESTORE_BIN' "$test_root/missing-pg-restore.err" ||
  fail "missing pg_restore was rejected with the wrong error"
test ! -e "$missing_pg_restore_target" ||
  fail "missing pg_restore still created the restore target"

expect_failure "$restore_script" "$restore_source" relative-restore-target
expect_failure "$restore_script" "$restore_source" /
expect_failure "$restore_script" "$test_root/does-not-exist" "$test_root/unused-target"
expect_failure "$restore_script" "$restore_source" "$restore_source"
symlink_restore_target="$test_root/symlink-restore-target"
ln -s "$test_root/real-restore-target" "$symlink_restore_target"
expect_failure "$restore_script" "$restore_source" "$symlink_restore_target"

printf 'PASS: database and media snapshots are complete, verified, restorable and safely retained\n'
