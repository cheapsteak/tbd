#!/usr/bin/env bash
# Tests for scripts/sweep-scratchpads.sh — run: bash scripts/sweep-scratchpads.test.sh
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/sweep-scratchpads.sh"   # source-guard prevents main() from running

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/sweep-test.XXXXXX"; }
NO_LSOF='printf ""'   # lsof seam reporting no live cwds

# make a scratchpad dir with a single file aged OLD (well past --days)
_mk_old_scratch() { local base="$1" slug="$2"; mkdir -p "$base/$slug"; : > "$base/$slug/f"; touch -t 200001010000.00 "$base/$slug/f"; }

test_live_cwd_slugs_slugifies_lsof_output() {
  local lsof="printf 'p1\nfcwd\nn/Users/x/wt\n'"
  local out; out="$(SWEEP_LSOF_CMD="$lsof" live_cwd_slugs)"
  assert_eq "cwd slugified with leading dash" "-Users-x-wt" "$out"
}

test_live_cwd_slugs_canonicalizes_symlinked_paths() {
  local root; root="$(mktmpd)"
  mkdir -p "$root/real"
  ln -s "$root/real" "$root/link"
  local canon; canon="$(cd "$root/real" && pwd -P)"
  local slug_real; slug_real="$(printf '%s\n' "$canon" | tr '/' '-')"
  local lsof; lsof="printf 'p1\nfcwd\nn%s\n' \"$root/link\""
  local out; out="$(SWEEP_LSOF_CMD="$lsof" live_cwd_slugs)"
  assert_eq "symlinked path resolves to canonical slug" "$slug_real" "$out"
  rm -rf "$root"
}

test_no_base_dir_is_noop() {
  local out; out="$(SWEEP_BASE="/no/such/base/here" bash "$HERE/sweep-scratchpads.sh" 2>&1)"
  assert_contains "missing base reported" "$out" "no scratchpad base at /no/such/base/here"
}

test_removes_orphaned_old_scratchpad() {
  local base; base="$(mktmpd)"
  _mk_old_scratch "$base" "-a-b-orphan"
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$NO_LSOF" bash "$HERE/sweep-scratchpads.sh" 2>&1)"
  assert_contains "orphan planned for removal" "$out" "PLAN remove -a-b-orphan"
  assert_eq "orphan removed" "false" "$([[ -d "$base/-a-b-orphan" ]] && echo true || echo false)"
  rm -rf "$base"
}

test_keeps_live_session_slug() {
  local base; base="$(mktmpd)"
  _mk_old_scratch "$base" "-x-y-live"          # old, but a live cwd owns it
  local lsof="printf 'p1\nfcwd\nn/x/y/live\n'"
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$lsof" bash "$HERE/sweep-scratchpads.sh" 2>&1)"
  assert_contains "live slug kept" "$out" "KEEP live -x-y-live"
  assert_eq "live scratchpad survives" "true" "$([[ -d "$base/-x-y-live" ]] && echo true || echo false)"
  rm -rf "$base"
}

test_keeps_recently_written_scratchpad() {
  local base; base="$(mktmpd)"
  mkdir -p "$base/-fresh-one"; : > "$base/-fresh-one/f"   # default mtime = now
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$NO_LSOF" bash "$HERE/sweep-scratchpads.sh" 2>&1)"
  assert_contains "recent scratchpad kept" "$out" "KEEP recent -fresh-one"
  assert_eq "recent scratchpad survives" "true" "$([[ -d "$base/-fresh-one" ]] && echo true || echo false)"
  rm -rf "$base"
}

test_dry_run_removes_nothing() {
  local base; base="$(mktmpd)"
  _mk_old_scratch "$base" "-a-b-orphan"
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$NO_LSOF" bash "$HERE/sweep-scratchpads.sh" --dry-run 2>&1)"
  assert_contains "dry-run still plans removal" "$out" "PLAN remove -a-b-orphan"
  assert_eq "dry-run keeps the dir" "true" "$([[ -d "$base/-a-b-orphan" ]] && echo true || echo false)"
  rm -rf "$base"
}

test_days_override_widens_keep_window() {
  local base; base="$(mktmpd)"
  mkdir -p "$base/-agedays"; : > "$base/-agedays/f"
  touch -t "$(date -r "$(( $(date +%s) - 5*86400 ))" +%Y%m%d%H%M.%S)" "$base/-agedays/f"   # ~5 days old
  local kept; kept="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$NO_LSOF" SWEEP_DAYS=7 bash "$HERE/sweep-scratchpads.sh" --dry-run 2>&1)"
  assert_contains "5-day file kept when window is 7 days" "$kept" "KEEP recent -agedays"
  local swept; swept="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$NO_LSOF" SWEEP_DAYS=3 bash "$HERE/sweep-scratchpads.sh" --dry-run 2>&1)"
  assert_contains "5-day file planned when window is 3 days" "$swept" "PLAN remove -agedays"
  rm -rf "$base"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
