#!/usr/bin/env bash
# Tests for scripts/reclaim-build.sh — run: bash scripts/reclaim-build.test.sh
# shellcheck disable=SC2329 # helpers/test_* are dispatched dynamically via `declare -F`/"$t" below
# shellcheck disable=SC2034 # LIVE_CWDS is set here but read by is_live_cwd in the sourced script
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
  local out; out="$(RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 tbd)"
  assert_eq "no .build -> no output" "" "$out"
  rm -rf "$d"
}

test_plan_fresh_skips_both_tiers() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 60 60   # 1 min old — fresh
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 tbd)"
  assert_eq "fresh -> SKIP fresh" "SKIP fresh $d" "$out"
  rm -rf "$d"
}

test_plan_stale_index_only_is_tier1() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 25000 60   # index ~7h old, debug fresh
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 tbd)"
  assert_eq "stale index only -> tier1" "PLAN tier1 $d" "$out"
  rm -rf "$d"
}

test_plan_stale_whole_build_no_session_is_tier2() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 200000 200000   # both > 48h
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 tbd)"
  assert_eq "stale whole build, no session -> tier2" "PLAN tier2 $d" "$out"
  rm -rf "$d"
}

test_plan_stale_build_with_live_session_falls_to_tier1() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 200000 200000   # both stale, but session present
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 1 tbd)"
  assert_eq "stale build + live session -> tier1 (keep debug)" "PLAN tier1 $d" "$out"
  rm -rf "$d"
}

test_plan_active_build_hard_skips() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 200000 200000
  local ps="printf '%s\n' \"711 /usr/bin/swift-frontend -c $d/Sources/A.swift\""
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$ps" plan_worktree "$d" 0 tbd)"
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

test_main_exclude_path_skips_only_that_worktree() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/excluded" b="$root/sibling"
  _mk_worktree "$a" "$now" 200000 200000   # tier2-eligible — but excluded
  _mk_worktree "$b" "$now" 200000 200000   # tier2-eligible sibling, same run
  local j="$root/wt.json"
  cat > "$j" <<JSON
[
  {"path":"$a","status":"active","liveClaudeSessionCount":0},
  {"path":"$b","status":"active","liveClaudeSessionCount":0}
]
JSON
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" RECLAIM_EXCLUDE_PATH="$a" \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "excluded worktree logged as skipped" "$out" "SKIP excluded $a"
  assert_missing  "excluded worktree never planned"     "$out" "PLAN tier2 $a"
  assert_contains "sibling still planned in same run"   "$out" "PLAN tier2 $b"
  assert_eq "excluded .build survives"  "true"  "$([[ -d "$a/.build" ]] && echo true || echo false)"
  assert_eq "sibling .build reclaimed"  "false" "$([[ -d "$b/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_main_exclude_path_canonicalizes_variants() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/real"
  _mk_worktree "$a" "$now" 200000 200000   # tier2-eligible
  ln -s "$a" "$root/link"                   # symlinked route to the same dir
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$a","status":"active","liveClaudeSessionCount":0}]
JSON
  # Exclude via a symlink AND a trailing slash — textually nothing like the
  # listed path; only canonicalization of both sides can match them.
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" RECLAIM_EXCLUDE_PATH="$root/link/" \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "unnormalized exclude still skips"   "$out" "SKIP excluded $a"
  assert_missing  "unnormalized exclude blocks plan"   "$out" "PLAN tier2 $a"
  assert_eq "excluded .build survives symlink variant" "true" "$([[ -d "$a/.build" ]] && echo true || echo false)"
  rm -rf "$root"
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
  : > "$d/Package.swift"
  : > "$d/.build/x86_64-apple-macosx/debug/app.o"; touch_age "$d/.build/x86_64-apple-macosx/debug/app.o" "$now" 200000
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 tbd)"
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

  # The launch line itself must be fully detached from the terminal: stderr
  # merged into the log and stdin redirected from /dev/null, then backgrounded.
  local launch_line
  # shellcheck disable=SC2016
  launch_line="$(grep -F 'nohup "$RECLAIM_SCRIPT"' "$restart")"
  assert_contains "launch line merges stderr into the log" "$launch_line" '2>&1'
  assert_contains "launch line redirects stdin from /dev/null" "$launch_line" '< /dev/null'
  assert_contains "launch line is backgrounded" "$launch_line" '/dev/null &'
  # Self-collision guard: the reclaim must never sweep the very worktree
  # whose build it overlaps (a revived ≥48h-stale .build is tier2-eligible
  # at plan time, before the new build has touched it).
  # shellcheck disable=SC2016
  assert_contains "launch line excludes its own worktree" "$launch_line" 'RECLAIM_EXCLUDE_PATH="$REPO_ROOT"'

  # Regression guard: a bare `disown` under restart.sh's set -e aborts the
  # whole restart if the reclaim job already finished and was reaped (and
  # prints "no such job" to the terminal). nohup + full fd redirection in a
  # non-interactive shell detaches on its own; disown must never come back.
  assert_missing "restart.sh contains no disown" "$body" 'disown'

  # Ordering: the reclaim launch must precede the swift build so the two
  # overlap instead of the reclaim running after the restart's slow phase.
  local nohup_ln build_ln
  # shellcheck disable=SC2016
  nohup_ln="$(grep -nF 'nohup "$RECLAIM_SCRIPT"' "$restart" | head -1 | cut -d: -f1)"
  # shellcheck disable=SC2016
  build_ln="$(grep -nF 'run_governed_build "$REPO_ROOT"' "$restart" | head -1 | cut -d: -f1)"
  local order="unknown"
  if [[ -n "$nohup_ln" && -n "$build_ln" ]] && (( nohup_ln < build_ln )); then order="before"; fi
  assert_eq "reclaim launch (line ${nohup_ln:-?}) precedes swift build (line ${build_ln:-?})" "before" "$order"
}

