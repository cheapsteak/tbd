#!/usr/bin/env bash
# Tests for scripts/flake_lib.py and scripts/flake-ledger.py — run:
#   bash scripts/flake-ledger.test.sh
#
# NO BUILD, NO NETWORK, NO REAL `gh`. Every case is pure Python and bash over
# fixtures: `analyze` cases build a work directory with
# scripts/fixtures/flake/build.py, and the GitHub cases put a stub `gh` in
# FLAKE_GH_CMD that answers from a routes file and logs every call.
#
# WHERE THE FIXTURE SHAPES COME FROM. scripts/fixtures/flake/xunit/ is cut from
# the real `xunit-results` artifact of `test.yml` run 37517751216, attempt 1
# (the HolderLockTests failure PR #960 later fixed): Swift Testing's
# `<testcase ... />` and its `<failure message=... />` child, a free function
# whose classname is the bare module, a `<skipped>` case, a nested
# `TBDHomeSerialized` suite, and an XCTest file whose names carry no `()`.
# The one temp path in a failure message is replaced with /tmp/holder-lock-X.
# fixtures/flake/retry-metrics/self-test.jsonl is that run's real
# `retry-metrics` record. Timestamps in the two-attempt cases are that run's.
#
# EVERY GUARD IS MUTATION-CHECKED. `mutant_of` copies both scripts into a fresh
# directory with one sed edit applied to one of them; the case re-runs against
# the copy and the verdict has to flip.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # the sed mutation expressions must NOT expand here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$HERE/flake_lib.py"
LEDGER="$HERE/flake-ledger.py"
FIX="$HERE/fixtures/flake"
BUILD="$FIX/build.py"
WORKFLOW="$ROOT/.github/workflows/flake-fixer.yml"
BOT='tbd-flake-fixer[bot]'
REPO='cheapsteak/tbd'
HOLDER='TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()'

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export FLAKE_SEARCH_PAUSE_S=0
export FLAKE_WRITE_PAUSE_S=0
unset GITHUB_STEP_SUMMARY FLAKE_WRITE_TOKEN

FAIL=0
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; echo "$2" | sed 's/^/       /' | head -40; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output contains [$3]"; echo "$2" | sed 's/^/       /' | head -40; FAIL=1; fi; }
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] != [$3]"; FAIL=1; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/flake-ledger-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
# A fresh directory per call. Every caller is a `$(...)` subshell, so a counter
# kept in a shell variable would never advance and every case would share one.
mktmpd() { mktemp -d "$SCRATCH/d.XXXXXX"; }

# mutant_of SED_EXPR FILE -> a directory holding both scripts, FILE edited.
mutant_of() {
  local expr="$1" file="$2" dir name
  dir="$(mktmpd)"
  cp "$LIB" "$LEDGER" "$dir/"
  name="$(basename "$file")"
  sed -E "$expr" "$file" > "$dir/$name"
  if cmp -s "$file" "$dir/$name"; then
    echo "FAIL - mutation [$expr] did not change $name" >&2
    FAIL=1
  fi
  printf '%s' "$dir"
}

build() { python3 "$BUILD" "$@"; }

# py [DIR] <<'PY' ... — Python with flake_lib importable as `m` from DIR.
py() {
  local dir="${1:-$HERE}"
  python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import flake_lib as m; exec(sys.stdin.read())" "$dir"
}

# analyze WORK [DIR] -> the plan JSON on stdout; the exit code is analyze's.
analyze() { python3 "${2:-$HERE}/flake-ledger.py" analyze --work-dir "$1"; }

# The real run 37517751216: attempt 1 failed, attempt 2 passed, one
# `xunit-results` artifact per attempt. Attempt 1's holds the HolderLockTests
# failure, copied from the real artifact.
erased_run() {
  local work="$1" id="$2" branch="$3"; shift 3
  build run "$work" --id "$id" --branch "$branch" \
    --attempt "1|2026-10-06T19:16:42Z|failure" --attempt "2|2026-10-06T19:35:23Z|success" \
    --artifact "${id}1|xunit-results|2026-10-06T19:34:34Z" "$@"
  mkdir -p "$work/artifacts/${id}1"
  cp "$FIX/xunit/pass2-swift-testing.xml" "$work/artifacts/${id}1/xunit-app-swift-testing.xml"
}

# A nightly run on DATE whose FastPassWhole arm failed TEST once.
nightly_run() {
  local work="$1" id="$2" date="$3" test="$4"; shift 4
  build run "$work" --id "$id" --workflow nightly --branch main \
    --attempt "1|${date}T11:00:00Z|failure" --artifact "${id}1|nightly-xunit|${date}T13:00:00Z" "$@"
  build xunit "$work/artifacts/${id}1/FastPassWhole-1-swift-testing.xml" "$test" "nightly failure"
}

newwork() { local w; w="$(mktmpd)"; build init "$w" "$@"; printf '%s' "$w"; }

# A green run on BRANCH whose retry-metrics record TEST as passedOnRetry: one
# more place for TEST, so a case about its own issue sees it qualify.
retry_run() {
  local work="$1" id="$2" branch="$3" test="$4" file="$5"
  build run "$work" --id "$id" --branch "$branch" --attempt "1|2026-10-07T10:00:00Z|success" --artifact "${id}1|retry-metrics|2026-10-07T10:20:00Z"
  build retry "$work/artifacts/${id}1/retry-metrics.jsonl" "$test" passedOnRetry "$file"
}

# The watchlist's first planned comment body.
watch_body() { jq -r '.watchlist.writes[0].body' <<< "$1"; }

# ============================================================================
# flake_lib: identity and xunit
# ============================================================================

test_ids_normalize_both_sources_to_the_xunit_form() {
  local script out
  script='
for c, n in [("TBDSharedTests.HolderLockTests", "f()"),
             ("TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests", "f()"),
             ("TBDSharedTests", "hookPathArchive()"),
             ("TBDAppTests.ArchiveTombstoneTests", "testX")]:
    print(m.xunit_test_id(c, n))
for r in ["TBDDaemonTests.TBDHomeSerialized/AutoCloseSetupTests/f()",
          "TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()",
          "TBDSharedTests.hookPathArchive()"]:
    x = m.from_retry_metrics_id(r)
    print(x, m.filter_id(x) == r)
'
  out="$(py <<< "$script")"
  assert_eq "suite"     "TBDSharedTests.HolderLockTests/f()" "$(sed -n 1p <<< "$out")"
  assert_eq "nested"    "TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/f()" "$(sed -n 2p <<< "$out")"
  assert_eq "no suite"  "TBDSharedTests/hookPathArchive()" "$(sed -n 3p <<< "$out")"
  assert_eq "xctest"    "TBDAppTests.ArchiveTombstoneTests/testX" "$(sed -n 4p <<< "$out")"
  assert_eq "retry-metrics nested -> xunit form, round trip" "TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/f() True" "$(sed -n 5p <<< "$out")"
  assert_eq "retry-metrics top-level unchanged" "TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass() True" "$(sed -n 6p <<< "$out")"
  assert_eq "retry-metrics no suite" "TBDSharedTests/hookPathArchive() True" "$(sed -n 7p <<< "$out")"
  local mutant
  mutant="$(mutant_of 's/^        return "\.".join\(classparts\) \+ "\/" \+ name$/        return test_id/' "$LIB")"
  out="$(py "$mutant" <<< "$script")"
  assert_eq "mutation: without the nested rejoin the nested form survives" "TBDDaemonTests.TBDHomeSerialized/AutoCloseSetupTests/f() True" "$(sed -n 5p <<< "$out")"
}

test_cases_cli_reports_failed_passed_and_skipped() {
  local out
  out="$(python3 "$LIB" cases "$FIX/xunit/pass2-swift-testing.xml" "$FIX/xunit/app.xml" "$FIX/xunit/daemon-b-swift-testing.xml")"
  assert_contains "failure attributed, with its message" "$out" $'TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()\tfailed\tpass2-swift-testing.xml\tCaught error: .alreadyHeld'
  assert_contains "pass recorded" "$out" $'TBDSharedTests.HolderLockTests/acquiresAnUncontendedLock()\tpassed'
  assert_contains "skip recorded" "$out" $'TBDAppTests.TerminalStalePixelRepaintTests/scrollRepaintErasesVacatedCells()\tskipped'
  assert_contains "a free function keeps the bare module" "$out" $'TBDSharedTests/hookPathArchive()\tpassed'
  assert_contains "an XCTest case" "$out" $'TBDAppTests.ArchiveTombstoneTests/testArchivingActiveWorktreeDoesNotShowAlert\tpassed'
  assert_contains "a nested suite" "$out" $'TBDDaemonTests.TBDHomeSerialized.ActuationLogSpawnWiringTests/worktreeCreateWithUnknownRepoWritesNoRow()\tpassed'
}

test_a_truncated_xunit_file_is_an_error_not_a_clean_file() {
  local rc=0 mutant
  python3 "$LIB" cases "$FIX/xunit/truncated-swift-testing.xml" >/dev/null 2>&1 || rc=$?
  assert_eq "truncated -> exit 2" "2" "$rc"
  mutant="$(mutant_of 's/^    if not parser.root_closed:$/    if False:/' "$LIB")"
  rc=0; python3 "$mutant/flake_lib.py" cases "$FIX/xunit/truncated-swift-testing.xml" >/dev/null 2>&1 || rc=$?
  assert_eq "mutation: without the depth check it reads as clean" "0" "$rc"
}

test_xunit_files_finds_both_swiftpm_writers() {
  local d out
  d="$(mktmpd)"; : > "$d/T-1.xml"; : > "$d/T-1-swift-testing.xml"; : > "$d/T-10.xml"
  out="$(py <<< "from pathlib import Path; print([p.name for p in m.xunit_files(Path('$d'), 'T-1')])")"
  assert_eq "stem matches both files, not T-10" "['T-1-swift-testing.xml', 'T-1.xml']" "$out"
}

test_retry_records_cli_matches_the_normalized_id_and_fails_closed() {
  local d out rc=0
  d="$(mktmpd)"
  cp "$FIX/retry-metrics/self-test.jsonl" "$d/a.jsonl"
  build retry "$d/a.jsonl" 'TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/f()' passedOnRetry Tests/TBDDaemonTests/AutoCloseSetupTests.swift
  out="$(python3 "$LIB" retry-records --test 'TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/f()' "$d/a.jsonl")"
  assert_eq "the nested record matches its xunit ID" "$d/a.jsonl	passedOnRetry" "$out"
  out="$(python3 "$LIB" retry-records --test 'TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()' "$d/a.jsonl")"
  assert_eq "the real record matches its xunit ID" "$d/a.jsonl	passedOnRetry" "$out"
  echo '{not json' >> "$d/a.jsonl"
  python3 "$LIB" retry-records --test x/y "$d/a.jsonl" >/dev/null 2>&1 || rc=$?
  assert_eq "an unparsable line -> exit 2" "2" "$rc"
}

# ============================================================================
# flake_lib: state, threshold, comment format
# ============================================================================

# F(key, occurrence, episode=0, pre_fix=False) for the state cases below.
STATE_PRELUDE='
def F(key, occ, ep=0, pre=False, sig="boom", at="2026-10-01T11:00:00Z"):
    return m.Failure(key=key, run_id=1, attempt=1, occurrence=occ, at=at, source="nightly",
                     signature=sig, head_sha="a"*40, episode=ep, pre_fix=pre)
'

test_occurrence_keys() {
  local out
  out="$(py <<< '
print(m.occurrence_key("nightly", "main", "2026-10-01T11:00:00Z"))
print(m.occurrence_key("ci-xunit", "main", "2026-10-01T11:00:00Z"))
print(m.occurrence_key("ci-xunit", "tbd/foo", "2026-10-01T11:00:00Z"))
print(m.occurrence_key("ci-retry", "preflight/tbd/foo", "2026-10-02T11:00:00Z"))
')"
  assert_eq "nightly -> night:<date>" "night:2026-10-01" "$(sed -n 1p <<< "$out")"
  assert_eq "main -> main:<date>" "main:2026-10-01" "$(sed -n 2p <<< "$out")"
  assert_eq "branch -> branch:<name>" "branch:tbd/foo" "$(sed -n 3p <<< "$out")"
  assert_eq "the valve's preflight ref is the same branch" "branch:tbd/foo" "$(sed -n 4p <<< "$out")"
}

test_threshold_at_one_and_two_keys() {
  local script out mutant
  script="$STATE_PRELUDE"'
print(m.qualifies(m.State("t/x()", failures=[F("1", "night:2026-10-01"), F("2", "night:2026-10-01")])))
print(m.qualifies(m.State("t/x()", failures=[F("1", "night:2026-10-01"), F("2", "branch:foo")])))
print(m.qualifies(m.State("t/x()", failures=[F("1", "branch:foo"), F("2", "branch:bar")])))
'
  out="$(py <<< "$script")"
  assert_eq "two failures, one key: no" "False" "$(sed -n 1p <<< "$out")"
  assert_eq "a night and a branch: yes" "True" "$(sed -n 2p <<< "$out")"
  assert_eq "two branches: yes" "True" "$(sed -n 3p <<< "$out")"
  mutant="$(mutant_of 's/^QUALIFY_DISTINCT_OCCURRENCES = 2$/QUALIFY_DISTINCT_OCCURRENCES = 1/' "$LIB")"
  out="$(py "$mutant" <<< "$script")"
  assert_eq "mutation: a threshold of one qualifies one bad night" "True" "$(sed -n 1p <<< "$out")"
}

test_only_the_current_episode_counts() {
  local out
  out="$(py <<< "$STATE_PRELUDE"'
s = m.State("t/x()", episode=1, failures=[F("1", "night:2026-10-01"), F("2", "branch:foo"), F("3", "branch:bar", ep=1)])
print(len(m.current_failures(s)), sorted(m.distinct_occurrences(s)), m.qualifies(s))
')"
  assert_eq "episode 0's keys do not count in episode 1; the recurrence rule qualifies it" "1 ['branch:bar'] True" "$out"
}

test_a_recurrence_qualifies_on_one_key() {
  local script out mutant
  script="$STATE_PRELUDE"'
print(m.qualifies(m.State("t/x()", episode=1, failures=[F("1", "night:2026-10-01"), F("2", "branch:foo", ep=1)])))
print(m.qualifies(m.State("t/x()", episode=1, failures=[F("1", "night:2026-10-01"), F("2", "branch:bar")])))
'
  out="$(py <<< "$script")"
  assert_eq "episode 1 with one failure qualifies" "True" "$(sed -n 1p <<< "$out")"
  assert_eq "episode 1 with no failure yet does not" "False" "$(sed -n 2p <<< "$out")"
  mutant="$(mutant_of 's/^    if state.episode > 0 and current_count\(state\) > 0:$/    if False:/' "$LIB")"
  out="$(py "$mutant" <<< "$script")"
  assert_eq "mutation: without the recurrence clause one key is not enough" "False" "$(sed -n 1p <<< "$out")"
}

test_pre_fix_failures_never_count() {
  local out
  out="$(py <<< "$STATE_PRELUDE"'
print(m.qualifies(m.State("t/x()", failures=[F("1", "night:2026-10-01"), F("2", "branch:foo", pre=True)])))
')"
  assert_eq "a pre-fix failure on a second key does not qualify" "False" "$out"
}

test_attempts_round_trip_and_reject_another_author() {
  local out
  out="$(py <<< '
a = [m.Attempt(run_id=7, started_at="2026-10-02T05:00:00Z", main_sha="b"*40, episode=0, outcome="pr-opened",
               notes="session says --> hi", pr=12, scope="test", n=59, false_pass=0.046, weak=False,
               protected_touched=[], verdict="pass"),
     m.Attempt(run_id=8, started_at="2026-10-03T05:00:00Z", main_sha="c"*40, episode=0, outcome="aborted")]
body = m.render_attempts(a, "cheapsteak/tbd")
print(m.parse_attempts(body, m.BOT_LOGIN, "Bot") == a)
print(m.parse_attempts(body, "someone", "User"))
print(m.parse_attempts(body, "tbd-flake-fixer", "User"))
print(m.parse_attempts(body, m.BOT_LOGIN, "User"))
')"
  assert_eq "round trip under the bot" "True" "$(sed -n 1p <<< "$out")"
  assert_eq "a human login: not state" "None" "$(sed -n 2p <<< "$out")"
  assert_eq "a look-alike login without [bot]: not state" "None" "$(sed -n 3p <<< "$out")"
  assert_eq "the bot login with a non-Bot type: not state" "None" "$(sed -n 4p <<< "$out")"
}

test_merge_is_idempotent() {
  local out
  out="$(py <<< "$STATE_PRELUDE"'
s = m.State("t/x()")
s1, c1 = m.merge(s, [F("1", "night:2026-10-01"), F("2", "branch:foo")])
s2, c2 = m.merge(s1, [F("1", "night:2026-10-01"), F("2", "branch:foo")])
print(c1, c2, m.render_comment(s1, "r/r") == m.render_comment(s2, "r/r"))
')"
  assert_eq "the second merge changes nothing" "True False True" "$out"
}

test_render_parse_round_trip() {
  local out
  out="$(py <<< "$STATE_PRELUDE"'
s = m.State("t/x()", episode=1, failures=[F("1", "night:2026-10-01"), F("2", "branch:foo", ep=1)],
            fixes=[{"sha": "f"*40, "at": "2026-10-01T12:00:00Z", "episode": 0, "pr": 960}],
            prs=[{"number": 960, "outcome": "merged", "merge_sha": "f"*40, "episode": 0}], links=[512])
body = m.render_comment(s, "cheapsteak/tbd")
print(body.startswith(m.SENTINEL), m.parse_comment(body, m.BOT_LOGIN, "Bot") == s)
')"
  assert_eq "renders under the sentinel and parses back equal" "True True" "$out"
}

test_a_forged_comment_is_not_state() {
  local script out mutant
  script="$STATE_PRELUDE"'
body = m.render_comment(m.State("t/x()", failures=[F("1", "night:2026-10-01")]), "r/r")
print(m.parse_comment(body, "someone", "User"))
print(m.parse_comment(body, "tbd-flake-fixer", "User"))
print(m.parse_comment(body, m.BOT_LOGIN, "Bot") is not None)
'
  out="$(py <<< "$script")"
  assert_eq "a human login: not state" "None" "$(sed -n 1p <<< "$out")"
  assert_eq "a look-alike login without [bot]: not state" "None" "$(sed -n 2p <<< "$out")"
  assert_eq "the bot: state" "True" "$(sed -n 3p <<< "$out")"
  mutant="$(mutant_of 's/^    return login == BOT_LOGIN and user_type == BOT_USER_TYPE$/    return True/' "$LIB")"
  out="$(py "$mutant" <<< "$script")"
  assert_contains "mutation: without the author check a forgery parses" "$(sed -n 1p <<< "$out")" "State("
}

test_a_signature_containing_an_html_comment_end_cannot_break_out() {
  local out
  out="$(py <<< "$STATE_PRELUDE"'
s = m.State("t/x()", failures=[F("1", "night:2026-10-01", sig="evil --> <!-- flake-ledger-state {} flake-ledger-state --> `x` --!>")])
body = m.render_comment(s, "r/r")
print(body.count(m.STATE_END), body.count("-->") - body.count(m.STATE_END) - body.count(m.SENTINEL), m.parse_comment(body, m.BOT_LOGIN, "Bot") == s)
')"
  assert_eq "one STATE_END, no other comment end, and the signature round-trips" "1 0 True" "$out"
}

