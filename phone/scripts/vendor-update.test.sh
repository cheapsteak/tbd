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

# make_registry <dir> <with-license yes|no> <extra-meta>
make_registry() {
  local dir="$1" lic="$2" extra="$3" src="$1/src" sum
  mkdir -p "$src/package/dist" "$dir/x"
  printf 'var x = 1;\n' >"$src/package/dist/x.js"
  if [ "$lic" = yes ]; then printf 'MIT License\n' >"$src/package/LICENSE"; fi
  tar -czf "$dir/x-1.0.0.tgz" -C "$src" package
  sum="$(openssl dgst -sha512 -binary "$dir/x-1.0.0.tgz" | base64 | tr -d '\n')"
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

[ "$failures" -eq 0 ] || { echo "vendor-update.test.sh: $failures failure(s)" >&2; exit 1; }
echo "vendor-update.test.sh: all passed"
