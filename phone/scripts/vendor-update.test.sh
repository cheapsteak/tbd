#!/usr/bin/env bash
# Harness for vendor-update.sh against a scratch file:// registry. No network.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
update="$here/vendor-update.sh"
check="$here/vendor-check.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/vendor-update-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failures=0

ok() { echo "ok - $1"; }
bad() { echo "not ok - $1" >&2; failures=$((failures + 1)); }

# make_registry <dir> <with-license yes|no> <extra-meta> [prepare]
# `prepare`, a function name, runs with the package directory before it is packed.
make_registry() {
  local dir="$1" lic="$2" extra="$3" prepare="${4:-}" src="$1/src" sum
  mkdir -p "$src/package/dist" "$dir/x"
  printf 'var x = 1;\n' >"$src/package/dist/x.js"
  if [ "$lic" = yes ]; then printf 'MIT License\n' >"$src/package/LICENSE"; fi
  if [ -n "$prepare" ]; then "$prepare" "$src/package"; fi
  tar -czf "$dir/x-1.0.0.tgz" -C "$src" package
  sum="$(openssl dgst -sha512 -binary "$dir/x-1.0.0.tgz" | base64 | tr -d '\n')"
  printf '%s' "$sum" >"$dir/sum"
  printf '{"name":"x","version":"1.0.0","dist":{"tarball":"file://%s/x-1.0.0.tgz","integrity":"sha512-%s"%s}}\n' \
    "$dir" "$sum" "$extra" >"$dir/x/1.0.0"
}

reg="$tmp/reg1"; root="$tmp/root1"; make_registry "$reg" yes ""
if VENDOR_REGISTRY="file://$reg" VENDOR_ROOT="$root" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 \
  && [ -f "$root/x/dist/x.js" ] && [ -f "$root/x/LICENSE" ] \
  && [ "$(grep -c . "$root/vendor.lock")" -eq 6 ] \
  && grep -q "$(printf 'x\t1.0.0\tprovenance\tno')" "$root/vendor.lock" \
  && bash "$check" "$root" >/dev/null 2>&1; then
  ok "update copies files, writes five rows, check passes"
else bad "happy path"; fi

# Wrong integrity: old directory and lock untouched.
cp -R "$root" "$tmp/root1.before"
reg2="$tmp/reg2"; make_registry "$reg2" yes ""
sed 's/"integrity":"sha512-[^"]*"/"integrity":"sha512-AAAA"/' "$reg2/x/1.0.0" >"$reg2/x/1.0.0.new" && mv "$reg2/x/1.0.0.new" "$reg2/x/1.0.0"
rc=0; VENDOR_REGISTRY="file://$reg2" VENDOR_ROOT="$root" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && diff -r "$root" "$tmp/root1.before" >/dev/null; then ok "wrong integrity refuses, tree untouched"; else bad "wrong integrity rc=$rc"; fi

reg3="$tmp/reg3"; root3="$tmp/root3"; make_registry "$reg3" no ""
rc=0; VENDOR_REGISTRY="file://$reg3" VENDOR_ROOT="$root3" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$root3/x" ]; then ok "missing license refuses"; else bad "missing license rc=$rc"; fi

rc=0; VENDOR_REGISTRY="file://$reg" VENDOR_ROOT="$tmp/root4" bash "$update" x 1.0.0 dist/nope.js >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/root4/x" ]; then ok "missing requested file refuses"; else bad "missing file rc=$rc"; fi

reg5="$tmp/reg5"; root5="$tmp/root5"; make_registry "$reg5" yes ',"attestations":{"url":"https://example.invalid/a"}'
if VENDOR_REGISTRY="file://$reg5" VENDOR_ROOT="$root5" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 \
  && grep -q "$(printf 'x\t1.0.0\tprovenance\tyes')" "$root5/vendor.lock"; then
  ok "attestations record provenance yes"
else bad "provenance yes"; fi

