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

# helper: build a fake worktree with index-build + debug build files aged relative to NOW
_mk_worktree() { # dir now index_age debug_age
  local d="$1" now="$2" iage="$3" dage="$4"
  mkdir -p "$d/.build/index-build" "$d/.build/arm64-apple-macosx/debug"
  : > "$d/Package.swift"
  : > "$d/.build/index-build/idx.o";        touch_age "$d/.build/index-build/idx.o" "$now" "$iage"
  : > "$d/.build/arm64-apple-macosx/debug/app.o"; touch_age "$d/.build/arm64-apple-macosx/debug/app.o" "$now" "$dage"
}
NO_PS='printf ""'   # ps seam that matches nothing

test_plan_skips_when_no_build_dir() {
  local d; d="$(mktmpd)"
  local out; out="$(RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0)"
  assert_eq "no .build -> no output" "" "$out"
  rm -rf "$d"
}

test_plan_fresh_skips_both_tiers() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 60 60   # 1 min old — fresh
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0)"
  assert_eq "fresh -> SKIP fresh" "SKIP fresh $d" "$out"
  rm -rf "$d"
}

test_plan_stale_index_only_is_tier1() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 25000 60   # index ~7h old, debug fresh
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0)"
  assert_eq "stale index only -> tier1" "PLAN tier1 $d" "$out"
  rm -rf "$d"
}

test_plan_stale_whole_build_no_session_is_tier2() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 200000 200000   # both > 48h
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0)"
  assert_eq "stale whole build, no session -> tier2" "PLAN tier2 $d" "$out"
  rm -rf "$d"
}

test_plan_stale_build_with_live_session_falls_to_tier1() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 200000 200000   # both stale, but session present
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 1)"
  assert_eq "stale build + live session -> tier1 (keep debug)" "PLAN tier1 $d" "$out"
  rm -rf "$d"
}

test_plan_active_build_hard_skips() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 200000 200000
  local ps="printf '%s\n' \"711 /usr/bin/swift-frontend -c $d/Sources/A.swift\""
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$ps" plan_worktree "$d" 0)"
  assert_eq "active build -> hard skip" "SKIP active-build $d" "$out"
  rm -rf "$d"
}

test_list_worktrees_tsv_active_only_with_sessions() {
  local j; j="$(mktmpd)/wt.json"
  cat > "$j" <<'JSON'
[
  {"path":"/w/active-a","status":"active","liveClaudeSessionCount":2},
  {"path":"/w/active-b","status":"active"},
  {"path":"/w/archived","status":"archived","liveClaudeSessionCount":0}
]
JSON
  local out; out="$(RECLAIM_WT_JSON="$j" list_worktrees_tsv)"
  assert_contains "active-a with session count" "$out" "/w/active-a	2"
  assert_contains "active-b defaults to 0" "$out" "/w/active-b	0"
  assert_missing  "archived excluded" "$out" "/w/archived"
  rm -rf "$(dirname "$j")"
}

test_main_dry_run_plans_but_deletes_nothing() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/active-a" b="$root/active-b"
  _mk_worktree "$a" "$now" 200000 200000   # fully stale, no session -> tier2
  _mk_worktree "$b" "$now" 25000 60         # index stale only -> tier1
  local j="$root/wt.json"
  cat > "$j" <<JSON
[
  {"path":"$a","status":"active","liveClaudeSessionCount":0},
  {"path":"$b","status":"active","liveClaudeSessionCount":0}
]
JSON
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD='printf ""' bash "$HERE/reclaim-build.sh" --dry-run 2>&1)"
  assert_contains "dry-run plans tier2 for a" "$out" "PLAN tier2 $a"
  assert_contains "dry-run plans tier1 for b" "$out" "PLAN tier1 $b"
  assert_eq "dry-run keeps a/.build" "true" "$([[ -d "$a/.build" ]] && echo true || echo false)"
  assert_eq "dry-run keeps b/index-build" "true" "$([[ -d "$b/.build/index-build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_main_real_run_reclaims() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/active-a" b="$root/active-b"
  _mk_worktree "$a" "$now" 200000 200000   # tier2 -> whole .build deleted
  _mk_worktree "$b" "$now" 25000 3600       # tier1 -> only index-build deleted (debug past active-grace window)
  local j="$root/wt.json"
  cat > "$j" <<JSON
