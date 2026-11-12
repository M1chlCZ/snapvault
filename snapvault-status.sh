#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  printf 'usage: snapvault-status.sh DESTINATION [--json] [--retention-days DAYS]\n' >&2
  printf '                          [--max-age-days DAYS] [--require-complete]\n' >&2
}

fail() {
  printf 'snapvault-status: %s\n' "$*" >&2
  exit 2
}

destination=
json=0
retention_days=
max_age_days=
require_complete=0
while test "$#" -gt 0; do
  case "$1" in
    --json)
      json=1
      shift
      ;;
    --retention-days)
      test "$#" -ge 2 || {
        usage
        fail "--retention-days requires a value"
      }
      retention_days=$2
      shift 2
      ;;
    --max-age-days)
      test "$#" -ge 2 || {
        usage
        fail "--max-age-days requires a value"
      }
      max_age_days=$2
      shift 2
      ;;
    --require-complete)
      require_complete=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    -*)
      usage
      fail "unknown option: $1"
      ;;
    *)
      test -z "$destination" || {
        usage
        fail "only one destination is allowed"
      }
      destination=$1
      shift
      ;;
  esac
done
test -n "$destination" || {
  usage
  fail "destination is required"
}
test -d "$destination" || fail "destination is not a directory: $destination"
if test -n "$retention_days"; then
  [[ "$retention_days" =~ ^[0-9]{1,5}$ ]] ||
    fail "--retention-days must be a non-negative integer"
  retention_days=$((10#$retention_days))
fi
if test -n "$max_age_days"; then
  [[ "$max_age_days" =~ ^[0-9]{1,5}$ ]] ||
    fail "--max-age-days must be a non-negative integer"
  max_age_days=$((10#$max_age_days))
fi
destination=$(CDPATH= cd -- "$destination" && pwd -P)

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\t'/\\t}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '%s' "$value"
}

mtime_seconds() {
  local target=$1
  if stat -c %Y "$target" >/dev/null 2>&1; then
    stat -c %Y "$target"
    return 0
  fi
  stat -f %m "$target"
}

path_size_bytes() {
  local target=$1
  if test -d "$target"; then
    du -sk "$target" | awk '{ print $1 * 1024 }'
    return 0
  fi
  wc -c <"$target" | tr -d ' '
}

listing=$(mktemp "${TMPDIR:-/tmp}/snapvault-status.XXXXXX") ||
  fail "cannot create a listing"
entries=$(mktemp "${TMPDIR:-/tmp}/snapvault-status.XXXXXX") ||
  fail "cannot create an entry list"
problems=
cleanup() {
  rm -f -- "$listing" "$entries"
  if test -n "${problems:-}"; then
    rm -f -- "$problems"
  fi
}
trap cleanup EXIT HUP INT TERM

find "$destination" \
  -mindepth 1 \
  -maxdepth 1 \
  \( -type d -o -type f \) \
  -print0 >"$listing" ||
  fail "cannot list the destination"

now=$(date +%s)
while IFS= read -r -d '' path; do
  test ! -L "$path" || {
    printf 'snapvault-status: skipping symlink: %s\n' "$path" >&2
    continue
  }
  name=${path##*/}
  kind=
  state=
  case "$name" in
    .*.tar.gz.incomplete | .*.tar.gz.age.incomplete)
      kind=incomplete
      state=incomplete
      ;;
    .*".incomplete."*)
      kind=incomplete
      state=incomplete
      ;;
    .*".transport."*)
      kind=transport
      state=incomplete
      ;;
    *)
      if test -d "$path"; then
        [[ "$name" =~ ^[a-z0-9-]+-[0-9]{8}T[0-9]{6}Z$ ]] || continue
        kind=plain
        if test -f "$path/COMPLETE"; then
          state=complete
        else
          state=incomplete
        fi
      else
        case "$name" in
          *.tar.gz.age)
            [[ "${name%.tar.gz.age}" =~ ^[a-z0-9-]+-[0-9]{8}T[0-9]{6}Z$ ]] || continue
            kind=encrypted
            state=complete
            ;;
          *.tar.gz)
            [[ "${name%.tar.gz}" =~ ^[a-z0-9-]+-[0-9]{8}T[0-9]{6}Z$ ]] || continue
            kind=transport
            state=complete
            ;;
          *)
            continue
            ;;
        esac
      fi
      ;;
  esac
  completed_at=-
  if test "$kind" = plain && test -f "$path/COMPLETE"; then
    completed_at=$(sed -n 's/^completed_at=//p' "$path/COMPLETE" | head -n 1)
    [[ "$completed_at" =~ ^[0-9A-Za-z:._+-]+$ ]] || completed_at=-
    test -n "$completed_at" || completed_at=-
  fi
  mtime=$(mtime_seconds "$path") || continue
  age_seconds=$((now - mtime))
  test "$age_seconds" -ge 0 || age_seconds=0
  age_days=$((age_seconds / 86400))
  size=$(path_size_bytes "$path")
  expired=false
  if test -n "$retention_days" &&
    test "$kind" = plain &&
    test "$state" = complete &&
    test "$age_days" -gt "$retention_days"; then
    expired=true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$kind" "$state" "$size" "$age_days" "$completed_at" "$expired" >>"$entries"
