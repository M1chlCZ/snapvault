#!/usr/bin/env bash
set -Eeuo pipefail

allow_incomplete=0
if test "${1:-}" = "--allow-incomplete"; then
  allow_incomplete=1
  shift
fi
snapshot=${1:-}

fail() {
  printf 'snapvault-verify: %s\n' "$*" >&2
  exit 1
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

sha256_check() {
  if test "$sha256_kind" = shasum; then
    "$sha256_tool" -a 256 -c -- "$1"
  else
    "$sha256_tool" --check --strict -- "$1"
  fi
}

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

test -n "$snapshot" || fail "snapshot path is required"
case "$snapshot" in
  /*) ;;
  *) fail "snapshot path must be absolute" ;;
esac
test ! -L "$snapshot" || fail "snapshot must not be a symlink"
test -d "$snapshot" || fail "snapshot directory does not exist"
snapshot=$(CDPATH= cd -- "$snapshot" && pwd -P) ||
  fail "snapshot cannot be resolved"
test "$snapshot" != "/" || fail "snapshot must not be the filesystem root"

if test "$allow_incomplete" -eq 0; then
  test -f "$snapshot/COMPLETE" || fail "snapshot has no COMPLETE marker"
fi
for required_file in database.dump media.tar.gz media-index.sha256 SHA256SUMS; do
  test -f "$snapshot/$required_file" ||
    fail "snapshot is missing $required_file"
done
test -s "$snapshot/database.dump" || fail "database dump is empty"

(
  cd "$snapshot"
  sha256_check SHA256SUMS
) >/dev/null || fail "snapshot checksum verification failed"

while IFS= read -r archive_path; do
  case "$archive_path" in
    /*|../*|*/../*|*/..)
      fail "media archive contains an unsafe path"
      ;;
  esac
done < <("$tar_bin" -tzf "$snapshot/media.tar.gz")

restore_root=$(mktemp -d)
trap 'rm -rf -- "$restore_root"' EXIT HUP INT TERM
"$tar_bin" -xzf "$snapshot/media.tar.gz" -C "$restore_root"
(
  cd "$restore_root"
  sha256_check "$snapshot/media-index.sha256"
) >/dev/null || fail "media index verification failed"

printf 'verified=%s\n' "$snapshot"