[
  {"path":"$a","status":"active","liveClaudeSessionCount":0},
  {"path":"$b","status":"active","liveClaudeSessionCount":0}
]
JSON
  RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD='printf ""' bash "$HERE/reclaim-build.sh" >/dev/null 2>&1
  assert_eq "tier2 removed a/.build"          "false" "$([[ -d "$a/.build" ]] && echo true || echo false)"
  assert_eq "tier1 removed b/index-build"     "false" "$([[ -d "$b/.build/index-build" ]] && echo true || echo false)"
  assert_eq "tier1 kept b debug build"        "true"  "$([[ -d "$b/.build/arm64-apple-macosx" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_write_plist_contains_label_interval_and_script() {
  # shellcheck source=/dev/null
  source "$HERE/install-reclaim-agent.sh"   # source-guarded; must not run install
  local out; out="$(mktmpd)/agent.plist"
  write_plist "$out" "/repo/scripts/reclaim-build.sh"
  local body; body="$(cat "$out")"
  assert_contains "plist has label"        "$body" "com.tbd.reclaim-build"
  assert_contains "plist hourly interval"  "$body" "<integer>3600</integer>"
  assert_contains "plist runs the script"  "$body" "/repo/scripts/reclaim-build.sh"
  assert_contains "plist sets launchd PATH" "$body" "<key>PATH</key>"
  assert_contains "plist PATH includes homebrew" "$body" "/opt/homebrew/bin"
  rm -rf "$(dirname "$out")"
}

test_main_skips_worktree_without_package_swift() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/swift-wt" b="$root/nonswift-wt"
  _mk_worktree "$a" "$now" 200000 200000   # has Package.swift, tier2-eligible
  # b: active, stale .build, but NO Package.swift -> must be skipped entirely
  mkdir -p "$b/.build/arm64-apple-macosx/debug"
  : > "$b/.build/arm64-apple-macosx/debug/app.o"
  touch_age "$b/.build/arm64-apple-macosx/debug/app.o" "$now" 200000
  local j="$root/wt.json"
  cat > "$j" <<JSON
[
  {"path":"$a","status":"active","liveClaudeSessionCount":0},
  {"path":"$b","status":"active","liveClaudeSessionCount":0}
]
JSON
  local out; out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD='printf ""' bash "$HERE/reclaim-build.sh" --dry-run 2>&1)"
  assert_contains "swift worktree planned" "$out" "PLAN tier2 $a"
  assert_missing "non-swift worktree skipped entirely" "$out" "$b"
  rm -rf "$root"
}

test_main_skips_recently_touched_build() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/wt"
  _mk_worktree "$a" "$now" 200000 200000   # arm64 + index both stale -> tier2 by clocks
  mkdir -p "$a/.build/repositories"
  : > "$a/.build/repositories/fresh"; touch_age "$a/.build/repositories/fresh" "$now" 0   # touched "now"
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$a","status":"active","liveClaudeSessionCount":0}]
JSON
  RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD='printf ""' bash "$HERE/reclaim-build.sh" >/dev/null 2>&1
  assert_eq "recently-touched .build NOT deleted" "true" "$([[ -d "$a/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_repo_root_for_worktree_returns_parent_of_git_common_dir() {
  local d; d="$(mktmpd)"
  git init -q "$d"
  # git canonicalizes symlinks (e.g. macOS /tmp -> /private/tmp) in its
  # absolute-path output, so compare against the same resolution.
  local expected; expected="$(cd "$d" && pwd -P)"
  local out; out="$(repo_root_for_worktree "$d")"
  assert_eq "repo root is parent of .git" "$expected" "$out"
  rm -rf "$d"
}

test_repo_root_for_worktree_fails_for_non_git_dir() {
  local d; d="$(mktmpd)"
  local out rc=0
  out="$(repo_root_for_worktree "$d")" || rc=$?
  assert_eq "non-git dir yields nonzero exit" "1" "$rc"
  assert_eq "non-git dir yields empty output" "" "$out"
  rm -rf "$d"
}