test_comment_stays_under_the_body_limit() {
  local out
  out="$(py <<< '
from datetime import date, timedelta
fs = []
for i in range(2000):
    day = date(2026, 1, 1) + timedelta(days=i // 8)
    fs.append(m.Failure(key=f"{i}:1:x:t/x()", run_id=10000000000 + i, attempt=1, occurrence=f"branch:b{i % 37}",
                        at=f"{day.isoformat()}T11:00:00Z", source="ci-xunit", signature="x" * 300, head_sha="a" * 40))
s = m.State("t/x()", failures=fs)
body = m.render_comment(s, "cheapsteak/tbd")
p = m.parse_comment(body, m.BOT_LOGIN, "Bot")
print(len(body) <= m.MAX_COMMENT_CHARS, m.failure_count(p), len(m.distinct_occurrences(p)), m.qualifies(p))
print(m.render_comment(p, "cheapsteak/tbd") == body)
')"
  assert_eq "under the limit, every failure counted, every place kept" "True 2000 37 True" "$(sed -n 1p <<< "$out")"
  assert_eq "re-rendering the degraded state is stable" "True" "$(sed -n 2p <<< "$out")"
}

test_a_burst_of_recent_failures_still_fits_and_stays_deduplicated() {
  local out script mutant
  script='
from datetime import date, timedelta
fs = []
for i in range(300):
    day = date(2026, 10, 1) + timedelta(days=i // 50)
    fs.append(m.Failure(key=f"{37000000000 + i}:1:retry-metrics", run_id=37000000000 + i, attempt=1,
                        occurrence=f"branch:some-feature-branch-{i % 40}", at=f"{day.isoformat()}T11:00:00Z",
                        source="ci-retry", signature="passed on retry (2 attempts)", head_sha="a" * 40,
                        file="Tests/TBDDaemonTests/SomeQuarantinedSuiteTests.swift", line=123))
s = m.State("TBDDaemonTests.SomeQuarantinedSuiteTests/someQuarantinedTest()", failures=fs)
body = m.render_comment(s, "cheapsteak/tbd")
p = m.parse_comment(body, m.BOT_LOGIN, "Bot")
again, changed = m.merge(p, fs)
print(len(body) <= m.MAX_COMMENT_CHARS, m.failure_count(p), len(m.distinct_occurrences(p)), changed)
'
  out="$(py <<< "$script")"
  assert_eq "300 failures in six days: under the limit, all counted, none re-added" "True 300 40 False" "$out"
  mutant="$(mutant_of 's/^    while len\(body\) > limit and state.failures:$/    while False:/' "$LIB")"
  out="$(py "$mutant" <<< "$script")"
  assert_contains "mutation: without folding the burst overflows" "$out" "False 300"
}

# ============================================================================
# analyze: sources, exclusions, attempt windows
# ============================================================================

test_two_attempts_two_artifacts_assigned_by_timestamp() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 37517751216 sidebar-groups-toggle --artifact "11439214712|xunit-results|2026-10-06T19:54:56Z"
  build xunit "$w/artifacts/11439214712/xunit-app-swift-testing.xml" 'TBDSharedTests.OtherTests/attemptTwoOnly()'
  out="$(analyze "$w")"
  assert_eq "attempt 1's failure is planned" "$HOLDER" "$(jq -r '.tests[].test_id' <<< "$out")"
  assert_contains "with its real signature, on the watchlist" "$(watch_body "$out")" "Caught error: .alreadyHeld"
  mutant="$(mutant_of 's/^            chosen = attempt\["attempt"\]$/            chosen = 1/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_contains "mutation: without the window, attempt 2's artifact is read as attempt 1's" "$(jq -r '.tests[].test_id' <<< "$out")" "attemptTwoOnly"
}

test_fork_runs_are_excluded() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 1001 sidebar --repo someone/tbd
  out="$(analyze "$w")"
  assert_eq "no test for a fork's run" "0" "$(jq '.tests | length' <<< "$out")"
  mutant="$(mutant_of 's/^    if run.get\("head_repo"\) != repo:$/    if False:/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without the fork check it records the test" "1" "$(jq '.tests | length' <<< "$out")"
}

test_flakefix_branches_are_excluded() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 1002 flakefix/issue-970
  out="$(analyze "$w")"
  assert_eq "no test for the bot's own branch" "0" "$(jq '.tests | length' <<< "$out")"
  mutant="$(mutant_of 's/^FLAKEFIX_PREFIX = "flakefix\/"$/FLAKEFIX_PREFIX = "nothing-matches\/"/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without the exclusion it records the test" "1" "$(jq '.tests | length' <<< "$out")"
}

test_a_nightly_dispatched_on_a_branch_is_excluded() {
  local w out mutant
  w="$(newwork)"
  build run "$w" --id 1011 --workflow nightly --branch feature-x \
    --attempt "1|2026-10-05T11:00:00Z|failure" --artifact "10111|nightly-xunit|2026-10-05T13:00:00Z"
  build xunit "$w/artifacts/10111/FastPassWhole-1-swift-testing.xml" "$HOLDER"
  out="$(analyze "$w")"
  assert_eq "a branch nightly says nothing about flakiness" "0" "$(jq '.tests | length' <<< "$out")"
  mutant="$(mutant_of 's/^    if run.get\("workflow"\) == "nightly" and run.get\("head_branch"\) != "main":$/    if False:/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without the main-only rule it is counted" "1" "$(jq '.tests | length' <<< "$out")"
}

test_an_unparsable_bot_comment_leaves_that_issue_alone_and_the_rest_running() {
  local w out body
  w="$(newwork)"
  erased_run "$w" 1012 sidebar
  nightly_run "$w" 2012 2026-10-05 'TBDSharedTests.OtherTests/other()'
  body="$(mktmpd)/broken.md"
  printf '%s\nhand-edited\n<!-- flake-ledger-state\n{not json\nflake-ledger-state -->\n' '<!-- flake-ledger v1 -->' > "$body"
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky --comment "95|$BOT|Bot|$body"
  out="$(analyze "$w")"
  assert_eq "no write to the issue with the broken comment" "0" "$(jq '[.actions[] | select(.issue == 970)] | length' <<< "$out")"
  assert_eq "and no second issue for its test" "0" "$(jq --arg t "$HOLDER" '[.actions[] | select(.test_id == $t)] | length' <<< "$out")"
  assert_contains "it is listed" "$(jq -r '.notes.unreadable[]' <<< "$out")" "#970 comment 95"
  assert_eq "the other test is still planned" "TBDSharedTests.OtherTests/other()" "$(jq -r '[.tests[].test_id] | join(",")' <<< "$out")"
}

test_a_reopened_issue_keeps_its_closing_fix_so_a_died_run_converges() {
  local w out
  w="$(newwork)"
  erased_run "$w" 1013 rebased --sha cccc
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --state OPEN --closed-reason completed --label flaky \
    --fix "9609609@2026-10-05T12:00:00Z@960"
  build set "$w" ancestry.json '{"9609609..cccc": true}'
  out="$(analyze "$w")"
  assert_eq "already open: the recurrence is recorded, with no second reopen" "1 false" "$(jq -r '"\(.tests[0].episode) \(.actions[0].reopen)"' <<< "$out")"
}

test_the_quarantine_self_test_is_excluded() {
  local w out mutant
  w="$(newwork)"
  build run "$w" --id 1003 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "10031|retry-metrics|2026-10-06T10:20:00Z"
  mkdir -p "$w/artifacts/10031"
  cp "$FIX/retry-metrics/self-test.jsonl" "$w/artifacts/10031/retry-metrics.jsonl"
  build retry "$w/artifacts/10031/retry-metrics.jsonl" 'TBDSharedTests.OtherTests/flaky()' passedOnRetry Tests/TBDSharedTests/OtherTests.swift
  out="$(analyze "$w")"
  assert_eq "only the other test is planned" "TBDSharedTests.OtherTests/flaky()" "$(jq -r '[.tests[].test_id] | join(",")' <<< "$out")"
  mutant="$(mutant_of 's/^EXCLUDED_TEST_ID = .*$/EXCLUDED_TEST_ID = "nothing"/' "$LIB")"
  out="$(analyze "$w" "$mutant")"
  assert_contains "mutation: without the exclusion the self-test is planned" "$(jq -r '[.tests[].test_id] | join(",")' <<< "$out")" "retriesUntilPass"
}

test_passed_on_retry_counts_as_a_failure() {
  local w out
  w="$(newwork)"
  build run "$w" --id 1004 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "10041|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/10041/retry-metrics.jsonl" 'TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/f()' passedOnRetry Tests/TBDDaemonTests/AutoCloseSetupTests.swift
  out="$(analyze "$w")"
  assert_eq "a green run's passedOnRetry is a failure, under the xunit form" "TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/f() 1" "$(jq -r '.tests[0] | "\(.test_id) \(.failures)"' <<< "$out")"
  assert_contains "with source ci-retry" "$(watch_body "$out")" '"source":"ci-retry"'
}

test_a_run_that_was_not_rerun_to_green_contributes_no_xunit_failures() {
  local w out mutant
  w="$(newwork)"
  build run "$w" --id 1005 --branch b --attempt "1|2026-10-06T19:16:42Z|failure" --artifact "10051|xunit-results|2026-10-06T19:34:34Z"
  mkdir -p "$w/artifacts/10051"; cp "$FIX/xunit/pass2-swift-testing.xml" "$w/artifacts/10051/"
  out="$(analyze "$w")"
  assert_eq "a red run nobody reran says nothing about flakiness" "0" "$(jq '.tests | length' <<< "$out")"
  mutant="$(mutant_of 's/^    return any\(a\["conclusion"\] == "success" for a in ordered\[1:\]\)$/    return True/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: reading every red run's xunit plans it" "1" "$(jq '.tests | length' <<< "$out")"
}

test_nightly_failures_carry_the_target_issue() {
  local w out
  w="$(newwork)"
  nightly_run "$w" 2001 2026-10-05 "$HOLDER"
  out="$(analyze "$w")"
  assert_eq "night key" "night:2026-10-05" "$(jq -r '.tests[0].distinct[0]' <<< "$out")"
  assert_contains "the entry names the stress target's issue" "$(watch_body "$out")" '"suite_issue":962'
}

test_threshold_one_and_two_keys_end_to_end() {
  local w out
  w="$(newwork)"
  nightly_run "$w" 2002 2026-10-05 "$HOLDER"
  out="$(analyze "$w")"
  assert_eq "one night: on the watchlist, no issue, not qualified" "false true false 0" "$(jq -r '"\(.tests[0].create) \(.tests[0].watch) \(.tests[0].qualifies) \(.actions | length)"' <<< "$out")"
  erased_run "$w" 1006 sidebar
  out="$(analyze "$w")"
  assert_eq "one night and one branch: qualifies, and gets its issue" "true true" "$(jq -r '.tests[0] | "\(.qualifies) \(.create)"' <<< "$out")"
}

test_runs_and_artifacts_outside_the_seven_day_window_are_ignored() {
  local w out
  w="$(newwork --now 2026-10-14T20:00:00Z)"
  erased_run "$w" 1007 sidebar
  out="$(analyze "$w")"
  assert_eq "an 8-day-old run is not read" "0" "$(jq '.tests | length' <<< "$out")"
  w="$(newwork --now 2026-10-13T00:00:00Z)"
  erased_run "$w" 1008 sidebar
  out="$(analyze "$w")"
  assert_eq "a 6-day-old run is" "1" "$(jq '.tests | length' <<< "$out")"
}

test_both_xunit_files_of_a_pass_are_read() {
  local w out
  w="$(newwork)"
  build run "$w" --id 1009 --branch b --attempt "1|2026-10-06T19:16:42Z|failure" --attempt "2|2026-10-06T19:35:23Z|success" \
    --artifact "10091|xunit-results|2026-10-06T19:34:34Z"
  mkdir -p "$w/artifacts/10091"
  cp "$FIX/xunit/app.xml" "$w/artifacts/10091/xunit-app.xml"
  cp "$FIX/xunit/pass2-swift-testing.xml" "$w/artifacts/10091/xunit-app-swift-testing.xml"
  out="$(analyze "$w")"
  assert_eq "the failure only the Swift Testing file holds is found" "$HOLDER" "$(jq -r '.tests[0].test_id' <<< "$out")"
}

test_an_unreadable_artifact_is_listed_not_read_as_clean() {
  local w out
  w="$(newwork)"
  build run "$w" --id 1010 --branch b --attempt "1|2026-10-06T19:16:42Z|failure" --attempt "2|2026-10-06T19:35:23Z|success" \
    --artifact "10101|xunit-results|2026-10-06T19:34:34Z"
  mkdir -p "$w/artifacts/10101"; cp "$FIX/xunit/truncated-swift-testing.xml" "$w/artifacts/10101/"
  out="$(analyze "$w")"
  assert_contains "listed as unreadable" "$(jq -r '.notes.unreadable[]' <<< "$out")" "truncated-swift-testing.xml"
}

# ============================================================================
# analyze: finding the issue
# ============================================================================

test_issue_lookup_by_title() {
  local w out
  w="$(newwork)"
  erased_run "$w" 1101 sidebar
  build issue "$w" --number 970 --title "Flaky test: $HOLDER"
  out="$(analyze "$w")"
  assert_eq "the titled issue, labelled, with a new comment" "970 null true null" "$(jq -r '.actions[0] | "\(.issue) \(.create) \(.add_label) \(.comment_id)"' <<< "$out")"
}

test_issue_lookup_by_flaky_trait() {
  local w out
  w="$(newwork)"
  build run "$w" --id 1102 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "11021|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/11021/retry-metrics.jsonl" 'TBDSharedTests.OtherTests/flaky()' passedOnRetry Tests/TBDSharedTests/OtherTests.swift
  printf 'Tests/TBDSharedTests/OtherTests.swift\tflaky\t600\n' > "$w/inventory.tsv"
  build issue "$w" --number 600 --title "OtherTests.flaky hangs under load" --label bug
  out="$(analyze "$w")"
  assert_eq "adopts #600, adds the label, keeps the title" "600 null true" "$(jq -r '.actions[0] | "\(.issue) \(.create) \(.add_label)"' <<< "$out")"
}

test_issue_creation() {
  local w out
  w="$(newwork)"
  erased_run "$w" 1103 sidebar
  nightly_run "$w" 2103 2026-10-05 "$HOLDER"
  out="$(analyze "$w")"
  assert_eq "creates the exact title" "Flaky test: $HOLDER" "$(jq -r '.actions[0].create.title' <<< "$out")"
  assert_eq "and a new comment" "null" "$(jq -r '.actions[0].comment_id' <<< "$out")"
}

test_an_ambiguous_trait_match_falls_through_to_create() {
  local w out
  w="$(newwork)"
  build run "$w" --id 1104 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "11041|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/11041/retry-metrics.jsonl" 'TBDSharedTests.SuiteA/flaky()' passedOnRetry Tests/TBDSharedTests/Shared.swift
  build retry "$w/artifacts/11041/retry-metrics.jsonl" 'TBDSharedTests.SuiteB/flaky()' passedFirstTry Tests/TBDSharedTests/Shared.swift
  retry_run "$w" 1114 c 'TBDSharedTests.SuiteA/flaky()' Tests/TBDSharedTests/Shared.swift
  printf 'Tests/TBDSharedTests/Shared.swift\tflaky\t601\n' > "$w/inventory.tsv"
  build issue "$w" --number 601 --title "flaky in Shared.swift"
  out="$(analyze "$w")"
  assert_eq "a function name shared by two suites in one file: create" "Flaky test: TBDSharedTests.SuiteA/flaky()" "$(jq -r '.actions[0].create.title' <<< "$out")"
  assert_contains "and the row is listed as skipped" "$(jq -r '.notes.inventory_skipped[]' <<< "$out")" "2 recorded tests"
}

test_a_shared_flaky_issue_gets_a_separate_per_test_issue() {
  local w out
  w="$(newwork)"
  build run "$w" --id 1105 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "11051|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/11051/retry-metrics.jsonl" 'TBDSharedTests.OtherTests/flaky()' passedOnRetry Tests/TBDSharedTests/OtherTests.swift
  retry_run "$w" 1115 c 'TBDSharedTests.OtherTests/flaky()' Tests/TBDSharedTests/OtherTests.swift
  printf 'Tests/TBDSharedTests/OtherTests.swift\tflaky\t512\nTests/TBDSharedTests/OtherTests.swift\tother\t512\n' > "$w/inventory.tsv"
  build issue "$w" --number 512 --title "OtherTests are flaky"
  out="$(analyze "$w")"
  assert_eq "a new per-test issue" "Flaky test: TBDSharedTests.OtherTests/flaky()" "$(jq -r '.actions[0].create.title' <<< "$out")"
  assert_contains "whose body links the shared issue" "$(jq -r '.actions[0].create.body' <<< "$out")" "#512"
  assert_contains "and whose ledger links it too" "$(jq -r '.actions[0].comment_body' <<< "$out")" "names #512"
  assert_eq "the shared issue itself gets nothing" "0" "$(jq '[.actions[] | select(.issue == 512)] | length' <<< "$out")"
}

test_a_suite_level_flaky_issue_is_not_reused() {
  local w out
  w="$(newwork)"
  build run "$w" --id 1106 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "11061|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/11061/retry-metrics.jsonl" 'TBDDaemonLiveTests.GitManagerTimeoutTests/hangs()' passedOnRetry Tests/TBDDaemonLiveTests/GitManagerTimeoutTests.swift
  retry_run "$w" 1116 c 'TBDDaemonLiveTests.GitManagerTimeoutTests/hangs()' Tests/TBDDaemonLiveTests/GitManagerTimeoutTests.swift
  printf 'Tests/TBDDaemonLiveTests/GitManagerTimeoutTests.swift\thangs\t961\n' > "$w/inventory.tsv"
  build issue "$w" --number 961 --title "GitManagerTimeout flakes"
  out="$(analyze "$w")"
  assert_eq "a stress target's issue is suite-level: create" "true" "$(jq -r '.actions[0].create != null' <<< "$out")"
  assert_contains "linking #961" "$(jq -r '.actions[0].create.body' <<< "$out")" "#961"
}

test_an_issue_holding_another_tests_ledger_is_not_reused() {
  local w out body
  w="$(newwork)"
  build run "$w" --id 1107 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "11071|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/11071/retry-metrics.jsonl" 'TBDSharedTests.OtherTests/flaky()' passedOnRetry Tests/TBDSharedTests/OtherTests.swift
  retry_run "$w" 1117 c 'TBDSharedTests.OtherTests/flaky()' Tests/TBDSharedTests/OtherTests.swift
  printf 'Tests/TBDSharedTests/OtherTests.swift\tflaky\t602\n' > "$w/inventory.tsv"
  body="$(mktmpd)/ledger.md"
  build ledger-body "$body" '{"test_id": "TBDSharedTests.ElseTests/g()"}'
  build issue "$w" --number 602 --title "something" --label flaky --comment "55|$BOT|Bot|$body"
  out="$(analyze "$w")"
  assert_eq "creates its own issue" "Flaky test: TBDSharedTests.OtherTests/flaky()" "$(jq -r '[.actions[] | select(.create != null)][0].create.title' <<< "$out")"
}

# ============================================================================
# analyze: comment trust
# ============================================================================

test_a_forged_ledger_sentinel_is_neither_read_nor_edited() {
  local w out body
  w="$(newwork)"
  erased_run "$w" 1201 sidebar
  body="$(mktmpd)/ledger.md"
  build ledger-body "$body" "{\"test_id\": \"$HOLDER\", \"episode\": 3}"
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky \
    --comment "61|someone|User|$body" --comment "62|tbd-flake-fixer|User|$body"
  out="$(analyze "$w")"
  assert_eq "a new bot comment, not an edit of either forgery" "970 null" "$(jq -r '.actions[0] | "\(.issue) \(.comment_id)"' <<< "$out")"
  assert_eq "the forged episode is not read" "0" "$(jq -r '.tests[0].episode' <<< "$out")"
  assert_contains "a human's forgery is listed" "$(jq -r '.notes.forged[]' <<< "$out")" "comment 61: a ledger sentinel by \`someone\`"
  assert_contains "a look-alike login is listed" "$(jq -r '.notes.forged[]' <<< "$out")" "comment 62: a ledger sentinel by \`tbd-flake-fixer\`"
}