# Arguments that would reach outside vendor/<name>/, or outside the package, are refused as bad
# usage before anything is fetched, removed or written.
reg6="$tmp/reg6"; make_registry "$reg6" yes ""
# This registry answers for x, and, with the name '..', for file://$reg6/sub/../1.0.0 too (curl
# squashes the dot segment), so only the argument checks stand between a bad argument and the
# vendor root's parent.
mkdir -p "$reg6/sub/x"; cp "$reg6/x/1.0.0" "$reg6/sub/x/1.0.0"; cp "$reg6/x/1.0.0" "$reg6/1.0.0"
outside="$tmp/out6"; root6="$outside/vendor"
fresh_root6() { rm -rf "$outside"; mkdir -p "$root6"; printf 'keep\n' >"$outside/keep"; }
# refuses_usage <label> <name> <version> <file>...
refuses_usage() {
  local label="$1" rc=0 err
  shift
  fresh_root6
  err="$(VENDOR_REGISTRY="file://$reg6/sub" VENDOR_ROOT="$root6" bash "$update" "$@" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 2 ] && [ -f "$outside/keep" ] && [ -z "$(ls -A "$root6")" ] \
    && [ "$(find "$outside" -mindepth 1 | wc -l | tr -d ' ')" -eq 2 ] \
    && printf '%s' "$err" | grep -q 'usage: vendor-update.sh'; then
    ok "refuses $label"
  else bad "$label: rc=$rc $err"; fi
}
refuses_usage "the name '..'" .. 1.0.0 dist/x.js
refuses_usage "a name with a slash" x/y 1.0.0 dist/x.js
refuses_usage "a name starting with '.'" .x 1.0.0 dist/x.js
refuses_usage "an empty name" '' 1.0.0 dist/x.js
refuses_usage "a name with a space" 'x y' 1.0.0 dist/x.js
refuses_usage "a version with a slash" x 1.0.0/.. dist/x.js
refuses_usage "a version with a tab" x "$(printf '1.0.0\tfile')" dist/x.js
refuses_usage "a file climbing out of the package" x 1.0.0 ../../pkg.tgz
refuses_usage "a file climbing back in" x 1.0.0 dist/../dist/x.js
refuses_usage "an absolute file" x 1.0.0 /etc/hosts
refuses_usage "a file with an empty segment" x 1.0.0 dist//x.js
refuses_usage "a file ending in a slash" x 1.0.0 dist/
refuses_usage "a file starting with ./" x 1.0.0 ./dist/x.js
refuses_usage "a dotfile" x 1.0.0 .npmrc
refuses_usage "a file with a newline" x 1.0.0 "$(printf 'dist/x.js\nLICENSE')"
refuses_usage "a bad file after a good one" x 1.0.0 dist/x.js ../x.js
fresh_root6
if VENDOR_REGISTRY="file://$reg6" VENDOR_ROOT="$root6" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 \
  && [ -f "$root6/x/dist/x.js" ] && [ -f "$outside/keep" ]; then
  ok "the same registry vendors good arguments"
else bad "good arguments after the refusals"; fi

# A file in the tarball that is a symlink, or sits behind one, would copy what it points at.
printf 'not for the repo\n' >"$tmp/secret"
link_file() { ln -s "$tmp/secret" "$1/dist/link.js"; }
link_dir() { mkdir -p "$tmp/elsewhere"; printf 'x\n' >"$tmp/elsewhere/y.js"; ln -s "$tmp/elsewhere" "$1/lib"; }
reg7="$tmp/reg7"; make_registry "$reg7" yes "" link_file
reg8="$tmp/reg8"; make_registry "$reg8" yes "" link_dir
refuses_symlink() { # <registry dir> <file>
  local rc=0
  VENDOR_REGISTRY="file://$1" VENDOR_ROOT="$tmp/root7" bash "$update" x 1.0.0 "$2" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ] && [ ! -e "$tmp/root7/x" ]; then ok "a symlinked $2 refuses"; else bad "symlinked $2 rc=$rc"; fi
}
refuses_symlink "$reg7" dist/link.js
refuses_symlink "$reg8" lib/y.js