test_claude_agent_worktree_tier2_reaped() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-abc123"
  _mk_worktree "$agent" "$now" 200000 200000   # both stale -> tier2
  local j="$root/wt.json"; printf '[]' > "$j"
  RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" \
    bash "$HERE/reclaim-build.sh" >/dev/null 2>&1
  assert_eq "claude agent worktree .build reaped (tier2)" "false" "$([[ -d "$agent/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_claude_agent_worktree_without_package_swift_skipped() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-nopkg"
  mkdir -p "$agent/.build/arm64-apple-macosx/debug"
  : > "$agent/.build/arm64-apple-macosx/debug/app.o"
  touch_age "$agent/.build/arm64-apple-macosx/debug/app.o" "$now" 200000
  # deliberately NO Package.swift
  local j="$root/wt.json"; printf '[]' > "$j"
  local out; out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" \
    bash "$HERE/reclaim-build.sh" --dry-run 2>&1)"
  assert_missing "non-swift claude agent worktree skipped entirely" "$out" "$agent"
  rm -rf "$root"
}

test_claude_agent_worktree_fresh_build_skipped() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-fresh"
  _mk_worktree "$agent" "$now" 60 60   # 1 min old — within grace, fresh
  local j="$root/wt.json"; printf '[]' > "$j"
  local out; out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" \
    bash "$HERE/reclaim-build.sh" --dry-run 2>&1)"
  assert_contains "fresh claude agent worktree skipped" "$out" "SKIP fresh $agent"
  rm -rf "$root"
}

test_repo_roots_injection_dedups_against_tbd_list() {
  local root; root="$(mktmpd)"; local now=2000000000
  # Same path enumerated via BOTH the TBD list and RECLAIM_REPO_ROOTS-derived
  # .claude/worktrees glob — dedup must keep exactly one line, using the TBD
  # list's (nonzero) session count so tier2 (needs sessions==0) is blocked.
  local dup="$root/.claude/worktrees/dup-agent"
  _mk_worktree "$dup" "$now" 200000 200000   # both stale -> tier2 if sessions==0
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$dup","status":"active","liveClaudeSessionCount":5}]
JSON
  local out; out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" \
    bash "$HERE/reclaim-build.sh" --dry-run 2>&1)"
  local count; count="$(grep -c -- "$dup" <<<"$out")"
  assert_eq "dup path processed exactly once" "1" "$count"
  assert_contains "dup path uses TBD session count -> tier1 not tier2" "$out" "PLAN tier1 $dup"
  rm -rf "$root"
}

test_plan_tier2_works_on_x86_64_triple() {
  local d; d="$(mktmpd)"; local now=2000000000
  mkdir -p "$d/.build/x86_64-apple-macosx/debug"
  : > "$d/.build/x86_64-apple-macosx/debug/app.o"; touch_age "$d/.build/x86_64-apple-macosx/debug/app.o" "$now" 200000
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0)"
  assert_eq "x86_64 triple -> tier2" "PLAN tier2 $d" "$out"
  rm -rf "$d"
}

# Static check (not a functional test — restart.sh builds/launches the real
# app, so it can't be exercised here): confirm restart.sh still wires up the
# opportunistic background reclaim launch it added in scripts/restart.sh —
# async (nohup, backgrounded), silent (no bare invocation without redirects),
# and gated on both the opt-out env var and the script actually being present.
test_restart_sh_launches_reclaim_async_and_silent() {
  local restart="$HERE/restart.sh"
  local body; body="$(cat "$restart")"
  # shellcheck disable=SC2016 # single-quoted on purpose: searching restart.sh
  # for these literal, unexpanded strings, not expanding them ourselves.
  assert_contains "restart.sh backgrounds reclaim-build.sh with nohup" "$body" 'nohup "$RECLAIM_SCRIPT"'
  assert_contains "restart.sh redirects reclaim output to the shared log file" "$body" 'Library/Logs/tbd-reclaim-build.log'
  assert_contains "restart.sh honors TBD_SKIP_RECLAIM opt-out" "$body" 'TBD_SKIP_RECLAIM'
  # shellcheck disable=SC2016
  assert_contains "restart.sh guards on reclaim script executability" "$body" '[ -x "$RECLAIM_SCRIPT" ]'
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
