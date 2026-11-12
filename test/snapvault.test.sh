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

cat >"$fake_bin/age" <<'EOF'
#!/bin/sh
set -eu
mode=
recipient=
identity=
output=
input=
while test "$#" -gt 0; do
  case "$1" in
    --encrypt) mode=encrypt ;;
    --decrypt) mode=decrypt ;;
    --recipient)
      shift
      recipient=$1
      ;;
    --identity)
      shift
      identity=$1
      ;;
    --output)
      shift
      output=$1
      ;;
    -e) mode=encrypt ;;
    -d) mode=decrypt ;;
    -r)
      shift
      recipient=$1
      ;;
    -i)
      shift
      identity=$1
      ;;
    -o)
      shift
      output=$1
      ;;
    *)
      input=$1
      ;;
  esac
  shift
done
if test "${FAKE_AGE_FAIL:-0}" = "1"; then
  printf 'fake age: forced failure\n' >&2
  exit 91
fi
test -n "$mode" || { printf 'fake age: mode is required\n' >&2; exit 64; }
test -n "$output" || { printf 'fake age: output is required\n' >&2; exit 64; }
test -n "$input" || { printf 'fake age: input is required\n' >&2; exit 64; }
case "$mode" in
  encrypt)
    test -n "$recipient" || { printf 'fake age: recipient is required\n' >&2; exit 64; }
    if test -n "${FAKE_AGE_RECIPIENT_LOG:-}"; then
      printf '%s\n' "$recipient" >>"$FAKE_AGE_RECIPIENT_LOG"
    fi
    printf 'FAKE-AGE-1\n' >"$output"
    cat "$input" >>"$output"
    ;;
  decrypt)
    test -n "$identity" || { printf 'fake age: identity is required\n' >&2; exit 64; }
    if ! grep -q 'FAKE-AGE-IDENTITY' "$identity"; then
      printf 'fake age: unknown identity\n' >&2
      exit 92
    fi
    if test "$(head -c 10 "$input")" != 'FAKE-AGE-1'; then
      printf 'fake age: input is not encrypted\n' >&2
      exit 93
    fi
    tail -c +12 "$input" >"$output"
    ;;
  *)
    printf 'fake age: unknown mode\n' >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fake_bin/age"

cat >"$fake_bin/ssh" <<'EOF'
#!/bin/sh
set -eu
log=${FAKE_SSH_LOG:-}
batch=0
strict=0
connect=
while test "$#" -gt 0; do
  case "$1" in
    -o)
      shift
      test "$#" -gt 0 || { printf 'fake ssh: missing option value\n' >&2; exit 64; }
      case "$1" in
        BatchMode=yes) batch=1 ;;
        StrictHostKeyChecking=yes) strict=1 ;;
        ConnectTimeout=*) connect=${1#ConnectTimeout=} ;;
        *)
          printf 'fake ssh: unexpected option: %s\n' "$1" >&2
          exit 64
          ;;
      esac
      ;;
    -*)
      printf 'fake ssh: unexpected option: %s\n' "$1" >&2
      exit 64
      ;;
    *)
      break
      ;;
  esac
  shift
done
test "$batch" -eq 1 && test "$strict" -eq 1 ||
  { printf 'fake ssh: strict options are required\n' >&2; exit 65; }
case "$connect" in
  ''|*[!0-9]*)
    printf 'fake ssh: a numeric ConnectTimeout is required\n' >&2
    exit 65
    ;;
esac
test "$#" -eq 2 || { printf 'fake ssh: expected a host and one command\n' >&2; exit 66; }
host=$1
shift
command=$1
if test -n "$log"; then
  printf '%s\t%s\n' "$host" "$command" >>"$log"
fi
if test "${FAKE_SSH_FAIL:-0}" = "1"; then
  printf 'fake ssh: forced failure\n' >&2
  exit 90
fi
case "$command" in
  sha256sum*)
    if test "${FAKE_SSH_WRONG_DIGEST:-0}" = "1"; then
      printf '%s  wrong\n' '0000000000000000000000000000000000000000000000000000000000000000'
      exit 0
    fi
    ;;
esac
shim_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/remote
exec env PATH="$shim_dir:$PATH" sh -c "$command"
EOF
chmod +x "$fake_bin/ssh"

remote_bin="$fake_bin/remote"
sha_tool=
for candidate in sha256sum gsha256sum shasum; do
  if command -v "$candidate" >/dev/null 2>&1; then
    sha_tool=$(command -v "$candidate")
    break
  fi
