#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
verify_script="$script_dir/snapvault-verify.sh"
temporary_snapshot=
temporary_transport=

fail() {
  printf 'snapvault: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if test -n "$temporary_snapshot" && test -d "$temporary_snapshot"; then
    rm -rf -- "$temporary_snapshot"
  fi
  if test -n "$temporary_transport" && test -d "$temporary_transport"; then
    rm -rf -- "$temporary_transport"
  fi
}
trap cleanup EXIT HUP INT TERM

require_value() {
  local name=$1
  local value=${!name:-}
  test -n "$value" || fail "$name is required"
  case "$value" in
    *'$'*|*'${'*|*'}'*) fail "$name contains an unresolved variable" ;;
  esac
}

snapshot_prefix_from_env() {
  local value=${SNAPVAULT_PREFIX:-snapshot}
  case "$value" in
    ''|*[!a-z0-9-]*) fail "SNAPVAULT_PREFIX must contain only lowercase letters, digits and dashes" ;;
  esac
  case "$value" in
    -*|*-) fail "SNAPVAULT_PREFIX must not start or end with a dash" ;;
  esac
  printf '%s\n' "$value"
}

redact_recipient() {
  local value=$1
  local prefix=${value%"${value#????????}"}
  local suffix=${value#"${value%????}"}
  printf '%s...%s\n' "$prefix" "$suffix"
}

canonicalize_absolute() {
  local input=$1
  local component result=
  local -a parts=()
  local -a resolved=()
  local IFS=/
  set -f
  parts=($input)
  set +f
  for component in "${parts[@]}"; do
    case "$component" in
      ''|.) ;;
      ..)
        if test "${#resolved[@]}" -gt 0; then
          unset "resolved[${#resolved[@]}-1]"
        fi
        ;;
      *) resolved[${#resolved[@]}]=$component ;;
    esac
  done
  if test "${#resolved[@]}" -eq 0; then
    printf '/\n'
    return 0
  fi
  for component in "${resolved[@]}"; do
    result="$result/$component"
  done
  printf '%s\n' "$result"
}

validate_directory() {
  local name=$1
  local value=${!name}
  local resolved mount_target
  local component=$value
  local resolved_home

  case "$value" in
    /*) ;;
    *) fail "$name must be an absolute path" ;;
  esac
  test "$value" != "/" || fail "$name must not be the filesystem root"
  if test -n "${HOME:-}" && test "$value" = "$HOME"; then
    fail "$name must not be HOME"
  fi
  while test "$component" != "/"; do
    test ! -L "$component" ||
      fail "$name contains a symlink component"
    component=${component%/*}
    if test -z "$component"; then
      component=/
    fi
  done
  test ! -L "$value" || fail "$name must not be a symlink"
  test -d "$value" || fail "$name must be an existing directory"
  resolved=$(canonicalize_absolute "$value")
  test "$resolved" != "/" || fail "$name resolved to the filesystem root"
  if test -n "${HOME:-}"; then
    resolved_home=$(canonicalize_absolute "$HOME")
    test "$resolved" != "$resolved_home" || fail "$name resolved to HOME"
  fi
  if command -v findmnt >/dev/null 2>&1; then
    mount_target=$(findmnt -n -o TARGET --target "$resolved" 2>/dev/null || true)
    test "$mount_target" != "$resolved" ||
      fail "$name must point inside a mount, not at its root"
  fi
  printf '%s\n' "$resolved"
}

remote_directory_from_env() {
  local value=${SNAPVAULT_REMOTE_DIR:-}
  local component
  local rest
  local -a parts=()
  local IFS=/
  test -n "$value" || fail "SNAPVAULT_REMOTE_DIR is required with SNAPVAULT_REMOTE"
  case "$value" in
    /*) ;;
    *) fail "SNAPVAULT_REMOTE_DIR must be an absolute path" ;;
  esac
  test "$value" != "/" || fail "SNAPVAULT_REMOTE_DIR must not be the filesystem root"
  rest=${value#/}
  set -f
  parts=($rest)
  set +f
  for component in "${parts[@]}"; do
    case "$component" in
      ''|.|..)
        fail "SNAPVAULT_REMOTE_DIR must not contain empty, . or .. components"
        ;;
      *[!A-Za-z0-9._-]*)
        fail "SNAPVAULT_REMOTE_DIR contains unsupported characters"
        ;;
    esac
  done
  printf '%s\n' "$value"
}

sha256_tool=${SNAPVAULT_SHA256SUM_BIN:-}
sha256_kind=
if test -n "$sha256_tool"; then
  case "$sha256_tool" in
    */*)
      test -x "$sha256_tool" || fail "SNAPVAULT_SHA256SUM_BIN is not executable"
      ;;
    *)
      sha256_tool=$(command -v "$sha256_tool") ||
        fail "SNAPVAULT_SHA256SUM_BIN was not found"
      ;;
  esac