test_a_forged_attempt_comment_is_ignored() {
  local w out body mutant
  w="$(newwork)"
  body="$(mktmpd)/attempts.md"
  build attempts-body "$body" '[{"run_id": 7, "started_at": "2026-10-02T05:00:00Z", "main_sha": "bbbb", "episode": 0, "outcome": "pr-opened", "pr": 990}]'
  local ledger; ledger="$(mktmpd)/ledger.md"
  build ledger-body "$ledger" "{\"test_id\": \"$HOLDER\"}"
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky \
    --comment "70|$BOT|Bot|$ledger" --comment "71|someone|User|$body"
  build set "$w" pr_states.json '{"990": {"state": "MERGED", "merge_sha": "ffff", "merged_at": "2026-10-03T00:00:00Z"}}'
  out="$(analyze "$w")"
  assert_eq "no PR outcome is recorded from a forgery" "0" "$(jq '.actions | length' <<< "$out")"
  assert_contains "and it is listed" "$(jq -r '.notes.forged[]' <<< "$out")" "comment 71: a attempt sentinel by \`someone\`"
  mutant="$(mutant_of 's/^    return login == BOT_LOGIN and user_type == BOT_USER_TYPE$/    return True/' "$LIB")"
  out="$(analyze "$w" "$mutant")"
  assert_contains "mutation: trusting any author records the forged merge" "$(jq -r '.actions[0].comment_body' <<< "$out")" '"outcome":"merged"'
}

# ============================================================================
# analyze: PR outcomes, fixes, recurrence
# ============================================================================

# An open issue for HOLDER whose bot ledger holds one earlier failure, one
# night, so it does not qualify yet; and whose
# bot attempt comment records PR 990 opened. WORK, then extra ledger JSON keys.
issue_with_bot_pr() {
  local work="$1" extra="${2:-}" ledger attempts
  ledger="$(mktmpd)/ledger.md"; attempts="$(mktmpd)/attempts.md"
  build ledger-body "$ledger" "{\"test_id\": \"$HOLDER\", \"failures\": [{\"key\": \"1:1:x:$HOLDER\", \"run_id\": 1, \"attempt\": 1, \"occurrence\": \"night:2026-09-20\", \"at\": \"2026-09-20T11:00:00Z\", \"source\": \"nightly\"}]$extra}"
  build attempts-body "$attempts" '[{"run_id": 7, "started_at": "2026-10-01T05:00:00Z", "main_sha": "bbbb", "episode": 0, "outcome": "pr-opened", "pr": 990}]'
  build issue "$work" --number 970 --title "Flaky test: $HOLDER" --label flaky \
    --comment "80|$BOT|Bot|$ledger" --comment "81|$BOT|Bot|$attempts"
}

test_merged_and_closed_unmerged_are_recorded_from_pr_state_once() {
  local w out w2
  w="$(newwork)"; issue_with_bot_pr "$w"
  build set "$w" pr_states.json '{"990": {"state": "OPEN", "merge_sha": null, "merged_at": null}}'
  out="$(analyze "$w")"
  assert_eq "an open PR records nothing" "0" "$(jq '.actions | length' <<< "$out")"
  build set "$w" pr_states.json '{"990": {"state": "MERGED", "merge_sha": "ffff", "merged_at": "2026-10-03T00:00:00Z"}}'
  out="$(analyze "$w")"
  assert_contains "merged, with the merge commit" "$(jq -r '.actions[0].comment_body' <<< "$out")" '"merge_sha":"ffff","number":990,"outcome":"merged"'
  w2="$(newwork)"
  issue_with_bot_pr "$w2" ", \"prs\": [{\"number\": 990, \"outcome\": \"merged\", \"merge_sha\": \"ffff\", \"episode\": 0}], \"fixes\": [{\"sha\": \"ffff\", \"at\": \"2026-10-03T00:00:00Z\", \"episode\": 0, \"pr\": 990}]"
  out="$(analyze "$w2")"
  assert_eq "recorded once: a second run with the outcome on record plans nothing" "0" "$(jq '.actions | length' <<< "$out")"
  w="$(newwork)"; issue_with_bot_pr "$w"
  build set "$w" pr_states.json '{"990": {"state": "CLOSED", "merge_sha": null, "merged_at": null}}'
  out="$(analyze "$w")"
  assert_contains "closed-unmerged" "$(jq -r '.actions[0].comment_body' <<< "$out")" '"outcome":"closed-unmerged"'
}

test_a_post_merge_failure_containing_the_fix_is_a_recurrence() {
  local w out
  w="$(newwork)"; issue_with_bot_pr "$w"
  build set "$w" pr_states.json '{"990": {"state": "MERGED", "merge_sha": "ffff", "merged_at": "2026-10-03T00:00:00Z"}}'
  erased_run "$w" 1301 later-branch --sha cccc
  build set "$w" ancestry.json '{"ffff..cccc": true}'
  out="$(analyze "$w")"
  assert_eq "episode 2, qualifying on one key" "1 true" "$(jq -r '.tests[0] | "\(.episode) \(.qualifies)"' <<< "$out")"
  assert_eq "the issue is open (the bot PR's Fixes line was removed), so no reopen" "false" "$(jq -r '.actions[0].reopen' <<< "$out")"
}

test_a_post_merge_failure_without_the_fix_is_pre_fix() {
  local w out mutant
  w="$(newwork)"; issue_with_bot_pr "$w"
  build set "$w" pr_states.json '{"990": {"state": "MERGED", "merge_sha": "ffff", "merged_at": "2026-10-03T00:00:00Z"}}'
  erased_run "$w" 1302 stale-branch --sha dddd
  build set "$w" ancestry.json '{"ffff..dddd": false}'
  out="$(analyze "$w")"
  assert_eq "still episode 1, and the second place does not qualify it" "0 false" "$(jq -r '.tests[0] | "\(.episode) \(.qualifies)"' <<< "$out")"
  assert_contains "recorded as pre-fix" "$(jq -r '.actions[0].comment_body' <<< "$out")" '"pre_fix":true'
  mutant="$(mutant_of 's/^        if not contains:$/        if False:/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: a commit without the fix read as a recurrence" "1" "$(jq -r '.tests[0].episode' <<< "$out")"
}

test_a_missing_ancestry_entry_fails_closed() {
  local w rc=0
  w="$(newwork)"; issue_with_bot_pr "$w"
  build set "$w" pr_states.json '{"990": {"state": "MERGED", "merge_sha": "ffff", "merged_at": "2026-10-03T00:00:00Z"}}'
  erased_run "$w" 1303 later --sha eeee
  analyze "$w" > /dev/null 2>&1 || rc=$?
  assert_eq "exit 2, not a guess" "2" "$rc"
}

test_a_not_planned_issue_logs_failures_but_stays_closed() {
  local w out
  w="$(newwork)"
  erased_run "$w" 1304 sidebar
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --state CLOSED --closed-reason not_planned --label flaky
  out="$(analyze "$w")"
  assert_eq "the failure is logged, the issue not reopened" "970 false" "$(jq -r '.actions[0] | "\(.issue) \(.reopen)"' <<< "$out")"
}

test_an_issue_closed_without_a_linked_fix_stays_closed() {
  local w out
  w="$(newwork)"
  erased_run "$w" 1305 sidebar
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --state CLOSED --closed-reason completed --label flaky
  out="$(analyze "$w")"
  assert_eq "completed with no closer: logged, stays closed" "970 false" "$(jq -r '.actions[0] | "\(.issue) \(.reopen)"' <<< "$out")"
}

test_an_issue_closed_by_a_human_pr_reopens_on_a_failure_containing_that_merge() {
  local w out
  w="$(newwork)"
  erased_run "$w" 1306 rebased --sha cccc
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --state CLOSED --closed-reason completed --label flaky \
    --fix "9609609@2026-10-05T12:00:00Z@960"
  build set "$w" ancestry.json '{"9609609..cccc": true}'
  out="$(analyze "$w")"
  assert_eq "reopened, episode 2" "true 1" "$(jq -r '"\(.actions[0].reopen) \(.tests[0].episode)"' <<< "$out")"
  assert_contains "the reopen comment links the failing run" "$(jq -r '.actions[0].reopen_body' <<< "$out")" "actions/runs/1306/attempts/1"
  assert_contains "and the fix that did not hold" "$(jq -r '.actions[0].reopen_body' <<< "$out")" "#960"
}

test_an_issue_closed_by_a_commit_reopens_on_a_failure_containing_it_and_not_before() {
  local w out
  w="$(newwork)"
  erased_run "$w" 1307 later --sha cccc
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --state CLOSED --closed-reason completed --label flaky \
    --fix "c0ffee@2026-10-05T12:00:00Z"
  build set "$w" ancestry.json '{"c0ffee..cccc": true}'
  out="$(analyze "$w")"
  assert_eq "contains the closing commit: reopened" "true" "$(jq -r '.actions[0].reopen' <<< "$out")"
  build set "$w" ancestry.json '{"c0ffee..cccc": false}'
  out="$(analyze "$w")"
  assert_eq "does not contain it: pre-fix, stays closed" "false 0" "$(jq -r '"\(.actions[0].reopen) \(.tests[0].episode)"' <<< "$out")"
  w="$(newwork)"
  erased_run "$w" 1308 earlier --sha cccc
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --state CLOSED --closed-reason completed --label flaky \
    --fix "c0ffee@2026-10-07T12:00:00Z"
  out="$(analyze "$w")"
  assert_eq "a failure before the fix landed needs no ancestry and changes nothing" "false 0" "$(jq -r '"\(.actions[0].reopen) \(.tests[0].episode)"' <<< "$out")"
}

test_a_run_read_after_a_recurrence_lands_in_the_episode_it_happened_in() {
  local w out ledger mutant
  w="$(newwork)"
  ledger="$(mktmpd)/ledger.md"
  # Fix ffff landed 2026-10-06T12:00; a failure containing it already began episode 2.
  build ledger-body "$ledger" "{\"test_id\": \"$HOLDER\", \"episode\": 1,
    \"fixes\": [{\"sha\": \"ffff\", \"at\": \"2026-10-06T12:00:00Z\", \"episode\": 0, \"pr\": 960}],
    \"failures\": [{\"key\": \"9:1:x\", \"run_id\": 9, \"attempt\": 1, \"occurrence\": \"branch:after\", \"at\": \"2026-10-07T11:00:00Z\", \"source\": \"ci-xunit\", \"episode\": 1}]}"
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky --comment "96|$BOT|Bot|$ledger"
  # Run 1501 started 2026-10-06T19:16, after the fix, on a commit without it.
  erased_run "$w" 1501 stale --sha dddd
  build set "$w" ancestry.json '{"ffff..dddd": false}'
  out="$(analyze "$w")"
  assert_eq "pre-fix, in the fix's episode, and episode 2 still holds one failure" "0 true 1" \
    "$(jq -r '.actions[0].comment_body' <<< "$out" | sed -n '/flake-ledger-state$/,$p' | sed -n 2p | jq -r '[.failures[] | select(.run_id == 1501)][0] | "\(.episode // 0) \(.pre_fix)"') $(jq -r '.actions[0].comment_body' <<< "$out" | sed -n '/flake-ledger-state$/,$p' | sed -n 2p | jq '[.failures[] | select(.episode == 1 and (.pre_fix | not))] | length')"
  # The mutant restores the old rule: only the current episode's fixes, and a
  # failure with none before it joins the current episode.
  mutant="$(mutant_of 's/^        prior = \[fix for fix in state.fixes if parse_time\(fix\["at"\]\) < moment\]$/        prior = [fix for fix in state.fixes if fix["episode"] == state.episode and parse_time(fix["at"]) < moment]/; s/^            placed.append\(replace\(failure, episode=0\)\)$/            placed.append(replace(failure, episode=state.episode))/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: considering only the current episode's fixes counts the late run in episode 2" "2" \
    "$(jq -r '.actions[0].comment_body' <<< "$out" | sed -n '/flake-ledger-state$/,$p' | sed -n 2p | jq '[.failures[] | select(.episode == 1 and (.pre_fix | not))] | length')"
}

test_a_later_fix_that_did_not_hold_opens_its_own_episode() {
  local w out
  w="$(newwork)"; issue_with_bot_pr "$w"
  # Bot PR 990 merged first (f1); a human's closing commit f2 landed later.
  build set "$w" pr_states.json '{"990": {"state": "MERGED", "merge_sha": "f1", "merged_at": "2026-10-03T00:00:00Z"}}'
  build run "$w" --id 1601 --branch x --sha aaaa --attempt "1|2026-10-04T10:00:00Z|failure" --attempt "2|2026-10-04T11:00:00Z|success" \
    --artifact "16011|xunit-results|2026-10-04T10:30:00Z"
  mkdir -p "$w/artifacts/16011"; cp "$FIX/xunit/pass2-swift-testing.xml" "$w/artifacts/16011/"
  erased_run "$w" 1602 y --sha bbbb
  jq '.[0].closed_reason = "completed" | .[0].closing_fix = {sha: "f2", at: "2026-10-05T00:00:00Z", pr: null}' "$w/issues.json" > "$w/i.json" && mv "$w/i.json" "$w/issues.json"
  build set "$w" ancestry.json '{"f1..aaaa": true, "f2..bbbb": true}'
  out="$(analyze "$w")"
  assert_eq "two fixes that did not hold, two new episodes" "2" "$(jq -r '.tests[0].episode' <<< "$out")"
  local mutant
  mutant="$(mutant_of 's/^            fixes = \[dict\(f, episode=new_episode\).*$/            fixes = state.fixes/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without moving the later fix forward, its failure is folded into episode 2" "1" "$(jq -r '.tests[0].episode' <<< "$out")"
}

test_analyze_refuses_a_work_dir_fetch_did_not_finish() {
  local w rc=0
  w="$(newwork)"; rm "$w/issues.json"
  analyze "$w" > /dev/null 2>&1 || rc=$?
  assert_eq "a missing issues.json is exit 2, not 'no issues'" "2" "$rc"
}

test_a_trait_issue_with_an_unparsable_bot_comment_is_not_split() {
  local w out body
  w="$(newwork)"
  build run "$w" --id 1502 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "15021|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/15021/retry-metrics.jsonl" 'TBDSharedTests.OtherTests/flaky()' passedOnRetry Tests/TBDSharedTests/OtherTests.swift
  printf 'Tests/TBDSharedTests/OtherTests.swift\tflaky\t600\n' > "$w/inventory.tsv"
  body="$(mktmpd)/broken.md"
  printf '%s\n<!-- flake-ledger-state\n{oops\nflake-ledger-state -->\n' '<!-- flake-ledger v1 -->' > "$body"
  build issue "$w" --number 600 --title "OtherTests.flaky hangs" --label flaky --comment "97|$BOT|Bot|$body"
  out="$(analyze "$w")"
  assert_eq "no new issue that would split its history" "0" "$(jq '.actions | length' <<< "$out")"
  assert_contains "listed" "$(jq -r '.notes.unreadable[]' <<< "$out")" "#600"
}

test_processing_the_same_runs_twice_changes_nothing() {
  local w out w2
  w="$(newwork)"
  erased_run "$w" 1401 sidebar
  nightly_run "$w" 2401 2026-10-05 "$HOLDER"
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky
  out="$(analyze "$w")"
  jq -r '.actions[0].comment_body' <<< "$out" > "$w/s3-body.md"
  w2="$(newwork)"
  erased_run "$w2" 1401 sidebar
  nightly_run "$w2" 2401 2026-10-05 "$HOLDER"
  build issue "$w2" --number 970 --title "Flaky test: $HOLDER" --label flaky --comment "90|$BOT|Bot|$w/s3-body.md"
  out="$(analyze "$w2")"
  assert_eq "the second pass plans no write" "0" "$(jq '.actions | length' <<< "$out")"
  assert_eq "and still reports the test" "2 true" "$(jq -r '.tests[0] | "\(.failures) \(.qualifies)"' <<< "$out")"
}

# ============================================================================
# GitHub I/O through a stub gh
# ============================================================================

# stub_gh DIR: writes DIR/gh, which answers from DIR/routes.json (a list of
# {"match": regex over the space-joined args, "out"|"file", "exit"}) and logs
# every call to DIR/log as `<GH_TOKEN> <args>`, then `  STDIN <body>` lines.
stub_gh() {
  local dir="$1"
  cat > "$dir/gh" <<'PY'
#!/usr/bin/env python3
import json, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
args = " ".join(sys.argv[1:])
data = sys.stdin.read() if "--input" in sys.argv else ""
with open(os.path.join(here, "log"), "a") as log:
    log.write(f"{os.environ.get('GH_TOKEN', '')} {args}\n")
    for line in data.splitlines():
        log.write(f"  STDIN {line}\n")
for route in json.load(open(os.path.join(here, "routes.json"))):
    if re.search(route["match"], args):
        if "file" in route:
            sys.stdout.buffer.write(open(route["file"], "rb").read())
        else:
            sys.stdout.write(route.get("out", ""))
        sys.stderr.write(route.get("err", ""))
        sys.exit(route.get("exit", 0))
sys.stderr.write(f"stub gh: no route for {args}\n")
sys.exit(99)
PY
  chmod +x "$dir/gh"
  : > "$dir/log"
}

# A fixture repository root with the two scripts fetch runs, and the one
# quarantine every tree has: the self-test's.
stub_root() {
  local root; root="$(mktmpd)"
  mkdir -p "$root/scripts" "$root/Tests/TBDDaemonTests"
  cp "$ROOT/scripts/nightly-quarantine-audit.sh" "$ROOT/scripts/nightly-flake-stress.sh" "$root/scripts/"
  cp "$ROOT/Tests/TBDDaemonTests/FlakyQuarantineSelfTests.swift" "$root/Tests/TBDDaemonTests/"
  printf '%s' "$root"
}

# A world with one rerun-erased test.yml run whose attempt 1 failed HOLDER, no
# nightly runs, no flaky issues, and no label yet. Routes may be prepended.
stub_world() {
  local dir="$1" zipdir; shift
  zipdir="$(mktmpd)"
  cp "$FIX/xunit/pass2-swift-testing.xml" "$zipdir/xunit-app-swift-testing.xml"
  (cd "$zipdir" && python3 -c "import zipfile; z = zipfile.ZipFile('$dir/x.zip', 'w'); z.write('xunit-app-swift-testing.xml'); z.close()")
  local run='{"id": 37517751216, "run_attempt": 2, "conclusion": "success", "event": "pull_request", "head_branch": "sidebar-groups-toggle", "head_sha": "538ba7eb", "head_repository": {"full_name": "cheapsteak/tbd"}, "created_at": "2026-10-06T19:16:42Z", "run_started_at": "2026-10-06T19:35:23Z"}'
  local extra="${1:-[]}"
  jq -n --argjson extra "$extra" --arg run "$run" --arg zip "$dir/x.zip" '$extra + [
    {match: "actions/workflows/test.yml/runs", out: ($run + "\n")},
    {match: "actions/workflows/nightly.yml/runs", out: ""},
    {match: "actions/runs/37517751216/attempts/1$", out: "{\"run_started_at\": \"2026-10-06T19:16:42Z\", \"conclusion\": \"failure\"}"},
    {match: "actions/runs/37517751216/attempts/2$", out: "{\"run_started_at\": \"2026-10-06T19:35:23Z\", \"conclusion\": \"success\"}"},
    {match: "actions/runs/37517751216/artifacts", out: "{\"id\": 11438169230, \"name\": \"xunit-results\", \"created_at\": \"2026-10-06T19:34:34Z\", \"expired\": false}\n{\"id\": 11439214712, \"name\": \"xunit-results\", \"created_at\": \"2026-10-06T19:54:56Z\", \"expired\": false}\n"},
    {match: "actions/artifacts/11438169230/zip", file: $zip},
    {match: "issues\\?labels=flaky", out: ""},
    {match: "issues\\?labels=flake-watchlist", out: ""},
    {match: "repos/cheapsteak/tbd/issues/499$", out: "{\"number\": 499, \"title\": \"Quarantine self-test\", \"state\": \"open\", \"labels\": []}"},
    {match: "issues/[0-9]+/comments\\?per_page", out: ""},
    {match: "search/issues", out: ""},
    {match: "labels\\?per_page", out: ""},
    {match: "graphql", out: "{\"data\": {\"repository\": {\"issue\": {\"timelineItems\": {\"nodes\": []}}}}}"},
    {match: "-X POST repos/cheapsteak/tbd/issues --input", out: "{\"number\": 1000}"},
    {match: "-X (POST|PATCH)", out: "{}"}
  ]' > "$dir/routes.json"
  stub_gh "$dir"
}