done
test -n "$sha_tool" || fail "no SHA-256 tool found for the fake remote"
mkdir -p "$remote_bin"
if test "${sha_tool##*/}" = shasum; then
  {
    printf '#!/bin/sh\n'
    printf 'exec "%s" -a 256 "$@"\n' "$sha_tool"
  } >"$remote_bin/sha256sum"
else
  {
    printf '#!/bin/sh\n'
    printf 'exec "%s" "$@"\n' "$sha_tool"
  } >"$remote_bin/sha256sum"
fi
chmod +x "$remote_bin/sha256sum"

identity_file="$test_root/identity.agekey"
printf 'FAKE-AGE-IDENTITY\n' >"$identity_file"
wrong_identity_file="$test_root/wrong-identity.agekey"
printf 'FAKE-AGE-OTHER\n' >"$wrong_identity_file"
recipient="age1$(printf 'q%.0s' {1..58})"

encrypted_artifact="$destination/snapshot-20260829T140000Z.tar.gz.age"
encrypted_output=$(SNAPVAULT_AGE_RECIPIENT="$recipient" \
  SNAPVAULT_AGE_BIN="$fake_bin/age" \
  SNAPVAULT_BACKUP_DESTINATION="$destination" \
  SNAPVAULT_MEDIA_ROOT="$media_root" \
  SNAPVAULT_DATABASE_URL="postgres://backup-test" \
  SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
  SNAPVAULT_TIMESTAMP=20260829T140000Z \
  "$backup_script" 2>"$test_root/encrypted.err")
test "$encrypted_output" = "$encrypted_artifact" ||
  fail "encrypted backup did not report its artifact"
assert_file "$encrypted_artifact"
test ! -e "$destination/snapshot-20260829T140000Z" ||
  fail "encrypted backup kept the plain snapshot directory"
case "$encrypted_output" in
  *"$recipient"*) fail "encrypted backup printed the full recipient" ;;
esac
if grep -qF "$recipient" "$test_root/encrypted.err"; then
  fail "encrypted backup logged the full recipient"
fi
grep -q 'encrypting for recipient age1' "$test_root/encrypted.err" ||
  fail "encrypted backup did not log a redacted recipient"
if find "$destination" -maxdepth 1 -name '.snapshot-20260829T140000Z*' -print -quit | grep -q .; then
  fail "encrypted backup left staging directories"
fi

env SNAPVAULT_AGE_BIN="$fake_bin/age" SNAPVAULT_AGE_IDENTITY_FILE="$identity_file" \
  "$verify_script" "$encrypted_artifact" >/dev/null ||
  fail "the encrypted artifact did not verify with the identity"
PATH="$fake_bin:$PATH" env SNAPVAULT_AGE_IDENTITY_FILE="$identity_file" \
  "$verify_script" "$encrypted_artifact" >/dev/null ||
  fail "the encrypted artifact did not verify with a PATH-injected age"

if env SNAPVAULT_AGE_BIN="$fake_bin/age" SNAPVAULT_AGE_IDENTITY_FILE= \
  "$verify_script" "$encrypted_artifact" >/dev/null 2>"$test_root/verify-no-identity.err"; then
  fail "verify accepted an encrypted artifact without an identity"
fi
grep -q 'AGE_IDENTITY_FILE' "$test_root/verify-no-identity.err" ||
  fail "verify rejected a missing identity with the wrong error"

if env SNAPVAULT_AGE_BIN="$fake_bin/age" SNAPVAULT_AGE_IDENTITY_FILE="$wrong_identity_file" \
  "$verify_script" "$encrypted_artifact" >/dev/null 2>"$test_root/verify-wrong-identity.err"; then
  fail "verify accepted a wrong identity"
fi

restored_encrypted="$test_root/restored-encrypted"
encrypted_restore_output=$(env \
  SNAPVAULT_AGE_BIN="$fake_bin/age" \
  SNAPVAULT_AGE_IDENTITY_FILE="$identity_file" \
  "$restore_script" "$encrypted_artifact" "$restored_encrypted")
printf '%s\n' "$encrypted_restore_output" | grep -q "^restored_media=$restored_encrypted$" ||
  fail "restore from an encrypted artifact did not report restored_media"
cmp "$media_root/media-sources/source.webp" "$restored_encrypted/media-sources/source.webp" ||
  fail "restore from an encrypted artifact extracted different media"

missing_identity_target="$test_root/missing-identity-target"
if env SNAPVAULT_AGE_BIN="$fake_bin/age" SNAPVAULT_AGE_IDENTITY_FILE= \
  "$restore_script" "$encrypted_artifact" "$missing_identity_target" \
  >/dev/null 2>"$test_root/restore-no-identity.err"; then
  fail "restore accepted an encrypted artifact without an identity"