else
  for candidate in sha256sum gsha256sum shasum; do
    if command -v "$candidate" >/dev/null 2>&1; then
      sha256_tool=$(command -v "$candidate")
      break
    fi
  done
fi
test -n "$sha256_tool" || fail "no SHA-256 tool found; install coreutils or shasum"
case "${sha256_tool##*/}" in
  shasum) sha256_kind=shasum ;;
  *) sha256_kind=gnu ;;
esac

sha256_one() {
  if test "$sha256_kind" = shasum; then
    "$sha256_tool" -a 256 -- "$@"
  else
    "$sha256_tool" -- "$@"
  fi
}

require_value SNAPVAULT_DATABASE_URL
require_value SNAPVAULT_MEDIA_ROOT
require_value SNAPVAULT_BACKUP_DESTINATION

snapshot_prefix=$(snapshot_prefix_from_env)
backup_destination=$(validate_directory SNAPVAULT_BACKUP_DESTINATION)
media_root=$(validate_directory SNAPVAULT_MEDIA_ROOT)
test "$backup_destination" != "$media_root" ||
  fail "backup destination and media root must be different"

pg_dump_bin=${SNAPVAULT_PG_DUMP_BIN:-pg_dump}
case "$pg_dump_bin" in
  */*)
    test -x "$pg_dump_bin" || fail "SNAPVAULT_PG_DUMP_BIN is not executable"
    ;;
  *)
    pg_dump_bin=$(command -v "$pg_dump_bin") ||
      fail "pg_dump was not found"
    ;;
esac

tar_bin=${SNAPVAULT_TAR_BIN:-tar}
case "$tar_bin" in
  */*)
    test -x "$tar_bin" || fail "SNAPVAULT_TAR_BIN is not executable"
    ;;
  *)
    tar_bin=$(command -v "$tar_bin") ||
      fail "tar was not found"
    ;;
esac
tar_kind=bsd
if "$tar_bin" --version 2>/dev/null | head -n 1 | grep -q 'GNU tar'; then
  tar_kind=gnu
fi

age_recipient=${SNAPVAULT_AGE_RECIPIENT:-}
age_bin=
if test -n "$age_recipient"; then
  [[ "$age_recipient" =~ ^age1[0-9a-z]{58}$ ]] ||
    fail "SNAPVAULT_AGE_RECIPIENT must be one age public key"
  age_bin=${SNAPVAULT_AGE_BIN:-age}
  case "$age_bin" in
    */*)
      test -x "$age_bin" || fail "SNAPVAULT_AGE_BIN is not executable"
      ;;
    *)
      age_bin=$(command -v "$age_bin") ||
        fail "age was not found; install age or unset SNAPVAULT_AGE_RECIPIENT"
      ;;
  esac
fi

remote=${SNAPVAULT_REMOTE:-}
remote_dir=
ssh_bin=
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
if test -z "$remote" && test -n "${SNAPVAULT_REMOTE_DIR:-}"; then
  fail "SNAPVAULT_REMOTE_DIR requires SNAPVAULT_REMOTE"
fi
if test -n "$remote"; then
  case "$remote" in
    *[!A-Za-z0-9._@-]*|-*|@*|*@|*@*@*)
      fail "SNAPVAULT_REMOTE must be [user@]host"
      ;;
  esac
  case "${remote##*@}" in
    -*|'') fail "SNAPVAULT_REMOTE must be [user@]host" ;;
  esac
  remote_dir=$(remote_directory_from_env)
  ssh_bin=${SNAPVAULT_SSH_BIN:-ssh}
  case "$ssh_bin" in
    */*)
      test -x "$ssh_bin" || fail "SNAPVAULT_SSH_BIN is not executable"
      ;;
    *)
      ssh_bin=$(command -v "$ssh_bin") ||
        fail "ssh was not found; install ssh or unset SNAPVAULT_REMOTE"
      ;;
  esac