ledger_run() { # DIR [extra args...] — `run` against the stub; prints stdout+stderr
  local dir="$1" script="${LEDGER_UNDER_TEST:-$LEDGER}"; shift
  FLAKE_GH_CMD="$dir/gh" GH_TOKEN=read-token python3 "$script" run --repo "$REPO" \
    --work-dir "$dir/work" --root "$(stub_root)" --now 2026-10-08T00:00:00Z "$@" 2>&1
}

writes_in() { grep -E -- '-X (POST|PATCH|DELETE)|issue (create|edit)|label create' "$1" || true; }

test_report_only_makes_no_write_calls() {
  local d out mutant
  d="$(mktmpd)"; stub_world "$d"
  out="$(ledger_run "$d")"
  assert_contains "the report names the test" "$out" "$HOLDER"
  assert_contains "and says it is report-only" "$out" "report-only"
  assert_eq "no write call at all" "" "$(writes_in "$d/log")"
  d="$(mktmpd)"; stub_world "$d"
  mutant="$(mutant_of 's/^    if args.write:$/    if True:/' "$LEDGER")"
  out="$(FLAKE_WRITE_TOKEN=app-token LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d")"
  assert_contains "mutation: applying unconditionally writes" "$(writes_in "$d/log")" "-X POST"
}

test_write_mode_puts_a_first_failure_on_a_new_watchlist_with_the_app_token() {
  local d out writes
  d="$(mktmpd)"; stub_world "$d"
  out="$(FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write)"
  writes="$(writes_in "$d/log")"
  assert_eq "label, watchlist issue, comment, in that order" \
    "app-token api -X POST repos/cheapsteak/tbd/labels --input -
app-token api -X POST repos/cheapsteak/tbd/issues --input -
app-token api -X POST repos/cheapsteak/tbd/issues/1000/comments --input -" "$writes"
  assert_contains "the label is the watchlist's" "$(cat "$d/log")" '"name": "flake-watchlist"'
  assert_contains "the issue is the watchlist, under its own label" "$(cat "$d/log")" '"title": "Flake watchlist"'
  assert_contains "and carries only that label" "$(cat "$d/log")" '"labels": ["flake-watchlist"]'
  assert_lacks "no per-test issue for one failure" "$(cat "$d/log")" "\"title\": \"Flaky test: $HOLDER\""
  assert_contains "the comment opens with the watchlist sentinel" "$(cat "$d/log")" '"body": "<!-- flake-watchlist v1 -->'
  assert_lacks "no read used the App token" "$(grep -v -- '-X ' "$d/log" | grep -v STDIN)" "app-token"
}

test_write_mode_without_the_app_token_refuses() {
  local d rc=0
  d="$(mktmpd)"; stub_world "$d"
  FLAKE_GH_CMD="$d/gh" python3 "$LEDGER" run --repo "$REPO" --work-dir "$d/work" --root "$(stub_root)" --write > /dev/null 2>&1 || rc=$?
  assert_eq "exit 2" "2" "$rc"
  assert_eq "before any call" "" "$(cat "$d/log")"
}

test_an_api_error_leaves_the_ledger_unwritten() {
  local d out rc=0 mutant
  d="$(mktmpd)"; stub_world "$d" '[{"match": "actions/workflows/test.yml/runs", "exit": 1}]'
  out="$(FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write)" || rc=$?
  assert_eq "exit 2" "2" "$rc"
  assert_eq "no write call" "" "$(writes_in "$d/log")"
  d="$(mktmpd)"; stub_world "$d" '[{"match": "actions/workflows/test.yml/runs", "exit": 1}]'
  mutant="$(mutant_of 's/^    if proc.returncode != 0:$/    if False:/' "$LEDGER")"
  rc=0; out="$(FLAKE_WRITE_TOKEN=app-token LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" --write)" || rc=$?
  assert_eq "mutation: swallowing gh errors exits 0" "0" "$rc"
}

# Two issue actions after one watchlist comment edit; the first action's
# comment write fails.
APPLY_PLAN='{actions: [
    {test_id: "a/b()", issue: 970, create: null, add_label: true, reopen: false, reopen_body: null, comment_id: null, comment_body: "x", qualifies: false},
    {test_id: "c/d()", issue: 971, create: null, add_label: false, reopen: false, reopen_body: null, comment_id: 5, comment_body: "y", qualifies: false}],
  watchlist: {issue: 900, create: null, add_label: false, writes: [{index: 0, comment_id: 901, body: "w", tests: 1}]}}'

# apply_with DIR FAILING_ROUTE [LEDGER] [STDERR] -> apply's stdout+stderr; DIR/rc holds its exit code.
apply_with() {
  local d="$1" failing="$2" script="${3:-$LEDGER}" err="${4:-}" rc=0
  jq -n --arg failing "$failing" --arg err "$err" '[{match: "labels\\?per_page", out: "{\"name\": \"flaky\"}\n"}, {match: $failing, exit: 1, err: $err}, {match: "-X", out: "{}"}]' > "$d/routes.json"
  stub_gh "$d"
  jq -n "$APPLY_PLAN" > "$d/plan.json"
  FLAKE_GH_CMD="$d/gh" FLAKE_WRITE_TOKEN=app-token python3 "$script" apply --plan "$d/plan.json" --repo "$REPO" 2>&1 || rc=$?
  echo "$rc" > "$d/rc"
}

test_apply_keeps_going_past_a_failed_issue_write() {
  local d out mutant
  d="$(mktmpd)"
  out="$(apply_with "$d" "issues/970/comments")"
  assert_eq "exit 2 once every write was tried" "2" "$(cat "$d/rc")"
  assert_contains "the issue after the failed one is still written" "$(cat "$d/log")" "-X PATCH repos/cheapsteak/tbd/issues/comments/5 "
  assert_contains "the failed one is listed" "$out" "**Issue writes that failed: 1.**"
  assert_contains "by its test" "$out" '`a/b()` (#970)'
  assert_lacks "an existing label is not created again" "$(cat "$d/log")" "-X POST repos/cheapsteak/tbd/labels "
  assert_contains "but the issue gets it" "$(cat "$d/log")" "-X POST repos/cheapsteak/tbd/issues/970/labels"
  assert_eq "the watchlist is written before any issue" "issues/comments/901" \
    "$(writes_in "$d/log" | grep -v '/labels ' | head -1 | grep -oE 'issues/comments/[0-9]+')"
  d="$(mktmpd)"
  mutant="$(mutant_of 's/^            failed.append\(f"`\{action\[.test_id.\]\}` \(\{where\}\): \{error\}"\)$/            raise/' "$LEDGER")"
  apply_with "$d" "issues/970/comments" "$mutant/flake-ledger.py" > /dev/null
  assert_lacks "mutation: stopping at the first failure leaves the next issue unwritten" "$(cat "$d/log")" "comments/5 "
  d="$(mktmpd)"
  mutant="$(mutant_of 's/^    if not failed:$/    if True:/' "$LEDGER")"
  apply_with "$d" "issues/970/comments" "$mutant/flake-ledger.py" > /dev/null
  assert_eq "mutation: ignoring the failures ends the run green" "0" "$(cat "$d/rc")"
}

test_a_rate_limit_or_bad_token_stops_the_issue_writes() {
  local d out err mutant
  for err in "gh: Bad credentials (HTTP 401)" "gh: API rate limit exceeded (HTTP 429)" "gh: You have exceeded a secondary rate limit (HTTP 403)"; do
    d="$(mktmpd)"
    out="$(apply_with "$d" "issues/970/comments" "$LEDGER" "$err")"
    assert_eq "[$err]: exit 2" "2" "$(cat "$d/rc")"
    assert_lacks "[$err]: no write after it" "$(cat "$d/log")" "comments/5 "
    assert_contains "[$err]: the rest are listed as not tried" "$out" "**Issue writes not tried: 1**"
    assert_lacks "[$err]: and not as failed" "$out" "Issue writes that failed: 2"
  done
  d="$(mktmpd)"
  out="$(apply_with "$d" "issues/970/comments" "$LEDGER" "gh: Unable to create comment because issue is locked (HTTP 403)")"
  assert_contains "a 403 that is no rate limit concerns that issue alone" "$(cat "$d/log")" "comments/5 "
  assert_contains "and says every other write was tried" "$out" "Every other issue write was tried."
  d="$(mktmpd)"
  mutant="$(mutant_of 's/^STOP_STATUSES = \(401, 429\)$/STOP_STATUSES = ()/' "$LEDGER")"
  apply_with "$d" "issues/970/comments" "$mutant/flake-ledger.py" "gh: API rate limit exceeded (HTTP 429)" > /dev/null
  assert_contains "mutation: writing on through a rate limit" "$(cat "$d/log")" "comments/5 "
  d="$(mktmpd)"
  mutant="$(mutant_of 's/ or \(error.status == 403 and error.rate_limited\)$//' "$LEDGER")"
  apply_with "$d" "issues/970/comments" "$mutant/flake-ledger.py" "gh: You have exceeded a secondary rate limit (HTTP 403)" > /dev/null
  assert_contains "mutation: writing on through a secondary rate limit" "$(cat "$d/log")" "comments/5 "
}

test_a_failed_write_after_a_create_names_the_new_issue() {
  local d out rc=0
  d="$(mktmpd)"
  jq -n '[{match: "labels\\?per_page", out: "{\"name\": \"flaky\"}\n"}, {match: "-X POST repos/cheapsteak/tbd/issues --input", out: "{\"number\": 1234}"},
          {match: "issues/1234/comments", exit: 1}, {match: "-X", out: "{}"}]' > "$d/routes.json"
  stub_gh "$d"
  jq -n '{actions: [{test_id: "a/b()", issue: null, create: {title: "Flaky test: a/b()", body: "b"}, add_label: false, reopen: false, reopen_body: null, comment_id: null, comment_body: "x", qualifies: true}]}' > "$d/plan.json"
  out="$(FLAKE_GH_CMD="$d/gh" FLAKE_WRITE_TOKEN=app-token python3 "$LEDGER" apply --plan "$d/plan.json" --repo "$REPO" 2>&1)" || rc=$?
  assert_eq "exit 2" "2" "$rc"
  assert_contains "the half-written issue is named by its number" "$out" '`a/b()` (#1234)'
}

test_a_failed_watchlist_write_stops_the_run_before_any_issue() {
  local d
  d="$(mktmpd)"
  apply_with "$d" "issues/comments/901" > /dev/null
  assert_eq "exit 2" "2" "$(cat "$d/rc")"
  assert_eq "no issue write after it" "" "$(writes_in "$d/log" | grep -E 'issues/(970|comments/5)')"
}

test_fetch_maps_compare_status_to_ancestry() {
  local d out
  d="$(mktmpd)"
  jq -n '[{match: "compare/a1\\.\\.\\.h", out: "ahead\n"}, {match: "compare/a2\\.\\.\\.h", out: "identical\n"},
          {match: "compare/a3\\.\\.\\.h", out: "behind\n"}, {match: "compare/a4\\.\\.\\.h", out: "diverged\n"}]' > "$d/routes.json"
  stub_gh "$d"
  mkdir -p "$d/work"
  out="$(FLAKE_GH_CMD="$d/gh" python3 -c "
import sys, importlib.util
from pathlib import Path
s = importlib.util.spec_from_file_location('fl_ledger', sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules['fl_ledger'] = m; s.loader.exec_module(m)
m.fetch_ancestry(Path(sys.argv[2]), 'cheapsteak/tbd', ['a1..h', 'a2..h', 'a3..h', 'a4..h'])
print(open(sys.argv[2] + '/ancestry.json').read())
" "$LEDGER" "$d/work" | jq -c .)"
  assert_eq "ahead and identical contain the fix; behind and diverged do not" '{"a1..h":true,"a2..h":true,"a3..h":false,"a4..h":false}' "$out"
}

test_run_fetches_ancestry_for_a_closed_issue_and_reopens() {
  local d out
  d="$(mktmpd)"
  local issue='{"number": 970, "title": "Flaky test: '"$HOLDER"'", "state": "closed", "labels": [{"name": "flaky"}]}'
  local close='{"data": {"repository": {"issue": {"timelineItems": {"nodes": [{"createdAt": "2026-10-05T12:00:00Z", "stateReason": "COMPLETED", "closer": {"__typename": "PullRequest", "number": 960, "merged": true, "mergedAt": "2026-10-05T12:00:00Z", "mergeCommit": {"oid": "9609609"}}}]}}}}}'
  stub_world "$d" "$(jq -n --arg issue "$issue" --arg close "$close" '[
    {match: "issues\\?labels=flaky", out: ($issue + "\n")},
    {match: "issues/970/comments\\?per_page", out: ""},
    {match: "graphql", out: $close},
    {match: "compare/9609609\\.\\.\\.538ba7eb", out: "ahead\n"}]')"
  out="$(FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write)"
  assert_contains "the report says it reopens" "$out" "reopens it as a recurrence"
  assert_contains "it reopened #970" "$(writes_in "$d/log")" "-X PATCH repos/cheapsteak/tbd/issues/970 --input -"
  assert_contains "and posted the reopen comment" "$(cat "$d/log")" "Reopened by the flake ledger"
}

# ============================================================================
# the watchlist (spec §4.4)
# ============================================================================

# An old failure of TEST, outside every read window, as watchlist JSON.
OLD_NIGHT='{"key": "1:1:x", "run_id": 1, "attempt": 1, "occurrence": "night:2026-09-20", "at": "2026-09-20T11:00:00Z", "source": "nightly", "signature": "old night"}'

# watched WORK TEST [NUMBER] [COMMENT_ID]: a bot watchlist whose one bot
# comment holds TEST with OLD_NIGHT.
watched() {
  local work="$1" test="$2" number="${3:-900}" cid="${4:-901}" body
  body="$(mktmpd)/watch.md"
  build watchlist-body "$body" "[{\"test_id\": \"$test\", \"failures\": [$OLD_NIGHT]}]"
  build watchlist "$work" --number "$number" --comment "$cid|$BOT|Bot|$body"
}

test_a_test_below_the_threshold_goes_on_the_watchlist_only() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 3001 sidebar
  out="$(analyze "$w")"
  assert_eq "no per-test issue" "0" "$(jq '.actions | length' <<< "$out")"
  assert_eq "one watchlist comment, on a watchlist to create" "1 Flake watchlist" "$(jq -r '"\(.watchlist.writes | length) \(.watchlist.create.title)"' <<< "$out")"
  assert_contains "holding the test's failure" "$(watch_body "$out")" '"key":"3001:1:xunit-app-swift-testing.xml"'
  mutant="$(mutant_of 's/^    if view is None and not summary\["qualifies"\]:$/    if False:/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without the watchlist the first failure opens an issue" "Flaky test: $HOLDER" "$(jq -r '.actions[0].create.title' <<< "$out")"
}

test_a_second_place_opens_the_issue_and_keeps_the_entry_until_the_issue_holds_it() {
  local w out mutant d writes body watchbody w2
  w="$(newwork)"
  watched "$w" "$HOLDER"
  erased_run "$w" 3002 sidebar
  out="$(analyze "$w")"
  assert_eq "a new issue for the test, now qualified" "Flaky test: $HOLDER true" "$(jq -r '.actions[0] | "\(.create.title) \(.qualifies)"' <<< "$out")"
  assert_contains "its ledger holds the watchlist's old failure" "$(jq -r '.actions[0].comment_body' <<< "$out")" '"key":"1:1:x"'
  assert_contains "and the new one" "$(jq -r '.actions[0].comment_body' <<< "$out")" '"key":"3002:1:xunit-app-swift-testing.xml"'
  assert_eq "the watchlist keeps the test this run, updated" "901 1 1" "$(jq -r '"\(.watchlist.writes[0].comment_id) \(.watchlist.writes[0].tests) \(.watchlist.tests)"' <<< "$out")"
  assert_contains "with the new failure too" "$(watch_body "$out")" '"key":"3002:1:xunit-app-swift-testing.xml"'
  assert_eq "the summary says it leaves next run" "true" "$(jq -r '.tests[0].leaves_watchlist_next_run' <<< "$out")"
  mutant="$(mutant_of 's/^        state = replace\(watched, links=watched.links or links\)$/        state = fl.State(test_id=test, links=links)/' "$LEDGER")"
  assert_eq "mutation: without the watchlist's history the second place is missed" "0" "$(analyze "$w" "$mutant" | jq '.actions | length')"
  mutant="$(mutant_of 's/^    pending = watched is not None and not .*$/    pending = False/' "$LEDGER")"
  assert_eq "mutation: dropping the entry on promotion empties the watchlist before the issue exists" "0" "$(analyze "$w" "$mutant" | jq '.watchlist.tests')"
  # The next run reads the issue with that history in its ledger comment, and
  # only then takes the test off the watchlist.
  body="$(mktmpd)/ledger.md"; jq -r '.actions[0].comment_body' <<< "$out" > "$body"
  watchbody="$(mktmpd)/watch.md"; watch_body "$out" > "$watchbody"
  w2="$(newwork)"
  erased_run "$w2" 3002 sidebar
  build issue "$w2" --number 1000 --title "Flaky test: $HOLDER" --label flaky --comment "1001|$BOT|Bot|$body"
  build watchlist "$w2" --number 900 --comment "901|$BOT|Bot|$watchbody"
  out="$(analyze "$w2")"
  assert_eq "next run: the issue holds the history, so the entry goes, and the issue needs no write" "0 901 0 0" \
    "$(jq -r '"\(.watchlist.tests) \(.watchlist.writes[0].comment_id) \(.watchlist.writes[0].tests) \(.actions | length)"' <<< "$out")"
  mutant="$(mutant_of 's/^    pending = watched is not None and not .*$/    pending = watched is not None/' "$LEDGER")"
  assert_eq "mutation: never confirming keeps the test on the watchlist for good" "1" "$(analyze "$w2" "$mutant" | jq '.watchlist.tests')"
  # Write mode: the watchlist, still holding the test, before its new issue.
  local entry; entry="$(mktmpd)/watch.md"
  build watchlist-body "$entry" "[{\"test_id\": \"$HOLDER\", \"failures\": [$OLD_NIGHT]}]"
  d="$(mktmpd)"
  stub_world "$d" "$(jq -n --arg body "$(cat "$entry")" --arg bot "$BOT" '[
    {match: "issues\\?labels=flake-watchlist", out: (({number: 900, title: "Flake watchlist", state: "open", labels: [{name: "flake-watchlist"}], created_at: "2026-10-01T00:00:00Z", user: {login: $bot, type: "Bot"}} | tojson) + "\n")},
    {match: "issues/900/comments\\?per_page", out: (({id: 901, body: $body, user: {login: $bot, type: "Bot"}} | tojson) + "\n")},
    {match: "nightly.yml/runs", out: (({id: 2900, run_attempt: 1, conclusion: "failure", event: "schedule", head_branch: "main", head_sha: "ab", head_repository: {full_name: "cheapsteak/tbd"}, created_at: "2026-10-05T11:00:00Z", run_started_at: "2026-10-05T11:00:00Z"} | tojson) + "\n")},
    {match: "actions/runs/2900/artifacts", out: ""}]')"
  FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write > /dev/null
  writes="$(writes_in "$d/log")"
  assert_eq "label, the watchlist edit, then the test's issue and its ledger" \
    "app-token api -X POST repos/cheapsteak/tbd/labels --input -