# Static check: the shared clang/Swift module cache must be selected in exactly
# ONE place — scripts/swift-safe, the wrapper every governed compile goes
# through — so that `build`, `test` and `run` plan identically. Two entry points
# that disagree about the path make every transition between them a full
# recompile, because SwiftPM bakes the path into .build/debug.yaml at plan time.
# The invariant is therefore two-sided: the wrapper supplies both flags, and
# restart.sh supplies neither.
# See docs/specs/2026-08-30-shared-module-cache-design.md.
test_the_shared_module_cache_is_selected_only_by_the_wrapper() {
  local restart="$HERE/restart.sh"
  local wrapper; wrapper="$(cat "$HERE/swift-safe")"

  assert_contains "the wrapper points at the shared per-user module cache" "$wrapper" 'Library/Caches/tbd/swift-module-cache'
  assert_contains "the wrapper supplies the Swift frontend module-cache-path" "$wrapper" '"-module-cache-path"'
  assert_contains "the wrapper supplies the clang modules cache path" "$wrapper" 'f"-fmodules-cache-path={path}"'
  # The path must come from the passwd database: scripts/test.sh points HOME at
  # a scratch fence it deletes, so a $HOME-derived cache would be minted empty
  # inside the fence on every test run and every run would pay a full rebuild.
  assert_contains "the wrapper resolves the path from the passwd database" "$wrapper" 'pwd.getpwuid(os.getuid()).pw_dir'
  assert_missing "the wrapper never derives the cache from \$HOME" "$wrapper" 'os.environ["HOME"]'
  # The wrapper creates it, so no build races a missing parent directory.
  assert_contains "the wrapper creates the shared cache dir" "$wrapper" 'path.mkdir(parents=True, exist_ok=True)'

  # restart.sh must not select it a second time, in any spelling.
  local body; body="$(cat "$restart")"
  local restart_flags
  restart_flags="$(grep -nE '^[^#]*(-module-cache-path|-fmodules-cache-path|MODULE_CACHE_FLAGS)' "$restart" || true)"
  assert_eq "restart.sh selects no module cache of its own" "" "$restart_flags"

  # The build still runs through scripts/restart-build-lib.sh, which captures
  # swift-safe's real exit status instead of piping it away, and that lib is
  # where the admission wrapper is actually invoked.
  # shellcheck disable=SC2016 # literal, unexpanded strings searched in restart.sh
  assert_contains "restart.sh runs the governed build with no extra flags" "$body" 'run_governed_build "$REPO_ROOT" || exit $?'
  # shellcheck disable=SC2016
  assert_contains "the governed build still uses the admission wrapper" \
    "$(cat "$HERE/restart-build-lib.sh")" 'scripts/swift-safe build'
}

