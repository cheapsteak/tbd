#!/usr/bin/env bash
# Harness for vendor-check.sh. Works only inside its own mktemp directory.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check="$here/vendor-check.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/vendor-check-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failures=0

ok() { echo "ok - $1"; }
bad() { echo "not ok - $1" >&2; failures=$((failures + 1)); }

make_root() { # $1 = dir
  mkdir -p "$1/lib/dist"
  printf 'console.log(1)\n' >"$1/lib/dist/lib.js"
  printf 'MIT\n' >"$1/lib/LICENSE"
  local a b
  a="$(shasum -a 256 "$1/lib/dist/lib.js" | awk '{print $1}')"
  b="$(shasum -a 256 "$1/lib/LICENSE" | awk '{print $1}')"
  {
    printf '# name\tversion\tkind\tvalue\t[sha256]\n'
    printf 'lib\t1.0.0\ttarball\tfile:///x.tgz\n'
    printf 'lib\t1.0.0\tintegrity\tsha512-AAAA\n'
    printf 'lib\t1.0.0\tprovenance\tno\n'
    printf 'lib\t1.0.0\tfile\tLICENSE\t%s\n' "$b"
    printf 'lib\t1.0.0\tfile\tdist/lib.js\t%s\n' "$a"
  } >"$1/vendor.lock"
}

run() { # $1 = root; sets out, rc
  rc=0
  out="$(bash "$check" "$1" 2>&1)" || rc=$?
}

r="$tmp/pass"; make_root "$r"; run "$r"
if [ "$rc" -eq 0 ]; then ok "matching tree passes"; else bad "matching tree should pass: $out"; fi

r="$tmp/flip"; make_root "$r"; printf 'console.log(2)\n' >"$r/lib/dist/lib.js"; run "$r"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'lib/dist/lib.js'; then ok "flipped byte fails and names the file"; else bad "flipped byte: rc=$rc $out"; fi

r="$tmp/unlisted"; make_root "$r"; printf 'x\n' >"$r/lib/extra.js"; run "$r"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unlisted'; then ok "unlisted file fails"; else bad "unlisted: rc=$rc $out"; fi

r="$tmp/missing"; make_root "$r"; rm "$r/lib/LICENSE"; run "$r"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'lib/LICENSE'; then ok "missing listed file fails"; else bad "missing: rc=$rc $out"; fi

r="$tmp/dup"; make_root "$r"; printf 'lib\t1.0.0\ttarball\tfile:///y.tgz\n' >>"$r/vendor.lock"; run "$r"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'tarball'; then ok "two tarball rows fail"; else bad "dup tarball: rc=$rc $out"; fi

# --- What stage-loader.sh would refuse to serve ------------------------------------------

# A loader around a vendor root, as stage-loader.sh reads it: the runner with its placeholder
# and an index page beside vendor/.
make_loader() { # $1 = dir
  mkdir -p "$1"
  printf '<meta content="script-src https://loader-origin.invalid">\n' >"$1/runner.html"
  printf '<!doctype html>\n' >"$1/index.html"
  make_root "$1/vendor"
}

# add_row <root> <name> <path> [file content]: writes the file at <path> under the library
# directory, wherever the path leads, and lists it with its real checksum, so that only a
# check of the row itself can refuse it.
add_row() {
  local root="$1" name="$2" path="$3" content="${4:-x}" file sum
  file="$root/$name/$path"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" >"$file"
  sum="$(shasum -a 256 "$file" | awk '{print $1}')"
  printf '%s\t1.0.0\tfile\t%s\t%s\n' "$name" "$path" "$sum" >>"$root/vendor.lock"
}
# A library of its own, with its tarball, integrity and provenance rows.
add_library() { # <root> <name>
  printf '%s\t1.0.0\ttarball\tfile:///x.tgz\n%s\t1.0.0\tintegrity\tsha512-AAAA\n%s\t1.0.0\tprovenance\tno\n' \
    "$2" "$2" "$2" >>"$1/vendor.lock"
}

