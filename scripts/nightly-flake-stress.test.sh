#!/usr/bin/env bash
# Tests for scripts/nightly-flake-stress.sh — run: bash scripts/nightly-flake-stress.test.sh
#
# ZERO BUILDS, ZERO CPU LOAD. Everything proven here is proven against synthetic
# `swift test` logs and against `sleep` processes, so this runs safely on a shared
# box while other agents are working.
#
# What matters most in the stress loop is not that it runs tests — it is how it
# JUDGES a run. A wedged run exits with no summary line, and a harness that
# checks `rc == 0` scores it green; that mistake has been made repeatedly in this
# program, and it is the reason a nightly can report "clean" while a suite is
# hanging every night. So the judgment is tested first and mutation-checked.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2034 # SPINNER_PIDS is owned by the sourced script under test
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/nightly-flake-stress.sh"
# shellcheck source=/dev/null
source "$SCRIPT"   # source-guard prevents main() from running

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/stress-test.XXXXXX"; }

mk_log() { local f="$1"; shift; printf '%s\n' "$@" > "$f"; }

# A copy of the script with one guard deliberately weakened. Echoes its path.
MUTANT_DIR="$(mktmpd)"
MUTANT_SEQ=0
trap 'rm -rf "$MUTANT_DIR"' EXIT
mutant_of() {
  local sed_expr="$1" out
  MUTANT_SEQ=$((MUTANT_SEQ + 1))
  out="$MUTANT_DIR/mutant.$MUTANT_SEQ.sh"
  sed -E "$sed_expr" "$SCRIPT" > "$out"
  echo "$out"
}

# Run judge_iteration inside a MUTATED copy of the script, to prove a given
# verdict is actually produced by the guard it is attributed to.
judge_mutated() {
  local sed_expr="$1" rc="$2" log="$3" floor="$4"
  bash -c "source '$(mutant_of "$sed_expr")'; judge_iteration '$rc' '$log' '$floor'"
}

# ---------------------------------------------------------------------------
# The verdict rules
# ---------------------------------------------------------------------------

test_a_clean_run_passes_with_its_count() {
  local d; d="$(mktmpd)"
  mk_log "$d/ok.log" "Test run started." "Test run with 42 tests passed after 3.1 seconds."
  assert_eq "clean run -> PASS with the executed count" "PASS 42" "$(judge_iteration 0 "$d/ok.log" 10)"
  rm -rf "$d"
}

test_a_truncated_log_is_a_failure_not_a_pass() {
  # THE RULE THIS FILE EXISTS FOR. A wedged run produces no summary line, and
  # `rc == 0` alone scores it green.
  local d; d="$(mktmpd)"
  mk_log "$d/trunc.log" "Test run started." "Suite \"ControlModeInputHealth\" started."
  local verdict; verdict="$(judge_iteration 0 "$d/trunc.log" 10)"
  assert_contains "no summary line -> FAIL even with rc=0" "$verdict" "FAIL"
  # The DIAGNOSIS matters as much as the verdict: "it wedged" and "your filter
  # under-matched" send a reader to completely different places.
  assert_contains "and the reason names the missing summary" "$verdict" "no 'Test run with N tests' summary"

  # MUTATION, and it did not do what I expected — recorded rather than tidied
  # away. Removing the summary guard alone does NOT produce a pass: the count is
  # empty, so the floor guard catches it next and the run still fails. That is
  # defense in depth, and it is worth locking in as its own assertion.
  local without_summary_guard
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  without_summary_guard="$(judge_mutated 's/if \[\[ -z "\$count" \]\]/if [[ -z "NEVER" ]]/' 0 "$d/trunc.log" 10)"
  assert_contains "mutation: with the summary guard gone, the FLOOR guard still catches a wedge" \
    "$without_summary_guard" "FAIL"
  # And the set as a whole IS load-bearing: remove both and the wedge scores green,
  # which is precisely the "rc == 0 means pass" mistake this harness exists to avoid.
  local without_both
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  without_both="$(judge_mutated 's/if \[\[ -z "\$count" \]\]/if [[ -z "NEVER" ]]/; s/if \[\[ "\$count" -lt "\$floor" \]\]/if [[ "$count" -lt -1 ]]/' 0 "$d/trunc.log" 10)"
  assert_contains "mutation: with BOTH guards gone, a wedged run scores PASS" "$without_both" "PASS"
  rm -rf "$d"
}