# --- install-reaping + gate helpers ------------------------------------------
# _mk_install_dir wt now age name : create an install dir whose OWN mtime is
# `age` seconds before NOW (dir_mtime reads the dir mtime, not its contents).
_mk_install_dir() {
  local wt="$1" now="$2" age="$3" name="$4"
  mkdir -p "$wt/$name"
  : > "$wt/$name/content"
  touch_age "$wt/$name" "$now" "$age"
}

test_dir_mtime_reads_dir_not_contents() {
  local d; d="$(mktmpd)"; local now=2000000000
  mkdir -p "$d/node_modules"; : > "$d/node_modules/pkg"
  touch_age "$d/node_modules" "$now" 5000
  assert_eq "dir_mtime is the dir's own mtime" "$((now - 5000))" "$(dir_mtime "$d/node_modules")"
  rm -rf "$d"
}

test_eligible_install_dirs_includes_present_regenerable() {
  local d; d="$(mktmpd)"
  : > "$d/package.json"
  mkdir -p "$d/node_modules"
  : > "$d/main.tf"
  mkdir -p "$d/.terraform"
  local out; out="$(eligible_install_dirs "$d")"
  assert_contains "eligible includes regenerable node_modules" "$out" "node_modules"
  assert_contains "eligible includes regenerable .terraform" "$out" ".terraform"
  rm -rf "$d"
}

test_eligible_install_dirs_excludes_non_regenerable() {
  local d; d="$(mktmpd)"
  mkdir -p "$d/node_modules"     # present but NO package.json
  mkdir -p "$d/.terraform"       # present but NO *.tf
  local out; out="$(eligible_install_dirs "$d")"
  assert_eq "non-regenerable dirs excluded" "" "$out"
  rm -rf "$d"
}

test_worktree_newest_mtime_picks_newest_non_pruned_file() {
  local d; d="$(mktmpd)"; local now=2000000000
  mkdir -p "$d/Sources"
  : > "$d/Sources/main.swift"
  touch_age "$d/Sources/main.swift" "$now" 5000
  mkdir -p "$d/.build"           # pruned dir
  : > "$d/.build/artifact"
  touch_age "$d/.build/artifact" "$now" 100    # much newer, but in pruned dir
  local expected; expected="$((now - 5000))"
  assert_eq "worktree_newest_mtime ignores .build" "$expected" "$(worktree_newest_mtime "$d")"
  rm -rf "$d"
}

test_worktree_newest_mtime_empty_when_only_pruned_dirs() {
  local d; d="$(mktmpd)"; local now=2000000000
  mkdir -p "$d/node_modules"; : > "$d/node_modules/pkg"
  touch_age "$d/node_modules/pkg" "$now" 100
  mkdir -p "$d/.build"; : > "$d/.build/artifact"
  touch_age "$d/.build/artifact" "$now" 50
  assert_eq "no non-pruned files -> empty" "" "$(worktree_newest_mtime "$d")"
  rm -rf "$d"
}

test_has_reclaimable_true_for_regenerable_installs() {
  local d; d="$(mktmpd)"
  : > "$d/package.json"
  mkdir -p "$d/node_modules"
  if has_reclaimable "$d"; then assert_eq "regenerable installs -> reclaimable" y y; else assert_eq "regenerable installs -> reclaimable" y n; fi
  rm -rf "$d"
}

test_has_reclaimable_false_for_non_regenerable_install() {
  local d; d="$(mktmpd)"
  mkdir -p "$d/node_modules"  # present but NO package.json
  if has_reclaimable "$d"; then assert_eq "non-regenerable installs not reclaimable" n y; else assert_eq "non-regenerable installs not reclaimable" n n; fi
  rm -rf "$d"
}

