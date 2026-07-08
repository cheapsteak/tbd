#!/usr/bin/env bash
# Tests for scripts/reclaim-build.sh — run: bash scripts/reclaim-build.test.sh
# shellcheck disable=SC2329 # helpers/test_* are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/reclaim-build.sh"   # source-guard prevents main() from running

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
assert_missing()  { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] unexpectedly has [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/reclaim-test.XXXXXX"; }
# set a file's mtime to N seconds before epoch NOW
touch_age()       { local f="$1" now="$2" age="$3"; touch -t "$(date -r "$((now - age))" +%Y%m%d%H%M.%S)" "$f"; }

test_newest_mtime_returns_newest_file() {
  local d; d="$(mktmpd)"
  : > "$d/old"; : > "$d/new"
  touch -t 202601010000.00 "$d/old"
  touch -t 202606010000.00 "$d/new"
  local expected; expected="$(stat -f '%m' "$d/new")"
  assert_eq "newest_mtime picks the newest file" "$expected" "$(newest_mtime "$d")"
  rm -rf "$d"
}

test_newest_mtime_empty_for_missing_dir() {
  assert_eq "newest_mtime empty for missing dir" "" "$(newest_mtime /no/such/dir/here)"
}

test_newest_mtime_empty_for_empty_dir() {
  local d; d="$(mktmpd)"
  assert_eq "newest_mtime empty for empty dir" "" "$(newest_mtime "$d")"
  rm -rf "$d"
}

test_has_active_build_true_when_swift_proc_matches() {
  local ps_out='901 /usr/bin/swift-frontend -c /Users/x/tbd/worktrees/tbd/w1/Sources/A.swift'
  if RECLAIM_PS_CMD="printf '%s\n' \"$ps_out\"" has_active_build "/Users/x/tbd/worktrees/tbd/w1"; then
    assert_eq "active build detected" "yes" "yes"
  else
    assert_eq "active build detected" "yes" "no"
  fi
}

test_has_active_build_false_when_no_swift_proc() {
  local ps_out='902 /bin/zsh -l'
  if RECLAIM_PS_CMD="printf '%s\n' \"$ps_out\"" has_active_build "/Users/x/tbd/worktrees/tbd/w1"; then
    assert_eq "no active build" "no" "yes"
  else
    assert_eq "no active build" "no" "no"
  fi
}

test_has_active_build_false_when_swift_proc_other_worktree() {
  local ps_out='903 /usr/bin/swiftc /Users/x/tbd/worktrees/tbd/OTHER/Sources/A.swift'
  if RECLAIM_PS_CMD="printf '%s\n' \"$ps_out\"" has_active_build "/Users/x/tbd/worktrees/tbd/w1"; then
    assert_eq "swift proc in other worktree ignored" "no" "yes"
  else
    assert_eq "swift proc in other worktree ignored" "no" "no"
  fi
}

test_ensure_lsp_config_seeds_when_absent() {
  local wt; wt="$(mktmpd)"
  local out; out="$(ensure_lsp_config "$wt" false)"
  assert_contains "seeds when absent (output)" "$out" "SEED lsp-config"
  assert_eq "config file written" "true" "$([[ -f "$wt/.sourcekit-lsp/config.json" ]] && echo true || echo false)"
  assert_contains "config disables bg indexing" "$(cat "$wt/.sourcekit-lsp/config.json")" '"backgroundIndexing": false'
  rm -rf "$wt"
}

test_ensure_lsp_config_dry_run_writes_nothing() {
  local wt; wt="$(mktmpd)"
  local out; out="$(ensure_lsp_config "$wt" true)"
  assert_contains "dry-run still reports SEED" "$out" "SEED lsp-config"
  assert_eq "dry-run writes no file" "false" "$([[ -f "$wt/.sourcekit-lsp/config.json" ]] && echo true || echo false)"
  rm -rf "$wt"
}

test_ensure_lsp_config_noop_when_present() {
  local wt; wt="$(mktmpd)"
  mkdir -p "$wt/.sourcekit-lsp"
  printf '{ "someOtherKey": true }\n' > "$wt/.sourcekit-lsp/config.json"
  local out; out="$(ensure_lsp_config "$wt" false)"
  assert_contains "no-op when present (output)" "$out" "SKIP lsp-config-exists"
  assert_contains "existing config untouched" "$(cat "$wt/.sourcekit-lsp/config.json")" '"someOtherKey": true'
  rm -rf "$wt"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
