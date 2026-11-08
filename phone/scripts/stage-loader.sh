#!/usr/bin/env bash
# usage: stage-loader.sh <loader-dir> <site-dir> <origin>
#
# Copies the files the phone loader serves, and nothing else, from <loader-dir> into
# <site-dir>, and stamps <origin> into runner.html's policy in place of its placeholder.
# The loader repo's deploy and the Playwright test server both run it.
#
# Served: top-level *.html, *.js, *.css and *.webmanifest; channel/*.js; and each `file`
# row of vendor/vendor.lock, as vendor/<name>/<path>, which must be a script, a stylesheet or
# a license notice (the path rule below). Never served: *.test.js, test/, vendor.lock, *.md,
# dotfiles, symlinks. A served file whose path holds anything but A-Z a-z 0-9 . _ / - refuses.
# The only pages are index.html and runner.html: any other page would run with the loader's
# origin and could read its IndexedDB.
#
# <site-dir> must be absent or empty. The site is built in a scratch directory and copied
# into <site-dir> only once every check passes, so a refusal leaves <site-dir> untouched.
# The source tree is never written to.
#
# Exit status: 0 staged (the staged paths are printed, one per line, sorted), 1 refused,
# 64 bad usage.
set -euo pipefail
export LC_ALL=C

placeholder='https://loader-origin.invalid'
placeholder_sed='https://loader-origin[.]invalid' # the same text, as a sed pattern
work=''

finish() {
  local rc=$?
  if [ -n "$work" ]; then rm -rf -- "$work"; fi
  # Any failure that is not a usage error is a refusal.
  case "$rc" in 0 | 64) ;; *) rc=1 ;; esac
  exit "$rc"
}
trap finish EXIT

refuse() {
  echo "stage-loader: $*" >&2
  exit 1
}

if [ "$#" -ne 3 ]; then
  echo "usage: stage-loader.sh <loader-dir> <site-dir> <origin>" >&2
  exit 64
fi
loader="$1"
site="$2"
origin="$3"

# 1. The origin: a scheme, a host and an optional port. No path (so no trailing slash),
#    quotes, spaces, ';' or anything else a policy or sed would read specially.
https_origin='^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$'
local_origin='^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?$'
if ! [[ "$origin" =~ $https_origin || "$origin" =~ $local_origin ]]; then
  refuse "origin must be https://<host>[:<port>], or http:// with 127.0.0.1 or localhost, and nothing more: '$origin'"
fi

# 2. The site directory: absent or empty.
if [ -e "$site" ]; then
  if [ ! -d "$site" ]; then refuse "$site exists and is not a directory"; fi
  if [ -n "$(ls -A -- "$site")" ]; then refuse "$site is not empty"; fi
fi
if [ ! -d "$loader" ]; then refuse "$loader is not a directory"; fi

work="$(mktemp -d "${TMPDIR:-/tmp}/stage-loader.XXXXXX")"
stage="$work/site"
mkdir -- "$stage"

# True for a path under the loader directory whose every component exists and is not a
# symlink, and whose last component is a regular file. $1 is relative to the loader.
served_file() {
  local rest="$1" cur="$loader" part
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=''; else rest="${rest#*/}"; fi
    cur="$cur/$part"
    if [ -L "$cur" ]; then return 1; fi
  done
  [ -f "$cur" ]
}

# Copies $1, relative to the loader directory, to the same path in the stage. Every
# staged path is plain: letters, digits, '.', '_', '-' and '/'. A name holding a newline
# would read as two paths in the listing below, and could slip a page past step 4.
safe_path='^[A-Za-z0-9._/-]+$'
copy() {
  if ! [[ "$1" =~ $safe_path ]]; then
    # Name it with every other byte shown as '?', so the message carries no control bytes.
    refuse "refusing to stage a path with a character other than A-Z a-z 0-9 . _ / -: $(printf '%s' "$1" | tr -c 'A-Za-z0-9._/-' '?')"
  fi
  case "$1" in */*) mkdir -p -- "$stage/${1%/*}" ;; esac
  cp -- "$loader/$1" "$stage/$1"
}

# 3. The allowlist, and nothing else.
for path in "$loader"/*; do
  name="${path##*/}"
  case "$name" in
    .* | *.test.js) continue ;;
    *.html | *.js | *.css | *.webmanifest) ;;
    *) continue ;;
  esac
  if served_file "$name"; then copy "$name"; fi