app-token api -X PATCH repos/cheapsteak/tbd/issues/comments/901 --input -
app-token api -X POST repos/cheapsteak/tbd/issues --input -
app-token api -X POST repos/cheapsteak/tbd/issues/1000/comments --input -" "$writes"
  assert_contains "the issue's ledger carries the old failure" "$(cat "$d/log")" '\"key\":\"1:1:x\"'
}

test_an_issue_without_the_watchlist_history_is_seeded_and_the_entry_kept() {
  local w out body mutant
  # A run created the issue, then its ledger comment write failed: the issue
  # is found with no ledger comment.
  w="$(newwork)"
  watched "$w" "$HOLDER"
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky
  out="$(analyze "$w")"
  assert_contains "the found issue gets the watchlist's history" "$(jq -r '.actions[] | select(.issue == 970) | .comment_body' <<< "$out")" '"key":"1:1:x"'
  assert_eq "and the test stays on the watchlist until a run reads it there" "1" "$(jq '.watchlist.tests' <<< "$out")"
  # Its ledger comment exists but lacks a failure the watchlist holds.
  body="$(mktmpd)/ledger.md"
  build ledger-body "$body" "{\"test_id\": \"$HOLDER\", \"failures\": [{\"key\": \"2:1:x\", \"run_id\": 2, \"attempt\": 1, \"occurrence\": \"branch:x\", \"at\": \"2026-09-21T11:00:00Z\", \"source\": \"ci-xunit\"}]}"
  w="$(newwork)"
  watched "$w" "$HOLDER"
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky --comment "971|$BOT|Bot|$body"
  out="$(analyze "$w")"
  assert_contains "a ledger missing a watched failure gets it" "$(jq -r '.actions[] | select(.issue == 970) | .comment_body' <<< "$out")" '"key":"1:1:x"'
  assert_eq "and the entry stays until a run reads it there" "1" "$(jq '.watchlist.tests' <<< "$out")"
  mutant="$(mutant_of 's/^    return \{f.key for f in absorbed.failures\} == .*$/    return True/' "$LEDGER")"
  assert_eq "mutation: trusting any ledger drops the entry before its failure is on the issue" "0" "$(analyze "$w" "$mutant" | jq '.watchlist.tests')"
}

test_a_promoted_test_whose_issue_was_never_created_is_retried_without_a_new_failure() {
  local w out body mutant
  # The entry qualifies (two places) but no issue exists: the create failed,
  # and its failures have since left the read window. It is 40 days old.
  body="$(mktmpd)/watch.md"
  build watchlist-body "$body" "[{\"test_id\": \"$HOLDER\", \"failures\": [$OLD_NIGHT, {\"key\": \"2:1:x\", \"run_id\": 2, \"attempt\": 1, \"occurrence\": \"branch:x\", \"at\": \"2026-08-29T11:00:00Z\", \"source\": \"ci-xunit\"}]}]"
  w="$(newwork --now 2026-10-30T00:00:00Z)"
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$body"
  out="$(analyze "$w")"
  assert_eq "its issue is created again, from the entry, and the entry kept, not aged" "Flaky test: $HOLDER 1" \
    "$(jq -r '"\(.actions[0].create.title) \(.watchlist.tests)"' <<< "$out")"
  mutant="$(mutant_of 's/^    planned = set\(by_test\) \| set\(mapping\) \| bound$/    planned = set(by_test) | set(mapping)/' "$LEDGER")"
  assert_eq "mutation: planning only tests with new failures strands it" "0" "$(analyze "$w" "$mutant" | jq '.actions | length')"
  # fetch searches for its issue first, though the test did not fail this run.
  local d entry
  entry="$(mktmpd)/watch.md"
  build watchlist-body "$entry" '[{"test_id": "TBDSharedTests.Q/q()", "failures": [{"key": "1:1:x", "run_id": 1, "attempt": 1, "occurrence": "night:2026-09-20", "at": "2026-09-20T11:00:00Z", "source": "nightly"}, {"key": "2:1:x", "run_id": 2, "attempt": 1, "occurrence": "branch:x", "at": "2026-09-21T11:00:00Z", "source": "ci-xunit"}]}]'
  d="$(mktmpd)"
  stub_world "$d" "$(jq -n --arg body "$(cat "$entry")" --arg bot "$BOT" '[
    {match: "issues\\?labels=flake-watchlist", out: (({number: 900, title: "Flake watchlist", state: "open", labels: [{name: "flake-watchlist"}], created_at: "2026-10-01T00:00:00Z", user: {login: $bot, type: "Bot"}} | tojson) + "\n")},
    {match: "issues/900/comments\\?per_page", out: (({id: 901, body: $body, user: {login: $bot, type: "Bot"}} | tojson) + "\n")}]')"
  ledger_run "$d" > /dev/null
  assert_contains "fetch searches for the qualifying entry's issue" "$(grep search/issues "$d/log")" "TBDSharedTests.Q"
  d="$(mktmpd)"
  stub_world "$d" "$(jq -n --arg body "$(cat "$entry")" --arg bot "$BOT" '[
    {match: "issues\\?labels=flake-watchlist", out: (({number: 900, title: "Flake watchlist", state: "open", labels: [{name: "flake-watchlist"}], created_at: "2026-10-01T00:00:00Z", user: {login: $bot, type: "Bot"}} | tojson) + "\n")},
    {match: "issues/900/comments\\?per_page", out: (({id: 901, body: $body, user: {login: $bot, type: "Bot"}} | tojson) + "\n")}]')"
  mutant="$(mutant_of 's/^    for test in sorted\(\(set\(by_test\) \| qualified\) - set\(mapping\)\):$/    for test in sorted(set(by_test) - set(mapping)):/' "$LEDGER")"
  LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" > /dev/null
  assert_lacks "mutation: searching only tests that failed this run could create a duplicate" "$(grep search/issues "$d/log")" "TBDSharedTests.Q"
}

test_an_entry_whose_trait_issue_serves_it_alone_is_not_aged() {
  local w out body mutant
  body="$(mktmpd)/watch.md"
  build watchlist-body "$body" '[{"test_id": "TBDSharedTests.OtherTests/flaky()", "failures": [{"key": "1:1:x", "run_id": 1, "attempt": 1, "occurrence": "branch:x", "at": "2026-08-20T11:00:00Z", "source": "ci-retry", "file": "Tests/TBDSharedTests/OtherTests.swift", "line": 3}]}]'
  w="$(newwork)"
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$body"
  printf 'Tests/TBDSharedTests/OtherTests.swift\tflaky\t600\n' > "$w/inventory.tsv"
  build issue "$w" --number 600 --title "OtherTests.flaky hangs under load" --label bug
  out="$(analyze "$w")"
  assert_eq "kept, though 49 days quiet: its history is bound for #600" "1 0" "$(jq -r '"\(.watchlist.tests) \(.notes.aged | length)"' <<< "$out")"
  assert_contains "and #600 gets it" "$(jq -r '.actions[] | select(.issue == 600) | .comment_body' <<< "$out")" '"key":"1:1:x"'
  mutant="$(mutant_of 's/^        if test in mapping or fl.qualifies\(state\) or adopted:$/        if test in mapping or fl.qualifies(state):/' "$LEDGER")"
  assert_eq "mutation: aging it drops the history before #600 holds it" "0" "$(analyze "$w" "$mutant" | jq '.watchlist.tests')"
}

test_an_existing_issue_below_the_threshold_keeps_recording_there() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 3003 sidebar
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky
  out="$(analyze "$w")"
  assert_eq "recorded on #970, not qualified" "970 false" "$(jq -r '.actions[0] | "\(.issue) \(.qualifies)"' <<< "$out")"
  assert_eq "nothing on the watchlist" "0 0" "$(jq -r '"\(.watchlist.tests) \(.watchlist.writes | length)"' <<< "$out")"
  mutant="$(mutant_of 's/^    if view is None and not summary\["qualifies"\]:$/    if not summary["qualifies"]:/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: watching every unqualified test strands #970" "0 1" "$(jq -r '"\(.actions | length) \(.watchlist.tests)"' <<< "$out")"
}

test_a_forged_watchlist_comment_or_issue_is_ignored() {
  local w out body mutant
  w="$(newwork)"
  erased_run "$w" 3004 sidebar
  body="$(mktmpd)/forged.md"
  # Two places: were it read, the test would qualify and get an issue.
  build watchlist-body "$body" "[{\"test_id\": \"$HOLDER\", \"failures\": [$OLD_NIGHT, {\"key\": \"2:1:x\", \"run_id\": 2, \"attempt\": 1, \"occurrence\": \"branch:x\", \"at\": \"2026-09-21T11:00:00Z\", \"source\": \"ci-xunit\"}]}]"
  build watchlist "$w" --number 900 --comment "905|someone|User|$body" --comment "906|tbd-flake-fixer|User|$body"
  build watchlist "$w" --number 800 --login mallory --type User --created 2026-01-01T00:00:00Z --comment "801|mallory|User|$body"
  out="$(analyze "$w")"
  assert_eq "no issue: the forged history is not read" "0" "$(jq '.actions | length' <<< "$out")"
  assert_eq "the bot's watchlist #900 gets a new comment; neither forgery is edited" "900 null" "$(jq -r '"\(.watchlist.issue) \(.watchlist.writes[0].comment_id)"' <<< "$out")"
  assert_contains "a human's forged comment is listed" "$(jq -r '.notes.forged[]' <<< "$out")" "#900 comment 905: a watchlist sentinel by \`someone\`"
  assert_contains "a look-alike's too" "$(jq -r '.notes.forged[]' <<< "$out")" "#900 comment 906: a watchlist sentinel by \`tbd-flake-fixer\`"
  assert_contains "and an issue a human opened under the label" "$(jq -r '.notes.forged[]' <<< "$out")" "#800: labelled \`flake-watchlist\` but opened by \`mallory\`"
  mutant="$(mutant_of 's/^    return login == BOT_LOGIN and user_type == BOT_USER_TYPE$/    return True/' "$LIB")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: trusting any author opens an issue from forged history" "Flaky test: $HOLDER" "$(jq -r '.actions[0].create.title' <<< "$out")"
}

test_a_missing_watchlist_is_created_once() {
  local w w2 out body
  w="$(newwork)"
  erased_run "$w" 3005 sidebar
  nightly_run "$w" 3006 2026-10-05 'TBDSharedTests.OtherTests/other()'
  out="$(analyze "$w")"
  assert_eq "one watchlist issue, one comment, both tests" "Flake watchlist 1 2" "$(jq -r '"\(.watchlist.create.title) \(.watchlist.writes | length) \(.watchlist.tests)"' <<< "$out")"
  body="$w/wl-body.md"; watch_body "$out" > "$body"
  w2="$(newwork)"
  erased_run "$w2" 3005 sidebar
  nightly_run "$w2" 3006 2026-10-05 'TBDSharedTests.OtherTests/other()'
  build watchlist "$w2" --number 900 --comment "901|$BOT|Bot|$body"
  out="$(analyze "$w2")"
  assert_eq "once it exists: no second create, and no write for the same runs" "null 0 2" "$(jq -r '"\(.watchlist.create) \(.watchlist.writes | length) \(.watchlist.tests)"' <<< "$out")"
}

test_two_watchlists_use_the_oldest() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 3007 sidebar
  build watchlist "$w" --number 900 --created 2026-10-01T00:00:00Z
  build watchlist "$w" --number 905 --created 2026-09-01T00:00:00Z
  out="$(analyze "$w")"
  assert_eq "the oldest, #905, is written; no third is created" "905 null" "$(jq -r '"\(.watchlist.issue) \(.watchlist.create)"' <<< "$out")"
  assert_contains "both are listed" "$(jq -r '.notes.duplicates[]' <<< "$out")" "watchlist issues #905, #900; using the oldest, #905"
  mutant="$(mutant_of 's/^    mine.sort\(key=lambda i: \(i.get\("created_at"\) or "", int\(i\["number"\]\)\)\)$/    mine.sort(key=lambda i: int(i["number"]))/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: ordering by number writes to the newer one" "900" "$(jq -r '.watchlist.issue' <<< "$out")"
}

test_the_report_counts_issues_to_open_and_tests_on_the_watchlist() {
  local w out report mutant
  w="$(newwork)"
  watched "$w" 'TBDSharedTests.Quiet/f()'
  erased_run "$w" 3008 sidebar
  nightly_run "$w" 3009 2026-10-05 "$HOLDER"
  nightly_run "$w" 3010 2026-10-05 'TBDSharedTests.OtherTests/other()'
  out="$(analyze "$w")"
  report="$(python3 "$LEDGER" report --plan <(printf '%s' "$out"))"
  assert_contains "one per-test issue to open" "$report" "**Per-test issues to open: 1** (0 promoted from the watchlist)"
  assert_contains "two tests on the watchlist, one new" "$report" "**Tests on the watchlist: 2** (1 new, 0 leaving it), in 1 comment(s); the watchlist issue: #900."
  assert_contains "the sub-threshold test's line says where" "$report" "qualifies: no; the watchlist"
  mutant="$(mutant_of 's/^    opening = \[t for t in tests if t\["create"\]\]$/    opening = tests/' "$LEDGER")"
  assert_contains "mutation: counting every test overstates the issues" "$(python3 "$mutant/flake-ledger.py" report --plan <(printf '%s' "$out"))" "**Per-test issues to open: 2**"
}

test_a_test_left_in_two_watchlist_comments_is_kept_in_the_later_one() {
  local w out early late mutant
  w="$(newwork)"
  early="$(mktmpd)/early.md"; late="$(mktmpd)/late.md"
  build watchlist-body "$early" "[{\"test_id\": \"$HOLDER\", \"failures\": [$OLD_NIGHT]}]"
  build watchlist-body "$late" "[{\"test_id\": \"$HOLDER\", \"failures\": [$OLD_NIGHT, {\"key\": \"2:1:x\", \"run_id\": 2, \"attempt\": 1, \"occurrence\": \"night:2026-09-20\", \"at\": \"2026-09-20T12:00:00Z\", \"source\": \"nightly\"}]}]"
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$early" --comment "902|$BOT|Bot|$late"
  out="$(analyze "$w")"
  assert_eq "only the earlier comment is rewritten, now without the test" "901 0" "$(jq -r '.watchlist.writes | map("\(.comment_id) \(.tests)") | join(",")' <<< "$out")"
  assert_eq "the test is held once" "1" "$(jq -r '.watchlist.tests' <<< "$out")"
  assert_contains "and the merge is listed" "$(jq -r '.notes.duplicates[]' <<< "$out")" "in two watchlist comments; merged"
  mutant="$(mutant_of 's/ if t in fitted and home\[t\] == i\] for i, \(_, tests, _\)/ if t in fitted] for i, (_, tests, _)/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: keeping every copy leaves the test in both" "901 1" "$(jq -r '.watchlist.writes | map("\(.comment_id) \(.tests)") | join(",")' <<< "$out")"
}

test_merging_two_copies_never_counts_a_folded_failure_twice() {
  local script out mutant
  script='
import sys, importlib.util
s = importlib.util.spec_from_file_location("fl_ledger", sys.argv[1] + "/flake-ledger.py"); m = importlib.util.module_from_spec(s); sys.modules["fl_ledger"] = m; s.loader.exec_module(m)
fl = m.fl
fs = [fl.Failure(key=f"{i}:1:x", run_id=i, attempt=1, occurrence="branch:a", at=f"2026-09-{1 + i * 2:02d}T11:00:00Z", source="ci-xunit") for i in range(11)]
whole = fl.State(test_id="T/t()", failures=fs)
folded = fl._fold(whole, 10)  # keys more than 8 days older than the newest are dropped
print(fl.failure_count(m._merge_entries(folded, whole)), fl.failure_count(m._merge_entries(whole, folded)))
'
  out="$(python3 -c "$script" "$HERE")"
  assert_eq "eleven failures, whichever copy is kept" "11 11" "$out"
  mutant="$(mutant_of 's/^    cutoff = max\(\(f.last for f in keep.folded\), default=""\)$/    cutoff = ""/' "$LEDGER")"
  assert_eq "mutation: merging by key alone re-adds folded failures" "1" "$(python3 -c "$script" "$mutant" | awk '{print ($1 > 11)}')"
}

test_an_unreadable_watchlist_comment_is_skipped_and_left_for_a_human() {
  local w out broken quiet mutant rc=0
  w="$(newwork)"
  erased_run "$w" 3011 sidebar
  build issue "$w" --number 970 --title "Flaky test: TBDSharedTests.OtherTests/other()" --label flaky
  nightly_run "$w" 3012 2026-10-05 'TBDSharedTests.OtherTests/other()'
  broken="$(mktmpd)/broken.md"
  printf '%s\nhand-edited\n<!-- flake-watchlist-state\n{not json\nflake-watchlist-state -->\n' '<!-- flake-watchlist v1 -->' > "$broken"
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$broken"
  out="$(analyze "$w")"
  assert_contains "listed" "$(jq -r '.notes.unreadable[]' <<< "$out")" "#900 comment 901"
  assert_eq "the test without an issue starts a fresh entry, holding only this run's failure" "true 1" \
    "$(jq -r --arg t "$HOLDER" '.tests[] | select(.test_id == $t) | "\(.watch) \(.failures)"' <<< "$out")"
  assert_eq "written to a new comment on #900; the broken one is never edited" "900 null null 1" \
    "$(jq -r '"\(.watchlist.issue) \(.watchlist.create) \([.watchlist.writes[].comment_id | tostring] | join(",")) \(.watchlist.tests)"' <<< "$out")"
  assert_eq "a test with an issue is still recorded there" "970" "$(jq -r '.actions[].issue' <<< "$out")"
  # A readable bot comment beside the broken one takes the new entry.
  quiet="$(mktmpd)/quiet.md"
  build watchlist-body "$quiet" "[{\"test_id\": \"TBDSharedTests.Quiet/f()\", \"failures\": [$OLD_NIGHT]}]"
  w="$(newwork)"
  erased_run "$w" 3011 sidebar
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$broken" --comment "902|$BOT|Bot|$quiet"
  out="$(analyze "$w")"
  assert_eq "the readable comment, never the broken one" "902 2" "$(jq -r '"\([.watchlist.writes[].comment_id] | join(",")) \(.watchlist.tests)"' <<< "$out")"
  mutant="$(mutant_of 's/^        if states is None:$/        if False:/' "$LEDGER")"
  analyze "$w" "$mutant" > /dev/null 2>&1 || rc=$?
  assert_eq "mutation: without skipping it the whole run fails" "2" "$rc"
}

# ----------------------------------------------------------------------------
# schema versions (spec §4.4, §8): a newer state format stops the run; a
# corrupt comment does not
# ----------------------------------------------------------------------------

# bump IN OUT [SENTINEL_V] [JSON_V]: IN as a writer of another schema version
# would stamp it – the sentinel's version and the JSON block's `schema`.
bump() {
  sed -E "1s/ v1 -->\$/ v${3:-2} -->/; s/\"schema\":1([,}])/\"schema\":${4:-2}\\1/" "$1" > "$2"
  if cmp -s "$1" "$2" && [[ "${3:-2}${4:-2}" != 11 ]]; then echo "FAIL - bump changed nothing in $1"; FAIL=1; fi
}

# The schema check's one line, and a mutation that turns it off.
NO_SCHEMA_CHECK='s/^    unreadable = \[v for v in declared_versions\(body, prefix, begin, end\) if v not in READABLE_SCHEMAS\]$/    unreadable = []/'

# watch_world DIR BODY: stub_world plus a bot watchlist, #900, whose one
# comment, 901, is BODY.
watch_world() {
  stub_world "$1" "$(jq -n --arg body "$(cat "$2")" --arg bot "$BOT" '[
    {match: "issues\\?labels=flake-watchlist", out: (({number: 900, title: "Flake watchlist", state: "open", labels: [{name: "flake-watchlist"}], created_at: "2026-10-01T00:00:00Z", user: {login: $bot, type: "Bot"}} | tojson) + "\n")},
    {match: "issues/900/comments\\?per_page", out: (({id: 901, body: $body, user: {login: $bot, type: "Bot"}} | tojson) + "\n")}]')"
}