test_has_reclaimable_false_for_bare_build_without_package_swift() {
  local d; d="$(mktmpd)"
  mkdir -p "$d/.build/arm64-apple-macosx"   # no Package.swift, no installs
  if has_reclaimable "$d"; then assert_eq "bare .build not reclaimable" n y; else assert_eq "bare .build not reclaimable" n n; fi
  rm -rf "$d"
}

test_is_live_cwd_prefix_matches_inside_worktree() {
  local wt="/w/proj/alpha"
  LIVE_CWDS="/w/proj/alpha/Sources
/other/path"
  if is_live_cwd "$wt"; then assert_eq "cwd inside worktree is live" y y; else assert_eq "cwd inside worktree is live" y n; fi
  LIVE_CWDS=""
}

test_is_live_cwd_ignores_parent_and_prefix_sibling() {
  local wt="/w/proj/alpha"
  LIVE_CWDS="/w/proj
/w/proj/alphabet"     # a parent, and a sibling sharing the 'alpha' prefix
  if is_live_cwd "$wt"; then assert_eq "parent/sibling not live" n y; else assert_eq "parent/sibling not live" n n; fi
  LIVE_CWDS=""
}

test_is_live_cwd_canonicalizes_symlinked_worktree() {
  local root; root="$(mktmpd)"
  mkdir -p "$root/real/Sources"
  ln -s "$root/real" "$root/link"
  local canon; canon="$(cd "$root/real" && pwd -P)"
  LIVE_CWDS="$canon/Sources"
  if is_live_cwd "$root/link"; then assert_eq "symlinked worktree seen as live" y y; else assert_eq "symlinked worktree seen as live" y n; fi
  LIVE_CWDS=""
  rm -rf "$root"
}

test_live_cwds_parses_and_dedups_lsof_fn_output() {
  local lsof="printf 'p1\nfcwd\nn/a/b\np2\nfcwd\nn/a/b\np3\nfcwd\nn/c/d\n'"
  local out; out="$(RECLAIM_LSOF_CMD="$lsof" live_cwds)"
  assert_contains "parsed cwd a/b" "$out" "/a/b"
  assert_contains "parsed cwd c/d" "$out" "/c/d"
  local n; n="$(printf '%s\n' "$out" | grep -c '/a/b')"
  assert_eq "duplicate cwd deduped" "1" "$n"
}

test_is_dirty_true_for_uncommitted_git_repo() {
  local d; d="$(mktmpd)"
  git init -q "$d"; : > "$d/newfile"
  if is_dirty "$d"; then assert_eq "uncommitted -> dirty" y y; else assert_eq "uncommitted -> dirty" y n; fi
  rm -rf "$d"
}

test_is_dirty_false_for_non_git_dir() {
  local d; d="$(mktmpd)"
  if is_dirty "$d"; then assert_eq "non-git -> clean" n y; else assert_eq "non-git -> clean" n n; fi
  rm -rf "$d"
}

test_is_worktree_locked_true_when_locked() {
  local wt; wt="$(mktmpd)"
  mkdir -p "$wt"
  local porcelain; porcelain="worktree $wt
locked"
  local cmd; cmd="printf '%s\n' \"$porcelain\""
  if RECLAIM_WORKTREE_LIST_CMD="$cmd" is_worktree_locked "$wt"; then
    assert_eq "worktree marked locked -> true" y y
  else
    assert_eq "worktree marked locked -> true" y n
  fi
  rm -rf "$wt"
}

test_is_worktree_locked_false_when_not_locked() {
  local wt; wt="$(mktmpd)"
  mkdir -p "$wt"
  local porcelain; porcelain="worktree $wt
detached"
  local cmd; cmd="printf '%s\n' \"$porcelain\""
  if RECLAIM_WORKTREE_LIST_CMD="$cmd" is_worktree_locked "$wt"; then
    assert_eq "worktree not marked locked -> false" n y
  else
    assert_eq "worktree not marked locked -> false" n n
  fi
  rm -rf "$wt"
}