fi
grep -q 'AGE_IDENTITY_FILE' "$test_root/restore-no-identity.err" ||
  fail "restore rejected a missing identity with the wrong error"
test ! -e "$missing_identity_target" ||
  fail "restore without an identity created the target directory"

printf 'not a snapshot\n' >"$test_root/unknown-artifact.bin"
if "$verify_script" "$test_root/unknown-artifact.bin" >/dev/null 2>"$test_root/unknown-artifact.err"; then
  fail "verify accepted a file with an unknown suffix"
fi
grep -q 'tar.gz' "$test_root/unknown-artifact.err" ||
  fail "an unknown artifact suffix was rejected with the wrong error"

remote_dir="$test_root/remote"
ssh_log="$test_root/ssh.log"
mkdir -p "$remote_dir"

run_remote_backup() {
  local timestamp=$1
  env \
    SNAPVAULT_REMOTE="fake@remote.example" \
    SNAPVAULT_REMOTE_DIR="$remote_dir" \
    SNAPVAULT_SSH_BIN="$fake_bin/ssh" \
    FAKE_SSH_LOG="$ssh_log" \
    SNAPVAULT_BACKUP_DESTINATION="$destination" \
    SNAPVAULT_MEDIA_ROOT="$media_root" \
    SNAPVAULT_DATABASE_URL="postgres://backup-test" \
    SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
    SNAPVAULT_TIMESTAMP="$timestamp" \
    "$backup_script"
}

expect_backup_failure() {
  expect_failure env \
    SNAPVAULT_BACKUP_DESTINATION="$destination" \
    SNAPVAULT_MEDIA_ROOT="$media_root" \
    SNAPVAULT_DATABASE_URL="postgres://backup-test" \
    SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
    SNAPVAULT_TIMESTAMP=20260829T150300Z \
    "$@" \
    "$backup_script"
}

: >"$ssh_log"
remote_encrypted_output=$(SNAPVAULT_AGE_RECIPIENT="$recipient" \
  SNAPVAULT_AGE_BIN="$fake_bin/age" \
  run_remote_backup 20260829T150000Z 2>"$test_root/remote-encrypted.err") ||
  fail "encrypted remote backup failed"
remote_encrypted_name=snapshot-20260829T150000Z.tar.gz.age
remote_encrypted_artifact="$remote_dir/$remote_encrypted_name"
test "$remote_encrypted_output" = "fake@remote.example:$remote_encrypted_artifact" ||
  fail "remote backup did not report the remote artifact"
assert_file "$remote_encrypted_artifact"
if find "$remote_dir" -maxdepth 1 -name '*.incomplete' -print -quit | grep -q .; then
  fail "remote backup left an .incomplete file"
fi
if find "$destination" -maxdepth 1 \
  \( -name 'snapshot-20260829T150000Z*' -o -name '.snapshot-20260829T150000Z*' \) \
  -print -quit | grep -q .; then
  fail "remote backup left a local artifact or staging directory"
fi
env SNAPVAULT_AGE_BIN="$fake_bin/age" SNAPVAULT_AGE_IDENTITY_FILE="$identity_file" \
  "$verify_script" "$remote_encrypted_artifact" >/dev/null ||
  fail "the remote encrypted artifact did not verify"
upload_line=$(grep -nF "cat > '$remote_dir/.$remote_encrypted_name.incomplete'" "$ssh_log" |
  sed -n '1s/:.*//p' || true)
checksum_line=$(grep -nF "sha256sum '$remote_dir/.$remote_encrypted_name.incomplete'" "$ssh_log" |
  sed -n '1s/:.*//p' || true)
rename_line=$(grep -nF "mv -- '$remote_dir/.$remote_encrypted_name.incomplete' '$remote_encrypted_artifact'" "$ssh_log" |
  sed -n '1s/:.*//p' || true)
test -n "$upload_line" || fail "the artifact was not uploaded to a staging name"
test -n "$checksum_line" || fail "the remote checksum was not checked"
test -n "$rename_line" || fail "the staged artifact was not renamed"
test "$upload_line" -lt "$checksum_line" ||
  fail "the remote checksum ran before the upload"
test "$checksum_line" -lt "$rename_line" ||
  fail "the remote rename ran before the checksum"
if grep -Eq 'rm --|rm -|rmdir' "$ssh_log"; then
  fail "a remote command attempted a deletion"
fi

