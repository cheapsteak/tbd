#!/usr/bin/env bash
# usage: vendor-check.sh [vendor-root]
# Verifies every vendored file against vendor.lock: checksums, no unlisted files,
# and exactly one tarball, integrity and provenance row per library.
#
# It also refuses what stage-loader.sh would refuse to serve from the lock, so a lock that
# passes here never fails a deploy: a library name or file path outside the path rule below,
# which admits only scripts, stylesheets and license notices; a listed file that is a symlink,
# sits behind one, or is not a regular file; and one that carries runner.html's origin
# placeholder. No symlink may be anywhere under the vendor root, listed or not, and neither
# the root nor the lock may be one.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
root="${1:-$repo/phone/loader/vendor}"
lock="$root/vendor.lock"
problems=0

fail() {
  echo "vendor-check: $*" >&2
  problems=$((problems + 1))
}

# $1 with every byte but A-Z a-z 0-9 . _ / - shown as '?', so a message carries no control bytes.
shown() { printf '%s' "$1" | tr -c 'A-Za-z0-9._/-' '?'; }

# The path rule for a vendored library's name and the paths of its files. stage-loader.sh,
# vendor-update.sh and vendor-check.sh each carry these lines word for word, so that each stays
# one self-contained file; path-rule.testlib.sh runs all three on one table of paths and fails
# when their verdicts, or these lines, differ.
#
# A vendored file is a script (.js), a stylesheet (.css) or a license notice (LICENSE,
# LICENCE, COPYING or NOTICE, in any case, alone or with .txt), and nothing else. The kinds are
# an allowlist because a static host serves many kinds of file as a page (.html, .xht, .svg,
# .xsl, .mhtml, .rss and more), and a page on the loader's origin could read its IndexedDB.
segment='[A-Za-z0-9_][A-Za-z0-9._-]*' # no leading dot, so no '..' and no dotfiles
lib_name="^$segment\$"
notice='([Ll][Ii][Cc][Ee][Nn][CcSs][Ee]|[Cc][Oo][Pp][Yy][Ii][Nn][Gg]|[Nn][Oo][Tt][Ii][Cc][Ee])(\.[Tt][Xx][Tt])?'
lib_path="^($segment/)*($segment\.(js|css)|$notice)\$"

# runner.html's placeholder, which stage-loader.sh refuses in any other served file.
placeholder='https://loader-origin.invalid'

# True when $2, a path relative to the directory $1, names a regular file and neither it nor
# any directory on the way is a symlink.
plain_file() {
  local cur="$1" rest="$2" part
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=''; else rest="${rest#*/}"; fi
    cur="$cur/$part"
    if [ -L "$cur" ]; then return 1; fi
  done
  [ -f "$cur" ]
}

if [ -L "${root%/}" ]; then
  echo "vendor-check: $root is a symlink" >&2
  exit 1
fi
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
  if ! [[ "$name" =~ $lib_name ]]; then
    fail "'$(shown "$name")': a library name must be one segment of A-Z a-z 0-9 . _ - not starting with '.'"
    continue
  fi
  [ "$kind" = file ] || continue
  rel="$name/$value"
  printf '%s\n' "$rel" >>"$work/listed"
  if ! [[ "$value" =~ $lib_path ]]; then
    fail "$(shown "$rel"): a vendored file must be a .js or .css file or a license notice (LICENSE, LICENCE, COPYING or NOTICE, alone or with .txt), at a path of segments of A-Z a-z 0-9 . _ - none starting with '.'"
    continue
  fi
  path="$root/$rel"
  if ! plain_file "$root" "$rel"; then
    if [ -e "$path" ] || [ -L "$path" ]; then
      fail "$rel: listed in vendor.lock but a symlink, behind one, or not a regular file"
    else
      fail "$rel: listed in vendor.lock but missing on disk"
    fi
    continue
  fi
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    fail "$rel: sha256 mismatch (lock $sha, disk $actual)"
  fi
  # grep exits 0 on a match and 1 on none; anything above 1 is a file it could not read.
  rc=0
  grep -qaF -- "$placeholder" "$path" || rc=$?
  case "$rc" in
    0) fail "$rel: carries $placeholder, which only runner.html may" ;;
    1) ;;
    *) fail "$rel: grep could not read it (exit $rc)" ;;
  esac
done <"$lock"

# Every regular file on disk (except the lock) must be listed.
(cd "$root" && find . -type f ! -path ./vendor.lock | sed 's|^\./||' | LC_ALL=C sort) >"$work/ondisk"
while IFS= read -r rel || [ -n "$rel" ]; do
  [ -n "$rel" ] || continue
  if ! grep -Fxq -- "$rel" "$work/listed"; then
    fail "$(shown "$rel"): unlisted file (present on disk, absent from vendor.lock)"
  fi
done <"$work/ondisk"

# No symlink anywhere under the root, the lock included: stage-loader.sh serves nothing
# through one, and a listed file reached through one is not the file the lock describes.
(cd "$root" && find . -type l | sed 's|^\./||' | LC_ALL=C sort) >"$work/links"
while IFS= read -r rel || [ -n "$rel" ]; do
  [ -n "$rel" ] || continue
  fail "$(shown "$rel"): a symlink under the vendor root"
done <"$work/links"

# Exactly one tarball, integrity and provenance row per library.
awk -F'\t' '!/^#/ && NF>0 {print $1}' "$lock" | LC_ALL=C sort -u >"$work/names"
while IFS= read -r n || [ -n "$n" ]; do
  [ -n "$n" ] || continue
  for k in tarball integrity provenance; do
    count="$(awk -F'\t' -v n="$n" -v k="$k" '$1==n && $3==k {c++} END {print c+0}' "$lock")"
    if [ "$count" -ne 1 ]; then
      fail "$(shown "$n"): expected exactly one $k row, found $count"
    fi
  done
done <"$work/names"

if [ "$problems" -ne 0 ]; then
  echo "vendor-check: $problems problem(s)" >&2
  exit 1
fi
echo "vendor-check: ok"