done

if [ -d "$loader/channel" ] && [ ! -L "$loader/channel" ]; then
  for path in "$loader"/channel/*.js; do
    name="${path##*/}"
    case "$name" in .* | *.test.js) continue ;; esac
    if served_file "channel/$name"; then copy "channel/$name"; fi
  done
fi

lock='vendor/vendor.lock'
if ! served_file "$lock"; then refuse "$loader/$lock is missing"; fi
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
tab="$(printf '\t')"
while IFS="$tab" read -r name _ kind value _ || [ -n "$name" ]; do
  case "$name" in '' | '#'*) continue ;; esac
  [ "$kind" = file ] || continue
  if ! [[ "$name" =~ $lib_name && "$value" =~ $lib_path ]]; then
    refuse "$lock: bad file row '$name' '$value'"
  fi
  rel="vendor/$name/$value"
  if ! served_file "$rel"; then
    refuse "$lock lists $rel, which is missing, not a regular file, or behind a symlink"
  fi
  copy "$rel"
done <"$loader/$lock"

(cd "$stage" && find . -type f) | sed 's|^\./||' | sort >"$work/list"

# 4. No page but index.html and runner.html. Step 3 staged top-level and channel/ files by
#    kind and vendored files by the path rule, so the only other page that gets this far is a
#    top-level *.html, which this refuses with anything else outside those kinds.
while IFS= read -r rel; do
  case "$rel" in
    index.html | runner.html | *.js | *.css | *.webmanifest | vendor/*) ;;
    *) refuse "$rel would be served as a page, or as a kind the loader does not serve; only index.html and runner.html may be pages" ;;
  esac
done <"$work/list"

# 5. Stamp the origin into the staged runner.html, and only there.
#
# grep exits 0 on a match and 1 on none. Anything above 1 is an error, such as a file it
# could not read, and is a refusal: read as "no match", it would let a check pass.
count() { # $1 = text, $2 = file; sets n to how many times $1 occurs in $2
  local rc=0
  grep -aoF -- "$1" "$2" >"$work/matches" || rc=$?
  if [ "$rc" -gt 1 ]; then refuse "grep could not read $2 (exit $rc)"; fi
  n="$(wc -l <"$work/matches" | tr -d '[:space:]')"
}
carries() { # $1 = text, $2 = file; true when $2 holds $1
  count "$1" "$2"
  [ "$n" -gt 0 ]
}
runner="$stage/runner.html"
if [ ! -f "$runner" ]; then refuse "runner.html is missing"; fi
count "$placeholder" "$runner"
if [ "$n" != 1 ]; then refuse "runner.html must carry $placeholder exactly once (found $n)"; fi
while IFS= read -r rel; do
  [ "$rel" != runner.html ] || continue
  if carries "$placeholder" "$stage/$rel"; then
    refuse "$rel carries $placeholder; only runner.html may"
  fi
done <"$work/list"

# The origin passed step 1, so it holds no '|', '&', '\' or newline for sed to read.
sed -i.bak "s|$placeholder_sed|$origin|" "$runner"
rm -- "$runner.bak"

count "$placeholder" "$runner"
if [ "$n" != 0 ]; then refuse "runner.html still carries $placeholder after stamping"; fi
count "$origin" "$runner"
if [ "$n" != 1 ]; then refuse "runner.html must name $origin exactly once after stamping (found $n)"; fi

mkdir -p -- "$site"
cp -R -- "$stage/." "$site/"

# 6. Report.
cat -- "$work/list"