: >"$ssh_log"
mismatch_status=0
FAKE_SSH_WRONG_DIGEST=1 SNAPVAULT_AGE_RECIPIENT="$recipient" SNAPVAULT_AGE_BIN="$fake_bin/age" \
  run_remote_backup 20260829T150050Z >/dev/null 2>"$test_root/remote-mismatch.err" ||
  mismatch_status=$?
test "$mismatch_status" -ne 0 || fail "a remote checksum mismatch succeeded"
grep -q 'checksum differs' "$test_root/remote-mismatch.err" ||
  fail "a remote checksum mismatch produced the wrong error"
test ! -e "$remote_dir/snapshot-20260829T150050Z.tar.gz.age" ||
  fail "a remote checksum mismatch published the artifact"
test -f "$remote_dir/.snapshot-20260829T150050Z.tar.gz.age.incomplete" ||
  fail "a remote checksum mismatch deleted the staging file"
if grep -F 'mv -- ' "$ssh_log" | grep -qF '150050Z'; then
  fail "a remote checksum mismatch renamed the staging file"
fi

: >"$ssh_log"
failure_status=0
FAKE_SSH_FAIL=1 SNAPVAULT_AGE_RECIPIENT="$recipient" SNAPVAULT_AGE_BIN="$fake_bin/age" \
  run_remote_backup 20260829T150100Z >/dev/null 2>"$test_root/remote-fail.err" ||
  failure_status=$?
test "$failure_status" -eq 90 ||
  fail "remote failure did not propagate the ssh exit code"
test ! -e "$remote_dir/snapshot-20260829T150100Z.tar.gz.age" ||
  fail "remote failure published the artifact"
test ! -e "$remote_dir/.snapshot-20260829T150100Z.tar.gz.age.incomplete" ||
  fail "remote failure left a staging file"
if find "$destination" -maxdepth 1 \
  \( -name 'snapshot-20260829T150100Z*' -o -name '.snapshot-20260829T150100Z*' \) \
  -print -quit | grep -q .; then
  fail "remote failure left a local fallback"
fi

: >"$ssh_log"
plain_remote_output=$(env \
  PATH="$fake_bin:$PATH" \
  SNAPVAULT_REMOTE="fake@remote.example" \
  SNAPVAULT_REMOTE_DIR="$remote_dir" \
  FAKE_SSH_LOG="$ssh_log" \
  SNAPVAULT_BACKUP_DESTINATION="$destination" \
  SNAPVAULT_MEDIA_ROOT="$media_root" \
  SNAPVAULT_DATABASE_URL="postgres://backup-test" \
  SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
  SNAPVAULT_TIMESTAMP=20260829T150200Z \
  "$backup_script") ||
  fail "plain remote backup with a PATH-injected ssh failed"
plain_remote_name=snapshot-20260829T150200Z.tar.gz
plain_remote_artifact="$remote_dir/$plain_remote_name"
test "$plain_remote_output" = "fake@remote.example:$plain_remote_artifact" ||
  fail "plain remote backup reported the wrong artifact"
assert_file "$plain_remote_artifact"
"$verify_script" "$plain_remote_artifact" >/dev/null ||
  fail "the plain remote artifact did not verify"
if find "$remote_dir" -maxdepth 1 -name ".$plain_remote_name.incomplete" -print -quit | grep -q .; then
  fail "plain remote backup left an .incomplete file"
fi
plain_remote_restore="$test_root/restored-plain-remote"
"$restore_script" "$plain_remote_artifact" "$plain_remote_restore" >/dev/null ||
  fail "restore from a plain remote artifact failed"
cmp "$media_root/media-sources/source.webp" "$plain_remote_restore/media-sources/source.webp" ||
  fail "restore from a plain remote artifact extracted different media"

retention_output=$(SNAPVAULT_RETENTION_DAYS=1 run_remote_backup 20260829T150250Z 2>&1 >/dev/null) ||
  fail "remote backup with retention failed"
printf '%s\n' "$retention_output" | grep -q 'ignored in remote mode' ||
  fail "remote retention did not warn"

expect_backup_failure \
  SNAPVAULT_REMOTE="fake@remote.example" \
  SNAPVAULT_REMOTE_DIR="relative/remote" \
  SNAPVAULT_SSH_BIN="$fake_bin/ssh"
expect_backup_failure \
  SNAPVAULT_REMOTE="fake@remote.example" \
  SNAPVAULT_REMOTE_DIR='/remote;rm -rf /' \
  SNAPVAULT_SSH_BIN="$fake_bin/ssh"