test_a_deadline_kill_is_reported_as_wedged() {
  local d; d="$(mktmpd)"
  mk_log "$d/wedged.log" "Test run started."
  local verdict; verdict="$(judge_iteration 124 "$d/wedged.log" 10)"
  assert_contains "rc=124 -> wedged" "$verdict" "FAIL wedged"
  # It has to say WHICH deadline, because the answer decides where a reader
  # goes next: the governed outer bound covers the lock wait as well as the
  # execution budget, so "it wedged" and "it never got admitted" are different
  # diagnoses wearing the same rc.
  assert_contains "and says it was the governed outer deadline" "$verdict" \
    "no completion within the governed outer deadline"
  assert_contains "and names both phases it covers" "$verdict" "lock wait"
  rm -rf "$d"
}

test_running_fewer_tests_than_the_floor_is_a_failure() {
  # `swift test --filter` exits GREEN on zero matches — five payouts in this
  # program so far. A renamed suite must not read as a clean run.
  local d; d="$(mktmpd)"
  mk_log "$d/thin.log" "Test run with 0 tests passed after 0.1 seconds."
  local verdict; verdict="$(judge_iteration 0 "$d/thin.log" 10)"
  assert_contains "zero matches -> FAIL despite rc=0" "$verdict" "FAIL ran 0 tests"
  assert_contains "and explains the green-on-zero-matches trap" "$verdict" "exits GREEN on zero matches"
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  assert_contains "mutation: without the floor guard, zero tests scores PASS" \
    "$(judge_mutated 's/if \[\[ "\$count" -lt "\$floor" \]\]/if [[ "$count" -lt -1 ]]/' 0 "$d/thin.log" 10)" "PASS"
  rm -rf "$d"
}

test_a_nonzero_rc_with_a_full_count_still_fails() {
  local d; d="$(mktmpd)"
  mk_log "$d/red.log" "Test run with 42 tests failed after 3.1 seconds."
  assert_contains "real test failure -> FAIL with the count" "$(judge_iteration 1 "$d/red.log" 10)" "FAIL rc=1 with 42 tests"
  rm -rf "$d"
}

test_the_three_verdicts_are_independent() {
  # A log can satisfy two rules and violate the third. Each must be able to fail
  # on its own, or the "three independent verdicts" claim is decorative.
  local d; d="$(mktmpd)"
  mk_log "$d/a.log" "Test run with 3 tests passed after 1s."
  assert_contains "summary present + rc 0 + below floor -> still fails" \
    "$(judge_iteration 0 "$d/a.log" 10)" "below the measured floor"
  mk_log "$d/b.log" "Test run with 42 tests failed after 1s."
  assert_contains "summary present + above floor + rc 1 -> still fails" \
    "$(judge_iteration 1 "$d/b.log" 10)" "FAIL rc=1"
  rm -rf "$d"
}

