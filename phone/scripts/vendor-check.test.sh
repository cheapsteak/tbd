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

[ "$failures" -eq 0 ] || { echo "vendor-check.test.sh: $failures failure(s)" >&2; exit 1; }
echo "vendor-check.test.sh: all passed"