expect_backup_failure SNAPVAULT_REMOTE_DIR="$remote_dir"
expect_backup_failure SNAPVAULT_REMOTE="user@-host" \
  SNAPVAULT_REMOTE_DIR="$remote_dir" \
  SNAPVAULT_SSH_BIN="$fake_bin/ssh"
expect_backup_failure SNAPVAULT_AGE_RECIPIENT="not-an-age-key" \
  SNAPVAULT_AGE_BIN="$fake_bin/age"

status_script="$repo_root/snapvault-status.sh"

rm -rf -- "$incomplete_snapshot"

dry_run_snapshot="$destination/snapshot-20000102T000000Z"
mkdir "$dry_run_snapshot"
touch "$dry_run_snapshot/COMPLETE"
if set_mtime_days_ago "$dry_run_snapshot" 4; then
  dry_run_output=$(
    SNAPVAULT_RETENTION_DAYS=1 \
    SNAPVAULT_RETENTION_DRY_RUN=1 \
    run_backup 20260829T120260Z 2>&1 >/dev/null
  )
  test -d "$dry_run_snapshot" || fail "retention dry-run deleted a snapshot"
  printf '%s\n' "$dry_run_output" | grep -q 'would delete' ||
    fail "retention dry-run did not report a candidate"
  test -d "$destination/snapshot-20260829T120260Z" ||
    fail "retention dry-run removed the new snapshot"
else
  printf 'SKIP: cannot set a directory mtime; dry-run retention is not exercised\n'
fi

expect_failure env \
  SNAPVAULT_BACKUP_DESTINATION="$destination" \
  SNAPVAULT_MEDIA_ROOT="$media_root" \
  SNAPVAULT_DATABASE_URL="postgres://backup-test" \
  SNAPVAULT_PG_DUMP_BIN="$fake_bin/pg_dump" \
  SNAPVAULT_TIMESTAMP=20260829T120270Z \
  SNAPVAULT_RETENTION_DAYS=1 \
  SNAPVAULT_RETENTION_DRY_RUN=yes \
  "$backup_script"

status_text=$("$status_script" "$destination")
printf '%s\n' "$status_text" | grep -q 'snapshot-20260829T120260Z' ||
  fail "status does not list the newest snapshot"
printf '%s\n' "$status_text" | grep -q '^plain ' ||
  fail "status does not report plain snapshots"
status_json=$("$status_script" "$destination" --json)
printf '%s\n' "$status_json" | grep -q '\"name\":\"snapshot-20260829T120260Z\"' ||
  fail "status JSON does not list the newest snapshot"
printf '%s\n' "$status_json" | grep -q '\"state\":\"complete\"' ||
  fail "status JSON does not report complete snapshots"
if set_mtime_days_ago "$dry_run_snapshot" 4; then
  status_expired=$("$status_script" "$destination" --retention-days 1)
  printf '%s\n' "$status_expired" | grep -q 'snapshot-20000102T000000Z (expired)' ||
    fail "status does not mark expired snapshots"
fi
mkdir "$test_root/empty-status"
expect_failure "$status_script" "$test_root/empty-status"
expect_failure "$status_script" "$destination" --bogus-option
expect_failure "$status_script" "$test_root/missing-status-directory"


mkdir "$test_root/status-staging"
touch "$test_root/status-staging/.snapshot-20260101T000000Z.tar.gz.age.incomplete"
mkdir "$test_root/status-staging/.snapshot-20260101T000000Z.transport.abcd"
status_staging=$("$status_script" "$test_root/status-staging")
printf '%s\n' "$status_staging" | grep -q '\.snapshot-20260101T000000Z.tar.gz.age.incomplete' ||
  fail "status does not list a remote staging file"
printf '%s\n' "$status_staging" | grep -Eq '^transport +incomplete' ||
  fail "status does not report transport staging as incomplete"

mkdir "$test_root/status-artifacts"
touch "$test_root/status-artifacts/snapshot-20260101T000000Z.tar.gz.age"
if set_mtime_days_ago "$test_root/status-artifacts/snapshot-20260101T000000Z.tar.gz.age" 4; then
  status_artifacts=$("$status_script" "$test_root/status-artifacts" --retention-days 1)
  if printf '%s\n' "$status_artifacts" | grep -q '(expired)'; then
    fail "status marked a non-retention artifact as expired"
  fi
fi

status_zero=$("$status_script" "$destination" --retention-days 01 --json)
printf '%s\n' "$status_zero" | grep -q '"retentionDays":1' ||
  fail "status JSON keeps a leading zero in retentionDays"


printf 'PASS: snapshots are complete, verified, restorable, encryptable and remotely publishable\n'
