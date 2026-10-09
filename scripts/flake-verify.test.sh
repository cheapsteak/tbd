#!/usr/bin/env bash
# Tests for scripts/flake-verify.sh and scripts/flake-verify.py — run:
#   bash scripts/flake-verify.test.sh
#
# NO BUILD, NO NETWORK, NO SWIFT. The judge and the baseline read synthetic
# stress-loop outputs written by scripts/fixtures/flake/verify_iter.py; the
# wrappers run against a stub `nightly-flake-stress.sh` that records its argv;
# `apply-candidate` and `protected-touched` run in throwaway git repos.
#
# THE PROCESS CASES NEVER SIGNAL ANYTHING THEY DID NOT START. The listing that
# `end-session-processes` acts on comes from FLAKE_VERIFY_PS, which these cases
# point at a stub that reports only the `sleep` processes the case itself
# spawned. On a developer machine the real listing holds every agent session
# the user is running; a case that used it would end them.
#
# EVERY GUARD IS MUTATION-CHECKED: `mutant_of` copies the scripts into a fresh
# directory with one sed edit applied, and the case re-runs against the copy.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # sed expressions must NOT expand here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/flake-verify.sh"
VPY="$HERE/flake-verify.py"
ITER="$HERE/fixtures/flake/verify_iter.py"
HOLDER='TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()'
NESTED='TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/closesAfterSetup()'

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