fi

timestamp=${SNAPVAULT_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
[[ "$timestamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
  fail "SNAPVAULT_TIMESTAMP must use YYYYMMDDTHHMMSSZ"
snapshot_name="$snapshot_prefix-$timestamp"
final_snapshot="$backup_destination/$snapshot_name"
test ! -e "$final_snapshot" || fail "snapshot already exists: $snapshot_name"
temporary_snapshot=$(mktemp -d "$backup_destination/.$snapshot_name.incomplete.XXXXXX")
media_file_list="$temporary_snapshot/.media-files"

(
  cd "$media_root"
  LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z >"$media_file_list"
  while IFS= read -r -d '' relative_path; do
    sha256_one "$relative_path"
  done <"$media_file_list"
) >"$temporary_snapshot/media-index.sha256"

if test "$tar_kind" = gnu; then
  "$tar_bin" \
    --create \
    --gzip \
    --file="$temporary_snapshot/media.tar.gz" \
    --directory="$media_root" \
    --null \
    --files-from="$media_file_list" \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner
else
  "$tar_bin" \
    --create \
    --gzip \
    --file="$temporary_snapshot/media.tar.gz" \
    --directory="$media_root" \
    --null \
    --files-from="$media_file_list" \
    --no-recursion \
    --uid=0 \
    --gid=0 \
    --uname=root \
    --gname=root
fi
rm -- "$media_file_list"

PGDATABASE="$SNAPVAULT_DATABASE_URL" "$pg_dump_bin" \
  --format=custom \
  --no-owner \
  --no-privileges \
  --file="$temporary_snapshot/database.dump"

test -s "$temporary_snapshot/database.dump" || fail "database dump is empty"
(
  cd "$temporary_snapshot"
  sha256_one database.dump media.tar.gz media-index.sha256 >SHA256SUMS
)

"$verify_script" --allow-incomplete "$temporary_snapshot" >/dev/null
printf 'completed_at=%s\n' "$timestamp" >"$temporary_snapshot/COMPLETE"

artifact_file=
artifact_name=
if test -n "$age_recipient" || test -n "$remote"; then
  temporary_transport=$(mktemp -d "$backup_destination/.$snapshot_name.transport.XXXXXX")
  "$tar_bin" -czf "$temporary_transport/snapshot.tar.gz" -C "$temporary_snapshot" .
  test -s "$temporary_transport/snapshot.tar.gz" || fail "transport archive is empty"
  artifact_file="$temporary_transport/snapshot.tar.gz"
  artifact_name="$snapshot_name.tar.gz"
  if test -n "$age_recipient"; then
    printf 'snapvault: encrypting for recipient %s\n' \
      "$(redact_recipient "$age_recipient")" >&2
    "$age_bin" --encrypt --recipient "$age_recipient" \
      --output "$temporary_transport/snapshot.tar.gz.age" \
      "$temporary_transport/snapshot.tar.gz"
    test -s "$temporary_transport/snapshot.tar.gz.age" ||
      fail "encrypted artifact is empty"
    rm -- "$temporary_transport/snapshot.tar.gz"
    artifact_file="$temporary_transport/snapshot.tar.gz.age"
    artifact_name="$snapshot_name.tar.gz.age"
  fi
fi

if test -n "$remote"; then
  remote_artifact="$remote_dir/$artifact_name"
  remote_staging="$remote_dir/.$artifact_name.incomplete"
  local_digest=$(sha256_one "$artifact_file")
  local_digest=${local_digest%% *}
  "$ssh_bin" "${ssh_options[@]}" "$remote" \
    "set -eu; umask 077; test -d '$remote_dir'; test ! -L '$remote_dir'; test ! -e '$remote_artifact'; cat > '$remote_staging'" \
    <"$artifact_file"
  remote_digest=$("$ssh_bin" "${ssh_options[@]}" "$remote" \
    "sha256sum '$remote_staging'" </dev/null)
  remote_digest=${remote_digest%% *}
  [[ "$remote_digest" =~ ^[0-9a-f]{64}$ ]] ||
    fail "remote host did not return a SHA-256 checksum"
  test "$remote_digest" = "$local_digest" ||
    fail "remote checksum differs; the artifact was not published"
  "$ssh_bin" "${ssh_options[@]}" "$remote" \
    "mv -- '$remote_staging' '$remote_artifact'" </dev/null
  final_snapshot="$remote:$remote_artifact"
  rm -rf -- "$temporary_snapshot"
  temporary_snapshot=
elif test -n "$age_recipient"; then
  test ! -e "$backup_destination/$artifact_name" ||
    fail "snapshot artifact already exists: $artifact_name"
  mv -- "$artifact_file" "$backup_destination/$artifact_name"
  final_snapshot="$backup_destination/$artifact_name"
  rm -rf -- "$temporary_snapshot"
  temporary_snapshot=
else
  mv -- "$temporary_snapshot" "$final_snapshot"
  temporary_snapshot=
fi
if test -n "$temporary_transport" && test -d "$temporary_transport"; then
  rm -rf -- "$temporary_transport"
  temporary_transport=
fi

retention_days=${SNAPVAULT_RETENTION_DAYS:-}
if test -n "$retention_days" && test -n "$remote"; then
  printf 'snapvault: warning: SNAPVAULT_RETENTION_DAYS is ignored in remote mode; remote artifacts are never deleted\n' >&2
  retention_days=
fi
if test -n "$retention_days"; then
  [[ "$retention_days" =~ ^[0-9]{1,5}$ ]] ||
    fail "SNAPVAULT_RETENTION_DAYS must be a non-negative integer"
  retention_listing=$(mktemp "${TMPDIR:-/tmp}/snapvault-retention.XXXXXX") ||
    fail "cannot create a retention listing"
  if ! find "$backup_destination" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name "$snapshot_prefix-????????T??????Z" \
    -mtime "+$retention_days" \
    -print0 >"$retention_listing"; then
    rm -f -- "$retention_listing"
    fail "cannot list retention candidates"
  fi
  while IFS= read -r -d '' expired_snapshot; do
    test ! -L "$expired_snapshot" ||
      fail "retention candidate must not be a symlink"
    expired_snapshot=$(canonicalize_absolute "$expired_snapshot")
    case "$expired_snapshot" in
      "$backup_destination"/"$snapshot_prefix"-*) ;;
      *) fail "unsafe retention candidate: $expired_snapshot" ;;
    esac
    [[ "${expired_snapshot##*/}" =~ ^"$snapshot_prefix"-[0-9]{8}T[0-9]{6}Z$ ]] ||
      fail "unsafe retention name: $expired_snapshot"
    test -f "$expired_snapshot/COMPLETE" ||
      fail "retention candidate is not a complete snapshot"
    rm -rf -- "$expired_snapshot"
  done <"$retention_listing"
  rm -f -- "$retention_listing"
fi

printf '%s\n' "$final_snapshot"