# A license file whose name breaks the rule refuses too, before the vendor root changes.
odd_license() { printf 'MIT License\n' >"$1/LICENSE copy"; }
reg9="$tmp/reg9"; root9="$tmp/root9"; make_registry "$reg9" yes "" odd_license
mkdir -p "$root9/x"; printf 'old\n' >"$root9/x/old.js"
rc=0; VENDOR_REGISTRY="file://$reg9" VENDOR_ROOT="$root9" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ -f "$root9/x/old.js" ] && [ ! -e "$root9/x/dist" ]; then ok "a license named outside the rule refuses, old files kept"; else bad "odd license rc=$rc"; fi

# Only the version document's own `dist` object counts. Registry JSON is minified onto one line,
# so a key of the same name elsewhere in it must neither stand in for a missing dist field nor
# override a present one.
reg10="$tmp/reg10"; make_registry "$reg10" yes ""
tarball10="file://$reg10/x-1.0.0.tgz"; integrity10="sha512-$(cat "$reg10/sum")"
# with_meta <label> <expected rc> <document>: runs the update with this version document.
with_meta() {
  local label="$1" want="$2" rc=0
  rm -rf "$tmp/root10"
  printf '%s\n' "$3" >"$reg10/x/1.0.0"
  VENDOR_REGISTRY="file://$reg10" VENDOR_ROOT="$tmp/root10" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ] && { [ "$want" -eq 0 ] || [ ! -e "$tmp/root10/x" ]; }; then ok "$label"; else bad "$label: rc=$rc"; fi
}
with_meta "a decoy integrity and tarball after dist are ignored" 0 \
  "{\"name\":\"x\",\"dist\":{\"tarball\":\"$tarball10\",\"integrity\":\"$integrity10\"},\"decoy\":{\"tarball\":\"file:///nonexistent.tgz\",\"integrity\":\"sha512-AAAA\",\"attestations\":{}}}"
if grep -qF "$(printf 'x\t1.0.0\tintegrity\t%s' "$integrity10")" "$tmp/root10/vendor.lock" \
  && grep -qF "$(printf 'x\t1.0.0\ttarball\t%s' "$tarball10")" "$tmp/root10/vendor.lock" \
  && grep -qF "$(printf 'x\t1.0.0\tprovenance\tno')" "$tmp/root10/vendor.lock"; then
  ok "the lock records dist's own tarball and integrity, and no provenance from a decoy"
else bad "lock rows from dist"; fi
with_meta "a dist without integrity refuses, even with the right one elsewhere" 1 \
  "{\"versions\":{\"tarball\":\"$tarball10\",\"integrity\":\"$integrity10\"},\"dist\":{\"tarball\":\"$tarball10\"}}"
with_meta "a dist without tarball refuses, even with the right one elsewhere" 1 \
  "{\"versions\":{\"tarball\":\"$tarball10\"},\"dist\":{\"integrity\":\"$integrity10\"}}"
with_meta "an integrity that is not a string refuses" 1 \
  "{\"dist\":{\"tarball\":\"$tarball10\",\"integrity\":[\"$integrity10\"]}}"
with_meta "a tarball that is not a string refuses" 1 \
  "{\"dist\":{\"tarball\":{\"url\":\"$tarball10\"},\"integrity\":\"$integrity10\"}}"
with_meta "an integrity holding a newline refuses" 1 \
  "{\"dist\":{\"tarball\":\"$tarball10\",\"integrity\":\"$integrity10\\nsha512-AAAA\"}}"
with_meta "a dist that is not an object refuses" 1 "{\"dist\":\"$tarball10\"}"
with_meta "a document that is not JSON refuses" 1 "{\"dist\":{\"tarball\":\"$tarball10\","