# issue_world DIR BODY: stub_world plus HOLDER's open issue, #970, whose one
# comment, 95, is BODY.
issue_world() {
  stub_world "$1" "$(jq -n --arg body "$(cat "$2")" --arg bot "$BOT" --arg t "Flaky test: $HOLDER" '[
    {match: "issues\\?labels=flaky", out: (({number: 970, title: $t, state: "open", labels: [{name: "flaky"}]} | tojson) + "\n")},
    {match: "issues/970/comments\\?per_page", out: (({id: 95, body: $body, user: {login: $bot, type: "Bot"}} | tojson) + "\n")}]')"
}

# write_run DIR [LEDGER] -> "rc=<n>" then the run's output; DIR/log has its calls.
write_run() {
  local rc=0 out
  out="$(FLAKE_WRITE_TOKEN=app-token LEDGER_UNDER_TEST="${2:-$LEDGER}" ledger_run "$1" --write)" || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
}

test_a_watchlist_comment_in_a_newer_schema_stops_the_run_unwritten() {
  local entry newer d out v mutant
  entry="$(mktmpd)/watch.md"; newer="$(mktmpd)/newer.md"
  build watchlist-body "$entry" "[{\"test_id\": \"TBDSharedTests.Quiet/f()\", \"failures\": [$OLD_NIGHT]}]"
  # Control: the same comment at this code's version is read and written.
  d="$(mktmpd)"; watch_world "$d" "$entry"
  assert_eq "at the current version the run goes on" "rc=0" "$(write_run "$d" | head -1)"
  assert_contains "and writes" "$(writes_in "$d/log")" "-X PATCH repos/cheapsteak/tbd/issues/comments/901"
  for v in "2 2" "2 1" "1 2"; do
    # shellcheck disable=SC2086 # two words on purpose: sentinel and JSON versions
    bump "$entry" "$newer" $v
    d="$(mktmpd)"; watch_world "$d" "$newer"
    out="$(write_run "$d")"
    assert_eq "sentinel/JSON at v$v: the run fails closed" "rc=2" "$(head -1 <<< "$out")"
    assert_eq "sentinel/JSON at v$v: nothing written" "" "$(writes_in "$d/log")"
    assert_contains "sentinel/JSON at v$v: names the comment, its version and the version read" "$out" \
      "#900 comment 901: the bot's watchlist comment declares schema version 2, newer than the versions this code reads (1)"
  done
  bump "$entry" "$newer"
  d="$(mktmpd)"; watch_world "$d" "$newer"
  mutant="$(mutant_of "$NO_SCHEMA_CHECK" "$LIB")"
  out="$(write_run "$d" "$mutant/flake-ledger.py")"
  assert_eq "mutation: without the check it is skipped as corrupt and the run goes on" "rc=0" "$(head -1 <<< "$out")"
  assert_contains "mutation: writing a fresh watchlist comment beside it" "$(writes_in "$d/log")" "-X POST repos/cheapsteak/tbd/issues/900/comments"
  d="$(mktmpd)"; watch_world "$d" "$newer"
  mutant="$(mutant_of 's/\(fl.WATCHLIST_SENTINEL_PREFIX,\)/(fl.WATCHLIST_SENTINEL,)/' "$LEDGER")"
  assert_eq "mutation: fetching by the v1 sentinel never sees the v2 comment" "rc=0" "$(write_run "$d" "$mutant/flake-ledger.py" | head -1)"
}

test_a_ledger_or_attempt_comment_in_a_newer_schema_stops_the_run_unwritten() {
  local body newer attempts w d out rc mutant
  body="$(mktmpd)/ledger.md"; newer="$(mktmpd)/newer.md"
  build ledger-body "$body" "{\"test_id\": \"$HOLDER\", \"failures\": [$OLD_NIGHT]}"
  bump "$body" "$newer"
  w="$(newwork)"
  erased_run "$w" 1012 sidebar
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky --comment "95|$BOT|Bot|$newer"
  rc=0; out="$(analyze "$w" 2>&1)" || rc=$?
  assert_eq "a newer ledger comment: analyze fails closed" "2" "$rc"
  assert_contains "naming it" "$out" "#970 comment 95: the bot's ledger comment declares schema version 2"
  mutant="$(mutant_of "$NO_SCHEMA_CHECK" "$LIB")"
  rc=0; analyze "$w" "$mutant" > /dev/null 2>&1 || rc=$?
  assert_eq "mutation: without the check it is read as corrupt and the run goes on" "0" "$rc"
  # The attempt comment, beside a readable ledger comment.
  attempts="$(mktmpd)/attempts.md"
  python3 - "$HERE" "$attempts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import flake_lib as fl
from pathlib import Path
a = fl.Attempt(run_id=1, started_at="2026-10-01T00:00:00Z", main_sha="b" * 40, episode=0, outcome="no-diff")
Path(sys.argv[2]).write_text(fl.render_attempts([a], "cheapsteak/tbd").replace('"schema":1', '"schema":2').replace(" v1 -->", " v2 -->", 1))
PY
  w="$(newwork)"
  erased_run "$w" 1012 sidebar
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --label flaky --comment "95|$BOT|Bot|$body" --comment "96|$BOT|Bot|$attempts"
  rc=0; out="$(analyze "$w" 2>&1)" || rc=$?
  assert_eq "a newer attempt comment: analyze fails closed" "2" "$rc"
  assert_contains "naming it" "$out" "#970 comment 96: the bot's attempt comment declares schema version 2"
  # Through `run`, which must fetch it under its v2 sentinel to see it at all.
  d="$(mktmpd)"; issue_world "$d" "$newer"
  out="$(write_run "$d")"
  assert_eq "run: fails closed" "rc=2" "$(head -1 <<< "$out")"
  assert_eq "run: nothing written" "" "$(writes_in "$d/log")"
  d="$(mktmpd)"; issue_world "$d" "$newer"
  mutant="$(mutant_of 's/\(fl.SENTINEL_PREFIX, fl.ATTEMPTS_SENTINEL_PREFIX\)/(fl.SENTINEL, fl.ATTEMPTS_SENTINEL)/' "$LEDGER")"
  out="$(write_run "$d" "$mutant/flake-ledger.py")"
  assert_eq "mutation: fetching by the v1 sentinels never sees it, and the run goes on" "rc=0" "$(head -1 <<< "$out")"
  assert_contains "mutation: writing a second ledger comment beside it" "$(writes_in "$d/log")" "-X POST repos/cheapsteak/tbd/issues/970/comments"
}

test_a_corrupt_watchlist_comment_at_a_known_version_is_still_skipped() {
  local w out rc corrupt bare mutant
  corrupt="$(mktmpd)/corrupt.md"; bare="$(mktmpd)/bare.md"
  # It parses, at schema 1, but its tests are not a list.
  printf '%s\nhand-edited\n<!-- flake-watchlist-state\n{"schema":1,"tests":"oops"}\nflake-watchlist-state -->\n' '<!-- flake-watchlist v1 -->' > "$corrupt"
  # And one whose block declares no schema at all.
  printf '%s\nhand-edited\n<!-- flake-watchlist-state\n{"tests":[]}\nflake-watchlist-state -->\n' '<!-- flake-watchlist v1 -->' > "$bare"
  w="$(newwork)"
  erased_run "$w" 3011 sidebar
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$corrupt" --comment "902|$BOT|Bot|$bare"
  rc=0; out="$(analyze "$w")" || rc=$?
  assert_eq "the run goes on" "0" "$rc"
  assert_contains "the first is listed" "$(jq -r '.notes.unreadable[]' <<< "$out")" "#900 comment 901"
  assert_contains "and the second" "$(jq -r '.notes.unreadable[]' <<< "$out")" "#900 comment 902"
  assert_eq "neither is written; the entry goes to a new comment" "0" "$(jq '[.watchlist.writes[].comment_id | select(. != null)] | length' <<< "$out")"
  mutant="$(mutant_of 's/ if v not in READABLE_SCHEMAS\]$/]/' "$LIB")"
  rc=0; analyze "$w" "$mutant" > /dev/null 2>&1 || rc=$?
  assert_eq "mutation: failing closed on every declared version stops the run" "2" "$rc"
}

test_an_additive_key_at_the_current_version_is_still_read() {
  local script out mutant
  script="$STATE_PRELUDE"'
s = m.State("t/x()", failures=[F("1", "night:2026-10-01")])
ledger = m.render_comment(s, "r/r").replace("{\"episode\"", "{\"added_later\":1,\"episode\"", 1)
watch = m.render_watchlist([s], "r/r").replace("{\"schema\"", "{\"added_later\":1,\"schema\"", 1)
a = m.Attempt(run_id=1, started_at="2026-10-01T00:00:00Z", main_sha="b"*40, episode=0, outcome="no-diff")
att = m.render_attempts([a], "r/r").replace("\"outcome\":\"no-diff\"", "\"outcome\":\"no-diff\",\"added_later\":1")
assert "added_later" in ledger and "added_later" in watch and "added_later" in att
print(m.parse_comment(ledger, m.BOT_LOGIN, "Bot") == s)
print(m.parse_watchlist(watch, m.BOT_LOGIN, "Bot") == [s])
print(m.parse_attempts(att, m.BOT_LOGIN, "Bot") == [a])
'
  out="$(py <<< "$script")"
  assert_eq "a ledger, watchlist and attempt comment each read with an unknown key" "True
True
True" "$out"
  mutant="$(mutant_of 's/ if k in known\}/}/' "$LIB")"
  assert_eq "mutation: refusing an unknown attempt key" "False" "$(py "$mutant" <<< "$script" | sed -n 3p)"
}

test_a_version_is_read_only_when_listed_and_writers_stamp_the_current_one() {
  local script out mutant
  script="$STATE_PRELUDE"'
s = m.State("t/x()", failures=[F("1", "night:2026-10-01")])
a = m.Attempt(run_id=1, started_at="2026-10-01T00:00:00Z", main_sha="b"*40, episode=0, outcome="no-diff")
kinds = [
    ("ledger", m.render_comment(s, "r/r"), m.SENTINEL_PREFIX, m.STATE_BEGIN, m.STATE_END, m.parse_comment),
    ("watchlist", m.render_watchlist([s], "r/r"), m.WATCHLIST_SENTINEL_PREFIX, m.WATCHLIST_BEGIN, m.WATCHLIST_END, m.parse_watchlist),
    ("attempt", m.render_attempts([a], "r/r"), m.ATTEMPTS_SENTINEL_PREFIX, m.ATTEMPTS_BEGIN, m.ATTEMPTS_END, m.parse_attempts),
]
for name, body, prefix, begin, end, parse in kinds:
    print(name, m.declared_versions(body, prefix, begin, end) == [m.SCHEMA, m.SCHEMA])
# An older version this code still reads, and one it no longer does.
for name, body, prefix, begin, end, parse in kinds:
    m.READABLE_SCHEMAS = frozenset({1, 2})
    old = parse(body, m.BOT_LOGIN, "Bot") is not None
    m.READABLE_SCHEMAS = frozenset({2})
    try:
        parse(body, m.BOT_LOGIN, "Bot")
        gone = "read"
    except m.UnsupportedSchema as error:
        gone = "not one of" in str(error)
    m.READABLE_SCHEMAS = frozenset({1})
    print(name, old, gone)
'
  out="$(py <<< "$script")"
  assert_eq "every writer stamps SCHEMA in its sentinel and its block" "ledger True
watchlist True
attempt True" "$(head -3 <<< "$out")"
  assert_eq "an older listed version reads; an unlisted one stops the reader" "ledger True True
watchlist True True
attempt True True" "$(tail -3 <<< "$out")"
  mutant="$(mutant_of 's/^    payload = \{"schema": SCHEMA, "attempts": \[$/    payload = {"schema": SCHEMA + 1, "attempts": [/' "$LIB")"
  assert_eq "mutation: an attempt writer stamping another version" "attempt False" "$(py "$mutant" <<< "$script" | sed -n 3p)"
  mutant="$(mutant_of 's/^WATCHLIST_SENTINEL = .*$/WATCHLIST_SENTINEL = "<!-- flake-watchlist v0 -->"/' "$LIB")"
  assert_eq "mutation: a watchlist sentinel spelling another version" "watchlist False" "$(py "$mutant" <<< "$script" 2>/dev/null | sed -n 2p)"
}

# aging_work [NOW] -> a work dir whose watchlist holds five tests: Old (last
# failed 2026-09-01), Recent (2026-09-20), Folded (counts only, latest
# 2026-09-20), HOLDER (2026-09-01, failing again on a branch this week), and
# Pending (2026-09-01, with an issue found without its ledger comment).
aging_work() {
  local w body
  w="$(newwork --now "${1:-2026-10-08T00:00:00Z}")"
  body="$(mktmpd)/watch.md"
  build watchlist-body "$body" "$(jq -n --arg holder "$HOLDER" '
    def f(at; occ): [{key: ("k" + at), run_id: 1, attempt: 1, occurrence: occ, at: at, source: "nightly"}];
    [{test_id: "TBDSharedTests.Old/f()", failures: f("2026-09-01T11:00:00Z"; "night:2026-09-01")},
     {test_id: "TBDSharedTests.Recent/f()", failures: f("2026-09-20T11:00:00Z"; "night:2026-09-20")},
     {test_id: "TBDSharedTests.Folded/f()", failures: [], folded: [{occurrence: "branch:a", episode: 0, pre_fix: false, count: 5, first: "2026-08-01T11:00:00Z", last: "2026-09-20T11:00:00Z"}]},
     {test_id: $holder, failures: f("2026-09-01T11:00:00Z"; "night:2026-09-01")},
     {test_id: "TBDSharedTests.Pending/f()", failures: f("2026-09-01T11:00:00Z"; "night:2026-09-01")}]')"
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$body"
  build issue "$w" --number 975 --title "Flaky test: TBDSharedTests.Pending/f()" --label flaky
  erased_run "$w" 3021 sidebar
  printf '%s' "$w"
}

# The watchlist's tests after analyze, in order.
watched_tests() { jq -r '[.watchlist.writes[].body | capture("flake-watchlist-state\n(?<j>.*)\nflake-watchlist-state"; "s").j | fromjson | .tests[].test_id] | join(",")' <<< "$1"; }

test_a_watchlist_entry_with_no_failure_in_thirty_days_ages_out() {
  local w out mutant
  w="$(aging_work)"
  out="$(analyze "$w")"
  assert_eq "Old goes; Recent, Folded, the fresh HOLDER, and Pending stay" \
    "TBDSharedTests.Folded/f(),$HOLDER,TBDSharedTests.Pending/f(),TBDSharedTests.Recent/f()" "$(watched_tests "$out")"
  assert_contains "the aged test is listed" "$(jq -r '.notes.aged[]' <<< "$out")" "\`TBDSharedTests.Old/f()\`: no failure since 2026-09-01T11:00:00Z"
  assert_eq "a test failing again after aging out starts fresh: one failure, on the watchlist, no issue" "true 1 null" \
    "$(jq -r --arg t "$HOLDER" '(.tests[] | select(.test_id == $t) | "\(.watch) \(.failures)") + " " + ([.actions[] | select(.test_id == $t)][0].issue | tostring)' <<< "$out")"
  assert_contains "the report has the section" "$(python3 "$LEDGER" report --plan <(printf '%s' "$out"))" "**Aged off the watchlist (no failure in 30 days):**"
  assert_lacks "exactly 30 days since the newest failure: aged" "$(watched_tests "$(analyze "$(aging_work 2026-10-20T11:00:00Z)")")" "Recent"
  assert_contains "a second under 30 days: kept" "$(watched_tests "$(analyze "$(aging_work 2026-10-20T10:59:59Z)")")" "Recent"
  out="$(analyze "$(aging_work 2026-10-25T00:00:00Z)")"
  assert_eq "a later now ages Recent and Folded too; Pending, waiting on its issue, stays" "TBDSharedTests.Pending/f()" "$(watched_tests "$out")"
  mutant="$(mutant_of 's/^WATCHLIST_AGE_OUT_DAYS = 30$/WATCHLIST_AGE_OUT_DAYS = 3000/' "$LIB")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without aging HOLDER's old night and new branch qualify it for an issue" "Flaky test: $HOLDER" "$(jq -r --arg t "$HOLDER" '.actions[] | select(.test_id == $t) | .create.title' <<< "$out")"
  mutant="$(mutant_of 's/ \+ \[f.last for f in state.folded\], default=""\)$/, default="")/' "$LIB")"
  assert_lacks "mutation: ignoring folded counts ages an entry folded down to counts" "$(watched_tests "$(analyze "$w" "$mutant")")" "Folded"
  mutant="$(mutant_of 's/^        if test not in exempt and \(not newest/        if (not newest/' "$LEDGER")"
  assert_lacks "mutation: aging a test that has an issue drops its unconfirmed history" "$(watched_tests "$(analyze "$w" "$mutant")")" "Pending"
}

test_folding_keeps_the_newest_failure_time() {
  local script mutant
  script='
fs = [m.Failure(key=f"{d}:1:x", run_id=d, attempt=1, occurrence="branch:a", at=f"2026-09-{d:02d}T11:00:00Z", source="ci-xunit") for d in (1, 9, 20, 5)]
folded = m._fold(m.State(test_id="T/t()", failures=fs), 4)
print(len(folded.failures), m.newest_failure_at(folded))
'
  assert_eq "every failure folded; the newest time survives" "0 2026-09-20T11:00:00Z" "$(py <<< "$script")"
  mutant="$(mutant_of 's/last=max\(f.last, failure.at\)\)/last=f.last)/' "$LIB")"
  assert_eq "mutation: a count that keeps its first time ages early" "0 2026-09-01T11:00:00Z" "$(py "$mutant" <<< "$script")"
}

test_a_new_test_fills_an_emptied_comment_first() {
  local w out empty full mutant
  w="$(newwork)"
  empty="$(mktmpd)/empty.md"; full="$(mktmpd)/full.md"
  build watchlist-body "$empty" '[]'
  build watchlist-body "$full" "[{\"test_id\": \"TBDSharedTests.Quiet/f()\", \"failures\": [$OLD_NIGHT]}]"
  build watchlist "$w" --number 900 --comment "901|$BOT|Bot|$empty" --comment "902|$BOT|Bot|$full"
  erased_run "$w" 3013 sidebar
  out="$(analyze "$w")"
  assert_eq "the new test goes into the emptied first comment" "901" "$(jq -r '.watchlist.writes | map(.comment_id) | join(",")' <<< "$out")"
  mutant="$(mutant_of 's/^        room = next\(.*$/        room = groups[-1]/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: appending to the last comment leaves the empty one unused" "902" "$(jq -r '.watchlist.writes | map(.comment_id) | join(",")' <<< "$out")"
}

# watch_routes ENTRY_OCCURRENCE LABELLED: stub routes for a bot watchlist #900
# holding HOLDER with one failure at ENTRY_OCCURRENCE, found by its label when
# LABELLED is true, else only by its title.
watch_routes() {
  local body; body="$(mktmpd)/watch.md"
  build watchlist-body "$body" "[{\"test_id\": \"$HOLDER\", \"failures\": [{\"key\": \"1:1:x\", \"run_id\": 1, \"attempt\": 1, \"occurrence\": \"$1\", \"at\": \"2026-09-20T11:00:00Z\", \"source\": \"ci-xunit\"}]}]"
  jq -n --arg body "$(cat "$body")" --arg bot "$BOT" --argjson labelled "$2" '
    ({number: 900, title: "Flake watchlist", state: "open", labels: (if $labelled then [{name: "flake-watchlist"}] else [] end),
      created_at: "2026-10-01T00:00:00Z", user: {login: $bot, type: "Bot"}}) as $issue | [
    {match: "issues\\?labels=flake-watchlist", out: (if $labelled then ($issue | tojson) + "\n" else "" end)},
    {match: "in:title \"Flake watchlist\"", out: (({incomplete: false, total: 1, items: [$issue]} | tojson) + "\n")},
    {match: "issues/900/comments\\?per_page", out: (({id: 901, body: $body, user: {login: $bot, type: "Bot"}} | tojson) + "\n")}]'
}