test_is_worktree_locked_false_when_other_locked() {
  local wt; wt="$(mktmpd)"; mkdir -p "$wt"
  local other; other="$(mktmpd)"; mkdir -p "$other"
  local porcelain; porcelain="worktree $other
locked
worktree $wt
detached"
  local cmd; cmd="printf '%s\n' \"$porcelain\""
  if RECLAIM_WORKTREE_LIST_CMD="$cmd" is_worktree_locked "$wt"; then
    assert_eq "different worktree locked -> target not locked" n y
  else
    assert_eq "different worktree locked -> target not locked" n n
  fi
  rm -rf "$wt" "$other"
}

test_plan_installs_when_idle_and_no_session_agent_worktree() {
  local d; d="$(mktmpd)"; local now=2000000000
  : > "$d/package.json"; touch_age "$d/package.json" "$now" 200000   # manifest aged old
  _mk_install_dir "$d" "$now" 200000 node_modules   # > 48h
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 agent)"
  assert_eq "idle installs, no session, agent -> PLAN installs" "PLAN installs $d" "$out"
  rm -rf "$d"
}

test_plan_installs_skipped_for_tbd_worktree_even_if_idle() {
  local d; d="$(mktmpd)"; local now=2000000000
  : > "$d/package.json"; touch_age "$d/package.json" "$now" 200000   # manifest aged old
  _mk_install_dir "$d" "$now" 200000 node_modules   # > 48h stale
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 tbd)"
  assert_eq "tbd source -> no installs plan even if idle" "" "$out"
  rm -rf "$d"
}

test_plan_installs_skipped_with_live_session() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_install_dir "$d" "$now" 200000 node_modules
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 1 agent)"
  assert_eq "idle installs but live session -> no plan" "" "$out"
  rm -rf "$d"
}

test_plan_installs_skipped_when_worktree_recently_used() {
  local d; d="$(mktmpd)"; local now=2000000000
  mkdir -p "$d/src"
  : > "$d/package.json"; touch_age "$d/package.json" "$now" 200000   # manifest aged old (idle)
  _mk_install_dir "$d" "$now" 200000 node_modules   # > 48h old
  : > "$d/src/main.py"; touch_age "$d/src/main.py" "$now" 60         # but source file recent -> active
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 agent)"
  assert_eq "worktree with recent use -> no plan" "" "$out"
  rm -rf "$d"
}

test_plan_installs_skipped_when_not_regenerable() {
  local d; d="$(mktmpd)"; local now=2000000000
  mkdir -p "$d/.terraform"       # present but NO *.tf
  touch_age "$d/.terraform" "$now" 200000
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 agent)"
  assert_eq "non-regenerable .terraform -> no plan" "" "$out"
  rm -rf "$d"
}

test_plan_swift_and_installs_both_emitted() {
  local d; d="$(mktmpd)"; local now=2000000000
  _mk_worktree "$d" "$now" 200000 200000            # tier2 .build
  touch_age "$d/Package.swift" "$now" 200000        # Package.swift also aged old
  : > "$d/main.tf"; touch_age "$d/main.tf" "$now" 200000  # manifest aged old (regenerable)
  _mk_install_dir "$d" "$now" 200000 .terraform     # + idle installs
  local out; out="$(RECLAIM_NOW=$now RECLAIM_PS_CMD="$NO_PS" plan_worktree "$d" 0 agent)"
  assert_contains "swift tier2 emitted" "$out" "PLAN tier2 $d"
  assert_contains "installs emitted alongside" "$out" "PLAN installs $d"
  rm -rf "$d"
}