# A run that fails while it vendors changes nothing: the old files and the old lock stay as they
# were, and no scratch directory is left in the vendor root. The shims stand in for a cp or mv
# that fails: cp for any argument ending in /$FAIL_CP_ON, mv for a source matching the pattern
# $FAIL_MV_FROM. Otherwise each runs the real tool.
shim="$tmp/shim"
mkdir -p "$shim"
cat >"$shim/cp" <<'EOF'
#!/bin/sh
if [ -n "${FAIL_CP_ON:-}" ]; then
  for a in "$@"; do
    case "$a" in */"$FAIL_CP_ON") echo "cp: $a: Permission denied" >&2; exit 1 ;; esac
  done
fi
exec "$REAL_CP" "$@"
EOF
cat >"$shim/mv" <<'EOF'
#!/bin/sh
if [ -n "${FAIL_MV_FROM:-}" ]; then
  case "$1" in $FAIL_MV_FROM) echo "mv: $1: Permission denied" >&2; exit 1 ;; esac
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$shim/cp" "$shim/mv"
real_cp="$(command -v cp)"
real_mv="$(command -v mv)"

# The library as vendored from reg (dist/x.js is 'var x = 1;'), and a package whose x.js differs.
base11="$tmp/root11.base"
VENDOR_REGISTRY="file://$reg" VENDOR_ROOT="$base11" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1
two() { printf 'var x = 2;\n' >"$1/dist/x.js"; }
reg11="$tmp/reg11"; make_registry "$reg11" yes "" two
# update_with <root> <VAR=value>...: runs the update from reg11 into <root> through the shims.
update_with() {
  local into="$1"
  shift
  rc=0
  env "$@" REAL_CP="$real_cp" REAL_MV="$real_mv" PATH="$shim:$PATH" \
    VENDOR_REGISTRY="file://$reg11" VENDOR_ROOT="$into" bash "$update" x 1.0.0 dist/x.js >/dev/null 2>&1 || rc=$?
}
# fails_unchanged <label> <VAR=value>...
fails_unchanged() {
  local label="$1"
  shift
  rm -rf "$tmp/root11"
  cp -R "$base11" "$tmp/root11"
  update_with "$tmp/root11" "$@"
  if [ "$rc" -eq 1 ] && diff -r "$tmp/root11" "$base11" >/dev/null && bash "$check" "$tmp/root11" >/dev/null 2>&1; then
    ok "$label"
  else bad "$label: rc=$rc $(diff -r "$tmp/root11" "$base11" 2>&1 | head -5)"; fi
}
fails_unchanged "a copy that fails leaves the old files and the old lock" FAIL_CP_ON=x.js
fails_unchanged "a new library that cannot move into place puts the old one back" FAIL_MV_FROM='*/.vendor-update.*/x'
fails_unchanged "a lock that cannot be replaced puts the old library back" FAIL_MV_FROM='*/.vendor-update.*/vendor.lock'

update_with "$tmp/root12" FAIL_CP_ON=x.js
if [ "$rc" -eq 1 ] && [ ! -e "$tmp/root12" ]; then ok "a copy that fails into a new vendor root leaves no root behind"; else bad "new root copy failure: rc=$rc"; fi

rm -rf "$tmp/root11"
cp -R "$base11" "$tmp/root11"
printf 'old\n' >"$tmp/root11/x/old.js"
update_with "$tmp/root11"
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/root11/x/dist/x.js")" = 'var x = 2;' ] && [ ! -e "$tmp/root11/x/old.js" ] \
  && [ "$(cd "$tmp/root11" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')" = './vendor.lock ./x ' ] \
  && bash "$check" "$tmp/root11" >/dev/null 2>&1; then
  ok "an update over a library replaces its files whole and leaves no scratch directory"
else bad "update over a library: rc=$rc"; fi

[ "$failures" -eq 0 ] || { echo "vendor-update.test.sh: $failures failure(s)" >&2; exit 1; }
echo "vendor-update.test.sh: all passed"