test_a_watchlist_whose_label_was_removed_is_found_by_title() {
  local d mutant
  d="$(mktmpd)"; stub_world "$d" "$(watch_routes night:2026-09-20 false)"
  FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write > /dev/null
  assert_contains "the label is put back" "$(writes_in "$d/log")" "-X POST repos/cheapsteak/tbd/issues/900/labels"
  assert_lacks "no second watchlist is created" "$(cat "$d/log")" '"title": "Flake watchlist"'
  assert_contains "and the old history seeds the test's issue" "$(cat "$d/log")" '\"key\":\"1:1:x\"'
  d="$(mktmpd)"; stub_world "$d" "$(watch_routes night:2026-09-20 false)"
  mutant="$(mutant_of 's/^    if not any\(fl.trusted_author\(\(r.get\("user"\).*$/    if False:/' "$LEDGER")"
  FLAKE_WRITE_TOKEN=app-token LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" --write > /dev/null
  assert_contains "mutation: without the title fallback a fresh watchlist abandons the history" "$(cat "$d/log")" '"title": "Flake watchlist"'
}

test_a_watched_test_is_title_searched_only_when_it_may_qualify() {
  local d mutant
  # The stub run fails HOLDER on branch sidebar-groups-toggle: the same place.
  d="$(mktmpd)"; stub_world "$d" "$(watch_routes branch:sidebar-groups-toggle true)"
  ledger_run "$d" > /dev/null
  assert_lacks "same place again: no search" "$(grep search/issues "$d/log")" "lockIsReacquirableAfterRelease"
  d="$(mktmpd)"; stub_world "$d" "$(watch_routes night:2026-09-20 true)"
  ledger_run "$d" > /dev/null
  assert_contains "a second place: searched before its issue is created" "$(grep search/issues "$d/log")" "lockIsReacquirableAfterRelease"
  d="$(mktmpd)"; stub_world "$d" "$(watch_routes branch:sidebar-groups-toggle true)"
  mutant="$(mutant_of 's/^        if test in entries and not _may_qualify\(entries\[test\], by_test.get\(test, \[\]\)\):$/        if False:/' "$LEDGER")"
  LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" > /dev/null
  assert_contains "mutation: searching every watched test every run" "$(grep search/issues "$d/log")" "lockIsReacquirableAfterRelease"
}

# big_watchlist DIR N -> plan_watchlist's result for N tests, each with 20
# long-signature failures on one branch, as JSON; DIR holds the scripts.
BIG_WATCHLIST='
import json, sys, importlib.util
sys.path.insert(0, sys.argv[1])
s = importlib.util.spec_from_file_location("fl_ledger", sys.argv[1] + "/flake-ledger.py"); m = importlib.util.module_from_spec(s); sys.modules["fl_ledger"] = m; s.loader.exec_module(m)
fl = m.fl
def entry(t):
    fs = [fl.Failure(key=f"{t}:{i}:1:x", run_id=37000000000 + i, attempt=1, occurrence=f"branch:b{t}", at=f"2026-10-0{1 + i % 7}T11:00:00Z",
                     source="ci-xunit", signature="Expectation failed: " + "x" * 280, head_sha="a" * 40) for i in range(20)]
    return fl.State(test_id=f"TBDSharedTests.Suite{t:03d}/test{t:03d}()", failures=fs)
entries = {e.test_id: e for e in (entry(t) for t in range(int(sys.argv[2])))}
first = m.plan_watchlist(m.Watchlist(), entries, "cheapsteak/tbd")
# The next run reads what the first wrote, and one new test arrives.
slots = [(1000 + w["index"], [x.test_id for x in fl.parse_watchlist(w["body"], fl.BOT_LOGIN, "Bot")], w["body"]) for w in first["writes"]]
read = {x.test_id: x for _, _, b in slots for x in fl.parse_watchlist(b, fl.BOT_LOGIN, "Bot")}
read["TBDSharedTests.Zeta/z()"] = fl.State(test_id="TBDSharedTests.Zeta/z()", failures=entry(999).failures)
second = m.plan_watchlist(m.Watchlist(number=900, slots=slots, entries=dict(read)), read, "cheapsteak/tbd")
# Or the first test in the first comment fails 40 more times: that comment
# overflows, and its last tests move forward through the others.
grown = {x.test_id: x for _, _, b in slots for x in fl.parse_watchlist(b, fl.BOT_LOGIN, "Bot")}
head = slots[0][1][0]
more = [fl.Failure(key=f"g:{i}:1:x", run_id=38000000000 + i, attempt=1, occurrence=grown[head].failures[0].occurrence, at="2026-10-07T11:00:00Z",
                   source="ci-xunit", signature="y" * 280, head_sha="a" * 40) for i in range(40)]
grown[head], _ = fl.merge(grown[head], more)
third = m.plan_watchlist(m.Watchlist(number=900, slots=slots, entries=dict(grown)), grown, "cheapsteak/tbd")
moved_from = {t: i for i, (_, ts, _) in enumerate(slots) for t in ts}
order = [w["index"] for w in third["writes"]]
moves = [(w["index"], moved_from[x.test_id]) for w in third["writes"] for x in fl.parse_watchlist(w["body"], fl.BOT_LOGIN, "Bot")
         if moved_from.get(x.test_id, w["index"]) != w["index"]]
# Each moved test is written to its new comment before its old one.
safe = all(order.index(new) < order.index(old) for new, old in moves if old in order)
held = sorted(x.test_id for w in first["writes"] for x in fl.parse_watchlist(w["body"], fl.BOT_LOGIN, "Bot"))
print(json.dumps({
  "comments": len(first["writes"]),
  "max": max(len(w["body"]) for w in first["writes"]),
  "all_held": held == sorted(entries),
  "second_ids": [w["comment_id"] for w in second["writes"]],
  "third_moves": len(moves),
  "third_safe": safe,
}))
'

test_a_big_watchlist_splits_across_comments_under_the_body_limit() {
  local out mutant
  out="$(python3 -c "$BIG_WATCHLIST" "$HERE" 120)"
  assert_eq "split across several comments" "true" "$(jq '.comments > 1' <<< "$out")"
  assert_eq "each under GitHub's 65,536 characters, and the bot's 60,000" "true" "$(jq '.max <= 60000' <<< "$out")"
  assert_eq "every test held exactly once" "true" "$(jq '.all_held' <<< "$out")"
  assert_eq "a new test the next run writes only to the last comment, or a new one" "0 true" "$(jq -r --argjson last "$((1000 + $(jq ".comments" <<< "$out") - 1))" '"\([.second_ids[] | select(. != null and . != $last)] | length) \(.second_ids | length > 0)"' <<< "$out")"
  assert_eq "a first comment that overflows moves tests forward" "true" "$(jq '.third_moves > 0' <<< "$out")"
  assert_eq "each moved test is written to its new comment before its old one drops it" "true" "$(jq '.third_safe' <<< "$out")"
  mutant="$(mutant_of 's/ else -w\["index"\]\)\)$/ else w["index"]))/' "$LEDGER")"
  assert_eq "mutation: writing the first comment first could drop a moved test" "false" "$(python3 -c "$BIG_WATCHLIST" "$mutant" 120 | jq '.third_safe')"
  mutant="$(mutant_of 's/^        while len\(groups\[i\]\) > 1 and len\(body_of\(groups\[i\]\)\) > fl.MAX_COMMENT_CHARS:$/        while False:/' "$LEDGER")"
  local rc=0
  python3 -c "$BIG_WATCHLIST" "$mutant" 120 > /dev/null 2>&1 || rc=$?
  assert_eq "mutation: without splitting, one comment overflows and the plan refuses" "1" "$rc"
}

# ============================================================================
# previous-ledger-conclusion and the tracking-issue rule (spec §8)
# ============================================================================

# runs_world DIR RUNS_JSON JOBS...: RUNS_JSON is the workflow_runs list; each
# JOBS arg is "<run id>=<ledger conclusion>".
runs_world() {
  local dir="$1" runs="$2"; shift 2
  local routes; routes="$(jq -n --argjson runs "$runs" '[{match: "flake-fixer.yml/runs\\?per_page=100&page=1$", out: ({workflow_runs: $runs} | tojson)},
                                                       {match: "flake-fixer.yml/runs\\?per_page=100&page=", out: "{\"workflow_runs\": []}"}]')"
  local spec id conclusion
  for spec in "$@"; do
    id="${spec%%=*}"; conclusion="${spec#*=}"
    routes="$(jq --arg id "$id" --arg c "$conclusion" '. + [{match: ("actions/runs/" + $id + "/jobs"), out: (({name: "ledger", conclusion: $c} | tojson) + "\n")}]' <<< "$routes")"
  done
  jq '. + [{match: "-X POST", out: "{}"}]' <<< "$routes" > "$dir/routes.json"
  stub_gh "$dir"
}

run_entry() { printf '{"id": %s, "event": "%s", "status": "%s", "created_at": "2026-10-07T18:00:00Z"}' "$1" "$2" "${3:-completed}"; }

prev() { FLAKE_GH_CMD="$1/gh" python3 "$LEDGER" previous-ledger-conclusion --repo "$REPO" --run-id 500 --now 2026-10-08T00:00:00Z; }

test_previous_ledger_conclusion_skips_runs_whose_ledger_job_was_skipped() {
  local d
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 499 workflow_run), $(run_entry 498 workflow_dispatch), $(run_entry 497 workflow_run), $(run_entry 496 workflow_run)]" \
    499=skipped 498=skipped 497=skipped 496=failure
  assert_eq "the first non-skipped ledger job decides" "failure" "$(prev "$d")"
}

test_previous_ledger_conclusion_ignores_the_current_run() {
  local d
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 500 workflow_run), $(run_entry 499 workflow_run)]" 500=failure 499=success
  assert_eq "the current run's own ledger job is not the previous one" "success" "$(prev "$d")"
}

test_previous_ledger_conclusion_counts_an_earlier_run_still_in_progress() {
  local d mutant
  # Run 499's ledger failed while its own ledger-notice job still runs; run 501
  # started after this one and says nothing about what came before it.
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 501 workflow_run), $(run_entry 499 workflow_run in_progress), $(run_entry 498 workflow_run)]" \
    501=success 499=failure 498=success
  assert_eq "the in-progress run's red ledger decides" "failure" "$(prev "$d")"
  mutant="$(mutant_of 's/^            if int\(run\["id"\]\) >= run_id:$/            if int(run["id"]) == run_id or run.get("status") != "completed":/' "$LEDGER")"
  assert_eq "mutation: skipping unfinished runs posts a second note for one streak" "success" \
    "$(FLAKE_GH_CMD="$d/gh" python3 "$mutant/flake-ledger.py" previous-ledger-conclusion --repo "$REPO" --run-id 500 --now 2026-10-08T00:00:00Z)"
}

test_a_rerun_attempt_counts_its_own_earlier_attempt() {
  local d out mutant
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=success
  jq '[{match: "actions/runs/500/attempts/1/jobs", out: (({name: "ledger", conclusion: "failure"} | tojson) + "\n")}] + .' "$d/routes.json" > "$d/r.json" && mv "$d/r.json" "$d/routes.json"
  out="$(FLAKE_GH_CMD="$d/gh" python3 "$LEDGER" previous-ledger-conclusion --repo "$REPO" --run-id 500 --run-attempt 2 --now 2026-10-08T00:00:00Z)"
  assert_eq "attempt 2 of a red run: its attempt 1 already posted" "failure" "$out"
  assert_eq "attempt 1 looks only at earlier runs" "success" "$(prev "$d")"
  assert_contains "the workflow passes the attempt" "$(step_block "$WORKFLOW" "Report the first red")" '--run-attempt "$GITHUB_RUN_ATTEMPT"'
  mutant="$(mutant_of 's/^    if run_attempt > 1:$/    if False:/' "$LEDGER")"
  out="$(FLAKE_GH_CMD="$d/gh" python3 "$mutant/flake-ledger.py" previous-ledger-conclusion --repo "$REPO" --run-id 500 --run-attempt 2 --now 2026-10-08T00:00:00Z)"
  assert_eq "mutation: ignoring the earlier attempt posts again" "success" "$out"
}

# Every commit status starts a run of this workflow (promote's trigger); a
# flood of them must not push the last ledger run past the bound.
test_previous_ledger_conclusion_bound_counts_only_ledger_triggers() {
  local d mutant
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 499 status), $(run_entry 498 status), $(run_entry 497 workflow_run)]" 497=failure
  assert_eq "status runs do not use up the bound" "failure" \
    "$(FLAKE_GH_CMD="$d/gh" python3 "$LEDGER" previous-ledger-conclusion --repo "$REPO" --run-id 500 --max-runs 1 --now 2026-10-08T00:00:00Z)"
  mutant="$(mutant_of 's/^            if run.get\("event"\) not in \("workflow_run", "workflow_dispatch"\):$/            if run.get("event") not in ("workflow_run", "workflow_dispatch") and (seen := seen + 1) > 0:/' "$LEDGER")"
  assert_eq "mutation: counting status runs reads the previous red as none" "none" \
    "$(FLAKE_GH_CMD="$d/gh" python3 "$mutant/flake-ledger.py" previous-ledger-conclusion --repo "$REPO" --run-id 500 --max-runs 1 --now 2026-10-08T00:00:00Z)"
}

test_previous_ledger_conclusion_is_none_when_no_ledger_ran() {
  local d
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=skipped
  assert_eq "none" "none" "$(prev "$d")"
}

test_previous_ledger_conclusion_fails_closed() {
  local d rc=0
  d="$(mktmpd)"
  jq -n '[{match: "flake-fixer.yml/runs", exit: 1}]' > "$d/routes.json"; stub_gh "$d"
  prev "$d" > /dev/null 2>&1 || rc=$?
  assert_eq "exit 2" "2" "$rc"
}

red_run() { FLAKE_GH_CMD="$1/gh" FLAKE_WRITE_TOKEN=app-token python3 "$LEDGER" report-red-run --repo "$REPO" --run-id 500 --issue 519 --now 2026-10-08T00:00:00Z; }

test_a_red_run_after_a_green_one_posts_to_the_tracking_issue() {
  local d
  d="$(mktmpd)"; runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=success
  red_run "$d" > /dev/null
  assert_contains "posted to #519 with the App token" "$(writes_in "$d/log")" "app-token api -X POST repos/cheapsteak/tbd/issues/519/comments"
}

test_a_red_run_after_a_red_one_posts_nothing() {
  local d
  d="$(mktmpd)"; runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=failure
  red_run "$d" > /dev/null
  assert_eq "no write" "" "$(writes_in "$d/log")"
}

test_a_red_first_ever_run_posts() {
  local d
  d="$(mktmpd)"; runs_world "$d" "[]"
  red_run "$d" > /dev/null
  assert_contains "posted" "$(writes_in "$d/log")" "issues/519/comments"
}

test_a_red_run_posted_with_the_job_token_says_so() {
  local d mutant
  d="$(mktmpd)"; runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=success
  FLAKE_GH_CMD="$d/gh" FLAKE_WRITE_TOKEN=job-token python3 "$LEDGER" report-red-run --repo "$REPO" --run-id 500 --issue 519 --now 2026-10-08T00:00:00Z --job-token > /dev/null
  assert_contains "posted to #519 with the token it was given" "$(writes_in "$d/log")" "job-token api -X POST repos/cheapsteak/tbd/issues/519/comments"
  assert_contains "and the comment says which token and why" "$(cat "$d/log")" "Posted with the workflow's job token"
  d="$(mktmpd)"; runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=success
  red_run "$d" > /dev/null
  assert_lacks "with the App token it does not" "$(cat "$d/log")" "job token"
  d="$(mktmpd)"; runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=failure
  FLAKE_GH_CMD="$d/gh" FLAKE_WRITE_TOKEN=job-token python3 "$LEDGER" report-red-run --repo "$REPO" --run-id 500 --issue 519 --now 2026-10-08T00:00:00Z --job-token > /dev/null
  assert_eq "a second red in a row posts nothing, whichever token" "" "$(writes_in "$d/log")"
  d="$(mktmpd)"; runs_world "$d" "[$(run_entry 499 workflow_run)]" 499=success
  mutant="$(mutant_of 's/^    if job_token:$/    if False:/' "$LEDGER")"
  FLAKE_GH_CMD="$d/gh" FLAKE_WRITE_TOKEN=job-token python3 "$mutant/flake-ledger.py" report-red-run --repo "$REPO" --run-id 500 --issue 519 --now 2026-10-08T00:00:00Z --job-token > /dev/null
  assert_lacks "mutation: without the clause the job-token comment is silent about it" "$(cat "$d/log")" "job token"
}

# ============================================================================
# fetch: a definite "does not exist" skips one test; anything else fails closed
# ============================================================================

NOT_FOUND=$'gh: Not Found (HTTP 404)\n'

test_a_trait_naming_a_missing_issue_skips_only_that_issue_in_fetch() {
  local d out rc=0 mutant
  # The stub root's one quarantine, the self-test's, names #499.
  d="$(mktmpd)"; stub_world "$d" "$(jq -n --arg e "$NOT_FOUND" '[{match: "repos/cheapsteak/tbd/issues/499$", exit: 1, err: $e}]')"
  out="$(ledger_run "$d")" || rc=$?
  assert_eq "a 404 does not fail the run" "0" "$rc"
  assert_contains "the missing issue is listed" "$out" "#499 (HTTP 404): a failing test whose trait names it gets an issue of its own"
  assert_contains "and the failing test is still reported" "$out" "$HOLDER"
  d="$(mktmpd)"; stub_world "$d" '[{"match": "repos/cheapsteak/tbd/issues/499$", "exit": 1, "err": "gh: Server Error (HTTP 502)\n"}]'
  rc=0; ledger_run "$d" > /dev/null || rc=$?
  assert_eq "a 502 still fails closed" "2" "$rc"
  d="$(mktmpd)"; stub_world "$d" "$(jq -n --arg e "$NOT_FOUND" '[{match: "repos/cheapsteak/tbd/issues/499$", exit: 1, err: $e}]')"
  mutant="$(mutant_of 's/^ISSUE_GONE_STATUSES = .*$/ISSUE_GONE_STATUSES = ()/' "$LEDGER")"
  rc=0; LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" > /dev/null || rc=$?
  assert_eq "mutation: without the 404 rule the whole run fails" "2" "$rc"
}

# trait_world GONE_JSON -> a work dir where OtherTests/flaky()'s trait names
# #600, fetch recorded GONE_JSON for it, and HOLDER failed one nightly.
trait_world() {
  local w; w="$(newwork)"
  build run "$w" --id 1701 --branch b --attempt "1|2026-10-06T10:00:00Z|success" --artifact "17011|retry-metrics|2026-10-06T10:20:00Z"
  build retry "$w/artifacts/17011/retry-metrics.jsonl" 'TBDSharedTests.OtherTests/flaky()' passedOnRetry Tests/TBDSharedTests/OtherTests.swift
  retry_run "$w" 1717 c 'TBDSharedTests.OtherTests/flaky()' Tests/TBDSharedTests/OtherTests.swift
  nightly_run "$w" 2701 2026-10-05 "$HOLDER"
  printf 'Tests/TBDSharedTests/OtherTests.swift\tflaky\t600\n' > "$w/inventory.tsv"
  build set "$w" fetch_notes.json "$1"
  printf '%s' "$w"
}

