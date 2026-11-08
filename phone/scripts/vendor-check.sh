#!/usr/bin/env bash
# usage: vendor-check.sh [vendor-root]
# Verifies every vendored file against vendor.lock: checksums, no unlisted files,
# and exactly one tarball, integrity and provenance row per library.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
root="${1:-$repo/phone/loader/vendor}"
lock="$root/vendor.lock"
problems=0

fail() {
  echo "vendor-check: $*" >&2
  problems=$((problems + 1))
}

if [ ! -f "$lock" ]; then
  echo "vendor-check: missing $lock" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
: >"$work/listed"
tab="$(printf '\t')"

while IFS="$tab" read -r name _ kind value sha || [ -n "$name" ]; do
  case "$name" in '' | '#'*) continue ;; esac
  [ "$kind" = file ] || continue
  rel="$name/$value"
  printf '%s\n' "$rel" >>"$work/listed"
  path="$root/$rel"
  if [ ! -f "$path" ]; then
    fail "$rel: listed in vendor.lock but missing on disk"
    continue
  fi
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    fail "$rel: sha256 mismatch (lock $sha, disk $actual)"
  fi
done <"$lock"

# Every regular file on disk (except the lock) must be listed.
(cd "$root" && find . -type f ! -path ./vendor.lock | sed 's|^\./||' | LC_ALL=C sort) >"$work/ondisk"
while IFS= read -r rel || [ -n "$rel" ]; do
  [ -n "$rel" ] || continue
  if ! grep -Fxq -- "$rel" "$work/listed"; then
    fail "$rel: unlisted file (present on disk, absent from vendor.lock)"
  fi
done <"$work/ondisk"

# Exactly one tarball, integrity and provenance row per library.
names="$(awk -F'\t' '!/^#/ && NF>0 {print $1}' "$lock" | LC_ALL=C sort -u)"
for n in $names; do
  for k in tarball integrity provenance; do
    count="$(awk -F'\t' -v n="$n" -v k="$k" '$1==n && $3==k {c++} END {print c+0}' "$lock")"
    if [ "$count" -ne 1 ]; then
      fail "$n: expected exactly one $k row, found $count"
    fi
  done
done

if [ "$problems" -ne 0 ]; then
  echo "vendor-check: $problems problem(s)" >&2
  exit 1
fi
echo "vendor-check: ok"
