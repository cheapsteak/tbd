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
# An lsof seam that RAN and produced a cwd list owning no fixture scratchpad —
# the "probe worked, nothing matched" case, which must still sweep. An empty
# list is not this case: the sweep reads that as a broken probe and keeps
# everything, so a fixture reporting nothing would test the opposite branch.
LSOF_NO_MATCH="printf 'p1\nfcwd\nn/Users/x/elsewhere\n'"

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
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$LSOF_NO_MATCH" bash "$HERE/sweep-scratchpads.sh" 2>&1)"
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
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$LSOF_NO_MATCH" bash "$HERE/sweep-scratchpads.sh" 2>&1)"
  assert_contains "recent scratchpad kept" "$out" "KEEP recent -fresh-one"
  assert_eq "recent scratchpad survives" "true" "$([[ -d "$base/-fresh-one" ]] && echo true || echo false)"
  rm -rf "$base"
}

test_dry_run_removes_nothing() {
  local base; base="$(mktmpd)"
  _mk_old_scratch "$base" "-a-b-orphan"
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$LSOF_NO_MATCH" bash "$HERE/sweep-scratchpads.sh" --dry-run 2>&1)"
  assert_contains "dry-run still plans removal" "$out" "PLAN remove -a-b-orphan"
  assert_eq "dry-run keeps the dir" "true" "$([[ -d "$base/-a-b-orphan" ]] && echo true || echo false)"
  rm -rf "$base"
}

test_days_override_widens_keep_window() {
  local base; base="$(mktmpd)"
  mkdir -p "$base/-agedays"; : > "$base/-agedays/f"
  touch -t "$(date -r "$(( $(date +%s) - 5*86400 ))" +%Y%m%d%H%M.%S)" "$base/-agedays/f"   # ~5 days old
  local kept; kept="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$LSOF_NO_MATCH" SWEEP_DAYS=7 bash "$HERE/sweep-scratchpads.sh" --dry-run 2>&1)"
  assert_contains "5-day file kept when window is 7 days" "$kept" "KEEP recent -agedays"
  local swept; swept="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD="$LSOF_NO_MATCH" SWEEP_DAYS=3 bash "$HERE/sweep-scratchpads.sh" --dry-run 2>&1)"
  assert_contains "5-day file planned when window is 3 days" "$swept" "PLAN remove -agedays"
  rm -rf "$base"
}

# --- the live-process probe fails closed -------------------------------------
# Without these the probe can go silently dead — a short PATH with no lsof on
# it, or a seam that errors — and the recency window becomes the only thing
# between a live session's scratchpad and rm -rf.

# Run a sourced function with no lsof resolvable anywhere: PATH scrubbed and the
# absolute fallback list pointed at a file that does not exist. Restores both.
_without_lsof() {
  local saved_path="$PATH" rc=0
  local saved_candidates=("${SWEEP_LSOF_CANDIDATES[@]}")
  # shellcheck disable=SC2123 # scrubbing PATH is the point: it is what makes
  # `command -v lsof` fail, and it is restored below.
  PATH="/nonexistent-dir-for-tests"
  SWEEP_LSOF_CANDIDATES=("/nonexistent-dir-for-tests/lsof")
  "$@" || rc=$?
  PATH="$saved_path"
  SWEEP_LSOF_CANDIDATES=("${saved_candidates[@]}")
  return "$rc"
}

test_lsof_available_true_when_seam_is_injected() {
  if SWEEP_LSOF_CMD="$LSOF_NO_MATCH" _without_lsof _lsof_available; then
    assert_eq "injected seam counts as available" y y
  else
    assert_eq "injected seam counts as available" y n
  fi
}

test_lsof_available_false_when_tool_is_nowhere() {
  if SWEEP_LSOF_CMD='' _without_lsof _lsof_available; then
    assert_eq "unresolvable lsof is unavailable" n y
  else
    assert_eq "unresolvable lsof is unavailable" n n
  fi
}

test_scan_live_slugs_marks_ok_only_with_data() {
  SWEEP_LSOF_CMD="$LSOF_NO_MATCH" scan_live_slugs
  assert_eq "probe with data -> LIVE_OK=1" "1" "$LIVE_OK"
  assert_eq "probe with data -> slugs captured" "-Users-x-elsewhere" "$KEEP_SLUGS"
  SWEEP_LSOF_CMD='printf ""' scan_live_slugs
  assert_eq "empty probe -> LIVE_OK=0" "0" "$LIVE_OK"
  SWEEP_LSOF_CMD='exit 127' scan_live_slugs
  assert_eq "failing probe -> LIVE_OK=0" "0" "$LIVE_OK"
  SWEEP_LSOF_CMD='' _without_lsof scan_live_slugs
  assert_eq "unavailable probe -> LIVE_OK=0" "0" "$LIVE_OK"
  LIVE_OK=0; KEEP_SLUGS=""
}

test_keeps_everything_when_probe_returns_nothing() {
  local base; base="$(mktmpd)"
  _mk_old_scratch "$base" "-a-b-orphan"
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD='printf ""' bash "$HERE/sweep-scratchpads.sh" 2>&1)"
  assert_contains "empty probe warns" "$out" "WARNING: live-process probe produced no cwds"
  assert_contains "empty probe keeps the orphan" "$out" "KEEP live-unknown -a-b-orphan"
  assert_eq "empty probe removes nothing" "true" "$([[ -d "$base/-a-b-orphan" ]] && echo true || echo false)"
  rm -rf "$base"
}

test_keeps_everything_when_probe_cannot_run() {
  local base; base="$(mktmpd)"
  _mk_old_scratch "$base" "-a-b-orphan"
  # A probe that exits nonzero and prints nothing — what a missing lsof looks
  # like from main()'s side.
  local out; out="$(SWEEP_BASE="$base" SWEEP_LSOF_CMD='exit 127' bash "$HERE/sweep-scratchpads.sh" 2>&1)"
  assert_contains "broken probe warns" "$out" "WARNING: live-process probe produced no cwds"
  assert_contains "broken probe keeps the orphan" "$out" "KEEP live-unknown -a-b-orphan"
  assert_eq "broken probe removes nothing" "true" "$([[ -d "$base/-a-b-orphan" ]] && echo true || echo false)"
  rm -rf "$base"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