# refuses <label> <mutator> <stage-loader verdict: refused | staged> <pattern>: vendor-check
# exits 1 for a loader the mutator changed, naming the problem, and stage-loader.sh gives the
# stated verdict on the same tree. No case may pass vendor-check and be refused by
# stage-loader.sh.
refuses() {
  local label="$1" mutate="$2" stage_want="$3" pattern="$4" t stage_rc=0
  t="$tmp/case$((++cases))"
  make_loader "$t"
  "$mutate" "$t/vendor"
  run "$t/vendor"
  bash "$here/stage-loader.sh" "$t" "$t-site" https://acme.github.io >/dev/null 2>&1 || stage_rc=$?
  local stage_got=staged
  if [ "$stage_rc" -ne 0 ]; then stage_got=refused; fi
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q -- "$pattern" && [ "$stage_got" = "$stage_want" ]; then
    ok "$label"
  else
    bad "$label: vendor-check rc=$rc, stage-loader $stage_got (want $stage_want): $out"
  fi
}
cases=0

t="$tmp/loader-pass"; make_loader "$t"; run "$t/vendor"
stage_rc=0; bash "$here/stage-loader.sh" "$t" "$t-site" https://acme.github.io >/dev/null 2>&1 || stage_rc=$?
if [ "$rc" -eq 0 ] && [ "$stage_rc" -eq 0 ]; then ok "a loader both scripts pass"; else bad "loader pass: vendor-check rc=$rc stage-loader rc=$stage_rc $out"; fi

dot_file() { add_row "$1" lib .hidden.js; }
dot_dir() { add_row "$1" lib dist/.cache/x.js; }
climbs() { add_row "$1" lib dist/../x.js; }
space() { add_row "$1" lib 'dist/a b.js'; }
plus() { add_row "$1" lib 'dist/a+b.js'; }
dot_name() { add_library "$1" .lib; add_row "$1" .lib x.js; }
space_name() { add_library "$1" 'my lib'; add_row "$1" 'my lib' x.js; }
refuses "a listed dotfile refuses" dot_file refused "lib/.hidden.js"
refuses "a listed file under a dot directory refuses" dot_dir refused "lib/dist/.cache/x.js"
refuses "a listed path with '..' refuses" climbs refused "lib/dist/../x.js"
refuses "a listed path with a space refuses" space refused "lib/dist/a?b.js"
refuses "a listed path with '+' refuses" plus refused "lib/dist/a?b.js"
refuses "a library name starting with '.' refuses" dot_name refused "'.lib': a library name"
refuses "a library name with a space refuses" space_name refused "'my?lib': a library name"

# Each symlinked row carries the checksum of what the link reaches, so only the symlink check
# can refuse it.
listed_link() {
  ln -s lib.js "$1/lib/dist/link.js"
  printf 'lib\t1.0.0\tfile\tdist/link.js\t%s\n' "$(shasum -a 256 "$1/lib/dist/lib.js" | awk '{print $1}')" >>"$1/vendor.lock"
}
behind_link() {
  mkdir -p "$1/../elsewhere"
  printf 'x\n' >"$1/../elsewhere/y.js"
  ln -s ../../elsewhere "$1/lib/ext"
  printf 'lib\t1.0.0\tfile\text/y.js\t%s\n' "$(shasum -a 256 "$1/../elsewhere/y.js" | awk '{print $1}')" >>"$1/vendor.lock"
}
unlisted_link() { ln -s dist/lib.js "$1/lib/alias.js"; }
lock_link() { mv "$1/vendor.lock" "$1/../real.lock"; ln -s ../real.lock "$1/vendor.lock"; }
refuses "a listed file that is a symlink refuses" listed_link refused "lib/dist/link.js"
refuses "a listed file behind a symlinked directory refuses" behind_link refused "lib/ext/y.js"
refuses "an unlisted symlink refuses, though stage-loader.sh would skip it" unlisted_link staged "lib/alias.js: a symlink"
refuses "a vendor.lock that is a symlink refuses" lock_link refused "vendor.lock: a symlink"

svg() { add_row "$1" lib dist/icon.svg '<svg/>'; }
page() { add_row "$1" lib demo.HTML '<p>x</p>'; }
stamped() { add_row "$1" lib dist/extra.js '// https://loader-origin.invalid'; }
refuses "a vendored .svg refuses" svg refused "lib/dist/icon.svg: would be served as a page"
refuses "a vendored page in capitals refuses" page refused "lib/demo.HTML: would be served as a page"
refuses "a vendored file carrying the origin placeholder refuses" stamped refused "lib/dist/extra.js: carries"

t="$tmp/root-link"; make_root "$tmp/real-root"; ln -s real-root "$t"; run "$t"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'is a symlink'; then ok "a vendor root that is a symlink refuses"; else bad "root symlink: rc=$rc $out"; fi

[ "$failures" -eq 0 ] || { echo "vendor-check.test.sh: $failures failure(s)" >&2; exit 1; }
echo "vendor-check.test.sh: all passed"