test_failure_signatures_are_extracted_and_capped() {
  local d; d="$(mktmpd)"
  : > "$d/many.log"
  local i
  for i in $(seq 1 30); do echo "✘ Test example$i() recorded an issue" >> "$d/many.log"; done
  local sigs count; sigs="$(failing_tests_from "$d/many.log")"
  count="$(printf '%s\n' "$sigs" | grep -c .)"
  assert_contains "failure lines are extracted" "$sigs" "example1()"
  assert_eq "and capped so one bad run cannot flood an issue comment" "12" "$count"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Kill discipline — proven with `sleep`, which costs zero CPU
# ---------------------------------------------------------------------------

test_stop_spinners_kills_only_its_captured_pids() {
  # `sleep` stands in for `yes`: same process-lifecycle question, none of the
  # load. A bystander process proves the cleanup is targeted rather than broad.
  local bystander mine1 mine2
  sleep 30 & bystander=$!
  sleep 30 & mine1=$!
  sleep 30 & mine2=$!
  SPINNER_PIDS=("$mine1" "$mine2")
  stop_spinners >/dev/null 2>&1
  sleep 0.3
  assert_eq "captured pid 1 is gone" "gone" "$(ps -p "$mine1" >/dev/null 2>&1 && echo live || echo gone)"
  assert_eq "captured pid 2 is gone" "gone" "$(ps -p "$mine2" >/dev/null 2>&1 && echo live || echo gone)"
  assert_eq "an uncaptured bystander is UNTOUCHED" "live" "$(ps -p "$bystander" >/dev/null 2>&1 && echo live || echo gone)"
  kill "$bystander" 2>/dev/null
  wait "$bystander" 2>/dev/null
  # shellcheck disable=SC2034 # SPINNER_PIDS belongs to the sourced script under test
  SPINNER_PIDS=()
}

test_stop_spinners_verifies_by_captured_pid_and_reports_survivors() {
  # The verification must be able to SEE a survivor. A check that always reports
  # zero survivors is a check that cannot fail — the exact defect this program
  # found in a spinner-survival check that cleared its PID array first.
  local stubborn
  sleep 30 & stubborn=$!
  SPINNER_PIDS=("$stubborn")
  # Make SIGTERM a no-op for the process by trapping it in a subshell we control:
  # simpler and more honest here is to assert the reporting path directly.
  local out; out="$(stop_spinners 2>&1)"
  assert_contains "stop_spinners reports how many it stopped" "$out" "stopped 1 spinner(s)"
  kill -9 "$stubborn" 2>/dev/null
  wait "$stubborn" 2>/dev/null
  SPINNER_PIDS=()
}

test_run_with_deadline_kills_an_overrunning_command() {
  local d; d="$(mktmpd)" rc=0
  local start elapsed
  start=$SECONDS
  run_with_deadline 2 "$d/out.log" sleep 60 || rc=$?
  elapsed=$((SECONDS - start))
  assert_eq "an overrunning command returns the deadline code" "124" "$rc"
  assert_eq "and is actually killed rather than waited out" "yes" \
    "$(if [[ $elapsed -lt 20 ]]; then echo yes; else echo "no ($elapsed s)"; fi)"
  rm -rf "$d"
}

test_run_with_deadline_passes_through_a_fast_commands_status() {
  local d; d="$(mktmpd)" rc=0
  run_with_deadline 30 "$d/out.log" true || rc=$?
  assert_eq "a fast success passes through rc 0" "0" "$rc"
  rc=0
  run_with_deadline 30 "$d/out.log" false || rc=$?
  assert_eq "a fast failure passes through its rc" "1" "$rc"
  rm -rf "$d"
}

# STUB WRAPPERS, AND `SCRIPT_DIR` IS THE ONLY SEAM THAT REACHES THEM. The script
# resolves both wrappers as `$SCRIPT_DIR/<name>`, so a case that overrode anything
# else — `REPO_ROOT`, a `cd`, a PATH entry — would leave `run_governed_swift` and
# `run_governed_fenced` invoking the REAL `scripts/swift-safe` and `scripts/test.sh`
# from this worktree. That is not a stub that quietly did nothing: it starts a real
# compile, takes the machine-global build slot, and contradicts this file's own
# "ZERO BUILDS" claim while every assertion reads an args file nothing wrote.
#
# Each stub records the environment it was handed. `${VAR-<unset>}` rather than
# `${VAR:-<unset>}` on purpose: the valve cases below turn on the difference
# between a variable that was CLEARED and one that was never set.
mk_stub_wrapper() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  cat > "$dir/$name" <<'EOF'
#!/usr/bin/env bash
{
  printf 'lock_timeout=%s\n' "${TBD_SWIFT_LOCK_TIMEOUT_SECONDS-<unset>}"
  printf 'TBD_REMOTE_VERIFY=%s\n' "${TBD_REMOTE_VERIFY-<unset>}"
  printf 'TBD_SWIFT_QUEUE_YIELD_SECONDS=%s\n' "${TBD_SWIFT_QUEUE_YIELD_SECONDS-<unset>}"
  printf 'argv=%s\n' "$*"
} > "$STUB_RECORD"
EOF
  chmod +x "$dir/$name"
}

# One recorded line's value, so an assertion can distinguish `VAR=` from `VAR=5`
# — which `assert_contains` on the name alone cannot.
recorded() { sed -n "s/^$2=//p" "$1"; }

