#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
verify_script="$script_dir/snapvault-verify.sh"

fail() {
  printf 'snapvault-restore: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: snapvault-restore.sh SNAPSHOT_DIR TARGET_DIR [--force] [--database URL]\n' >&2
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

reject_unsafe_path() {
  local name=$1
  local value=$2
  local resolved resolved_home
  case "$value" in
    /*) ;;
    *) fail "$name must be an absolute path" ;;
  esac
  test "$value" != "/" || fail "$name must not be the filesystem root"
  if test -n "${HOME:-}" && test "$value" = "$HOME"; then
    fail "$name must not be HOME"
  fi
  resolved=$(canonicalize_absolute "$value")
  test "$resolved" != "/" || fail "$name resolved to the filesystem root"
  if test -n "${HOME:-}"; then
    resolved_home=$(canonicalize_absolute "$HOME")
    test "$resolved" != "$resolved_home" || fail "$name resolved to HOME"
  fi
}

reject_symlink_components() {
  local name=$1
  local component=$2
  while test "$component" != "/"; do
    test ! -L "$component" || fail "$name contains a symlink component"
    component=${component%/*}
    if test -z "$component"; then
      component=/
    fi
  done
}

validate_existing_directory() {
  local name=$1
  local value=${!name}
  local resolved
  reject_unsafe_path "$name" "$value"
  reject_symlink_components "$name" "$value"
  test ! -L "$value" || fail "$name must not be a symlink"
  test -d "$value" || fail "$name must be an existing directory"
  resolved=$(canonicalize_absolute "$value")
  printf '%s\n' "$resolved"
}

validate_target_directory() {
  local name=$1
  local value=${!name}
  local resolved
  reject_unsafe_path "$name" "$value"
  reject_symlink_components "$name" "$value"
  if test -e "$value"; then
    test ! -L "$value" || fail "$name must not be a symlink"
    test -d "$value" || fail "$name must be a directory"
  fi
  resolved=$(canonicalize_absolute "$value")
  printf '%s\n' "$resolved"
}

force=0
database_url=
snapshot_argument=
target_argument=

while test "$#" -gt 0; do
  case "$1" in
    --force) force=1 ;;
    --database)
      shift
      test "$#" -gt 0 || { usage; fail "--database requires a value"; }
      test -n "$1" || fail "--database must not be empty"
      database_url=$1
      ;;
    -*)
      usage
      fail "unknown option: $1"
      ;;
    *)
      if test -z "$snapshot_argument"; then
        snapshot_argument=$1
      elif test -z "$target_argument"; then
        target_argument=$1
      else
        usage
        fail "unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

if test -z "$snapshot_argument" || test -z "$target_argument"; then
  usage
  fail "SNAPSHOT_DIR and TARGET_DIR are required"
fi

SNAPSHOT_DIR=$snapshot_argument
TARGET_DIR=$target_argument
snapshot_dir=$(validate_existing_directory SNAPSHOT_DIR)
target_dir=$(validate_target_directory TARGET_DIR)
test "$snapshot_dir" != "$target_dir" ||
  fail "snapshot directory and target directory must be different"
test -f "$snapshot_dir/COMPLETE" || fail "snapshot has no COMPLETE marker"

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

pg_restore_bin=
if test -n "$database_url"; then
  pg_restore_bin=${SNAPVAULT_PG_RESTORE_BIN:-pg_restore}
  case "$pg_restore_bin" in
    */*)
      test -x "$pg_restore_bin" || fail "SNAPVAULT_PG_RESTORE_BIN is not executable"
      ;;
    *)
      pg_restore_bin=$(command -v "$pg_restore_bin") ||
        fail "pg_restore was not found"
      ;;
  esac
fi

test -x "$verify_script" || fail "snapvault-verify.sh was not found"
"$verify_script" "$snapshot_dir" >/dev/null || fail "snapshot verification failed"

if test ! -d "$target_dir"; then
  mkdir -p -- "$target_dir" || fail "cannot create target directory: $target_dir"
elif test "$force" -eq 0; then
  if ! existing_entry=$(find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit); then
    fail "cannot read target directory: $target_dir"
  fi
  test -z "$existing_entry" ||
    fail "target directory is not empty; use --force to restore into it"
fi

"$tar_bin" -xzf "$snapshot_dir/media.tar.gz" -C "$target_dir" --no-same-owner

restored_database=skipped
if test -n "$database_url"; then
  PGDATABASE="$database_url" "$pg_restore_bin" "$snapshot_dir/database.dump"
  restored_database=ok
fi

printf 'restored_media=%s\n' "$target_dir"
printf 'restored_database=%s\n' "$restored_database"
