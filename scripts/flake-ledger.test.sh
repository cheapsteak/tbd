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
unset GITHUB_STEP_SUMMARY FLAKE_WRITE_TOKEN

FAIL=0
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; echo "$2" | sed 's/^/       /' | head -40; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output contains [$3]"; echo "$2" | sed 's/^/       /' | head -40; FAIL=1; fi; }
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] != [$3]"; FAIL=1; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/flake-ledger-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
SEQ=0
mktmpd() { SEQ=$((SEQ + 1)); mkdir -p "$SCRATCH/d$SEQ"; printf '%s' "$SCRATCH/d$SEQ"; }

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
  mutant="$(mutant_of 's/^    if state.episode > 0 and current > 0:$/    if False:/' "$LIB")"
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
  assert_contains "with its real signature" "$(jq -r '.actions[0].comment_body' <<< "$out")" "Caught error: .alreadyHeld"
  mutant="$(mutant_of 's/^            chosen = attempt\["attempt"\]$/            chosen = 1/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_contains "mutation: without the window, attempt 2's artifact is read as attempt 1's" "$(jq -r '.tests[].test_id' <<< "$out")" "attemptTwoOnly"
}

test_fork_runs_are_excluded() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 1001 sidebar --repo someone/tbd
  out="$(analyze "$w")"
  assert_eq "no actions for a fork's run" "0" "$(jq '.actions | length' <<< "$out")"
  mutant="$(mutant_of 's/^    if run.get\("head_repo"\) != repo:$/    if False:/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without the fork check it plans an issue" "1" "$(jq '.actions | length' <<< "$out")"
}

test_flakefix_branches_are_excluded() {
  local w out mutant
  w="$(newwork)"
  erased_run "$w" 1002 flakefix/issue-970
  out="$(analyze "$w")"
  assert_eq "no actions for the bot's own branch" "0" "$(jq '.actions | length' <<< "$out")"
  mutant="$(mutant_of 's/^FLAKEFIX_PREFIX = "flakefix\/"$/FLAKEFIX_PREFIX = "nothing-matches\/"/' "$LEDGER")"
  out="$(analyze "$w" "$mutant")"
  assert_eq "mutation: without the exclusion it plans an issue" "1" "$(jq '.actions | length' <<< "$out")"
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
  assert_contains "with source ci-retry" "$(jq -r '.actions[0].comment_body' <<< "$out")" '"source":"ci-retry"'
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
  assert_contains "the body links the stress target's issue" "$(jq -r '.actions[0].comment_body' <<< "$out")" "stress target #962"
}

test_threshold_one_and_two_keys_end_to_end() {
  local w out
  w="$(newwork)"
  nightly_run "$w" 2002 2026-10-05 "$HOLDER"
  out="$(analyze "$w")"
  assert_eq "one night: the issue is created, not qualified" "true false" "$(jq -r '.tests[0] | "\(.create) \(.qualifies)"' <<< "$out")"
  erased_run "$w" 1006 sidebar
  out="$(analyze "$w")"
  assert_eq "one night and one branch: qualifies" "true" "$(jq -r '.tests[0].qualifies' <<< "$out")"
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
  mutant="$(mutant_of 's/^            if contains:$/            if True:/' "$LEDGER")"
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
    {match: "repos/cheapsteak/tbd/issues/499$", out: "{\"number\": 499, \"title\": \"Quarantine self-test\", \"state\": \"open\", \"labels\": []}"},
    {match: "issues/[0-9]+/comments\\?per_page", out: ""},
    {match: "search/issues", out: ""},
    {match: "labels\\?per_page", out: ""},
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

test_write_mode_creates_then_comments_with_the_app_token() {
  local d out writes
  d="$(mktmpd)"; stub_world "$d"
  out="$(FLAKE_WRITE_TOKEN=app-token ledger_run "$d" --write)"
  writes="$(writes_in "$d/log")"
  assert_eq "label, issue, comment, in that order" \
    "app-token api -X POST repos/cheapsteak/tbd/labels --input -
app-token api -X POST repos/cheapsteak/tbd/issues --input -
app-token api -X POST repos/cheapsteak/tbd/issues/1000/comments --input -" "$writes"
  assert_contains "the issue title is exact" "$(cat "$d/log")" "\"title\": \"Flaky test: $HOLDER\""
  assert_contains "the comment opens with the sentinel" "$(cat "$d/log")" '"body": "<!-- flake-ledger v1 -->'
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

test_apply_stops_at_the_first_failed_write() {
  local d plan rc=0
  d="$(mktmpd)"
  jq -n '[{match: "labels\\?per_page", out: "{\"name\": \"flaky\"}\n"},{match: "issues/970/comments", exit: 1}, {match: "-X", out: "{}"}]' > "$d/routes.json"
  stub_gh "$d"
  plan="$d/plan.json"
  jq -n '{actions: [
    {test_id: "a/b()", issue: 970, create: null, add_label: true, reopen: false, reopen_body: null, comment_id: null, comment_body: "x", qualifies: false},
    {test_id: "c/d()", issue: 971, create: null, add_label: false, reopen: false, reopen_body: null, comment_id: 5, comment_body: "y", qualifies: false}]}' > "$plan"
  FLAKE_GH_CMD="$d/gh" FLAKE_WRITE_TOKEN=app-token python3 "$LEDGER" apply --plan "$plan" --repo "$REPO" > /dev/null 2>&1 || rc=$?
  assert_eq "exit 2" "2" "$rc"
  assert_lacks "the second issue is untouched" "$(cat "$d/log")" "comments/5"
  assert_lacks "an existing label is not created again" "$(cat "$d/log")" "-X POST repos/cheapsteak/tbd/labels "
  assert_contains "but the issue gets it" "$(cat "$d/log")" "-X POST repos/cheapsteak/tbd/issues/970/labels"
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

run_entry() { printf '{"id": %s, "event": "%s", "status": "completed", "created_at": "2026-10-07T18:00:00Z"}' "$1" "$2"; }

prev() { FLAKE_GH_CMD="$1/gh" python3 "$LEDGER" previous-ledger-conclusion --repo "$REPO" --run-id 500 --now 2026-10-08T00:00:00Z; }

test_previous_ledger_conclusion_skips_runs_whose_ledger_job_was_skipped() {
  local d
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 504 workflow_run), $(run_entry 503 workflow_dispatch), $(run_entry 502 workflow_run), $(run_entry 501 workflow_run)]" \
    504=skipped 503=skipped 502=skipped 501=failure
  assert_eq "the first non-skipped ledger job decides" "failure" "$(prev "$d")"
}

test_previous_ledger_conclusion_ignores_the_current_run() {
  local d
  d="$(mktmpd)"
  runs_world "$d" "[$(run_entry 500 workflow_run), $(run_entry 499 workflow_run)]" 500=failure 499=success
  assert_eq "the current run's own ledger job is not the previous one" "success" "$(prev "$d")"
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
  assert_contains "and its slug is checked against the trusted login" "$(step_block "$WORKFLOW" "Check the App token's bot login")" 'scripts/flake_lib.py bot-login'
  assert_contains "the tracking comment needs the flag and the token" "$(step_block "$WORKFLOW" "Report the first red")" "if: failure() && vars.FLAKE_LEDGER_ENABLED == 'true'"
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

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