done <"$listing"

sort -t "$(printf '\t')" -k1,1 "$entries" -o "$entries"
count=$(wc -l <"$entries" | tr -d ' ')

problems=$(mktemp "${TMPDIR:-/tmp}/snapvault-status.XXXXXX") ||
  fail "cannot create a problem list"

if test -n "$max_age_days"; then
  newest_complete=
  while IFS=$'\t' read -r name kind state size age_days completed expired; do
    test "$state" = complete || continue
    if test -z "$newest_complete" || test "$age_days" -lt "$newest_complete"; then
      newest_complete=$age_days
    fi
  done <"$entries"
  if test -z "$newest_complete"; then
    printf 'snapvault-status: no complete snapshot found\n' >>"$problems"
  elif test "$newest_complete" -gt "$max_age_days"; then
    printf 'snapvault-status: newest complete snapshot is %s days old (limit %s)\n' \
      "$newest_complete" "$max_age_days" >>"$problems"
  fi
fi

if test "$require_complete" = 1; then
  while IFS=$'\t' read -r name kind state size age_days completed expired; do
    if test "$kind" = plain && test "$state" = incomplete; then
      printf 'snapvault-status: snapshot %s has no COMPLETE marker\n' \
        "$name" >>"$problems"
    fi
  done <"$entries"
fi

problem_count=$(wc -l <"$problems" | tr -d ' ')

if test "$json" = 1; then
  healthy=true
  test "$problem_count" -eq 0 || healthy=false
  printf '{"destination":"%s","retentionDays":%s,"maxAgeDays":%s,' \
    "$(json_escape "$destination")" "${retention_days:-null}" \
    "${max_age_days:-null}"
  printf '"requireComplete":%s,"healthy":%s,"problems":[' \
    "$(test "$require_complete" = 1 && printf true || printf false)" \
    "$healthy"
  first_problem=1
  while IFS= read -r problem; do
    test "$first_problem" = 1 || printf ','
    first_problem=0
    printf '"%s"' "$(json_escape "$problem")"
  done <"$problems"
  printf '],"snapshots":['
  first=1
  while IFS=$'\t' read -r name kind state size age_days completed expired; do
    test "$first" = 1 || printf ','
    first=0
    printf '{"name":"%s","kind":"%s","state":"%s","sizeBytes":%s,"ageDays":%s,"expired":%s' \
      "$(json_escape "$name")" "$kind" "$state" "$size" "$age_days" "$expired"
    if test "$completed" != '-'; then
      printf ',"completedAt":"%s"' "$(json_escape "$completed")"
    fi
    printf '}'
  done <"$entries"
  printf ']}\n'
else
  printf '%-10s %-10s %14s %8s  %s\n' KIND STATE SIZE_BYTES AGE_DAYS NAME
  while IFS=$'\t' read -r name kind state size age_days completed expired; do
    suffix=
    if test "$expired" = true; then
      suffix=' (expired)'
    fi
    printf '%-10s %-10s %14s %8s  %s%s\n' \
      "$kind" "$state" "$size" "$age_days" "$name" "$suffix"
  done <"$entries"
  while IFS= read -r problem; do
    printf '%s\n' "$problem" >&2
  done <"$problems"
fi

test "$count" -gt 0 || exit 1
test "$problem_count" -eq 0