test_main_reaps_installs_in_agent_worktree() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-node"
  mkdir -p "$agent"
  : > "$agent/package.json"; touch_age "$agent/package.json" "$now" 200000
  : > "$agent/main.tf"; touch_age "$agent/main.tf" "$now" 200000
  _mk_install_dir "$agent" "$now" 200000 node_modules
  _mk_install_dir "$agent" "$now" 200000 .terraform
  local j="$root/wt.json"
  printf '[]' > "$j"
  RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD='printf ""' \
    bash "$HERE/reclaim-build.sh" >/dev/null 2>&1
  assert_eq "node_modules reaped" "false" "$([[ -d "$agent/node_modules" ]] && echo true || echo false)"
  assert_eq ".terraform reaped"   "false" "$([[ -d "$agent/.terraform" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_main_installs_recency_guard_keeps_fresh() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/node-wt"
  mkdir -p "$a"
  : > "$a/package.json"; touch_age "$a/package.json" "$now" 200000   # manifest aged old (regenerable + idle)
  mkdir -p "$a/node_modules"; : > "$a/node_modules/content"
  touch_age "$a/node_modules" "$now" 0     # dir touched "now" -> inside grace
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$a","status":"active","liveClaudeSessionCount":0}]
JSON
  # T2=0 forces a plan despite manifest freshness; the in-main RECLAIM_ACTIVE_GRACE guard
  # is what must save the just-touched install dir.
  RECLAIM_NOW=$now RECLAIM_T2_SECONDS=0 RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD='printf ""' \
    bash "$HERE/reclaim-build.sh" >/dev/null 2>&1
  assert_eq "recently-touched installs NOT reaped" "true" "$([[ -d "$a/node_modules" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_main_skips_live_cwd_worktree() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/wt"
  _mk_worktree "$a" "$now" 200000 200000            # tier2-eligible .build
  mkdir -p "$a/Sources"                              # Create so canon_path can resolve it
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$a","status":"active","liveClaudeSessionCount":0}]
JSON
  local lsof; lsof="printf 'p1\nfcwd\nn%s\n' \"$a/Sources\""
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD="$lsof" \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "live-cwd worktree skipped" "$out" "SKIP live-cwd $a"
  assert_eq "live-cwd .build survives" "true" "$([[ -d "$a/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_main_skips_dirty_worktree() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/wt"
  git init -q "$a"
  _mk_worktree "$a" "$now" 200000 200000            # tier2-eligible, but untracked -> dirty
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$a","status":"active","liveClaudeSessionCount":0}]
JSON
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD='printf ""' \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "dirty worktree skipped" "$out" "SKIP dirty $a"
  assert_eq "dirty .build survives" "true" "$([[ -d "$a/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_agent_worktree_installs_reaped() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-node"
  mkdir -p "$agent"
  : > "$agent/package.json"; touch_age "$agent/package.json" "$now" 200000
  _mk_install_dir "$agent" "$now" 200000 node_modules   # non-Swift agent worktree
  local j="$root/wt.json"; printf '[]' > "$j"
  RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD='printf ""' \
    bash "$HERE/reclaim-build.sh" >/dev/null 2>&1
  assert_eq "agent worktree node_modules reaped" "false" "$([[ -d "$agent/node_modules" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_agent_worktree_dirty_skipped() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-dirty"
  mkdir -p "$agent"
  git init -q "$agent"
  : > "$agent/package.json"; touch_age "$agent/package.json" "$now" 200000
  _mk_install_dir "$agent" "$now" 200000 node_modules
  local j="$root/wt.json"; printf '[]' > "$j"
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD='printf ""' \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "dirty agent worktree skipped" "$out" "SKIP dirty $agent"
  assert_eq "dirty agent installs survive" "true" "$([[ -d "$agent/node_modules" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_agent_worktree_live_cwd_skipped() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-live"
  mkdir -p "$agent"
  : > "$agent/package.json"; touch_age "$agent/package.json" "$now" 200000
  _mk_install_dir "$agent" "$now" 200000 node_modules
  local j="$root/wt.json"; printf '[]' > "$j"
  local lsof; lsof="printf 'p1\nfcwd\nn%s\n' \"$agent\""
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD="$lsof" \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "live agent worktree skipped" "$out" "SKIP live-cwd $agent"
  assert_eq "live agent installs survive" "true" "$([[ -d "$agent/node_modules" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_main_skips_opted_out_worktree() {
  local root; root="$(mktmpd)"; local now=2000000000
  local a="$root/wt-a" b="$root/wt-b"
  _mk_worktree "$a" "$now" 200000 200000   # both tier2-eligible
  _mk_worktree "$b" "$now" 200000 200000
  : > "$a/.tbd-reclaim-optout"   # opt out A
  local j="$root/wt.json"
  cat > "$j" <<JSON