test_a_test_whose_trait_issue_is_gone_gets_its_own_issue() {
  local w out mutant status
  for status in 404 410; do
    w="$(trait_world "{\"gone_issues\": {\"600\": $status}}")"
    out="$(analyze "$w")"
    assert_eq "HTTP $status: the test gets a fresh issue that links nothing, beside the other test" \
      "Flaky test: TBDSharedTests.OtherTests/flaky() false|$HOLDER" \
      "$(jq -r '[.actions[] | select(.test_id == "TBDSharedTests.OtherTests/flaky()") | "\(.create.title) \(.create.body | test("#600"))"][0] + "|" + ([.tests[].test_id | select(. != "TBDSharedTests.OtherTests/flaky()")] | join(","))' <<< "$out")"
    assert_contains "HTTP $status: the number is listed" "$(python3 "$LEDGER" report --plan <(printf '%s' "$out"))" "#600 (HTTP $status): a failing test whose trait names it gets an issue of its own"
  done
  mutant="$(mutant_of 's/ if trait is None or trait in ctx.gone_issues else trait$/ if trait is None else trait/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_contains "mutation: without the rule the new issue links a number that does not exist" \
    "$(jq -r '.actions[] | select(.test_id == "TBDSharedTests.OtherTests/flaky()") | .create.body' <<< "$out")" "#600"
}

test_a_compare_404_does_not_fail_the_run() {
  local d out rc=0 mutant routes
  local issue='{"number": 970, "title": "Flaky test: '"$HOLDER"'", "state": "closed", "labels": [{"name": "flaky"}]}'
  local close='{"data": {"repository": {"issue": {"timelineItems": {"nodes": [{"createdAt": "2026-10-05T12:00:00Z", "stateReason": "COMPLETED", "closer": {"__typename": "PullRequest", "number": 960, "merged": true, "mergedAt": "2026-10-05T12:00:00Z", "mergeCommit": {"oid": "9609609"}}}]}}}}}'
  routes="$(jq -n --arg issue "$issue" --arg close "$close" --arg e "$NOT_FOUND" '[
    {match: "issues\\?labels=flaky", out: ($issue + "\n")},
    {match: "issues/970/comments\\?per_page", out: ""},
    {match: "graphql", out: $close},
    {match: "compare/9609609\\.\\.\\.538ba7eb", exit: 1, err: $e},
    {match: "commits/9609609 ", out: "9609609\n"}]')"
  d="$(mktmpd)"; stub_world "$d" "$routes"
  out="$(FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write)" || rc=$?
  assert_eq "a 404 from compare, with the fix commit present, does not fail the run" "0" "$rc"
  assert_contains "the failure is listed as not recorded" "$out" "\`$HOLDER\`: failure 37517751216:1:xunit-app-swift-testing.xml not recorded: its commit 538ba7eb no longer exists"
  assert_lacks "and nothing reopens the issue on it" "$(writes_in "$d/log")" "-X PATCH repos/cheapsteak/tbd/issues/970 "
  d="$(mktmpd)"; stub_world "$d" "$(jq '(.[] | select(.match | startswith("compare"))) |= (.err = "gh: Server Error (HTTP 500)\n")' <<< "$routes")"
  rc=0; FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write > /dev/null || rc=$?
  assert_eq "a 500 still fails closed" "2" "$rc"
  d="$(mktmpd)"; stub_world "$d" "$routes"
  mutant="$(mutant_of 's/^COMPARE_GONE_STATUSES = .*$/COMPARE_GONE_STATUSES = ()/' "$LEDGER")"
  rc=0; FLAKE_WRITE_TOKEN=app-token LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" --write > /dev/null || rc=$?
  assert_eq "mutation: without the 404 rule the whole run fails" "2" "$rc"
  # The fix commit itself gone would make every later failure unplaceable.
  local gone_fix
  gone_fix="$(jq --arg e "$NOT_FOUND" '(.[] | select(.match == "commits/9609609 ")) |= {match: .match, exit: 1, err: $e}' <<< "$routes")"
  d="$(mktmpd)"; stub_world "$d" "$gone_fix"
  rc=0; out="$(FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write)" || rc=$?
  assert_eq "a missing fix commit fails closed" "2" "$rc"
  assert_contains "and says why" "$out" "the fix commit 9609609 no longer exists"
  d="$(mktmpd)"; stub_world "$d" "$gone_fix"
  mutant="$(mutant_of 's/^                gh\("api", f"repos\/\{repo\}\/commits\/\{base\}", "--jq", ".sha"\)$/                pass/' "$LEDGER")"
  rc=0; FLAKE_WRITE_TOKEN=app-token LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" --write > /dev/null || rc=$?
  assert_eq "mutation: without probing the fix commit its loss is silent" "0" "$rc"
}

test_an_uncomparable_failure_is_dropped_and_the_test_still_planned() {
  local w out mutant rc=0
  w="$(newwork)"
  erased_run "$w" 1901 rebased --sha cccc
  erased_run "$w" 1902 gone --sha dddd
  build issue "$w" --number 970 --title "Flaky test: $HOLDER" --state CLOSED --closed-reason completed --label flaky \
    --fix "9609609@2026-10-05T12:00:00Z@960"
  build set "$w" ancestry.json '{"9609609..cccc": true}'
  build set "$w" ancestry_unresolved.json '["9609609..dddd"]'
  out="$(analyze "$w")"
  assert_eq "the comparable failure still reopens the issue" "true 1" "$(jq -r '"\(.actions[0].reopen) \(.tests[0].episode)"' <<< "$out")"
  assert_contains "it is recorded" "$(jq -r '.actions[0].comment_body' <<< "$out")" '1901:1:xunit-app-swift-testing.xml'
  assert_lacks "and the dropped one is not" "$(jq -r '.actions[0].comment_body' <<< "$out")" '1902:1:xunit-app-swift-testing.xml'
  assert_contains "the other is listed" "$(jq -r '.notes.dropped[]' <<< "$out")" "failure 1902:1:xunit-app-swift-testing.xml not recorded"
  mutant="$(mutant_of 's/^        if contains is None and pair in ctx.unresolved:$/        if False:/' "$LEDGER")"
  analyze "$w" "$mutant" > /dev/null 2>&1 || rc=$?
  assert_eq "mutation: without dropping it the whole analysis fails" "2" "$rc"
}

test_a_long_title_is_searched_by_a_whole_word_prefix() {
  local d mutant script title q
  d="$(mktmpd)"
  jq -n '[{match: "search/issues", out: ""}]' > "$d/routes.json"; stub_gh "$d"
  title="Flaky test: TBDSharedTests.LongSuite/$(printf 'word%03d_' $(seq 1 60))end()"
  script='
import sys, importlib.util
s = importlib.util.spec_from_file_location("fl_ledger", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["fl_ledger"] = m; s.loader.exec_module(m)
m._search_title("cheapsteak/tbd", sys.argv[2])
'
  FLAKE_GH_CMD="$d/gh" python3 -c "$script" "$LEDGER" "$title"
  q="$(grep search/issues "$d/log" | sed -n 's/.*in:title "\([^"]*\)".*/\1/p')"
  assert_eq "the phrase fits under GitHub's limit" "yes" "$([[ ${#q} -le 200 && ${#q} -gt 0 ]] && echo yes || echo "no (${#q})")"
  assert_eq "and is a prefix of the title" "yes" "$([[ "$title" == "$q"* ]] && echo yes || echo no)"
  : > "$d/log"
  mutant="$(mutant_of 's/^SEARCH_PHRASE_MAX = 200$/SEARCH_PHRASE_MAX = 100000/' "$LEDGER")"
  FLAKE_GH_CMD="$d/gh" python3 -c "$script" "$mutant/flake-ledger.py" "$title"
  q="$(grep search/issues "$d/log" | sed -n 's/.*in:title "\([^"]*\)".*/\1/p')"
  assert_eq "mutation: uncapped, the whole title is sent" "${#title}" "${#q}"
}

test_check_app_slug_accepts_only_the_trusted_app() {
  local rc=0
  python3 "$LIB" check-app-slug tbd-flake-fixer 2>/dev/null || rc=$?
  assert_eq "the trusted slug" "0" "$rc"
  rc=0; python3 "$LIB" check-app-slug some-other-app 2>/dev/null || rc=$?
  assert_eq "another App" "1" "$rc"
}

# search_page ISSUE_JSON... -> one `--jq` page line as `_search_title` asks for it.
search_page() { jq -cn --argjson items "[$(IFS=,; printf '%s' "$*")]" '{incomplete: false, total: 2, items: $items}'; }

test_the_title_search_reads_every_page() {
  local d out mutant routes page1 page2
  page1="$(search_page '{"number": 1500, "title": "Flaky test: something else", "state": "open", "labels": []}')"
  page2="$(search_page "{\"number\": 970, \"title\": \"Flaky test: $HOLDER\", \"state\": \"open\", \"labels\": []}")"
  # The stub answers both pages only to a paginated call, as gh does.
  routes="$(jq -n --arg both "$page1"$'\n'"$page2"$'\n' --arg one "$page1"$'\n' '[
    {match: "--paginate -X GET search/issues", out: $both},
    {match: "search/issues", out: $one}]')"
  d="$(mktmpd)"; stub_world "$d" "$routes"
  out="$(ledger_run "$d")"
  assert_contains "the issue on page 2 is found, not duplicated" "$out" "#970 (open)"
  d="$(mktmpd)"; stub_world "$d" "$routes"
  mutant="$(mutant_of 's/^        "api", "--paginate", "-X", "GET", "search\/issues",$/        "api", "-X", "GET", "search\/issues",/' "$LEDGER")"
  out="$(LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d")"
  assert_contains "mutation: reading one page plans a duplicate" "$out" "a new issue"
}

test_the_title_search_fails_closed_on_an_incomplete_answer() {
  local d rc=0 mutant routes
  routes="$(jq -n '[{match: "search/issues", out: "{\"incomplete\": true, \"total\": 0, \"items\": []}\n"}]')"
  d="$(mktmpd)"; stub_world "$d" "$routes"
  ledger_run "$d" > /dev/null || rc=$?
  assert_eq "an incomplete search is exit 2, not 'no issue'" "2" "$rc"
  d="$(mktmpd)"; stub_world "$d" "$routes"
  mutant="$(mutant_of 's/^        if page.get\("incomplete"\):$/        if False:/' "$LEDGER")"
  rc=0; LEDGER_UNDER_TEST="$mutant/flake-ledger.py" ledger_run "$d" > /dev/null || rc=$?
  assert_eq "mutation: trusting it exits 0" "0" "$rc"
}

test_the_title_search_keeps_a_quote_from_ending_the_phrase() {
  local d out mutant script
  d="$(mktmpd)"
  jq -n '[{match: "search/issues", out: ""}]' > "$d/routes.json"; stub_gh "$d"
  script='
import sys, importlib.util
s = importlib.util.spec_from_file_location("fl_ledger", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["fl_ledger"] = m; s.loader.exec_module(m)
m._search_title("cheapsteak/tbd", "Flaky test: M.S/f(\"a\")")
'
  FLAKE_GH_CMD="$d/gh" python3 -c "$script" "$LEDGER"
  out="$(grep search/issues "$d/log")"
  assert_contains "the inner quotes are spaces, so the phrase is the whole title" "$out" 'in:title "Flaky test: M.S/f( a )"'
  : > "$d/log"
  mutant="$(mutant_of "s/^    phrase = title.replace\\('\"', \" \"\\)\$/    phrase = title/" "$LEDGER")"
  FLAKE_GH_CMD="$d/gh" python3 -c "$script" "$mutant/flake-ledger.py"
  assert_contains "mutation: unescaped, the first inner quote ends the phrase" "$(grep search/issues "$d/log")" 'in:title "Flaky test: M.S/f("a")"'
}

# ============================================================================
# analyze: artifacts it could not read are listed
# ============================================================================

test_expired_and_missing_artifacts_are_listed() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 1801 sidebar --artifact "18012|retry-metrics|2026-10-06T19:34:00Z"
  jq '(.[] | select(.run_id == 1801) | .artifacts[]) |= (.expired = true)' "$w/runs.json" > "$w/r.json" && mv "$w/r.json" "$w/runs.json"
  build run "$w" --id 1802 --branch b --attempt "1|2026-10-06T19:16:42Z|failure" --attempt "2|2026-10-06T19:35:23Z|success"
  build run "$w" --id 1803 --workflow nightly --branch main --attempt "1|2026-10-05T11:00:00Z|failure"
  out="$(analyze "$w")"
  assert_contains "an expired xunit artifact" "$(jq -r '.notes.unavailable[]' <<< "$out")" "run 1801: \`xunit-results\` artifact 18011 has expired"
  assert_contains "an expired retry-metrics artifact" "$(jq -r '.notes.unavailable[]' <<< "$out")" "run 1801: \`retry-metrics\` artifact 18012 has expired"
  assert_contains "a rerun-erased run with no attempt-1 xunit" "$(jq -r '.notes.unavailable[]' <<< "$out")" "run 1802: attempt 1 failed and a rerun passed"
  assert_contains "a nightly with none" "$(jq -r '.notes.unavailable[]' <<< "$out")" "nightly run 1803: no \`nightly-xunit\` artifact"
  assert_contains "the report has the section" "$(python3 "$LEDGER" report --plan <(printf '%s' "$out"))" "Artifacts not read (expired, or never uploaded)"
  mutant="$(mutant_of 's/^        notes.unavailable.extend\(artifact_gaps\(run\)\)$/        pass/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without the listing they vanish silently" "0" "$(jq '.notes.unavailable | length' <<< "$out")"
}

# ============================================================================
# flake-fixer.yml structure (no YAML parser on the runner: text checks)
# ============================================================================

# step_block FILE NAME: the lines of the step named NAME, up to the next step.
step_block() {
  awk -v name="$2" '
    /^      - (name|uses):/ { inside = (index($0, "- name: " name) > 0) }
    /^  [a-z]/ { inside = 0 }
    inside { print }
  ' "$1"
}

check_reclaimer_gated() { step_block "$1" "Reclaim flakefix/" | grep -q "if: vars.FLAKE_FIXER_ENABLED == 'true'"; }

test_ledger_writes_only_when_its_flag_is_true() {
  local block
  block="$(step_block "$WORKFLOW" "Ledger")"
  assert_contains "the write path is the flag's" "$(cat "$WORKFLOW")" "LEDGER_ENABLED: \${{ vars.FLAKE_LEDGER_ENABLED == 'true' }}"
  assert_contains "--write only under it" "$block" 'if [ "$LEDGER_ENABLED" = "true" ]; then'
  assert_eq "exactly one --write" "1" "$(grep -c -- '--write' <<< "$block")"
  assert_contains "the App token is minted only under it" "$(step_block "$WORKFLOW" "Mint the tbd-flake-fixer App token")" "if: vars.FLAKE_LEDGER_ENABLED == 'true'"
  assert_contains "and its slug is checked against the trusted login" "$(step_block "$WORKFLOW" "Check the App token's bot login")" 'scripts/flake_lib.py check-app-slug "$APP_SLUG"'
  assert_contains "the reclaimer cannot stop the ledger" "$(step_block "$WORKFLOW" "Reclaim flakefix/")" "continue-on-error: true"
}

test_the_reclaimer_runs_only_under_the_fixer_flag() {
  local copy rc=0
  check_reclaimer_gated "$WORKFLOW" || rc=$?
  assert_eq "the reclaimer step is gated" "0" "$rc"
  assert_contains "and sweeps only flakefix/ with a day's grace" "$(step_block "$WORKFLOW" "Reclaim flakefix/")" "--namespace flakefix/ --min-age-seconds 86400 --apply"
  copy="$(mktmpd)/flake-fixer.yml"
  sed "/if: vars.FLAKE_FIXER_ENABLED == 'true'/d" "$WORKFLOW" > "$copy"
  rc=0; check_reclaimer_gated "$copy" || rc=$?
  assert_eq "mutation: without the if: the check fails" "1" "$rc"
}

test_ledger_checkout_does_not_persist_credentials() {
  assert_contains "persist-credentials: false" "$(grep -A2 'uses: actions/checkout' "$WORKFLOW")" "persist-credentials: false"
  assert_eq "every checkout says so" "$(grep -c 'uses: actions/checkout' "$WORKFLOW")" "$(grep -c 'persist-credentials: false' "$WORKFLOW")"
}

test_ledger_requires_this_repository_and_its_triggers() {
  local job
  job="$(awk '/^  ledger:/{p=1} p && /^    runs-on:/{exit} p' "$WORKFLOW")"
  assert_contains "this repository only" "$job" "github.repository == 'cheapsteak/tbd'"
  assert_contains "after the nightly" "$job" "github.event.workflow_run.name == 'Nightly'"
  assert_contains "or on dispatch with job: ledger" "$job" "inputs.job == 'ledger'"
  assert_contains "the dispatch input is a required choice" "$(cat "$WORKFLOW")" "options: [ledger, fix]"
  assert_contains "one concurrency group for ledger writes" "$(cat "$WORKFLOW")" "group: flake-ledger-state"
}

# job_block FILE NAME: the lines of the job NAME, up to the next job.
job_block() {
  awk -v name="$2" '
    /^  [a-z][a-z_-]*:$/ { inside = ($0 == "  " name ":") }
    inside { print }
  ' "$1"
}

# The job token may write issues only in `ledger-notice`, and reaches
# FLAKE_WRITE_TOKEN only on its job-token branch, which says so.
check_job_token_writes_only_the_notice() {
  local file="$1"
  [[ "$(grep -c '^      issues: write$' "$file")" == 1 ]] || return 1
  job_block "$file" ledger-notice | grep -q '^      issues: write$' || return 1
  job_block "$file" ledger | grep -q '^      issues: read$' || return 1
  grep -q 'token="\$GH_TOKEN"; extra=(--job-token)$' "$file" || return 1
  ! grep -q 'FLAKE_WRITE_TOKEN: \${{ github.token }}' "$file"
}

test_a_red_ledger_run_is_reported_in_either_mode() {
  local job copy rc=0
  job="$(job_block "$WORKFLOW" ledger-notice)"
  assert_contains "it follows the ledger job" "$job" "needs: ledger"
  assert_contains "and runs when it failed, in this repository, whatever the flag" "$job" "if: always() && github.repository == 'cheapsteak/tbd' && needs.ledger.result == 'failure'"
  assert_lacks "the job itself is not gated on the ledger flag" "$(grep '^    if:' <<< "$job")" "FLAKE_LEDGER_ENABLED"
  assert_contains "a failed mint does not stop the notice" "$(step_block "$WORKFLOW" "Mint the App token for the notice")" "continue-on-error: true"
  assert_contains "the App token only under the flag" "$(step_block "$WORKFLOW" "Mint the App token for the notice")" "if: vars.FLAKE_LEDGER_ENABLED == 'true'"
  assert_contains "and only once its login checked out" "$(step_block "$WORKFLOW" "Report the first red")" "USE_APP_TOKEN: \${{ steps.notice-bot-login.outcome == 'success' }}"
  assert_contains "with the same check the ledger job uses" "$(step_block "$WORKFLOW" "Check the notice token's bot login")" 'scripts/flake_lib.py check-app-slug "$APP_SLUG"'
  assert_lacks "the ledger job no longer posts it" "$(job_block "$WORKFLOW" ledger)" "report-red-run"
  check_job_token_writes_only_the_notice "$WORKFLOW" || rc=$?
  assert_eq "the job token writes only the notice" "0" "$rc"
  copy="$(mktmpd)/flake-fixer.yml"
  awk '/^  ledger:$/{l=1} /^  ledger-notice:$/{l=0} l && /^      issues: read$/{sub(/read/, "write")} {print}' "$WORKFLOW" > "$copy"
  rc=0; check_job_token_writes_only_the_notice "$copy" || rc=$?
  assert_eq "mutation: issues: write on the ledger job fails the check" "1" "$rc"
  sed 's/extra=(--job-token)$/extra=()/' "$WORKFLOW" > "$copy"
  rc=0; check_job_token_writes_only_the_notice "$copy" || rc=$?
  assert_eq "mutation: a job-token post that does not say so fails the check" "1" "$rc"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