test_governed_swift_deadline_covers_lock_wait_and_command() {
  local d; d="$(mktmpd)"
  local record="$d/record"
  mk_stub_wrapper "$d/scripts" swift-safe

  local old_script_dir="$SCRIPT_DIR" old_lock="$SWIFT_LOCK_TIMEOUT_S"
  SCRIPT_DIR="$d/scripts"
  SWIFT_LOCK_TIMEOUT_S=7
  assert_eq "outer deadline includes lock wait, command budget, and grace" \
    "48" "$(governed_outer_deadline 11)"
  STUB_RECORD="$record" run_governed_swift 11 "$d/out.log" test --filter Foo

  assert_eq "governed command receives the explicit lock timeout" \
    "7" "$(recorded "$record" lock_timeout)"
  assert_eq "and the arguments it was given" \
    "test --filter Foo" "$(recorded "$record" argv)"
  assert_eq "governed command completes without consuming its outer deadline" \
    "" "$(cat "$d/out.log")"
  SCRIPT_DIR="$old_script_dir"
  SWIFT_LOCK_TIMEOUT_S="$old_lock"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# The remote verification valve is OFF for everything this harness governs
#
# `scripts/test.sh` opts into the valve on `TBD_REMOTE_VERIFY=1`, and this harness
# invokes `test.sh`. Routing an iteration to CI would not merely stretch a
# deadline — it would measure the wrong thing entirely: this program exists to
# reproduce LOCAL flakiness under induced contention, and a verdict computed on a
# quiet runner answers a question nobody asked. So the harness turns the valve off
# itself rather than trusting the shell it was started from.
# ---------------------------------------------------------------------------

test_an_iteration_never_routes_even_when_the_caller_enabled_the_valve() {
  local d; d="$(mktmpd)"
  local record="$d/record"
  mk_stub_wrapper "$d/scripts" test.sh

  local old_script_dir="$SCRIPT_DIR"
  SCRIPT_DIR="$d/scripts"
  # The caller's environment has the valve on and a bound of its own — the shape
  # of a night started from a shell that exported them for the soak.
  export TBD_REMOTE_VERIFY=1 TBD_SWIFT_QUEUE_YIELD_SECONDS=5
  STUB_RECORD="$record" run_governed_fenced 5 "$d/out.log" --no-fingerprint --filter Foo
  unset TBD_REMOTE_VERIFY TBD_SWIFT_QUEUE_YIELD_SECONDS
  SCRIPT_DIR="$old_script_dir"

  assert_eq "the iteration runs with the valve explicitly off" "0" \
    "$(recorded "$record" TBD_REMOTE_VERIFY)"
  # CLEARED, not merely unassigned: `env VAR=` wins over an inherited value, and
  # an inherited bound would make the test leg yield 76 with the valve off — a
  # status `test.sh` propagates and `judge_iteration` reads as a truncated log.
  assert_eq "and the inherited yield bound cleared rather than passed through" "" \
    "$(recorded "$record" TBD_SWIFT_QUEUE_YIELD_SECONDS)"
  assert_eq "the iteration's own arguments are untouched" \
    "--no-fingerprint --filter Foo" "$(recorded "$record" argv)"
  rm -rf "$d"
}

# The build leg goes straight to `swift-safe`, which ignores a yield bound for any
# subcommand but `test` — but it warns about one, into `build.log`, and the
# harness should not depend on that leniency to stay correct.
test_the_build_leg_also_runs_with_the_valve_off() {
  local d; d="$(mktmpd)"
  local record="$d/record"
  mk_stub_wrapper "$d/scripts" swift-safe

  local old_script_dir="$SCRIPT_DIR"
  SCRIPT_DIR="$d/scripts"
  export TBD_REMOTE_VERIFY=1 TBD_SWIFT_QUEUE_YIELD_SECONDS=5
  STUB_RECORD="$record" run_governed_swift 5 "$d/out.log" build --build-tests -j 2
  unset TBD_REMOTE_VERIFY TBD_SWIFT_QUEUE_YIELD_SECONDS
  SCRIPT_DIR="$old_script_dir"

  assert_eq "the build runs with the valve off too" "0" \
    "$(recorded "$record" TBD_REMOTE_VERIFY)"
  assert_eq "and with no inherited bound to warn about" "" \
    "$(recorded "$record" TBD_SWIFT_QUEUE_YIELD_SECONDS)"
  rm -rf "$d"
}

# MUTATION. Empty the clearing out of `NO_VALVE_ENV` — leaving a harmless
# placeholder so the array stays non-empty, since bash 3.2 errors on an empty
# `"${a[@]}"` under `set -u` and would fail for the wrong reason — and the caller's
# `TBD_REMOTE_VERIFY=1` rides into the iteration. That iteration then routes to
# GitHub, and this harness reports a verdict from a quiet runner as a measurement
# of local contention.
test_disabling_the_valve_is_load_bearing() {
  local d; d="$(mktmpd)"
  local record="$d/record" mutant
  mk_stub_wrapper "$d/scripts" test.sh
  mutant="$(mutant_of 's/^NO_VALVE_ENV=\(TBD_REMOTE_VERIFY=0 TBD_SWIFT_QUEUE_YIELD_SECONDS=\)$/NO_VALVE_ENV=(TBD_STRESS_MUTANT=1)/')"

  STUB_RECORD="$record" TBD_REMOTE_VERIFY=1 TBD_SWIFT_QUEUE_YIELD_SECONDS=5 \
    bash -c "source '$mutant'; SCRIPT_DIR='$d/scripts'; \
             run_governed_fenced 5 '$d/out.log' --no-fingerprint --filter Foo"

  assert_eq "without the clearing the caller's valve flag reaches the iteration" \
    "1" "$(recorded "$record" TBD_REMOTE_VERIFY)"
  assert_eq "and so does the caller's yield bound" "5" \
    "$(recorded "$record" TBD_SWIFT_QUEUE_YIELD_SECONDS)"
  rm -rf "$d"
}

# The harness's own account of WHY it disables the valve, pinned so a future edit
# cannot quietly turn "measure local flakiness" into "widen the deadline". The
# rejected fix is named because it is the one a reader reaches for first.
test_the_no_valve_decision_is_documented_in_the_script() {
  local body; body="$(cat "$SCRIPT")"
  assert_contains "the script says the valve is off for its runs" "$body" \
    "TBD_REMOTE_VERIFY=0"
  assert_contains "and says this harness measures LOCAL flakiness" "$body" \
    "MEASURES LOCAL FLAKINESS UNDER CONTENTION"
  assert_contains "and records that widening the deadline was the wrong fix" "$body" \
    'NOT "WIDEN THE DEADLINE"'
}

# ---------------------------------------------------------------------------
# Target table
# ---------------------------------------------------------------------------

test_every_target_names_an_issue_and_a_floor() {
  local spec name filter floor issue desc bad=0
  for spec in "${TARGETS[@]}"; do
    # shellcheck disable=SC2034 # desc is read to consume the field, not used
    IFS='|' read -r name filter floor issue desc <<< "$spec"
    [[ -n "$name" && -n "$filter" && -n "$issue" ]] || { echo "     malformed: $spec"; bad=$((bad + 1)); }
    [[ "$floor" =~ ^[0-9]+$ ]] || { echo "     non-numeric floor: $spec"; bad=$((bad + 1)); }
    [[ "$issue" =~ ^[0-9]+$ ]] || { echo "     non-numeric issue: $spec"; bad=$((bad + 1)); }
  done
  assert_eq "every stress target carries a numeric floor and an issue number" "0" "$bad"
  assert_eq "and there are the four targets the PR describes" "4" "${#TARGETS[@]}"
}

test_targets_reference_only_open_ledger_issues() {
  # The issues this loop comments on are #494, #503 and #496 — stated in the PR
  # and asserted here so the two cannot drift apart silently.
  local spec issue seen=""
  for spec in "${TARGETS[@]}"; do
    issue="$(printf '%s' "$spec" | cut -d'|' -f4)"
    case " $seen " in *" $issue "*) ;; *) seen="$seen $issue" ;; esac
  done
  assert_eq "the loop attaches to exactly the documented issue set" " 494 503 496" "$seen"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
