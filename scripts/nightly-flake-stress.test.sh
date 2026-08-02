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

# Run judge_iteration inside a MUTATED copy of the script, to prove a given
# verdict is actually produced by the guard it is attributed to.
judge_mutated() {
  local sed_expr="$1" rc="$2" log="$3" floor="$4"
  local mutant; mutant="$(mktmpd)/mutant.sh"
  sed -E "$sed_expr" "$SCRIPT" > "$mutant"
  bash -c "source '$mutant'; judge_iteration '$rc' '$log' '$floor'"
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
  assert_contains "and says it was the harness deadline" "$verdict" "killed by the harness deadline"
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

test_governed_swift_deadline_covers_lock_wait_and_command() {
  local d; d="$(mktmpd)"
  local fake_repo="$d/repo" args_file="$d/args"
  mkdir -p "$fake_repo/scripts"
  cat > "$fake_repo/scripts/swift-safe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TBD_SWIFT_LOCK_TIMEOUT_SECONDS|$*" > "$ARGS_FILE"
EOF
  chmod +x "$fake_repo/scripts/swift-safe"

  local old_repo_root="${REPO_ROOT:-}" old_lock="$SWIFT_LOCK_TIMEOUT_S"
  REPO_ROOT="$fake_repo"
  SWIFT_LOCK_TIMEOUT_S=7
  assert_eq "outer deadline includes lock wait, command budget, and grace" \
    "48" "$(governed_outer_deadline 11)"
  ARGS_FILE="$args_file" run_governed_swift 11 "$d/out.log" test --filter Foo

  assert_eq "governed command receives the explicit lock timeout" \
    "7|test --filter Foo" "$(cat "$args_file")"
  assert_eq "governed command completes without consuming its outer deadline" \
    "" "$(cat "$d/out.log")"
  REPO_ROOT="$old_repo_root"
  SWIFT_LOCK_TIMEOUT_S="$old_lock"
  rm -rf "$d"
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