FAIL=0
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; echo "$2" | sed 's/^/       /' | head -30; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output contains [$3]"; echo "$2" | sed 's/^/       /' | head -30; FAIL=1; fi; }
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] != [$3]"; FAIL=1; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/flake-verify-test.XXXXXX")"
SPAWNED=()
cleanup() {
  local pid
  for pid in "${SPAWNED[@]:-}"; do [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null; done
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
# mktemp, not a counter: callers run it in a command substitution, where a
# counter never advances and every "fresh" directory would be the same one.
mktmpd() { mktemp -d "$SCRATCH/d.XXXXXX"; }
# Every git command a case runs is meant for a throwaway repo under SCRATCH.
# A repo path that came out empty or mangled must fail there, never fall
# through to the checkout this harness lives in.
export GIT_CEILING_DIRECTORIES="$SCRATCH"
cd "$SCRATCH" || exit 2

# mutant_of SED_EXPR FILE -> a directory holding the scripts, FILE edited.
mutant_of() {
  local expr="$1" file="$2" dir name
  dir="$(mktmpd)"
  cp "$HERE/flake_lib.py" "$VERIFY" "$VPY" "$dir/"
  name="$(basename "$file")"
  sed -E "$expr" "$file" > "$dir/$name"
  if cmp -s "$file" "$dir/$name"; then
    echo "FAIL - mutation [$expr] did not change $name" >&2
    FAIL=1
  fi
  printf '%s' "$dir"
}

it() { python3 "$ITER" "$@"; }

# twenty D [args for every iteration]: a clean 20-iteration baseline.
twenty() { local d="$1" i; shift; for i in $(seq 1 20); do it "$d" "$i" "$@"; done; }

# scope D [quarantined] [DIR] -> "rc=<n> <scope> f/v"
scope() {
  local d="$1" q="${2:-no}" dir="${3:-$HERE}" rc=0
  bash "$dir/flake-verify.sh" choose-scope --test "$HOLDER" --dir "$d" --quarantined "$q" > /dev/null 2>&1 || rc=$?
  echo "rc=$rc $(cat "$d/scope" 2>/dev/null || echo -) $(cat "$d/f" 2>/dev/null || echo -)/$(cat "$d/v" 2>/dev/null || echo -)"
}

# A baseline of 20 where iteration 1 is replaced: rewrite the row file.
baseline_with() { # D ITERATION-1 ARGS...
  local d="$1" i; shift
  it "$d" 1 "$@"
  for i in $(seq 2 20); do it "$d" "$i"; done
}

# ============================================================================
# the baseline: scope choice (spec §6.2, §6.3)
# ============================================================================

test_one_failing_iteration_of_twenty_chooses_test_scope() {
  local d mutant; d="$(mktmpd)"
  baseline_with "$d" --kind FAIL --outcome failed
  assert_eq "1 of 20 reproduced: test scope" "rc=0 test 1/20" "$(scope "$d")"
  mutant="$(mutant_of 's/^    scope = "test" if f >= 1 else "pass"$/    scope = "test" if f >= 2 else "pass"/' "$VPY")"
  assert_eq "mutation: a threshold of two chooses pass scope" "rc=0 pass 1/20" "$(scope "$d" no "$mutant")"
}

test_zero_failures_choose_pass_scope_and_say_so() {
  local d; d="$(mktmpd)"
  twenty "$d"
  assert_eq "0 of 20: pass scope" "rc=0 pass 0/20" "$(scope "$d")"
  assert_contains "the baseline says what it measured" "$(cat "$d/baseline.md")" "0 of 20 valid test-alone iterations reproduced the failure (0 excluded)"
  assert_contains "and that pass scope was not measured" "$(cat "$d/baseline.md")" "The pre-fix failure rate at pass scope was not measured"
}

test_a_deadline_kill_after_the_target_started_is_a_reproduction() {
  local d; d="$(mktmpd)"
  baseline_with "$d" --kind FAIL --reason "wedged — no completion" --outcome absent --log "◇ Test lockIsReacquirableAfterRelease() started."
  assert_eq "wedged after the target started" "rc=0 test 1/20" "$(scope "$d")"
  d="$(mktmpd)"
  baseline_with "$d" --kind FAIL --reason "wedged — no completion" --outcome absent --log "Building for debugging..."
  assert_eq "wedged before it started is excluded" "rc=0 pass 0/19" "$(scope "$d")"
}

test_a_wedged_xctest_target_counts_as_a_reproduction() {
  local d; d="$(mktmpd)"
  baseline_with "$d" --kind FAIL --reason "wedged — no completion" --outcome absent \
    --log "Test Case '-[TBDSharedTests.HolderLockTests lockIsReacquirableAfterRelease()]' started."
  assert_eq "XCTest's started line counts too" "rc=0 test 1/20" "$(scope "$d")"
}

test_a_quarantined_targets_passed_on_retry_counts_as_a_reproduction() {
  local d mutant; d="$(mktmpd)"
  baseline_with "$d" --record passedOnRetry
  assert_eq "green xunit, a passedOnRetry record, quarantined: test" "rc=0 test 1/20" "$(scope "$d" yes)"
  mutant="$(mutant_of 's/^        if quarantined and any\(r.get\("outcome"\) in \("passedOnRetry", "failed"\) for r in records or \[\]\):$/        if False:/' "$VPY")"
  assert_eq "mutation: without the retry clause it is clean" "rc=0 pass 0/20" "$(scope "$d" yes "$mutant")"
}

test_the_same_record_for_an_unquarantined_target_is_not_a_reproduction() {
  local d; d="$(mktmpd)"
  baseline_with "$d" --record passedOnRetry
  assert_eq "the judge, not the baseline, treats it as a wiring disagreement" "rc=0 pass 0/20" "$(scope "$d" no)"
}

test_a_build_failure_a_harness_error_and_an_unexecuted_target_are_excluded() {
  local d i; d="$(mktmpd)"
  it "$d" 1 --kind FAIL --outcome failed
  it "$d" 2 --kind FAIL --reason "no 'Test run with N tests' summary — truncated log (rc=1)" --outcome absent --log "error: compile failed"
  # Iteration 3 has no row at all: the harness died mid-loop.
  it "$d" 4 --kind FAIL --reason "ran 0 tests, below the measured floor of 1 — the filter matched less" --outcome absent
  for i in $(seq 5 20); do it "$d" "$i"; done
  # Three exclusions is past the abort limit, so this run aborts; the
  # classification is still written, one reason per iteration.
  assert_eq "three exclusions: abort" "rc=4 - -/-" "$(scope "$d")"
  local classes; classes="$(cat "$d/classes.tsv")"
  assert_contains "a build failure (no summary) is excluded" "$classes" $'2\texcluded\tthe target never executed'
  assert_contains "a harness error (no row) is excluded" "$classes" $'3\texcluded\tno result row (harness error)'
  assert_contains "an unexecuted target is excluded" "$classes" $'4\texcluded\tthe target never executed'
  # Two of them: excluded from both f and v, so one reproduction is p = 1/18.
  d="$(mktmpd)"
  it "$d" 1 --kind FAIL --outcome failed
  it "$d" 2 --kind FAIL --reason "no 'Test run with N tests' summary — truncated log (rc=1)" --outcome absent
  for i in $(seq 4 20); do it "$d" "$i"; done
  assert_eq "excluded from f and v: p = 1/18" "rc=0 test 1/18" "$(scope "$d")"
}

test_broken_retry_wiring_excludes_the_iteration() {
  local d; d="$(mktmpd)"
  it "$d" 1 --metrics missing
  it "$d" 2 --log "warning: retry metrics disabled — open failed"
  local i; for i in $(seq 3 20); do it "$d" "$i"; done
  assert_eq "a missing ledger and the writer's warning both exclude" "rc=0 pass 0/18" "$(scope "$d")"
}

test_three_exclusions_abort_and_two_do_not() {
  local d i mutant; d="$(mktmpd)"
  for i in 1 2; do it "$d" "$i" --outcome absent; done
  for i in $(seq 3 20); do it "$d" "$i"; done
  assert_eq "two exclusions: a result" "rc=0 pass 0/18" "$(scope "$d")"
  d="$(mktmpd)"
  for i in 1 2 3; do it "$d" "$i" --outcome absent; done
  for i in $(seq 4 20); do it "$d" "$i"; done
  assert_eq "three exclusions: abort with exit 4 and no scope" "rc=4 - -/-" "$(scope "$d")"
  assert_contains "the baseline says why" "$(cat "$d/baseline.md")" "the attempt aborts"
  mutant="$(mutant_of 's/^    if x > max_excluded:$/    if x > max_excluded + 1:/' "$VPY")"
  rm -f "$d/scope"
  assert_eq "mutation: a looser limit lets it through" "rc=0 pass 0/17" "$(scope "$d" no "$mutant")"
}

# ============================================================================
# planning N (spec §6.3, §9)
# ============================================================================

# plan_for F V [SCOPE] [OVERRIDES] [DIR] -> the plan JSON
plan_for() {
  local f="$1" v="$2" sc="${3:-test}" over="${4:-:}" dir="${5:-$HERE}" b
  b="$(mktmpd)"
  echo "$f" > "$b/f"; echo "$v" > "$b/v"
  bash -c 'source "$1"; eval "$2"; main plan-iterations --scope "$3" --baseline-dir "$4" --out "$4/plan.json"' _ \
    "$dir/flake-verify.sh" "$over" "$sc" "$b" > /dev/null 2>&1
  cat "$b/plan.json" 2>/dev/null
}
field() { jq -r ".$2" <<< "$1"; }

# A test-scope cap high enough that no case below is capped: floor(1140 / 10).
ROOMY='TEST_T_S=10'

test_p_0_05_gives_59() {
  local p mutant
  p="$(plan_for 1 20 test "$ROOMY")"
  assert_eq "N" "59" "$(field "$p" n)"
  assert_eq "bound reached" "reached" "$(field "$p" bound)"
  assert_eq "false pass under 5%" "true" "$(jq '.false_pass < 0.05' <<< "$p")"
  assert_eq "not weak" "false" "$(field "$p" weak)"
  mutant="$(mutant_of 's/math\.ceil\(math\.log\(FALSE_PASS_TARGET\)/math.floor(math.log(FALSE_PASS_TARGET)/' "$VPY")"
  assert_eq "mutation: floor instead of ceil gives 58" "58" "$(field "$(plan_for 1 20 test "$ROOMY" "$mutant")" n)"
}

test_p_0_15_is_raised_to_20() {
  local mutant
  assert_eq "ceil(ln .05 / ln .85) = 19, raised to 20" "20" "$(field "$(plan_for 3 20)" n)"
  assert_eq "under the cap: bound reached" "reached" "$(field "$(plan_for 3 20)" bound)"
  mutant="$(mutant_of 's/, min_n\)$/, 0)/' "$VPY")"
  assert_eq "mutation: without the floor of 20 it runs 19" "19" "$(field "$(plan_for 3 20 test : "$mutant")" n)"
}

test_p_1_gives_20() {
  assert_eq "a test that failed every valid iteration runs 20" "20" "$(field "$(plan_for 18 18)" n)"
}

# At the shipped constants the test-scope cap is 45, below the 59 that p = 0.05
# needs: the measured CI timings make this the case for a rare flake.
test_a_cap_below_n_runs_the_cap_and_states_the_false_pass() {
  local p mutant
  p="$(plan_for 1 20)"
  assert_eq "N is the cap" "45" "$(field "$p" n)"
  assert_eq "bound not reached" "not-reached" "$(field "$p" bound)"
  assert_eq "false pass 0.95^45" "0.0994" "$(field "$p" false_pass)"
  assert_eq "weak" "true" "$(field "$p" weak)"
  mutant="$(mutant_of 's/^    n = min\(wanted, test_cap\)$/    n = wanted/' "$VPY")"
  assert_eq "mutation: ignoring the cap runs 59" "59" "$(field "$(plan_for 1 20 test : "$mutant")" n)"
}

test_pass_scope_runs_the_cap_with_the_bound_unknown() {
  local p
  p="$(plan_for 0 20 pass)"
  assert_eq "N is the pass cap" "5" "$(field "$p" n)"
  assert_eq "bound unknown" "unknown" "$(field "$p" bound)"
  assert_eq "no false-pass figure" "null" "$(field "$p" false_pass)"
  assert_eq "weak" "true" "$(field "$p" weak)"
  assert_eq "scale at p = 0.05" "0.774" "$(jq -r '.scale["0.05"]' <<< "$p")"
  assert_eq "scale at p = 0.15" "0.444" "$(jq -r '.scale["0.15"]' <<< "$p")"
}

test_the_caps_come_from_the_formula() {
  assert_eq "test cap floor((1440 - 300 - 0) / 25)" "45" "$(field "$(plan_for 1 20)" cap)"
  assert_eq "pass cap floor((1440 - 300 - 169) / 171)" "5" "$(field "$(plan_for 0 20 pass)" cap)"
}

# ============================================================================
# the wrappers' argv, against a stub stress loop
# ============================================================================

# stub_dir [EXIT] [OUTPUT]: flake-verify.sh beside a stress loop that records
# its argv to argv.txt and exits EXIT after printing OUTPUT.
stub_dir() {
  local d; d="$(mktmpd)"
  cp "$VERIFY" "$VPY" "$HERE/flake_lib.py" "$d/"
  cat > "$d/nightly-flake-stress.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$d/argv.txt"
echo "${2:-}"
exit ${1:-0}
EOF
  printf '%s' "$d"
}

test_baseline_passes_twenty_iterations_and_all_outputs() {
  local d out argv
  d="$(stub_dir)"; out="$(mktmpd)/b"
  bash "$d/flake-verify.sh" baseline --test "$HOLDER" --quarantined no --out-dir "$out" > /dev/null 2>&1
  argv="$(tr '\n' ' ' < "$d/argv.txt")"
  assert_contains "the test alone" "$argv" "--test $HOLDER "
  assert_contains "twenty iterations" "$argv" "--iterations 20 "
  assert_contains "xunit" "$argv" "--xunit-dir $out/xunit "
  assert_contains "metrics" "$argv" "--metrics-dir $out/metrics "
  assert_contains "logs" "$argv" "--log-dir $out/logs "
  assert_contains "results" "$argv" "--results-tsv $out/results.tsv "
}

test_a_harness_error_in_the_baseline_exits_two() {
  local d rc=0
  d="$(stub_dir 2 "nightly-flake-stress: BUILD FAILED")"
  bash "$d/flake-verify.sh" baseline --test "$HOLDER" --quarantined no --out-dir "$(mktmpd)/b" > /dev/null 2>&1 || rc=$?
  assert_eq "exit 2" "2" "$rc"
}

test_stress_passes_the_planned_iteration_count() {
  local d out rc=0
  d="$(stub_dir)"; out="$(mktmpd)/s"
  bash "$d/flake-verify.sh" stress --scope test --test "$HOLDER" --iterations 59 --out-dir "$out" || rc=$?
  assert_eq "a run that happened exits 0" "0" "$rc"
  assert_contains "test scope: --test, N" "$(tr '\n' ' ' < "$d/argv.txt")" "--test $HOLDER --iterations 59 "
  bash "$d/flake-verify.sh" stress --scope pass --test "$HOLDER" --iterations 9 --out-dir "$out" > /dev/null
  assert_contains "pass scope: --pass-of" "$(tr '\n' ' ' < "$d/argv.txt")" "--pass-of $HOLDER --iterations 9 "
  rc=0; d="$(stub_dir 1)"
  bash "$d/flake-verify.sh" stress --scope test --test "$HOLDER" --iterations 5 --out-dir "$out" || rc=$?
  assert_eq "failing iterations still exit 0: the judge decides" "0" "$rc"
}

test_a_candidate_that_does_not_build_is_judged_not_errored() {
  local d out rc=0 v
  d="$(stub_dir 2 "nightly-flake-stress: BUILD FAILED — error: cannot find X in scope")"; out="$(mktmpd)/s"
  bash "$d/flake-verify.sh" stress --scope test --test "$HOLDER" --iterations 5 --out-dir "$out" || rc=$?
  assert_eq "a build failure exits 0" "0" "$rc"
  rc=0; bash "$VERIFY" judge --scope test --test "$HOLDER" --dir "$out" --iterations 5 --quarantined no > /dev/null 2>&1 || rc=$?
  v="$(cat "$out/verdict.json")"
  assert_eq "and the judge fails it" "1 fail" "$rc $(jq -r .verdict <<< "$v")"
  assert_contains "with the build log for the second try" "$(cat "$out/failing-lines.txt")" "cannot find X in scope"
  rc=0; d="$(stub_dir 2 "nightly-flake-stress: unknown argument")"
  bash "$d/flake-verify.sh" stress --scope test --test "$HOLDER" --iterations 5 --out-dir "$(mktmpd)/s" 2>/dev/null || rc=$?
  assert_eq "any other harness error exits 2" "2" "$rc"
}

# ============================================================================
# the judge (spec §6.4)
# ============================================================================

# judge D [scope] [n] [quarantined] [DIR] [extra...] -> "rc=<n> <verdict>"
judge() {
  local d="$1" sc="${2:-test}" n="${3:-3}" q="${4:-no}" dir="${5:-$HERE}" rc=0; shift 5 2>/dev/null || shift $#
  bash "$dir/flake-verify.sh" judge --scope "$sc" --test "$HOLDER" --dir "$d" --iterations "$n" --quarantined "$q" "$@" > /dev/null 2>&1 || rc=$?
  echo "rc=$rc $(jq -r .verdict "$d/verdict.json" 2>/dev/null)"
}
three() { local d; d="$(mktmpd)"; it "$d" 1 "$@"; it "$d" 2; it "$d" 3; printf '%s' "$d"; }

test_a_clean_test_scope_run_passes() { assert_eq "clean" "rc=0 pass" "$(judge "$(three)")"; }

# A refused candidate (apply-candidate exit 3) is the candidate's failure:
# the verdict says so, lists the paths as protected, and blames no harness.
test_a_refused_candidate_fails_with_its_reason() {
  local d p mutant; d="$(mktmpd)"; p="$(mktmpd)/protected.txt"
  echo "the candidate commits files under a build directory: .build/x" > "$d/candidate-refused"
  echo ".build/x" > "$p"
  assert_eq "fails" "rc=1 fail" "$(judge "$d" test 3 no "$HERE" --protected-touched "$p")"
  assert_eq "naming the refusal, not the harness" "the verifier refused to apply the candidate" "$(jq -r '.reasons[0]' "$d/verdict.json")"
  assert_eq "with the paths protected" ".build/x" "$(jq -r '.protected[0]' "$d/verdict.json")"
  assert_contains "and the reason for the second try" "$(cat "$d/failing-lines.txt")" "under a build directory"
  mutant="$(mutant_of 's/^    for marker, reason in \(\("candidate-refused", "the verifier refused to apply the candidate"\),$/    for marker, reason in (("never-written", "x"),/' "$VPY")"
  rm -f "$d/verdict.json"; judge "$d" test 3 no "$mutant" --protected-touched "$p" > /dev/null
  assert_lacks "mutation: without the marker it is not named" "$(jq -r '.reasons[0]' "$d/verdict.json")" "refused"
}

test_a_failing_iteration_fails_at_test_scope() {
  local d; d="$(three --kind FAIL --outcome failed)"
  assert_eq "a failing iteration" "rc=1 fail" "$(judge "$d")"
  assert_eq "counted" "1" "$(jq -r .target_failures "$d/verdict.json")"
  assert_contains "the failing lines name the iteration" "$(cat "$d/failing-lines.txt")" "iteration 1: the target failed"
}

test_a_wedged_iteration_fails() {
  assert_eq "wedged" "rc=1 fail" "$(judge "$(three --kind FAIL --reason "wedged — no completion" --outcome absent)" pass)"
}

test_a_missing_iteration_row_fails() {
  local d mutant; d="$(mktmpd)"
  it "$d" 1; it "$d" 2
  assert_eq "2 rows for 3 planned" "rc=1 fail" "$(judge "$d")"
  assert_contains "truncated" "$(jq -r '.reasons[0]' "$d/verdict.json")" "truncated run"
  mutant="$(mutant_of 's/^    if len\(names\) != 1 or sorted\(r.iteration for r in rows\) != list\(range\(1, n \+ 1\)\):$/    if False:/' "$VPY")"
  assert_eq "mutation: without the row count it passes" "rc=0 pass" "$(judge "$d" test 3 no "$mutant")"
}

test_a_target_absent_from_xunit_fails() {
  local d mutant; d="$(three --outcome absent)"
  assert_eq "absent: a deleted test cannot pass by running nothing" "rc=1 fail" "$(judge "$d")"
  mutant="$(mutant_of 's/^        if not mine:$/        if False:/' "$VPY")"
  assert_eq "mutation: without the presence check it passes" "rc=0 pass" "$(judge "$d" test 3 no "$mutant")"
}

test_a_skipped_target_fails() {
  local d mutant; d="$(three --outcome skipped)"
  assert_eq "skipped is not passed" "rc=1 fail" "$(judge "$d")"
  mutant="$(mutant_of 's/^        elif any\(c.outcome != "passed" for c in mine\):$/        elif False:/' "$VPY")"
  assert_eq "mutation: treating skipped as passed passes" "rc=0 pass" "$(judge "$d" test 3 no "$mutant")"
}

test_the_judge_reads_both_swiftpm_files() {
  local d mutant; d="$(three --xctest)"
  it "$d" 4 --xctest; sed -i.bak '$d' "$d/results.tsv"
  assert_eq "a target in the XCTest file counts" "rc=0 pass" "$(judge "$d")"
  d="$(three)"
  mutant="$(mutant_of 's/^        wanted = \{f"\{stem\}.xml", f"\{stem\}-swift-testing.xml"\}$/        wanted = {f"{stem}.xml"}/' "$HERE/flake_lib.py")"
  assert_eq "mutation: reading only T-i.xml loses every Swift Testing case" "rc=1 fail" "$(judge "$d" test 3 no "$mutant")"
}

test_another_test_failing_at_pass_scope_does_not_fail_the_candidate() {
  local d; d="$(three --kind FAIL --other-failed "TBDSharedTests.OtherTests/flaps()")"
  assert_eq "pass scope: the target passed" "rc=0 pass" "$(judge "$d" pass)"
  assert_eq "the other failure is listed" '["TBDSharedTests.OtherTests/flaps()"]' "$(jq -c .other_failures "$d/verdict.json")"
  assert_contains "and named in the PR text" "$(cat "$d/verdict.md")" "TBDSharedTests.OtherTests/flaps()"
}

test_the_same_other_failure_at_test_scope_fails() {
  assert_eq "test scope: any failing row fails" "rc=1 fail" "$(judge "$(three --kind FAIL --other-failed "TBDSharedTests.OtherTests/flaps()")" test)"
}

test_a_missing_retry_ledger_fails() {
  local d mutant; d="$(three --metrics missing)"
  assert_eq "missing" "rc=1 fail" "$(judge "$d")"
  assert_contains "says so" "$(jq -r '.reasons[0]' "$d/verdict.json")" "retry ledger missing or unreadable"
  mutant="$(mutant_of 's/^        return None, f"retry ledger missing or unreadable \(\{error\}\)"$/        return [], None/' "$VPY")"
  assert_eq "mutation: without the check it passes" "rc=0 pass" "$(judge "$d" test 3 no "$mutant")"
}

test_an_unparseable_retry_line_fails() { assert_eq "garbage line" "rc=1 fail" "$(judge "$(three --metrics garbage)")"; }

test_the_writer_warning_in_the_log_fails() {
  local d mutant; d="$(three --log "warning: retry metrics disabled — open failed: EACCES")"
  assert_eq "the writer's warning" "rc=1 fail" "$(judge "$d")"
  mutant="$(mutant_of 's/^    if DISABLED_WARNING in text:$/    if False:/' "$VPY")"
  assert_eq "mutation: without the warning check it passes" "rc=0 pass" "$(judge "$d" test 3 no "$mutant")"
}

quarantined_three() { local d; d="$(mktmpd)"; it "$d" 1 "$@"; it "$d" 2 --record passedFirstTry; it "$d" 3 --record passedFirstTry; printf '%s' "$d"; }

test_a_quarantined_target_with_no_record_fails() {
  local d mutant; d="$(quarantined_three)"
  assert_eq "no record" "rc=1 fail" "$(judge "$d" test 3 yes)"
  mutant="$(mutant_of 's/^            if not records:$/            if False:/' "$VPY")"
  assert_eq "mutation: accepting zero records passes" "rc=0 pass" "$(judge "$d" test 3 yes "$mutant")"
}

test_a_quarantined_target_passed_on_retry_fails() {
  assert_eq "passedOnRetry" "rc=1 fail" "$(judge "$(quarantined_three --record passedFirstTry --record passedOnRetry)" test 3 yes)"
}

test_a_quarantined_target_all_first_try_passes() {
  assert_eq "all passedFirstTry" "rc=0 pass" "$(judge "$(quarantined_three --record passedFirstTry)" test 3 yes)"
}

test_an_unquarantined_target_with_an_empty_ledger_passes() {
  assert_eq "an empty file is a pass for this check" "rc=0 pass" "$(judge "$(three)" test 3 no)"
}

test_an_unquarantined_target_with_a_record_fails() {
  assert_eq "inventory and build disagree" "rc=1 fail" "$(judge "$(three --record passedFirstTry)" test 3 no)"
}

test_nested_suite_records_match_by_normalised_id() {
  local d i mutant rc=0; d="$(mktmpd)"
  for i in 1 2 3; do it "$d" "$i" --target "$NESTED" --record passedFirstTry --record-id 'TBDDaemonTests.TBDHomeSerialized/AutoCloseSetupTests/closesAfterSetup()'; done
  bash "$VERIFY" judge --scope test --test "$NESTED" --dir "$d" --iterations 3 --quarantined yes > /dev/null 2>&1 || rc=$?
  assert_eq "M.A/B/f() matches M.A.B/f()" "0" "$rc"
  mutant="$(mutant_of 's/fl\.from_retry_metrics_id\(r\["testID"\]\) == test/r["testID"] == test/' "$VPY")"
  rc=0; bash "$mutant/flake-verify.sh" judge --scope test --test "$NESTED" --dir "$d" --iterations 3 --quarantined yes > /dev/null 2>&1 || rc=$?
  assert_eq "mutation: without normalisation no record matches" "1" "$rc"
}

test_the_verdict_carries_n_p_bound_and_false_pass() {
  local d plan v
  d="$(three)"; plan="$(mktmpd)/plan.json"
  echo '{"n": 3, "p": 0.05, "cap": 82, "bound": "reached", "false_pass": 0.0485, "weak": false, "scale": null}' > "$plan"
  judge "$d" test 3 no "$HERE" --plan "$plan" > /dev/null
  v="$(cat "$d/verdict.json")"
  assert_eq "n p cap bound false_pass" "3 0.05 82 reached 0.0485 false" "$(jq -r '"\(.n) \(.p) \(.cap) \(.bound) \(.false_pass) \(.weak)"' <<< "$v")"
  assert_contains "the md states the probability is not a confidence bound" "$(cat "$d/verdict.md")" "not a confidence bound"
  assert_contains "and the limit" "$(cat "$d/verdict.md")" "not proof of a fix"
  echo '{"n": 3, "p": null, "cap": 9, "bound": "unknown", "false_pass": null, "weak": true, "scale": {"0.05": 0.857, "0.15": 0.614}}' > "$plan"
  d="$(three)"; judge "$d" pass 3 no "$HERE" --plan "$plan" > /dev/null
  assert_eq "pass scope: unknown" "unknown null true" "$(jq -r '"\(.bound) \(.false_pass) \(.weak)"' "$d/verdict.json")"
  assert_contains "the md gives both scale figures" "$(cat "$d/verdict.md")" "85.7% of the time against a flake with p = 0.05, and 61.4% against p = 0.15"
}

test_a_protected_path_makes_a_pass_ineligible() {
  local d p; d="$(three)"; p="$(mktmpd)/protected.txt"
  echo "scripts/test.sh" > "$p"
  assert_eq "clean stress, protected file: ineligible" "rc=3 ineligible" "$(judge "$d" test 3 no "$HERE" --protected-touched "$p")"
  assert_contains "the md says a human must judge it" "$(cat "$d/verdict.md")" "a human must judge this change"
}

# ============================================================================
# a renamed or retired target (spec §6.4)
# ============================================================================

CLOCK='TBDDaemonTests.ClockTestSupportTests/advanceWhenSuspendedMovesTheClockForward()'
NEWCLOCK='TBDDaemonTests.ClockTestSupportTests/advanceWhenSuspendedFiresTheEventDrivenClock()'
CLOCK_SRC='struct ClockTestSupportTests {
    @Test func advanceWhenSuspendedMovesTheClockForward() async {
        let clock = TestClock()
    }
}
extension ClockTestSupportTests {
    @Test func sleepReturnsOnAdvance() async {}
}'

# change_repo BASE CANDIDATE -> D: a throwaway repo D/r whose HEAD commits
# CANDIDATE over BASE in the clock suite's file; D/base holds the base SHA.
change_repo() {
  local d path=Tests/TBDDaemonTests/ClockTestSupportTests.swift
  d="$(mktmpd)"
  git init -q "$d/r"
  mkdir -p "$d/r/Tests/TBDDaemonTests"
  printf '%s\n' "$1" > "$d/r/$path"
  git -C "$d/r" add -A && git -C "$d/r" commit -q -m base
  git -C "$d/r" rev-parse HEAD > "$d/base"
  printf '%s\n' "$2" > "$d/r/$path"
  git -C "$d/r" commit -q -am candidate
  printf '%s' "$d"
}
# change D NOTES [DIR] -> the target-change JSON for CLOCK, NOTES as the notes.
change() {
  local d="$1" dir="${3:-$HERE}"
  printf '%s\n' "$2" > "$d/notes.md"
  (cd "$d/r" && bash "$dir/flake-verify.sh" target-change --test "$CLOCK" --base "$(cat "$d/base")" --notes "$d/notes.md")
}
kind_of() { jq -r '"\(.kind) \(.stressed)"' <<< "$1"; }

test_a_declared_rename_the_diff_bears_out_is_stressed_under_the_new_id() {
  local d out mutant
  d="$(change_repo "$CLOCK_SRC" "${CLOCK_SRC/advanceWhenSuspendedMovesTheClockForward/advanceWhenSuspendedFiresTheEventDrivenClock}")"
  out="$(change "$d" "Diagnosis: …
- RENAMED: \`$CLOCK\` -> \`$NEWCLOCK\`")"
  assert_eq "renamed, and the new ID is the one stressed" "renamed $NEWCLOCK" "$(kind_of "$out")"
  assert_eq "it records what it was renamed from" "$CLOCK" "$(jq -r .from <<< "$out")"
  mutant="$(mutant_of 's/^    added = func_net\(lines, new_module, new_files, new_func\) < 0$/    added = False/' "$VPY")"
  assert_eq "mutation: a rename the diff must also bear out on the new side" "none $CLOCK" "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> $NEWCLOCK" "$mutant")")"
}

test_a_renamed_suite_is_a_rename() {
  local d out new='TBDDaemonTests.TestClockTests/advanceWhenSuspendedMovesTheClockForward()'
  d="$(change_repo "$CLOCK_SRC" "${CLOCK_SRC//ClockTestSupportTests/TestClockTests}")"
  out="$(change "$d" "RENAMED: $CLOCK -> $new")"
  assert_eq "the suite's declaration moved, so the test did" "renamed $new" "$(kind_of "$out")"
}

test_a_declared_rename_that_keeps_the_old_test_is_not_honored() {
  local d out mutant
  # The new test is added beside the old, which still exists.
  d="$(change_repo "$CLOCK_SRC" "$CLOCK_SRC
extension ClockTestSupportTests {
    @Test func advanceWhenSuspendedFiresTheEventDrivenClock() async {}
}")"
  out="$(change "$d" "RENAMED: $CLOCK -> $NEWCLOCK")"
  assert_eq "not honored: the old ID is stressed" "none $CLOCK" "$(kind_of "$out")"
  assert_contains "and the declaration is kept, with why" "$(jq -r .rejected <<< "$out")" "neither takes the target's function out"
  mutant="$(mutant_of 's/^    if not \(removed or suite_gone\):$/    if False:/' "$VPY")"
  assert_eq "mutation: without the removal check it is a rename" "renamed $NEWCLOCK" "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> $NEWCLOCK" "$mutant")")"
}

test_an_undeclared_rename_changes_nothing() {
  local d out
  d="$(change_repo "$CLOCK_SRC" "${CLOCK_SRC/advanceWhenSuspendedMovesTheClockForward/advanceWhenSuspendedFiresTheEventDrivenClock}")"
  out="$(change "$d" "Renamed the test to say what it checks now.")"
  assert_eq "no declaration: the old ID is stressed, and is absent" "none $CLOCK" "$(kind_of "$out")"
  assert_eq "nothing declared" "null" "$(jq -r .declared <<< "$out")"
}

test_a_declared_retirement_that_removes_the_function_stresses_nothing() {
  local d out mutant
  d="$(change_repo "$CLOCK_SRC" 'struct ClockTestSupportTests {
}
extension ClockTestSupportTests {
    @Test func sleepReturnsOnAdvance() async {}
}')"
  out="$(change "$d" "RETIRED: $CLOCK — the clock it tested was removed")"
  assert_eq "retired, with nothing to stress" "retired null" "$(kind_of "$out")"
  assert_eq "with the session's reason" "the clock it tested was removed" "$(jq -r .reason <<< "$out")"
  mutant="$(mutant_of 's/^RETIRED_LINE = .*$/RETIRED_LINE = re.compile(r"$^")/' "$VPY")"
  assert_eq "mutation: without the declaration it is no retirement" "none $CLOCK" "$(kind_of "$(change "$d" "RETIRED: $CLOCK — x" "$mutant")")"
}

test_a_retirement_that_keeps_the_function_is_not_honored() {
  local d out mutant
  # Only an extension of the suite goes; the target is still declared.
  d="$(change_repo "$CLOCK_SRC" 'struct ClockTestSupportTests {
    @Test func advanceWhenSuspendedMovesTheClockForward() async {
        let clock = TestClock()
    }
}')"
  out="$(change "$d" "RETIRED: $CLOCK -- obsolete")"
  assert_eq "not honored" "none $CLOCK" "$(kind_of "$out")"
  mutant="$(mutant_of 's/^    removed = func_net\(lines, module, old_files, func\) > 0$/    removed = True/' "$VPY")"
  assert_eq "mutation: without the removal check it would retire" "retired null" "$(kind_of "$(change "$d" "RETIRED: $CLOCK -- obsolete" "$mutant")")"
}

# files_repo -> D: a throwaway repo D/r with two suites in two files of one
# module, each declaring `func shared()`, at D/base; the caller edits and
# commits the candidate.
OTHER_SRC='struct OtherSuiteTests {
    @Test func advanceWhenSuspendedMovesTheClockForward() async {}
}'
files_repo() {
  local d; d="$(mktmpd)"
  git init -q "$d/r"; mkdir -p "$d/r/Tests/TBDDaemonTests"
  printf '%s\n' "$CLOCK_SRC" > "$d/r/Tests/TBDDaemonTests/ClockTestSupportTests.swift"
  printf '%s\n' "$OTHER_SRC" > "$d/r/Tests/TBDDaemonTests/OtherSuiteTests.swift"
  git -C "$d/r" add -A && git -C "$d/r" commit -q -m base
  git -C "$d/r" rev-parse HEAD > "$d/base"
  printf '%s' "$d"
}

test_a_same_named_function_in_another_suite_proves_nothing() {
  local d
  d="$(files_repo)"
  # The other suite's same-named test goes; the target stays.
  printf 'struct OtherSuiteTests {\n}\n' > "$d/r/Tests/TBDDaemonTests/OtherSuiteTests.swift"
  git -C "$d/r" commit -q -am candidate
  assert_eq "a retirement is not honored" "none $CLOCK" "$(kind_of "$(change "$d" "RETIRED: $CLOCK — gone")")"
  # A commented-out declaration that goes is no removal of the test.
  d="$(change_repo "$CLOCK_SRC
// func advanceWhenSuspendedMovesTheClockForward() {}" "$CLOCK_SRC")"
  assert_eq "nor does deleting a comment that looks like it" "none $CLOCK" "$(kind_of "$(change "$d" "RETIRED: $CLOCK — gone")")"
}

test_a_move_to_another_suite_keeping_the_name_is_a_rename() {
  local d moved='TBDDaemonTests.OtherSuiteTests/advanceWhenSuspendedFires()' mutant
  d="$(files_repo)"
  printf '%s\n' "${CLOCK_SRC/advanceWhenSuspendedMovesTheClockForward/unrelatedStays}" > "$d/r/Tests/TBDDaemonTests/ClockTestSupportTests.swift"
  printf 'struct OtherSuiteTests {\n    @Test func advanceWhenSuspendedMovesTheClockForward() async {}\n    @Test func advanceWhenSuspendedFires() async {}\n}\n' > "$d/r/Tests/TBDDaemonTests/OtherSuiteTests.swift"
  git -C "$d/r" commit -q -am candidate
  assert_eq "moved and renamed into the other suite's file" "renamed $moved" "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> $moved")")"
  mutant="$(mutant_of 's/^    old_files = suite_files\(base_decls, module, suite\) if suite else None$/    old_files = set()/' "$VPY")"
  assert_eq "mutation: without the base's suite files nothing counts" "none $CLOCK" "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> $moved" "$mutant")")"
  # The same function name, moved to a suite in another file of the module.
  local same='TBDDaemonTests.ThirdSuiteTests/advanceWhenSuspendedMovesTheClockForward()'
  d="$(files_repo)"
  printf 'struct ThirdSuiteTests {\n}\n' > "$d/r/Tests/TBDDaemonTests/ThirdSuiteTests.swift"
  git -C "$d/r" add -A && git -C "$d/r" commit -q --amend -m base
  git -C "$d/r" rev-parse HEAD > "$d/base"
  printf '%s\n' "${CLOCK_SRC/advanceWhenSuspendedMovesTheClockForward/unrelatedStays}" > "$d/r/Tests/TBDDaemonTests/ClockTestSupportTests.swift"
  printf 'struct ThirdSuiteTests {\n    @Test func advanceWhenSuspendedMovesTheClockForward() async {}\n}\n' > "$d/r/Tests/TBDDaemonTests/ThirdSuiteTests.swift"
  git -C "$d/r" commit -q -am candidate
  assert_eq "a same-name move to another file's suite is a rename" "renamed $same" "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> $same")")"
}

test_a_rename_that_only_drops_a_suite_extension_is_not_honored() {
  local d
  d="$(change_repo "$CLOCK_SRC" 'struct ClockTestSupportTests {
    @Test func advanceWhenSuspendedMovesTheClockForward() async {
        let clock = TestClock()
    }
    @Test func somethingNew() async {}
}')"
  assert_eq "the target is still there" "none $CLOCK" \
    "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> TBDDaemonTests.ClockTestSupportTests/somethingNew()")")"
}

test_conflicting_or_foreign_declarations_are_not_honored() {
  local d
  d="$(change_repo "$CLOCK_SRC" "${CLOCK_SRC/advanceWhenSuspendedMovesTheClockForward/advanceWhenSuspendedFiresTheEventDrivenClock}")"
  assert_eq "two different declarations for the target" "none $CLOCK" "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> $NEWCLOCK
RETIRED: $CLOCK — gone")")"
  assert_eq "a declaration for another test" "none $CLOCK" "$(kind_of "$(change "$d" "RENAMED: TBDDaemonTests.OtherTests/x() -> $NEWCLOCK")")"
  assert_eq "a new ID not in the xunit form" "none $CLOCK" "$(kind_of "$(change "$d" "RENAMED: $CLOCK -> advanceWhenSuspendedFiresTheEventDrivenClock")")"
}

test_a_symlinked_notes_file_declares_nothing() {
  local d out
  d="$(change_repo "$CLOCK_SRC" "${CLOCK_SRC/advanceWhenSuspendedMovesTheClockForward/advanceWhenSuspendedFiresTheEventDrivenClock}")"
  printf 'RENAMED: %s -> %s\n' "$CLOCK" "$NEWCLOCK" > "$d/elsewhere.md"
  ln -s "$d/elsewhere.md" "$d/link.md"
  out="$(cd "$d/r" && bash "$VERIFY" target-change --test "$CLOCK" --base "$(cat "$d/base")" --notes "$d/link.md")"
  assert_eq "the session wrote the path; a link reads as no notes" "none $CLOCK" "$(kind_of "$out")"
  out="$(cd "$d/r" && bash "$VERIFY" target-change --test "$CLOCK" --base "$(cat "$d/base")" --notes "$d/missing.md")"
  assert_eq "and so does no notes file" "none $CLOCK" "$(kind_of "$out")"
}

NEWHOLDER='TBDSharedTests.HolderLockTests/lockIsFreedOnRelease()'
# change_file KIND [TO] -> a target-change file for HOLDER, as the stress step writes it.
change_file() {
  local f; f="$(mktmpd)/target-change.json"
  case "$1" in
    renamed) jq -n --arg f "$HOLDER" --arg t "$2" '{kind: "renamed", from: $f, to: $t, reason: null, stressed: $t, declared: "x", rejected: null}' > "$f" ;;
    retired) jq -n --arg f "$HOLDER" '{kind: "retired", from: $f, to: null, reason: "gone", stressed: null, declared: "x", rejected: null}' > "$f" ;;
    rejected) jq -n --arg f "$HOLDER" '{kind: "none", from: $f, to: null, reason: null, stressed: $f, declared: "x", rejected: "the diff takes neither"}' > "$f" ;;
  esac
  printf '%s' "$f"
}

test_a_renamed_target_is_judged_under_its_new_id_and_never_eligible() {
  local d c mutant
  d="$(mktmpd)"; it "$d" 1 --target "$NEWHOLDER"; it "$d" 2 --target "$NEWHOLDER"; it "$d" 3 --target "$NEWHOLDER"
  c="$(change_file renamed "$NEWHOLDER")"
  assert_eq "clean under the new ID, but a human must judge" "rc=3 ineligible" "$(judge "$d" test 3 no "$HERE" --target-change "$c")"
  assert_eq "the verdict carries the change" "renamed $NEWHOLDER" "$(jq -r '"\(.target_change.kind) \(.target_change.to)"' "$d/verdict.json")"
  assert_contains "the md says it was renamed and why it waits" "$(cat "$d/verdict.md")" "A human must judge whether coverage is preserved"
  assert_eq "without the change, the old ID is absent and fails" "rc=1 fail" "$(judge "$d")"
  mutant="$(mutant_of 's/"ineligible" if protected or changed else "pass"/"ineligible" if protected else "pass"/' "$VPY")"
  assert_eq "mutation: a rename would be promotable" "rc=0 pass" "$(judge "$d" test 3 no "$mutant" --target-change "$c")"
  d="$(three)"
  assert_eq "a rename whose new ID never ran fails" "rc=1 fail" "$(judge "$d" test 3 no "$HERE" --target-change "$c")"
}

test_a_retired_target_runs_nothing_and_claims_no_verdict() {
  local d c mutant
  d="$(mktmpd)"; c="$(change_file retired)"
  assert_eq "nothing ran, and it is not eligible" "rc=3 ineligible" "$(judge "$d" test 45 no "$HERE" --target-change "$c")"
  assert_eq "no iterations or evidence are claimed" "0 0 null false" "$(jq -r '"\(.iterations) \(.n) \(.false_pass) \(.weak)"' "$d/verdict.json")"
  assert_contains "the md says nothing was stress-run" "$(cat "$d/verdict.md")" "Nothing was stress-run and no stress verdict is claimed"
  assert_lacks "and states no result" "$(cat "$d/verdict.md")" "**Result:**"
  mutant="$(mutant_of 's/^    if kind == "retired":$/    if False:/' "$VPY")"
  rm -f "$d/verdict.json"
  assert_eq "mutation: judged as a run, it is truncated" "rc=1 fail" "$(judge "$d" test 45 no "$mutant" --target-change "$c")"
}

test_an_absent_target_with_no_honored_change_fails_and_says_how_to_declare() {
  local d c mutant
  d="$(three --outcome absent)"
  assert_eq "fails as always" "rc=1 fail" "$(judge "$d")"
  assert_contains "the second try is told how to declare a rename" "$(cat "$d/failing-lines.txt")" 'RENAMED: <old ID> -> <new ID>'
  c="$(change_file rejected)"
  assert_eq "a declaration the diff did not bear out fails too" "rc=1 fail" "$(judge "$d" test 3 no "$HERE" --target-change "$c")"
  assert_contains "saying why it was not honored" "$(cat "$d/failing-lines.txt")" "was not honored: the diff takes neither"
  mutant="$(mutant_of 's/^    if kind == "none" and any\(r.endswith/    if False and any(r.endswith/' "$VPY")"
  judge "$d" test 3 no "$mutant" > /dev/null
  assert_lacks "mutation: without the hint the second try is not told" "$(cat "$d/failing-lines.txt")" "RENAMED:"
}

test_a_failed_target_change_still_gets_its_harness_verdict() {
  local d f; d="$(mktmpd)"; f="$(mktmpd)/target-change.json"
  echo "target-change failed: git diff failed" > "$d/harness-error"; : > "$f"
  assert_eq "an empty change file is no change; the marker decides" "rc=1 fail" "$(judge "$d" test 3 no "$HERE" --target-change "$f")"
  assert_eq "as a harness error" "the stress harness errored" "$(jq -r '.reasons[0]' "$d/verdict.json")"
}

test_a_target_change_for_another_test_is_malformed() {
  local d c; d="$(three)"; c="$(change_file renamed "$NEWHOLDER")"
  jq '.from = "TBDSharedTests.OtherTests/x()"' "$c" > "$c.x" && mv "$c.x" "$c"
  assert_eq "refused" "rc=2" "$(judge "$d" test 3 no "$HERE" --target-change "$c" | cut -d' ' -f1)"
}

# ============================================================================
# the session transcripts (spec §6.1)
# ============================================================================

# keep RT FROM [DIR] -> "rc=<n>"; the message in RT/said.
keep() {
  local rt="$1" from="$2" dir="${3:-$HERE}" rc=0
  bash "$dir/flake-verify.sh" keep-transcript --from "$from" --runner-temp "$rt" \
    --out "$rt/flakefix-transcripts/session-1.json" > "$rt/said" 2>&1 || rc=$?
  echo "rc=$rc"
}
TRANSCRIPT='[{"type": "assistant", "text": "keep this line"},
 {"type": "tool_result", "text": "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-AbCdEfGhIjKlMnOp_qr-st"},
 {"type": "tool_result", "text": "GITHUB_TOKEN=ghs_0123456789abcdefghijABCDEFGHIJ012345"},
 {"type": "tool_result", "text": "ACTIONS_RUNTIME_TOKEN=eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJydW5uZXIifQ.c2lnbmF0dXJlLXNpZw"}]'

test_a_transcript_is_kept_redacted_and_its_original_removed() {
  local rt out mutant
  rt="$(mktmpd)"; printf '%s\n' "$TRANSCRIPT" > "$rt/claude-execution-output.json"
  assert_eq "kept" "rc=0" "$(keep "$rt" "$rt/claude-execution-output.json")"
  out="$(cat "$rt/flakefix-transcripts/session-1.json")"
  assert_contains "the session's text is there" "$out" "keep this line"
  assert_lacks "no OAuth token" "$out" "sk-ant-oat01"
  assert_lacks "no GitHub token" "$out" "ghs_0123456789"
  assert_lacks "no JWT" "$out" "eyJhbGciOiJSUzI1NiJ9"
  assert_eq "three redactions" "3" "$(grep -o '\[REDACTED\]' <<< "$out" | wc -l | tr -d ' ')"
  assert_contains "and it says how many" "$(cat "$rt/said")" "3 credential-shaped string(s) redacted"
  assert_eq "the original is gone, so the next session's is its own" "no" "$([[ -e "$rt/claude-execution-output.json" ]] && echo yes || echo no)"
  mutant="$(mutant_of "s/^  'sk-ant-/  'sk-zzz-/" "$VERIFY")"
  rt="$(mktmpd)"; printf '%s\n' "$TRANSCRIPT" > "$rt/claude-execution-output.json"
  keep "$rt" "$rt/claude-execution-output.json" "$mutant" > /dev/null
  assert_contains "mutation: without its pattern the token is kept" "$(cat "$rt/flakefix-transcripts/session-1.json")" "sk-ant-oat01"
}

test_only_the_actions_own_execution_file_is_kept() {
  local rt mutant
  rt="$(mktmpd)"; echo SECRET-FILE > "$rt/credentials.json"
  assert_eq "another path is refused" "rc=1" "$(keep "$rt" "$rt/credentials.json")"
  assert_eq "and nothing is copied" "no" "$([[ -e "$rt/flakefix-transcripts/session-1.json" ]] && echo yes || echo no)"
  mutant="$(mutant_of 's/^  if \[\[ "\$from" != "\$rt\/\$EXECUTION_FILE_NAME" \]\]; then$/  if false; then/' "$VERIFY")"
  keep "$rt" "$rt/credentials.json" "$mutant" > /dev/null
  assert_contains "mutation: without the check it would be uploaded" "$(cat "$rt/flakefix-transcripts/session-1.json" 2>/dev/null)" "SECRET-FILE"
  rt="$(mktmpd)"; echo SECRET-FILE > "$rt/credentials.json"; ln -s "$rt/credentials.json" "$rt/claude-execution-output.json"
  assert_eq "a symlink at the action's path is refused" "rc=1" "$(keep "$rt" "$rt/claude-execution-output.json")"
  assert_eq "an action that wrote no file keeps nothing" "rc=1" "$(keep "$rt" "")"
  assert_contains "and says why" "$(cat "$rt/said")" "left no execution file"
}

test_the_transcript_directory_holds_only_regular_files() {
  local rt
  rt="$(mktmpd)"; mkdir -p "$rt/flakefix-transcripts"; echo SECRET-FILE > "$rt/credentials.json"
  ln -s "$rt/credentials.json" "$rt/flakefix-transcripts/planted.json"
  printf '%s\n' "$TRANSCRIPT" > "$rt/claude-execution-output.json"
  assert_eq "kept" "rc=0" "$(keep "$rt" "$rt/claude-execution-output.json")"
  assert_eq "a planted link is removed before the upload" "no" "$([[ -L "$rt/flakefix-transcripts/planted.json" ]] && echo yes || echo no)"
  # A later session that left no execution file still cannot leave a link,
  # or an unredacted file, behind for the upload.
  rt="$(mktmpd)"; mkdir -p "$rt/flakefix-transcripts"; echo SECRET-FILE > "$rt/credentials.json"
  ln -s "$rt/credentials.json" "$rt/flakefix-transcripts/planted.json"
  printf '%s\n' "$TRANSCRIPT" > "$rt/flakefix-transcripts/session-1.json"
  assert_eq "nothing to keep" "rc=1" "$(keep "$rt" "")"
  assert_eq "the link still goes" "no" "$([[ -L "$rt/flakefix-transcripts/planted.json" ]] && echo yes || echo no)"
  assert_lacks "and a file rewritten there is redacted again" "$(cat "$rt/flakefix-transcripts/session-1.json")" "sk-ant-oat01"
}

# ============================================================================
# the candidate: applied exactly, judged in a clean tree
# ============================================================================

# repo_pair -> D, holding D/main (bare-ish origin), D/session and D/verify clones
# at one base commit; prints D. The base carries scripts/test.sh.
repo_pair() {
  local d; d="$(mktmpd)"
  case "$d" in "$SCRATCH"/d.*) ;; *) echo "repo_pair: refusing a repo outside the scratch dir: $d" >&2; exit 2 ;; esac
  git init -q "$d/origin" > /dev/null
  mkdir -p "$d/origin/scripts" "$d/origin/Tests/TBDSharedTests"
  echo 'echo main runner' > "$d/origin/scripts/test.sh"
  echo 'swift' > "$d/origin/Tests/TBDSharedTests/HolderLockTests.swift"
  git -C "$d/origin" add -A && git -C "$d/origin" commit -q -m base > /dev/null
  git clone -q "$d/origin" "$d/session"
  git clone -q "$d/origin" "$d/verify"
  # main's verifier copy, as the workflow takes it before the session.
  mkdir -p "$d/vs"
  cp "$VERIFY" "$VPY" "$HERE/flake_lib.py" "$d/vs/"
  printf '#!/usr/bin/env bash\necho main runner\n' > "$d/vs/test.sh"
  local f; for f in swift-safe remote-verify.sh tbd-home-fingerprint.sh; do echo "# main $f" > "$d/vs/$f"; done
  printf '%s' "$d"
}

test_apply_candidate_applies_exactly_the_bundle() {
  local d base tip out
  d="$(repo_pair)"; base="$(git -C "$d/session" rev-parse HEAD)"
  echo fixed > "$d/session/Tests/TBDSharedTests/HolderLockTests.swift"
  git -C "$d/session" commit -q -am fix
  tip="$(git -C "$d/session" rev-parse HEAD)"
  echo uncommitted >> "$d/session/Tests/TBDSharedTests/HolderLockTests.swift"
  echo junk > "$d/session/untracked.txt"
  git -C "$d/session" bundle create -q "$d/c.bundle" "$base..HEAD" 2>/dev/null
  echo stale > "$d/verify/leftover.txt"; mkdir -p "$d/verify/.build"; echo keep > "$d/verify/.build/cache"
  out="$(cd "$d/verify" && bash "$d/vs/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base")"
  assert_eq "prints the applied head" "$tip" "$out"
  assert_eq "HEAD is the bundle's tip" "$tip" "$(git -C "$d/verify" rev-parse HEAD)"
  assert_eq "the committed change is there" "fixed" "$(cat "$d/verify/Tests/TBDSharedTests/HolderLockTests.swift")"
  assert_eq "the session's uncommitted edit is not" "no" "$(grep -q uncommitted "$d/verify/Tests/TBDSharedTests/HolderLockTests.swift" && echo yes || echo no)"
  assert_eq "nor its untracked file" "no" "$([[ -e "$d/verify/untracked.txt" ]] && echo yes || echo no)"
  assert_eq "the tree's own leftovers are cleaned" "no" "$([[ -e "$d/verify/leftover.txt" ]] && echo yes || echo no)"
  assert_eq ".build survives for an incremental rebuild" "keep" "$(cat "$d/verify/.build/cache")"
}

test_apply_candidate_refuses_a_bundle_not_descending_from_base() {
  local d base side rc=0 mutant
  d="$(repo_pair)"; side="$(git -C "$d/session" rev-parse HEAD)"
  # The verification tree's base moves on; the candidate forks from its parent.
  echo more > "$d/verify/more.txt"; git -C "$d/verify" add more.txt; git -C "$d/verify" commit -q -m newer
  base="$(git -C "$d/verify" rev-parse HEAD)"
  echo x > "$d/session/x.txt"; git -C "$d/session" add x.txt; git -C "$d/session" commit -q -m sidefix
  git -C "$d/session" bundle create -q "$d/c.bundle" "$side..HEAD" 2>/dev/null
  (cd "$d/verify" && bash "$d/vs/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" > /dev/null 2>&1) || rc=$?
  assert_eq "refused with exit 2" "2" "$rc"
  mutant="$(mutant_of 's/^  git merge-base --is-ancestor "\$base" "\$tip" \|\| die .*$/  true/' "$VERIFY")"
  cp "$d/vs/test.sh" "$d/vs/swift-safe" "$d/vs/remote-verify.sh" "$d/vs/tbd-home-fingerprint.sh" "$mutant/"
  rc=0; (cd "$d/verify" && bash "$mutant/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" > /dev/null 2>&1) || rc=$?
  assert_eq "mutation: without the ancestor check it applies" "0" "$rc"
}

test_the_test_runner_is_mains_even_when_the_candidate_edited_it() {
  local d base mutant
  d="$(repo_pair)"; base="$(git -C "$d/session" rev-parse HEAD)"
  echo 'echo candidate runner always green' > "$d/session/scripts/test.sh"
  git -C "$d/session" commit -q -am "edit the runner"
  git -C "$d/session" bundle create -q "$d/c.bundle" "$base..HEAD" 2>/dev/null
  (cd "$d/verify" && bash "$d/vs/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" > /dev/null)
  assert_eq "scripts/test.sh in the verification tree is main's" "$(cat "$d/vs/test.sh")" "$(cat "$d/verify/scripts/test.sh")"
  assert_eq "so is swift-safe" "# main swift-safe" "$(cat "$d/verify/scripts/swift-safe")"
  assert_contains "and the candidate's edit still counts as touching a protected file" \
    "$(cd "$d/verify" && bash "$d/vs/flake-verify.sh" protected-touched --base "$base")" "scripts/test.sh"
  mutant="$(mutant_of 's/^RUNNER_CHAIN=\(.*\)$/RUNNER_CHAIN=()/' "$VERIFY")"
  (cd "$d/verify" && git reset -q --hard "$base" && bash "$mutant/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" > /dev/null)
  assert_eq "mutation: without the runner chain the candidate's runner is used" "echo candidate runner always green" "$(cat "$d/verify/scripts/test.sh")"
}

# ============================================================================
# protected paths (spec §6.4)
# ============================================================================

representative() {
  case "$1" in
    'scripts/flake-*') echo 'scripts/flake-pr.sh' ;;
    'scripts/ci/*') echo 'scripts/ci/watched-test-pass.sh' ;;
    '.build/*') echo '.build/debug/TBDPackageTests' ;;
    '.swiftpm/*') echo '.swiftpm/configuration/mirrors.json' ;;
    *) echo "$1" ;;
  esac
}

test_every_protected_entry_is_load_bearing() {
  local patterns i path got
  patterns="$(bash -c 'source "$1"; printf "%s\n" "${PROTECTED_PATTERNS[@]}"' _ "$VERIFY")"
  i=0
  while IFS= read -r pattern; do
    path="$(representative "$pattern")"
    got="$(bash -c 'source "$1"; is_protected "$2" && echo yes || echo no' _ "$VERIFY" "$path")"
    assert_eq "$path is protected" "yes" "$got"
    got="$(bash -c 'source "$1"; unset "PROTECTED_PATTERNS[$3]"; PROTECTED_PATTERNS=("${PROTECTED_PATTERNS[@]}"); is_protected "$2" && echo yes || echo no' _ "$VERIFY" "$path" "$i")"
    assert_eq "mutation: without '$pattern', $path is not" "no" "$got"
    i=$((i + 1))
  done <<< "$patterns"
  # The spec's named files, each matched by some pattern.
  for path in scripts/nightly-flake-stress.sh scripts/nightly-quarantine-audit.sh scripts/flake_lib.py \
      scripts/flake-verify.sh scripts/flake-ledger.py scripts/flake-pick.py scripts/test.sh scripts/swift-safe \
      scripts/remote-verify.sh scripts/tbd-home-fingerprint.sh scripts/ci/watched-test-pass.sh \
      scripts/ci/first-party-wipe-needed.sh scripts/repair-spm-workspace.sh \
      Tests/TestSupport/FlakyTestSupport.swift Package.swift Package.resolved; do
    assert_eq "spec §6.4 lists $path" "yes" "$(bash -c 'source "$1"; is_protected "$2" && echo yes || echo no' _ "$VERIFY" "$path")"
  done
}

test_protected_touched_reads_the_candidate_diff() {
  local d base rc=0 out
  d="$(repo_pair)"; base="$(git -C "$d/verify" rev-parse HEAD)"
  mkdir -p "$d/verify/scripts/ci"
  echo x > "$d/verify/scripts/ci/watched-test-pass.sh"; echo y > "$d/verify/Tests/TBDSharedTests/HolderLockTests.swift"
  git -C "$d/verify" add -A; git -C "$d/verify" commit -q -m c
  out="$(cd "$d/verify" && bash "$VERIFY" protected-touched --base "$base")" || rc=$?
  assert_eq "exit 1 when it prints" "1" "$rc"
  assert_eq "only the protected path" "scripts/ci/watched-test-pass.sh" "$out"
}

# protected-in: the same matcher over NUL-separated paths on stdin (promote
# reads a PR's files from GitHub and has no tree to diff).
test_protected_in_lists_the_protected_paths_it_is_given() {
  local rc=0 out mutant
  out="$(printf 'Tests/TBDSharedTests/HolderLockTests.swift\0scripts/flake-verify.sh\0Package.swift\0' | bash "$VERIFY" protected-in)" || rc=$?
  assert_eq "exit 1 when it prints" "1" "$rc"
  assert_eq "only the protected paths" "scripts/flake-verify.sh
Package.swift" "$out"
  rc=0; out="$(printf 'Tests/TBDSharedTests/HolderLockTests.swift\0' | bash "$VERIFY" protected-in)" || rc=$?
  assert_eq "exit 0 and silent with none" "0 " "$rc $out"
  mutant="$(mutant_of 's/^  list_protected$/  true/' "$VERIFY")"
  rc=0; printf 'scripts/test.sh\0' | bash "$mutant/flake-verify.sh" protected-in > /dev/null || rc=$?
  assert_eq "mutation: without the matcher nothing is flagged" "0" "$rc"
  rc=0; out="$(printf 'Tests/a.swift\0scripts/test.sh' | bash "$VERIFY" protected-in)" || rc=$?
  assert_eq "a last path with no NUL after it is still checked" "1 scripts/test.sh" "$rc $out"
  mutant="$(mutant_of 's/ \|\| \[\[ -n "\$path" \]\]; do$/; do/' "$VERIFY")"
  rc=0; printf 'Tests/a.swift\0scripts/test.sh' | bash "$mutant/flake-verify.sh" protected-in > /dev/null || rc=$?
  assert_eq "mutation: without the EOF guard it is dropped" "0" "$rc"
}

test_a_renamed_protected_file_is_flagged() {
  local d base rc=0 out mutant
  d="$(repo_pair)"
  mkdir -p "$d/verify/Tests/TestSupport"
  printf 'record\n%.0s' {1..40} > "$d/verify/Tests/TestSupport/FlakyTestSupport.swift"
  git -C "$d/verify" add -A; git -C "$d/verify" commit -q -m support
  base="$(git -C "$d/verify" rev-parse HEAD)"
  git -C "$d/verify" mv Tests/TestSupport/FlakyTestSupport.swift Tests/TestSupport/FlakyRetry.swift
  echo 'always passedFirstTry' >> "$d/verify/Tests/TestSupport/FlakyRetry.swift"
  git -C "$d/verify" commit -q -am rename
  out="$(cd "$d/verify" && bash "$VERIFY" protected-touched --base "$base")" || rc=$?
  assert_eq "a rename with edits still names the protected path" "1 Tests/TestSupport/FlakyTestSupport.swift" "$rc $(grep FlakyTestSupport <<< "$out")"
  mutant="$(mutant_of 's/git diff --no-renames --name-only/git diff -M --name-only/' "$VERIFY")"
  rc=0; out="$(cd "$d/verify" && bash "$mutant/flake-verify.sh" protected-touched --base "$base")" || rc=$?
  assert_eq "mutation: with rename detection it slips through" "0" "$rc"
}

# A name git would C-quote without -z: a non-ASCII byte and a double quote,
# under a protected glob. Read line by line from the quoted listing it began
# with `"` and matched nothing.
test_a_quoted_non_ascii_protected_path_is_flagged() {
  local d base rc=0 out mutant name
  d="$(repo_pair)"; base="$(git -C "$d/verify" rev-parse HEAD)"
  name=$'scripts/ci/w\xc3\xa4tched "pass".sh'
  mkdir -p "$d/verify/scripts/ci"; echo x > "$d/verify/$name"
  git -C "$d/verify" add -A; git -C "$d/verify" commit -q -m c
  out="$(cd "$d/verify" && bash "$VERIFY" protected-touched --base "$base")" || rc=$?
  assert_eq "flagged, exit 1" "1" "$rc"
  assert_eq "listed as one shell-quoted line" "$(printf '%q' "$name")" "$out"
  # The listing as it was: C-quoted names, one per line, and no fail-closed.
  mutant="$(mutant_of 's/--name-only -z/--name-only/; s/read -r -d .. path; do/read -r path; do/; s/^  matchable "\$1" \|\| return 0$/  true/' "$VERIFY")"
  rc=0; (cd "$d/verify" && bash "$mutant/flake-verify.sh" protected-touched --base "$base" > /dev/null) || rc=$?
  assert_eq "mutation: from the quoted listing it slips through" "0" "$rc"
}

# Fail closed: a name the filesystem may fold onto another (Unicode
# normalization), or one spelled in another case, is flagged.
test_an_unmatchable_or_recased_path_is_flagged() {
  local d base rc=0 out mutant
  d="$(repo_pair)"; base="$(git -C "$d/verify" rev-parse HEAD)"
  mkdir -p "$d/verify/Sources"
  echo x > "$d/verify/Sources/"$'Packag\xc3\xa9.swift'
  git -C "$d/verify" add -A; git -C "$d/verify" commit -q -m c
  out="$(cd "$d/verify" && bash "$VERIFY" protected-touched --base "$base")" || rc=$?
  assert_eq "a non-ASCII name outside every glob is flagged" "1" "$rc"
  mutant="$(mutant_of 's/^  matchable "\$1" \|\| return 0$/  true/' "$VERIFY")"
  rc=0; (cd "$d/verify" && bash "$mutant/flake-verify.sh" protected-touched --base "$base" > /dev/null) || rc=$?
  assert_eq "mutation: without failing closed it is not" "0" "$rc"
  d="$(repo_pair)"; base="$(git -C "$d/verify" rev-parse HEAD)"
  echo x > "$d/verify/PACKAGE.SWIFT"
  git -C "$d/verify" add -A; git -C "$d/verify" commit -q -m c
  rc=0; out="$(cd "$d/verify" && bash "$VERIFY" protected-touched --base "$base")" || rc=$?
  assert_eq "a protected name in another case is flagged" "1 PACKAGE.SWIFT" "$rc $out"
  mutant="$(mutant_of 's/^  shopt -s nocasematch$/  true/' "$VERIFY")"
  rc=0; (cd "$d/verify" && bash "$mutant/flake-verify.sh" protected-touched --base "$base" > /dev/null) || rc=$?
  assert_eq "mutation: matched with case it is not" "0" "$rc"
}

# A candidate that force-adds a file under .build would write it over the
# verification tree's warm build. It is refused before the tree is touched.
test_a_candidate_writing_into_the_build_directory_is_refused() {
  local d base rc=0 out mutant
  d="$(repo_pair)"; base="$(git -C "$d/session" rev-parse HEAD)"
  mkdir -p "$d/session/.build/debug" "$d/verify/.build/debug"
  echo planted > "$d/session/.build/debug/TBDPackageTests"
  echo fixed > "$d/session/Tests/TBDSharedTests/HolderLockTests.swift"
  git -C "$d/session" add -f -A; git -C "$d/session" commit -q -m fix
  git -C "$d/session" bundle create -q "$d/c.bundle" "$base..HEAD" 2>/dev/null
  echo warm > "$d/verify/.build/debug/TBDPackageTests"
  out="$(cd "$d/verify" && bash "$d/vs/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" 2> "$d/err")" || rc=$?
  assert_eq "refused with exit 3, the candidate's failure" "3" "$rc"
  assert_eq "listing the path on stdout" ".build/debug/TBDPackageTests" "$out"
  assert_contains "and saying why" "$(cat "$d/err")" "under a build directory"
  assert_eq "the warm build is untouched" "warm" "$(cat "$d/verify/.build/debug/TBDPackageTests")"
  assert_eq "and the tree is still the base" "$base" "$(git -C "$d/verify" rev-parse HEAD)"
  # A pattern that matches nothing, not an empty list: bash 3.2 reads an empty
  # array's "${a[@]}" under `set -u` as unbound, and the mutant would die.
  mutant="$(mutant_of 's/^BUILD_DIR_PATTERNS=\(.*\)$/BUILD_DIR_PATTERNS=(none)/' "$VERIFY")"
  cp "$d/vs/test.sh" "$d/vs/swift-safe" "$d/vs/remote-verify.sh" "$d/vs/tbd-home-fingerprint.sh" "$mutant/"
  rc=0; (cd "$d/verify" && bash "$mutant/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" > /dev/null 2>&1) || rc=$?
  assert_eq "mutation: without the check it overwrites the build" "0 planted" "$rc $(cat "$d/verify/.build/debug/TBDPackageTests")"
  # Applied anyway (the mutant above), the same paths are protected, so a
  # candidate that reached the judge still could not be promoted.
  assert_contains "and protected" "$(cd "$d/verify" && bash "$VERIFY" protected-touched --base "$base")" ".build/debug/TBDPackageTests"
}

# The refusal does not fail closed: a non-ASCII name outside the build
# directories is applied (and flagged as protected later), not refused.
test_a_non_ascii_name_elsewhere_is_applied() {
  local d base rc=0 mutant
  d="$(repo_pair)"; base="$(git -C "$d/session" rev-parse HEAD)"
  mkdir -p "$d/session/Tests/Fixtures"; echo x > "$d/session/Tests/Fixtures/"$'R\xc3\xa9sum\xc3\xa9.txt'
  git -C "$d/session" add -A; git -C "$d/session" commit -q -m fixture
  git -C "$d/session" bundle create -q "$d/c.bundle" "$base..HEAD" 2>/dev/null
  (cd "$d/verify" && bash "$d/vs/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" > /dev/null 2>&1) || rc=$?
  assert_eq "applied" "0" "$rc"
  mutant="$(mutant_of 's/if globs_match "\$path" "\$\{BUILD_DIR_PATTERNS/if matches_any "$path" "${BUILD_DIR_PATTERNS/' "$VERIFY")"
  cp "$d/vs/test.sh" "$d/vs/swift-safe" "$d/vs/remote-verify.sh" "$d/vs/tbd-home-fingerprint.sh" "$mutant/"
  rc=0; (cd "$d/verify" && git reset -q --hard "$base" && bash "$mutant/flake-verify.sh" apply-candidate --bundle "$d/c.bundle" --base "$base" > /dev/null 2>&1) || rc=$?
  assert_eq "mutation: failing closed there refuses it" "3" "$rc"
}

test_an_unprotected_change_is_not_flagged() {
  local d base rc=0 out
  d="$(repo_pair)"; base="$(git -C "$d/verify" rev-parse HEAD)"
  echo y > "$d/verify/Tests/TBDSharedTests/HolderLockTests.swift"; mkdir -p "$d/verify/Sources/TBDShared"; echo z > "$d/verify/Sources/TBDShared/Lock.swift"
  git -C "$d/verify" add -A; git -C "$d/verify" commit -q -m c
  out="$(cd "$d/verify" && bash "$VERIFY" protected-touched --base "$base")" || rc=$?
  assert_eq "test and production code are the bot's to change" "0 " "$rc $out"
}

# ============================================================================
# the session's processes (spec §6.4)
# ============================================================================

# A FLAKE_VERIFY_PS stub that lists only the PIDs in D/pids, in the real
# listing's format, from the real `ps`.
ps_stub() {
  local d="$1"
  cat > "$d/ps" <<EOF
#!/usr/bin/env bash
pids="\$(tr '\n' ',' < "$d/pids" | sed 's/,\$//')"
[[ -n "\$pids" ]] || exit 0
ps -o pid=,ppid=,stat=,lstart= -p "\$pids" | awk '{pid=\$1; ppid=\$2; st=\$3; \$1=\$2=\$3=""; sub(/^ +/, ""); print pid "\t" ppid "\t" st "\t" \$0}'
EOF
  chmod +x "$d/ps"
}

# Not called in a command substitution: the sleep must stay this shell's child,
# and SPAWNED must be this shell's array, so cleanup can end it.
spawn() { sleep 300 & LAST=$!; SPAWNED+=("$LAST"); disown "$LAST"; }
alive() { ps -o stat= -p "$1" 2>/dev/null | grep -qv '^Z' && echo yes || echo no; }

# end_session D [DIR] [PRELUDE] -> exit code
end_session() {
  local d="$1" dir="${2:-$HERE}" prelude="${3:-:}" rc=0
  FLAKE_VERIFY_PS="$d/ps" bash -c 'source "$1"; TERM_GRACE_S=1; KILL_GRACE_S=1; eval "$2"; main end-session-processes --before "$3"' _ \
    "$dir/flake-verify.sh" "$prelude" "$d/before" > "$d/out" 2>&1 || rc=$?
  echo "$rc"
}

test_a_process_new_since_the_snapshot_is_killed_and_an_old_one_is_not() {
  local d old new rc
  d="$(mktmpd)"; ps_stub "$d"
  spawn; old="$LAST"; echo "$old" > "$d/pids"
  FLAKE_VERIFY_PS="$d/ps" bash "$VERIFY" snapshot-processes --out "$d/before"
  spawn; new="$LAST"; printf '%s\n%s\n' "$old" "$new" > "$d/pids"
  rc="$(end_session "$d")"
  assert_eq "exit 0" "0" "$rc"
  assert_eq "the new sleep is gone" "no" "$(alive "$new")"
  assert_eq "the one in the snapshot is untouched" "yes" "$(alive "$old")"
}

test_a_child_forked_on_term_is_ended_too() {
  local d parent child mutant
  d="$(mktmpd)"; ps_stub "$d"
  printf '1\tMon Jan  1 00:00:00 2001\n' > "$d/before"
  # A session process that answers TERM by forking a child and exiting: the
  # child is born after the first listing.
  D="$d" bash -c 'trap '"'"'sleep 300 & echo $! >> "$D/pids"; exit 0'"'"' TERM; while :; do sleep 0.2; done' &
  parent=$!; SPAWNED+=("$parent"); disown "$parent"
  echo "$parent" > "$d/pids"
  assert_eq "exit 0" "0" "$(end_session "$d")"
  child="$(sed -n 2p "$d/pids")"; SPAWNED+=("$child")
  assert_eq "the parent is gone" "no" "$(alive "$parent")"
  assert_eq "and so is the child it forked" "no" "$(alive "$child")"
  mutant="$(mutant_of 's/^KILL_ROUNDS=3$/KILL_ROUNDS=1/' "$VERIFY")"
  D="$d" bash -c 'trap '"'"'sleep 300 & echo $! >> "$D/pids"; exit 0'"'"' TERM; while :; do sleep 0.2; done' &
  parent=$!; SPAWNED+=("$parent"); disown "$parent"
  echo "$parent" > "$d/pids"
  end_session "$d" "$mutant" > /dev/null
  child="$(sed -n 2p "$d/pids")"; SPAWNED+=("$child")
  assert_eq "mutation: with one round the child survives" "yes" "$(alive "$child")"
}

test_a_recycled_pid_counts_as_new() {
  local d pid
  d="$(mktmpd)"; ps_stub "$d"
  spawn; pid="$LAST"; echo "$pid" > "$d/pids"
  printf '%s\tMon Jan  1 00:00:00 2001\n' "$pid" > "$d/before"
  assert_eq "same PID, different start: killed" "0" "$(end_session "$d")"
  assert_eq "gone" "no" "$(alive "$pid")"
}

test_a_survivor_aborts_the_attempt() {
  local d pid mutant
  d="$(mktmpd)"; ps_stub "$d"
  printf '1\tMon Jan  1 00:00:00 2001\n' > "$d/before"
  spawn; pid="$LAST"; echo "$pid" > "$d/pids"
  assert_eq "a process the kill cannot end: exit 5" "5" "$(end_session "$d" "$HERE" 'kill() { :; }')"
  assert_contains "named" "$(cat "$d/out")" "survived SIGKILL: $pid"
  mutant="$(mutant_of 's/^    still_alive "\$entry" && survivors\+=\(.*$/    :/' "$VERIFY")"
  assert_eq "mutation: without the re-check it reports success" "0" "$(end_session "$d" "$mutant" 'kill() { :; }')"
}


# ============================================================================
# tree-digest (spec §6.4): the verification tree and try 1's output
# ============================================================================

digest() { python3 -B "$VPY" tree-digest "$1"; }

test_the_tree_digest_sees_every_kind_of_change() {
  local d a
  d="$(mktmpd)"; mkdir -p "$d/.git" "$d/.build/debug"
  echo '[core]' > "$d/.git/config"; echo built > "$d/.build/debug/T"; ln -s debug "$d/.build/current"
  a="$(digest "$d")"
  assert_eq "stable" "$a" "$(digest "$d")"
  assert_eq "a copy digests the same" "$a" "$(e="$(mktmpd)"; cp -R "$d/." "$e/"; digest "$e")"
  touch -t 200001010000 "$d/.build/debug/T"
  assert_eq "a timestamp alone does not change it" "$a" "$(digest "$d")"
  echo forged > "$d/.build/debug/T"
  assert_lacks "a content edit changes it" "$(digest "$d")" "$a"
  echo built > "$d/.build/debug/T"; assert_eq "and reverting it restores it" "$a" "$(digest "$d")"
  chmod +x "$d/.build/debug/T"
  assert_lacks "a mode change changes it" "$(digest "$d")" "$a"
  chmod -x "$d/.build/debug/T"
  rm "$d/.build/current"; ln -s release "$d/.build/current"
  assert_lacks "a retargeted symlink changes it" "$(digest "$d")" "$a"
  rm "$d/.build/current"; ln -s debug "$d/.build/current"; assert_eq "restored" "$a" "$(digest "$d")"
  : > "$d/.git/hooks-planted"
  assert_lacks "a new empty file changes it" "$(digest "$d")" "$a"
  rm "$d/.git/hooks-planted"; mkdir "$d/.git/hooks"
  assert_lacks "and so does a new empty directory" "$(digest "$d")" "$a"
  rmdir "$d/.git/hooks"; mv "$d/.build/debug/T" "$d/.build/debug/U"
  assert_lacks "and a rename" "$(digest "$d")" "$a"
}

test_the_tree_digest_does_not_follow_a_symlinked_root_or_entry() {
  local d e rc=0
  d="$(mktmpd)"; e="$(mktmpd)"; echo x > "$e/f"
  ln -s "$e" "$d/link"
  rc=0; digest "$d/link" > /dev/null 2>&1 || rc=$?
  assert_eq "a symlinked root is refused" "2" "$rc"
  local a; a="$(digest "$d")"
  echo y > "$e/f"
  assert_eq "a symlinked directory is hashed as a link, not walked" "$a" "$(digest "$d")"
  rc=0; digest "$d/missing" > /dev/null 2>&1 || rc=$?
  assert_eq "a missing directory is refused" "2" "$rc"
}

test_the_verifier_runs_python_isolated() {
  local d out
  d="$(mktmpd)"; mkdir "$d/site"
  # A module that would shadow the standard library's json from PYTHONPATH.
  printf 'raise SystemExit("planted json imported")\n' > "$d/site/json.py"
  out="$(PYTHONPATH="$d/site" bash "$VERIFY" plan-iterations --scope pass --baseline-dir "$d" --out "$d/plan.json" 2>&1)"
  assert_lacks "PYTHONPATH does not reach the verifier's Python" "$out" "planted json imported"
  local m; m="$(mutant_of 's/python3 -I -S -B /python3 /' "$VERIFY")"
  out="$(PYTHONPATH="$d/site" bash "$m/flake-verify.sh" plan-iterations --scope pass --baseline-dir "$d" --out "$d/plan2.json" 2>&1)"
  assert_contains "mutation: without -I it does" "$out" "planted json imported"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