[
  {"path":"$a","status":"active","liveClaudeSessionCount":0},
  {"path":"$b","status":"active","liveClaudeSessionCount":0}
]
JSON
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "opted-out worktree skipped" "$out" "SKIP opted-out $a"
  assert_contains "sibling still planned" "$out" "PLAN tier2 $b"
  assert_eq "opted-out .build survives" "true" "$([[ -d "$a/.build" ]] && echo true || echo false)"
  assert_eq "sibling .build reaped" "false" "$([[ -d "$b/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_reclaim_opted_out_via_repo_root_marker() {
  local root; root="$(mktmpd)"; local now=2000000000
  local agent="$root/.claude/worktrees/agent-opt"
  mkdir -p "$agent"
  _mk_worktree "$agent" "$now" 200000 200000
  git init -q "$root"
  : > "$root/.tbd-reclaim-optout"   # opt out the whole repo
  local j="$root/wt.json"; printf '[]' > "$j"
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_REPO_ROOTS="$root" RECLAIM_PS_CMD="$NO_PS" \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "repo-rooted marker skips agent worktree" "$out" "SKIP opted-out $agent"
  assert_eq "opted-out agent .build survives" "true" "$([[ -d "$agent/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_restart_sh_launches_scratchpad_sweep() {
  local restart="$HERE/restart.sh"
  local body; body="$(cat "$restart")"
  # shellcheck disable=SC2016
  assert_contains "restart.sh backgrounds sweep-scratchpads.sh with nohup" "$body" 'nohup "$SWEEP_SCRIPT"'
  # shellcheck disable=SC2016
  assert_contains "restart.sh guards sweep on executability" "$body" '[ -x "$SWEEP_SCRIPT" ]'
  assert_contains "restart.sh honors TBD_SKIP_RECLAIM for sweep" "$body" 'TBD_SKIP_RECLAIM'
  local launch_line
  # shellcheck disable=SC2016
  launch_line="$(grep -F 'nohup "$SWEEP_SCRIPT"' "$restart")"
  assert_contains "sweep launch merges stderr" "$launch_line" '2>&1'
  assert_contains "sweep launch redirects stdin from /dev/null" "$launch_line" '< /dev/null'
  assert_contains "sweep launch is backgrounded" "$launch_line" '/dev/null &'
}

test_main_skips_locked_worktree() {
  local root; root="$(mktmpd)"; local now=2000000000
  local wt="$root/wt"
  _mk_worktree "$wt" "$now" 200000 200000            # tier2-eligible
  mkdir -p "$wt/Sources"                              # Create so canon_path can resolve
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$wt","status":"active","liveClaudeSessionCount":0}]
JSON
  local porcelain; porcelain="worktree $wt
locked"
  local cmd; cmd="printf '%s\n' \"$porcelain\""
  local out
  out="$(RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" RECLAIM_WORKTREE_LIST_CMD="$cmd" \
    bash "$HERE/reclaim-build.sh" 2>&1)"
  assert_contains "locked worktree skipped" "$out" "SKIP locked $wt"
  assert_eq "locked .build survives" "true" "$([[ -d "$wt/.build" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_main_tbd_source_worktree_installs_not_reaped() {
  local root; root="$(mktmpd)"; local now=2000000000
  local wt="$root/wt"
  mkdir -p "$wt"
  : > "$wt/package.json"; touch_age "$wt/package.json" "$now" 200000
  _mk_install_dir "$wt" "$now" 200000 node_modules   # > 48h stale
  local j="$root/wt.json"
  cat > "$j" <<JSON
[{"path":"$wt","status":"active","liveClaudeSessionCount":0}]
JSON
  RECLAIM_NOW=$now RECLAIM_WT_JSON="$j" RECLAIM_PS_CMD="$NO_PS" RECLAIM_LSOF_CMD='printf ""' \
    bash "$HERE/reclaim-build.sh" >/dev/null 2>&1
  assert_eq "tbd source worktree node_modules NOT reaped" "true" "$([[ -d "$wt/node_modules" ]] && echo true || echo false)"
  rm -rf "$root"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
