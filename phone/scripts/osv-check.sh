#!/usr/bin/env bash
# usage: osv-check.sh [--print-queries] [lockfile...]
# Checks the vendored libraries (phone/loader/vendor/vendor.lock) and the packages pinned in
# each npm lockfile against OSV. Exit 0: no advisories. 1: advisories found. 2: could not check,
# which includes a lockfile or a vendor lock that does not exist: a run that skipped one it was
# asked to check would report a clean result for packages it never looked at.
# env: OSV_API_URL (default https://api.osv.dev/v1/querybatch), OSV_RESPONSE_FILE (test seam:
# read the response from this file instead of the network), VENDOR_LOCK (default the repo's lock).
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
api="${OSV_API_URL:-https://api.osv.dev/v1/querybatch}"
vendor_lock="${VENDOR_LOCK:-$repo/phone/loader/vendor/vendor.lock}"
print_queries=0
lockfiles=()

for arg in "$@"; do
  case "$arg" in
    --print-queries) print_queries=1 ;;
    *) lockfiles+=("$arg") ;;
  esac
done
if [ "${#lockfiles[@]}" -eq 0 ]; then
  lockfiles=("$repo/phone/package-lock.json")
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/osv-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

: >"$work/pairs"

if [ ! -f "$vendor_lock" ]; then
  echo "osv-check: vendor lock $vendor_lock does not exist" >&2
  exit 2
fi
if ! awk -F'\t' '!/^#/ && $3=="tarball" {print $1 "\t" $2}' "$vendor_lock" >>"$work/pairs"; then
  echo "osv-check: could not read $vendor_lock" >&2
  exit 2
fi

for lf in "${lockfiles[@]}"; do
  if [ ! -f "$lf" ]; then
    echo "osv-check: lockfile $lf does not exist" >&2
    exit 2
  fi
  if ! jq -r '.packages // {} | to_entries[]
      | select(.key | startswith("node_modules/"))
      | select(.value.version != null)
      | [(.value.name // (.key | sub("^.*node_modules/"; ""))), .value.version] | @tsv' \
    "$lf" >>"$work/pairs"; then
    echo "osv-check: could not read $lf" >&2
    exit 2
  fi
done

LC_ALL=C sort -u "$work/pairs" >"$work/unique"
jq -R -s -c '{queries: (split("\n") | map(select(length > 0) | split("\t")
  | {package: {ecosystem: "npm", name: .[0]}, version: .[1]}))}' "$work/unique" >"$work/queries.json"

if [ "$print_queries" -eq 1 ]; then
  cat "$work/queries.json"
  exit 0
fi

# Split into batches of 1000, one file per batch.
jq -c '.queries | _nwise(1000) | {queries: .}' "$work/queries.json" >"$work/batches"
n=0
hits=0
: >"$work/report"
while IFS= read -r batch || [ -n "$batch" ]; do
  n=$((n + 1))
  printf '%s\n' "$batch" >"$work/batch-$n.json"
  if [ -n "${OSV_RESPONSE_FILE:-}" ]; then
    cp "$OSV_RESPONSE_FILE" "$work/response-$n.json" || { echo "osv-check: could not read OSV response" >&2; exit 2; }
  else
    if ! curl -fsS --retry 3 -H 'Content-Type: application/json' --data @- "$api" \
      <"$work/batch-$n.json" >"$work/response-$n.json"; then
      echo "osv-check: could not read OSV response (request failed)" >&2
      exit 2
    fi
  fi
  if ! jq -e --slurpfile q "$work/batch-$n.json" \
    '(.results | type) == "array" and (.results | length) == ($q[0].queries | length)' \
    "$work/response-$n.json" >/dev/null 2>&1; then
    echo "osv-check: could not read OSV response (unexpected shape)" >&2
    exit 2
  fi
  jq -r --slurpfile q "$work/batch-$n.json" \
    '[.results, $q[0].queries] | transpose[]
     | select(.[0].vulns != null and (.[0].vulns | length) > 0)
     | .[1].package.name + "@" + .[1].version + ": " + (.[0].vulns | map(.id) | join(", "))' \
    "$work/response-$n.json" >>"$work/report"
done <"$work/batches"

if [ -s "$work/report" ]; then
  hits="$(wc -l <"$work/report" | tr -d ' ')"
  echo "osv-check: $hits package(s) with advisories:"
  cat "$work/report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### OSV advisories"
      cat "$work/report"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi
echo "osv-check: no advisories in $(wc -l <"$work/unique" | tr -d ' ') package(s)"
