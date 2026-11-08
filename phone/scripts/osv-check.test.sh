#!/usr/bin/env bash
# Harness for osv-check.sh. Works only inside its own mktemp directory; no network.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
osv="$here/osv-check.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/osv-check-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failures=0

ok() { echo "ok - $1"; }
bad() { echo "not ok - $1" >&2; failures=$((failures + 1)); }

printf '# name\tversion\tkind\tvalue\n' >"$tmp/vendor.lock"
printf 'jsqr\t1.4.0\ttarball\thttps://example.invalid/jsqr-1.4.0.tgz\n' >>"$tmp/vendor.lock"
printf 'jsqr\t1.4.0\tfile\tdist/jsQR.js\tabc\n' >>"$tmp/vendor.lock"
cat >"$tmp/package-lock.json" <<'JSON'
{"lockfileVersion":3,"packages":{
 "":{"name":"root","version":"0.0.0"},
 "node_modules/a":{"version":"2.0.0"},
 "node_modules/a/node_modules/b":{"version":"3.1.0"}
}}
JSON
unset GITHUB_STEP_SUMMARY
export VENDOR_LOCK="$tmp/vendor.lock"

out="$(bash "$osv" --print-queries "$tmp/package-lock.json" "$tmp/package-lock.json")"
want='{"queries":[{"package":{"ecosystem":"npm","name":"a"},"version":"2.0.0"},{"package":{"ecosystem":"npm","name":"b"},"version":"3.1.0"},{"package":{"ecosystem":"npm","name":"jsqr"},"version":"1.4.0"}]}'
if [ "$out" = "$want" ]; then ok "print-queries lists lock and lockfile packages once"; else bad "print-queries: $out"; fi

printf '{"results":[{},{},{}]}\n' >"$tmp/clean.json"
rc=0; OSV_RESPONSE_FILE="$tmp/clean.json" bash "$osv" "$tmp/package-lock.json" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then ok "clean response exits 0"; else bad "clean rc=$rc"; fi

printf '{"results":[{},{"vulns":[{"id":"GHSA-xxxx"}]},{}]}\n' >"$tmp/hit.json"
rc=0; out="$(OSV_RESPONSE_FILE="$tmp/hit.json" bash "$osv" "$tmp/package-lock.json" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'b@3.1.0: GHSA-xxxx'; then ok "hit exits 1 and names the package"; else bad "hit rc=$rc $out"; fi

printf 'not json\n' >"$tmp/bad.json"
rc=0; out="$(OSV_RESPONSE_FILE="$tmp/bad.json" bash "$osv" "$tmp/package-lock.json" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'could not read OSV response'; then ok "malformed response exits 2"; else bad "malformed rc=$rc $out"; fi

printf '{"results":[{}]}\n' >"$tmp/short.json"
rc=0; OSV_RESPONSE_FILE="$tmp/short.json" bash "$osv" "$tmp/package-lock.json" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "response of the wrong length exits 2"; else bad "short rc=$rc"; fi

# Read alone, the vendor lock makes one query, and this response answers it cleanly.
printf '{"results":[{}]}\n' >"$tmp/clean-one.json"
rc=0; out="$(OSV_RESPONSE_FILE="$tmp/clean-one.json" bash "$osv" "$tmp/missing.json" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "$tmp/missing.json does not exist"; then
  ok "a missing lockfile exits 2, never a clean result"
else bad "missing lockfile rc=$rc $out"; fi

rc=0; out="$(OSV_RESPONSE_FILE="$tmp/clean.json" bash "$osv" "$tmp/package-lock.json" "$tmp/missing.json" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q 'no advisories'; then
  ok "a missing lockfile beside one that exists still exits 2"
else bad "missing beside present rc=$rc $out"; fi

rc=0; out="$(bash "$osv" --print-queries "$tmp/missing.json" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '"queries"'; then
  ok "a missing lockfile exits 2 before printing queries"
else bad "missing lockfile with --print-queries rc=$rc $out"; fi

# A vendor lock that is not there, from a wrong VENDOR_LOCK or a moved file, must not pass for
# one with nothing in it: jsQR would go unchecked under a clean result.
rc=0; out="$(VENDOR_LOCK="$tmp/no-such.lock" OSV_RESPONSE_FILE="$tmp/clean.json" bash "$osv" "$tmp/package-lock.json" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "$tmp/no-such.lock does not exist" && ! printf '%s' "$out" | grep -q 'no advisories'; then
  ok "a missing vendor lock exits 2, never a clean result"
else bad "missing vendor lock rc=$rc $out"; fi

rc=0; out="$(VENDOR_LOCK="$tmp/no-such.lock" bash "$osv" --print-queries "$tmp/package-lock.json" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q '"queries"'; then
  ok "a missing vendor lock exits 2 before printing queries"
else bad "missing vendor lock with --print-queries rc=$rc $out"; fi

rc=0; out="$(VENDOR_LOCK="$tmp" OSV_RESPONSE_FILE="$tmp/clean.json" bash "$osv" "$tmp/package-lock.json" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q 'no advisories'; then
  ok "a vendor lock that is a directory exits 2"
else bad "directory vendor lock rc=$rc $out"; fi

[ "$failures" -eq 0 ] || { echo "osv-check.test.sh: $failures failure(s)" >&2; exit 1; }
echo "osv-check.test.sh: all passed"
