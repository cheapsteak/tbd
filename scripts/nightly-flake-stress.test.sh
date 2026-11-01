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

# Only this shell may delete MUTANT_DIR. A child that bash forks for `sleep 30 &`
# keeps a copy of this trap until it execs `sleep`, and bash runs the EXIT trap
# when a signal kills it in that window. The kill-discipline cases below kill
# their sleeps microseconds after spawning them. Without the check, the child
# deleted the directory and every later `mutant_of` wrote into one that no longer
# existed. `${BASHPID:-$$}` because bash 3.2 has no BASHPID; the comment above
# test_only_the_harness_shell_deletes_the_mutant_dir says why that is safe.
MUTANT_DIR="$(mktmpd)"
MUTANT_DIR_OWNER="${BASHPID:-$$}"
trap '[[ "${BASHPID:-$$}" == "$MUTANT_DIR_OWNER" ]] && rm -rf "$MUTANT_DIR"' EXIT

# mutant_of NAME FUNCTION SED_EXPR: write a copy of the script with one guard
# deliberately weakened by SED_EXPR, and set NAME to its path. FUNCTION is the
# one the caller is about to run in the copy.
#
# Each copy gets a file of its own from mktemp. A counter cannot do it: a caller
# that runs this inside `$(...)` never hands the bump back, so every mutant would
# share one file. And the copy is checked before anyone sources it, because a
# caller that sources a missing or unmutated copy gets a bare 127 — or the
# verdict it expected, for the wrong reason. A copy that fails a check fails the
# run with a line naming why, and NAME is left empty. That line goes to stderr
# because judge_mutated's callers capture stdout.
mutant_of() {
  local _name="$1" _fn="$2" _expr="$3" _out _why=""
  printf -v "$_name" '%s' ""
  if ! _out="$(mktemp "$MUTANT_DIR/mutant.XXXXXX" 2>/dev/null)"; then
    _why="cannot create a file in MUTANT_DIR ($MUTANT_DIR)"
  elif ! sed -E "$_expr" "$SCRIPT" > "$_out"; then
    _why="sed failed"
  elif [[ ! -s "$_out" ]]; then
    _why="the copy is empty"
  elif cmp -s "$SCRIPT" "$_out"; then
    _why="the expression changed nothing"
  elif ! bash -n "$_out" 2>/dev/null; then
    _why="the copy does not parse"
  elif ! grep -q "^$_fn() {" "$_out"; then
    _why="the copy no longer defines $_fn"
  fi
  if [[ -n "$_why" ]]; then
    echo "FAIL - mutant_of: $_why [sed: $_expr]" >&2
    FAIL=1
    return 1
  fi
  printf -v "$_name" '%s' "$_out"
}

# Run judge_iteration inside a MUTATED copy of the script, to prove a given
# verdict is actually produced by the guard it is attributed to. A copy that
# mutant_of refuses prints no verdict, so the caller's assertion fails alongside
# the FAIL line.
judge_mutated() {
  local sed_expr="$1" rc="$2" log="$3" floor="$4" mutant
  mutant_of mutant judge_iteration "$sed_expr" || return 1
  bash -c "source '$mutant'; judge_iteration '$rc' '$log' '$floor'"
}

# ---------------------------------------------------------------------------
# The mutant scaffolding — it can come out wrong without saying so
# ---------------------------------------------------------------------------

test_two_mutants_get_two_files() {
  # Made the way every caller once made them, each inside `$(...)`: a counter
  # bumped there never reached the next call, so the second mutant overwrote the
  # first and both paths named one file.
  local a b
  a="$(mutant_of m judge_iteration 's/^(SCRIPT_DIR=.*)$/\1 # mutant A/' && echo "$m")"
  b="$(mutant_of m judge_iteration 's/^(SCRIPT_DIR=.*)$/\1 # mutant B/' && echo "$m")"
  assert_eq "two calls get two paths" "different" \
    "$([[ -n "$a" && "$a" != "$b" ]] && echo different || echo "the same [$a]")"
  assert_eq "the first holds its own mutation and not the second's" "1 0" \
    "$(grep -c 'mutant A' "$a") $(grep -c 'mutant B' "$a")"
  assert_eq "and the second its own" "0 1" "$(grep -c 'mutant A' "$b") $(grep -c 'mutant B' "$b")"
}

# A mutant_of refusal, with this run's FAIL saved and restored around it so the
# refusal it provokes does not fail the run. FAIL starts clear and NAME starts
# holding a stale path, so each case shows that the refusal fails a run AND
# leaves nothing for a caller to source by mistake.
refusal_of() {
  local saved_fail="$FAIL" m=/previous rc=0
  FAIL=0
  mutant_of m judge_iteration "$1" 2>&1 || rc=$?
  echo "rc=$rc FAIL=$FAIL m=[$m]"
  FAIL="$saved_fail"
}

test_mutant_of_names_a_copy_it_cannot_vouch_for() {
  local d out; d="$(mktmpd)"
  out="$(refusal_of 's/THIS TEXT IS IN NO LINE OF THE SCRIPT//')"
  assert_contains "a mutation that does not apply is named" "$out" "the expression changed nothing"
  assert_contains "and refused" "$out" "rc=1 FAIL=1 m=[]"
  out="$(refusal_of 's/^judge_iteration\(\) \{/judge_iteration_renamed() {/')"
  assert_contains "a copy without the function the caller runs is named" "$out" "the copy no longer defines judge_iteration"
  assert_contains "and refused" "$out" "rc=1 FAIL=1 m=[]"
  out="$(refusal_of 's/^(SCRIPT_DIR=.*)$/\1; if/')"
  assert_contains "a copy that does not parse is named" "$out" "the copy does not parse"
  assert_contains "and refused" "$out" "rc=1 FAIL=1 m=[]"
  out="$(refusal_of 's/unterminated')"
  assert_contains "a sed expression sed rejects is named" "$out" "sed failed"
  assert_contains "and refused" "$out" "rc=1 FAIL=1 m=[]"
  # The failure this file actually had: the directory gone under a later mutant.
  out="$(MUTANT_DIR="$d/gone"; refusal_of 's/^(SCRIPT_DIR=.*)$/\1 # mutant/')"
  assert_contains "a missing mutant directory is named" "$out" "cannot create a file in MUTANT_DIR ($d/gone)"
  assert_contains "and refused" "$out" "rc=1 FAIL=1 m=[]"
  rm -rf "$d"
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

test_assertion_lines_survive_a_flood_of_failing_suites() {
  # THE BUG THIS PARTITION EXISTS FOR. `✘ Suite` sorts ahead of `✘ Test`, so a
  # single `sort -u | head -12` over a run with twelve or more red suites spent
  # the whole budget on suite summaries and cut every line naming an assertion.
  # Two flakes were reported on 28 and 24 nights apiece without the ledger ever
  # naming one.
  local d; d="$(mktmpd)"
  : > "$d/floody.log"
  local i
  for i in $(seq 1 20); do
    echo "✘ Suite \"Suite$i\" failed after 4.2 seconds with 2 issues." >> "$d/floody.log"
  done
  echo "✘ Test reapsItsPTYChild() recorded an issue at TerminalTests.swift:88:5: Expectation failed: child.isRunning" >> "$d/floody.log"

  local sigs; sigs="$(failing_tests_from "$d/floody.log")"
  assert_contains "the assertion line survives twenty failing suites" "$sigs" "reapsItsPTYChild()"
  assert_contains "and carries the expectation text a reader needs" "$sigs" "Expectation failed"
  # The summary is still worth a few lines — it is bounded, not banished.
  assert_contains "suite summaries still appear" "$sigs" '✘ Suite'
  assert_eq "but only up to their own budget" "$SIGNATURE_SUITE_LINES" \
    "$(printf '%s\n' "$sigs" | grep -c '^✘ Suite ')"
  assert_eq "and the whole block stays bounded" "$((SIGNATURE_SUITE_LINES + 1))" \
    "$(printf '%s\n' "$sigs" | grep -c .)"

  # MUTATION: collapse the partition back into the single shared cap it replaced
  # — one budget, filled in sort order — and the assertion line is gone. That is
  # the exact loss the ledger suffered, reproduced on demand.
  local mutant unpartitioned
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  mutant_of mutant failing_tests_from 's#^  detail=.*#  detail="$(head -12 <<< "$all")"#; s#^  suites=.*#  suites=""#' || { rm -rf "$d"; return; }
  unpartitioned="$(bash -c "source '$mutant'; failing_tests_from '$d/floody.log'")"
  assert_eq "mutation: with one shared cap the assertion line is cut" "0" \
    "$(printf '%s\n' "$unpartitioned" | grep -c 'reapsItsPTYChild')"
  assert_eq "mutation: and the whole budget goes to suite summaries" "12" \
    "$(printf '%s\n' "$unpartitioned" | grep -c '^✘ Suite ')"
  rm -rf "$d"
}

test_a_run_with_no_failure_lines_yields_nothing() {
  # The caller appends the block only when it is non-empty; an all-whitespace
  # block would indent a blank line into a GitHub comment.
  local d; d="$(mktmpd)"
  mk_log "$d/clean.log" "Test run started." "Test run with 42 tests passed after 3.1 seconds."
  assert_eq "a clean log produces an empty signature block" "" "$(failing_tests_from "$d/clean.log")"
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

# A TRAP BELONGS TO THE SHELL THAT INSTALLED IT. The two cases above kill their
# sleeps microseconds after spawning them. A child that bash forks for
# `sleep 30 &` keeps a copy of every trap until it execs `sleep`, so a SIGTERM in
# that window ran this harness's EXIT trap in the CHILD. The child deleted
# MUTANT_DIR, and the mutation cases that sort after these failed now and then
# on CI with "mutant.1.sh: No such file or directory". No case can win that race
# on demand, so this one runs the trap's own code in a subshell, which is a
# forked child exactly as `sleep 30 &` is until its exec.
#
# The guard needs BASHPID, which bash 3.2 lacks. On bash 3.2 it always passes,
# and that is safe there: in 100 tries of `sleep & kill`, bash 3.2 ran no trap
# in a child that had not exec'd yet. It dropped the signal instead.
#
# The script's own `trap cleanup EXIT INT TERM` gets no such guard, on purpose.
# The flake bot runs it under bash 3.2, where the guard could not tell a child
# from its parent and no pre-exec child runs a trap anyway. It signals its
# spinners and deadline commands long after they exec. And the bash 3.2 lint
# (scripts/flake-bash32.test.sh) forbids BASHPID in it. Here, a pre-exec child
# that runs `cleanup` finds no spinners in its copy of SPINNER_PIDS and exits.

dir_state() { if [[ -d "$1" ]]; then echo present; else echo gone; fi; }

# Run trap command $1 in this shell with MUTANT_DIR aimed at directory $2, so no
# case can delete the real one. Wrap the call in ( ) to run it the way a forked
# child would.
run_trap_aimed_at() {
  local MUTANT_DIR="$2"
  eval "$1"
}

test_only_the_harness_shell_deletes_the_mutant_dir() {
  if [[ -z "${BASHPID:-}" ]]; then
    echo "ok   - bash $BASH_VERSION has no BASHPID, so the trap guard is not checked here"
    return 0
  fi
  local spec body unguarded decoy
  spec="$(trap -p EXIT)"
  eval "set -- $spec"
  body="${3:-}"
  # shellcheck disable=SC2016 # the trap's text, not its expansion
  assert_contains "the EXIT trap removes the mutant dir" "$body" 'rm -rf "$MUTANT_DIR"'

  # A guard that never deletes anything would pass the child check below, so
  # first the owner has to get through.
  decoy="$(mktmpd)"
  run_trap_aimed_at "$body" "$decoy"
  assert_eq "the harness shell itself deletes it" "gone" "$(dir_state "$decoy")"

  decoy="$(mktmpd)"
  ( run_trap_aimed_at "$body" "$decoy" )
  assert_eq "a forked child running the trap leaves the directory alone" "present" "$(dir_state "$decoy")"

  # MUTATION: the trap as it was before the guard, run by the same child.
  unguarded="${body#*&& }"
  # shellcheck disable=SC2016 # the trap's text, not its expansion
  assert_eq "the mutant really is the bare rm" 'rm -rf "$MUTANT_DIR"' "$unguarded"
  ( run_trap_aimed_at "$unguarded" "$decoy" )
  assert_eq "mutation: without the guard, a forked child deletes the directory" "gone" "$(dir_state "$decoy")"
  rm -rf "$decoy"
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
  printf 'TBD_RETRY_METRICS_PATH=%s\n' "${TBD_RETRY_METRICS_PATH-<unset>}"
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
  mutant_of mutant run_governed_fenced 's/^NO_VALVE_ENV=\(TBD_REMOTE_VERIFY=0 TBD_SWIFT_QUEUE_YIELD_SECONDS=\)$/NO_VALVE_ENV=(TBD_STRESS_MUTANT=1)/' || { rm -rf "$d"; return; }

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
  # The issues this loop comments on are #494, #961, #496 and #962 — stated in the PR
  # and asserted here so the two cannot drift apart silently.
  local spec issue seen=""
  for spec in "${TARGETS[@]}"; do
    issue="$(printf '%s' "$spec" | cut -d'|' -f4)"
    case " $seen " in *" $issue "*) ;; *) seen="$seen $issue" ;; esac
  done
  assert_eq "the loop attaches to exactly the documented issue set" " 494 961 496 962" "$seen"
}

# ---------------------------------------------------------------------------
# Structured outputs (flake autofix, docs/specs/2026-10-07-flake-autofix-design.md §4.1, §6.4)
# ---------------------------------------------------------------------------

test_xunit_dir_names_one_file_per_iteration() {
  local out
  out="$(XUNIT_DIR=/x; iteration_args FastPassWhole 3 | tr '\n' ' ')"
  assert_contains "xunit-dir passes --xunit-output per iteration" "$out" "--xunit-output /x/FastPassWhole-3.xml"
  assert_contains "and asks for failure messages inside the XML" "$out" "--experimental-xunit-message-failure"
  out="$(XUNIT_DIR=""; iteration_args FastPassWhole 3)"
  assert_eq "no xunit-dir, no extra args" "" "$out"
}

test_filters_are_never_glob_expanded() {
  # `[A-O]` in an unquoted expansion is a glob. A file in cwd named like the
  # pattern would silently replace the filter.
  local d; d="$(mktmpd)"
  local want=$'--parallel\n--filter\n^TBDDaemonTests\\.[A-O]'
  ( cd "$d" && : > '^TBDDaemonTests.A' && filter_args_of '--parallel --filter ^TBDDaemonTests\.[A-O]' ) > "$d/out"
  assert_eq "filter survives a matching file in cwd" "$want" "$(cat "$d/out")"
  # MUTATION: the unquoted word-split this replaced. The file in the cwd wins.
  local mutant
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  mutant_of mutant filter_args_of 's/read -r -a parts <<< "\$1"/parts=($1)/' || { rm -rf "$d"; return; }
  ( cd "$d" && bash -c "source '$mutant'; filter_args_of '--parallel --filter ^TBDDaemonTests\.[A-O]'" ) > "$d/mutant.out"
  assert_contains "mutation: an unquoted split expands the filter into the file name" \
    "$(cat "$d/mutant.out")" "^TBDDaemonTests.A"
  assert_eq "mutation: and the filter is gone" "0" "$(grep -c '\[A-O\]' "$d/mutant.out")"
  rm -rf "$d"
}

test_results_tsv_records_every_iteration_verdict() {
  local d; d="$(mktmpd)"
  local old="$RESULTS_TSV"
  RESULTS_TSV="$d/r.tsv"
  record_result Test 1 "PASS 1" 0 "2.5" 4 4 31
  record_result Test 2 "FAIL rc=1 with 1 tests executed" 1 "3.0" 4 4 29
  record_result Test 3 "FAIL ran 0 tests, below the measured floor of 1" 0 "3.0" 4 4 2
  record_result Test 4 "FAIL no 'Test run with N tests' summary — truncated log or wedged run (rc=1)" 1 "3.0" 4 4 5
  RESULTS_TSV="$old"
  assert_eq "four rows" "4" "$(wc -l < "$d/r.tsv" | tr -d ' ')"
  assert_eq "every row has ten columns" "10" "$(awk -F'\t' '{print NF}' "$d/r.tsv" | sort -u)"
  assert_eq "row 2 verdict column" "FAIL" "$(sed -n 2p "$d/r.tsv" | cut -f3)"
  assert_eq "row 1 count column" "1" "$(sed -n 1p "$d/r.tsv" | cut -f4)"
  assert_eq "row 2 count column parsed from reason" "1" "$(sed -n 2p "$d/r.tsv" | cut -f4)"
  assert_eq "row 3 below-floor count parsed" "0" "$(sed -n 3p "$d/r.tsv" | cut -f4)"
  assert_eq "row 4 no summary, no count" "" "$(sed -n 4p "$d/r.tsv" | cut -f4)"
  assert_eq "row 1 seconds column" "31" "$(sed -n 1p "$d/r.tsv" | cut -f9)"
  assert_eq "row 2 reason column" "rc=1 with 1 tests executed" "$(sed -n 2p "$d/r.tsv" | cut -f10)"
  rm -rf "$d"
}

test_metrics_dir_reaches_the_fenced_run() {
  local d; d="$(mktmpd)"
  local record="$d/record"
  mk_stub_wrapper "$d/scripts" test.sh
  ( SCRIPT_DIR="$d/scripts"; ITER_METRICS_PATH="$d/m/T-1.jsonl"
    STUB_RECORD="$record" run_governed_fenced 5 "$d/log" --no-fingerprint )
  assert_eq "TBD_RETRY_METRICS_PATH set per iteration" "$d/m/T-1.jsonl" "$(recorded "$record" TBD_RETRY_METRICS_PATH)"
  ( SCRIPT_DIR="$d/scripts"; ITER_METRICS_PATH=""
    STUB_RECORD="$record" run_governed_fenced 5 "$d/log" --no-fingerprint )
  assert_eq "and not set at all without --metrics-dir" "<unset>" "$(recorded "$record" TBD_RETRY_METRICS_PATH)"
  rm -rf "$d"
}

# Drive one real iteration of run_target against the stub wrapper, in a child
# shell so the globals it sets stay there. The caller reads the stub's record
# and the files left behind.
run_one_stub_iteration() {
  local script="$1" d="$2"
  STUB_RECORD="$d/record" bash -c "source '$script'
    SCRIPT_DIR='$d/scripts'; REPORT_DIR='$d/reports'; NCPU=4
    XUNIT_DIR='$d/x'; METRICS_DIR='$d/m'; LOG_DIR='$d/logs'; RESULTS_TSV='$d/r.tsv'
    run_target 'Stub|--parallel --filter ^M\\.S/f\\(\\)|1|adhoc|stub target' 1 '$d/work'" >/dev/null 2>&1
}

test_run_target_wires_every_structured_output() {
  local d; d="$(mktmpd)"
  mk_stub_wrapper "$d/scripts" test.sh
  mkdir -p "$d/reports" "$d/x" "$d/m" "$d/logs" "$d/work"
  run_one_stub_iteration "$SCRIPT" "$d"
  assert_eq "the metrics file is pre-created, empty" "empty" \
    "$( [[ -f "$d/m/Stub-1.jsonl" && ! -s "$d/m/Stub-1.jsonl" ]] && echo empty || echo absent-or-nonempty)"
  assert_eq "and its path reached the test process" "$d/m/Stub-1.jsonl" "$(recorded "$d/record" TBD_RETRY_METRICS_PATH)"
  assert_eq "the filter and the xunit args reach test.sh as separate words" \
    "--no-fingerprint --parallel --filter ^M\\.S/f\\(\\) --xunit-output $d/x/Stub-1.xml --experimental-xunit-message-failure" \
    "$(recorded "$d/record" argv)"
  assert_eq "the iteration log lands in --log-dir" "yes" "$([[ -f "$d/logs/Stub-1.log" ]] && echo yes || echo no)"
  assert_eq "one results row" "1" "$(wc -l < "$d/r.tsv" | tr -d ' ')"
  assert_eq "scored FAIL: the stub printed no summary" "FAIL" "$(cut -f3 "$d/r.tsv")"
  assert_eq "with the core count" "4" "$(cut -f8 "$d/r.tsv")"
  assert_eq "and a numeric seconds column" "yes" "$([[ "$(cut -f9 "$d/r.tsv")" =~ ^[0-9]+$ ]] && echo yes || echo no)"

  # MUTATION: drop the pre-create, and an iteration whose test process never
  # wrote a record leaves no file at all.
  local e mutant; e="$(mktmpd)"
  mk_stub_wrapper "$e/scripts" test.sh
  mkdir -p "$e/reports" "$e/x" "$e/m" "$e/logs" "$e/work"
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  mutant_of mutant run_target '/: > "\$ITER_METRICS_PATH"/d' || { rm -rf "$d" "$e"; return; }
  run_one_stub_iteration "$mutant" "$e"
  assert_eq "mutation: without the pre-create the metrics file is absent" "absent" \
    "$([[ -e "$e/m/Stub-1.jsonl" ]] && echo present || echo absent)"
  rm -rf "$d" "$e"
}

# ---------------------------------------------------------------------------
# Ad hoc targets: --test and --pass-of (spec §4.2, §6.2, §6.4)
# ---------------------------------------------------------------------------

test_filter_form_converts_the_xunit_id() {
  assert_eq "top-level suite unchanged" 'M.S/f()' "$(filter_form_of 'M.S/f()')"
  assert_eq "nested suite" 'M.A/B/f()' "$(filter_form_of 'M.A.B/f()')"
  assert_eq "doubly nested suite" 'M.A/B/C/f()' "$(filter_form_of 'M.A.B.C/f()')"
  assert_eq "no suite" 'M.f()' "$(filter_form_of 'M/f()')"
  assert_eq "argument labels survive" 'M.S/f(x:y:)' "$(filter_form_of 'M.S/f(x:y:)')"
  # flake_lib.filter_id (a later slice) must agree; until it exists this
  # compares against the expected literal.
  assert_eq "agrees with flake_lib.filter_id" \
    "$(python3 -c "import sys; sys.path.insert(0,'$HERE'); import flake_lib; print(flake_lib.filter_id('M.A.B/f()'))" 2>/dev/null || echo 'M.A/B/f()')" \
    "$(filter_form_of 'M.A.B/f()')"
}

test_exact_id_filter_escapes_the_id() {
  assert_eq "parens and dots escaped, anchored at start" \
    '^TBDSharedTests\.HolderLockTests/lockIsReacquirableAfterRelease\(\)(/|$)' \
    "$(exact_id_filter 'TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()')"
  assert_eq "argument labels survive" '^M\.S/f\(x:\)(/|$)' "$(exact_id_filter 'M.S/f(x:)')"
  assert_eq "a nested suite is escaped in its filter form" '^M\.A/B/f\(\)(/|$)' "$(exact_id_filter 'M.A.B/f()')"
  assert_eq "a suite-less test too" '^M\.f\(\)(/|$)' "$(exact_id_filter 'M/f()')"
  # The escaped filter must match exactly the filter form, as an ERE.
  local re; re="$(exact_id_filter 'M.S/f(x:)')"
  assert_eq "the filter matches its own test" "yes" "$([[ 'M.S/f(x:)' =~ $re ]] && echo yes || echo no)"
  assert_eq "and not a test whose dot is another character" "no" "$([[ 'MxS/f(x:)' =~ $re ]] && echo yes || echo no)"
  # The trailing group (spec §6.4): an XCTest name has no `()` to end it.
  re="$(exact_id_filter 'M.S/testFoo')"
  assert_eq "an XCTest name matches itself" "yes" "$([[ 'M.S/testFoo' =~ $re ]] && echo yes || echo no)"
  assert_eq "and a trailing component" "yes" "$([[ 'M.S/testFoo/File.swift:12:3' =~ $re ]] && echo yes || echo no)"
  assert_eq "but not a test whose name extends it" "no" "$([[ 'M.S/testFooBar' =~ $re ]] && echo yes || echo no)"
  # MUTATION: stop escaping `(`, and the filter is no longer the ID.
  local mutant
  mutant_of mutant exact_id_filter 's/\+\?\(/+?/' || return
  assert_eq "mutation: without the ( escape the filter changes" \
    '^M\.S/f(x:\)(/|$)' "$(bash -c "source '$mutant'; exact_id_filter 'M.S/f(x:)'")"
  # MUTATION: drop the trailing group, and testFooBar matches.
  mutant_of mutant exact_id_filter "s/printf '\\^%s\\(\\/\\|\\\$\\)'/printf '^%s'/" || return
  re="$(bash -c "source '$mutant'; exact_id_filter 'M.S/testFoo'")"
  assert_eq "mutation: without the trailing group testFooBar matches" "yes" "$([[ 'M.S/testFooBar' =~ $re ]] && echo yes || echo no)"
}

test_test_mode_floor_is_one() {
  local spec; spec="$(adhoc_test_spec 'M.S/f()')"
  assert_eq "floor 1" "1" "$(spec_field "$spec" 3)"
  assert_contains "filter built from the ID" "$spec" '--filter ^M\.S/f\(\)(/|$)'
  assert_eq "no parallelism flag of its own" '--filter ^M\.S/f\(\)(/|$)' "$(spec_field "$spec" 2)"
  adhoc_test_spec 'M.S/f()' > /dev/null
  assert_eq "test scope uses the ordinary iteration deadline" "$ITERATION_DEADLINE_S" "$(iteration_deadline_for 1)"
}

test_pass_of_maps_each_target_to_its_ci_pass() {
  local cases=(
    'TBDDaemonTests.HolderTests/a()|Pass-fast-pass-daemon-a|1200'
    'TBDDaemonTests.ArchiveTests/x()|Pass-fast-pass-daemon-a|1200'
    'TBDDaemonTests.OrphanGCTests/a()|Pass-fast-pass-daemon-a|1200'
    'TBDDaemonTests.PRStatusTests/x()|Pass-fast-pass-daemon-b|1500'
    'TBDDaemonTests.SessionStatesRPCTests/a()|Pass-fast-pass-daemon-b|1500'
    'TBDDaemonTests.TBDHomeSerialized.AutoCloseSetupTests/a()|Pass-fast-pass-daemon-b|1500'
    'TBDDaemonTests/nilPreferredKeepsOrder()|Pass-fast-pass-daemon-b|1500'
    'TBDDaemonLiveTests.GitManagerTimeoutTests/a()|Pass-quiet-pass|35'
    'TBDAppTests.ArchiveTombstoneTests/testArchiving|Pass-fast-pass-app-a|1400'
    'TBDAppTests.PanelTabTests/a()|Pass-fast-pass-app-a|1400'
    'TBDAppTests.QuietIngestTests/a()|Pass-fast-pass-app-b|3200'
    'TBDAppTests.TranscriptEstimatorAccuracyTests/a()|Pass-fast-pass-app-b|3200'
    # A suite-less app test's filter form is `TBDAppTests.<name>()`, so it runs
    # in 2b unless its function name starts with an uppercase A–P.
    'TBDAppTests/suiteLessTest()|Pass-fast-pass-app-b|3200'
    'TBDAppTests/PascalCaseTest()|Pass-fast-pass-app-a|1400'
    'TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()|Pass-fast-pass-app-b|3200'
    'TBDSharedTests/topLevel()|Pass-fast-pass-app-b|3200'
    'TBDCLITests.ArgsTests/a()|Pass-fast-pass-app-b|3200'
  )
  local c id want_name want_floor spec
  for c in "${cases[@]}"; do
    IFS='|' read -r id want_name want_floor <<< "$c"
    spec="$(pass_spec_of "$id")"
    assert_eq "$id -> pass" "$want_name" "$(spec_field "$spec" 1)"
    assert_eq "$id -> floor" "$want_floor" "$(spec_field "$spec" 3)"
    assert_eq "$id -> ad hoc" "adhoc" "$(spec_field "$spec" 4)"
  done
  # A suite-less test's xunit classname is the bare module, which `^TBDDaemonTests\.`
  # does not match; only its FILTER form does. Matching the classname instead
  # would send it to fast pass 2b, where CI never runs it.
  local mutant
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  mutant_of mutant pass_spec_of 's/^  form="\$\(filter_form_of "\$id"\)"/  form="${id%\/*}"/' || return
  assert_eq "mutation: matching the classname misplaces a suite-less test" "Pass-fast-pass-app-b" \
    "$(bash -c "source '$mutant'; pass_spec_of 'TBDDaemonTests/nilPreferredKeepsOrder()'" | cut -d'|' -f1)"
}

test_a_filter_containing_a_pipe_keeps_its_floor() {
  # Fast pass 2b's skip regex holds a `|`. Read with `IFS='|'`, the floor field
  # would be the tail of that regex and every iteration would fail its floor.
  local spec; spec="$(pass_spec_of 'TBDAppTests.X/y()')"
  assert_eq "the whole filter" "--parallel --skip ^(TBDDaemonTests\\.|TBDDaemonLiveTests\\.|TBDAppTests\\.[A-P])" "$(spec_field "$spec" 2)"
  assert_eq "the floor" "3200" "$(spec_field "$spec" 3)"
  assert_eq "the issue field" "adhoc" "$(spec_field "$spec" 4)"
  assert_eq "a TARGETS line reads as before" "GitManagerTimeout|3|503" \
    "$(s='GitManagerTimeout|--no-parallel --filter ^X|3|503|desc'; printf '%s|%s|%s' "$(spec_field "$s" 1)" "$(spec_field "$s" 3)" "$(spec_field "$s" 4)")"
}

test_pass_of_ranges_are_code_point_ranges() {
  # A lowercase first letter is outside `[A-O]` for SwiftPM. In a collating
  # locale bash's `[A-O]` can admit it; the harness pins C collation. No
  # mutation case: whether a collating range admits lowercase depends on the
  # platform's regex library, so removing the pin flips this only on some hosts.
  assert_eq "lowercase suite name -> 1b, under any caller locale" "Pass-fast-pass-daemon-b" \
    "$(LC_ALL=en_US.UTF-8 pass_spec_of 'TBDDaemonTests.lowercaseSuite/x()' 2>/dev/null | cut -d'|' -f1)"
  assert_eq "lowercase app suite name -> 2b, under any caller locale" "Pass-fast-pass-app-b" \
    "$(LC_ALL=en_US.UTF-8 pass_spec_of 'TBDAppTests.lowercaseSuite/x()' 2>/dev/null | cut -d'|' -f1)"
}

test_pass_of_refuses_an_ambiguous_or_unmatched_id() {
  # MUTATION: widen 1a to every letter. SessionStatesRPCTests is then run by
  # 1a AND 1b, and the harness must refuse rather than pick one.
  local mutant out rc=0
  mutant_of mutant pass_spec_of 's/^(  "fast-pass-daemon-a.*)\[A-O\]/\1[A-Z]/' || return
  assert_contains "the mutant really widened 1a" "$(grep fast-pass-daemon-a "$mutant" | head -1)" "[A-Z]"
  out="$(bash -c "source '$mutant'; pass_spec_of 'TBDDaemonTests.SessionStatesRPCTests/a()'" 2>&1)" || rc=$?
  assert_eq "mutation: a 1a widened to [A-Z] no longer maps the P-Z suite" "1" "$rc"
  assert_contains "and says it is run by two passes" "$out" "two CI passes"
  # MUTATION: widen 2a to every letter while 2b still skips only A-P.
  # QuietIngestTests is then run by 2a AND 2b.
  mutant_of mutant pass_spec_of 's/^(  "fast-pass-app-a.*)\[A-P\]/\1[A-Z]/' || return
  assert_contains "the mutant really widened 2a" "$(grep fast-pass-app-a "$mutant" | head -1)" "[A-Z]"
  rc=0
  out="$(bash -c "source '$mutant'; pass_spec_of 'TBDAppTests.QuietIngestTests/a()'" 2>&1)" || rc=$?
  assert_eq "mutation: a 2a widened to [A-Z] no longer maps the Q-Z suite" "1" "$rc"
  assert_contains "and says it is run by two passes" "$out" "two CI passes"
  # MUTATION: drop the quiet pass. A live test then lands in no pass.
  mutant_of mutant pass_spec_of '/^  "quiet-pass\|/d' || return
  rc=0
  out="$(bash -c "source '$mutant'; pass_spec_of 'TBDDaemonLiveTests.GitManagerTimeoutTests/a()'" 2>&1)" || rc=$?
  assert_eq "mutation: without the quiet pass a live test is unmatched" "1" "$rc"
  assert_contains "and says so" "$out" "no CI pass runs"
}

# Spec §13: the pass table is checked against the watched-test-pass.sh
# invocations PARSED from test.yml, and a fixture test.yml with a changed filter
# or floor must make the check fail.
test_the_pass_table_matches_test_yml() {
  local wf="$HERE/../.github/workflows/test.yml"
  assert_eq "five invocations parsed from test.yml" "5" "$(pass_table_from_workflow "$wf" | grep -c .)"
  assert_eq "real test.yml agrees" "0" "$(check_pass_table "$wf" >/dev/null 2>&1; echo $?)"
  local d; d="$(mktmpd)"
  # Each floor below is used by one step only, so each mutation changes one
  # step's floor and no other step's copy can mask it.
  sed 's/--floor 1500/--floor 1600/' "$wf" > "$d/floor.yml"
  assert_eq "the 1b floor mutation changes one line" "1" "$(diff "$wf" "$d/floor.yml" | grep -c '^>')"
  assert_eq "a changed 1b floor is caught" "1" "$(check_pass_table "$d/floor.yml" >/dev/null 2>&1; echo $?)"
  sed 's/--floor 1400/--floor 1300/' "$wf" > "$d/floor-2a.yml"
  assert_eq "the 2a floor mutation changes one line" "1" "$(diff "$wf" "$d/floor-2a.yml" | grep -c '^>')"
  assert_eq "a changed 2a floor is caught" "1" "$(check_pass_table "$d/floor-2a.yml" >/dev/null 2>&1; echo $?)"
  sed 's/--floor 3200/--floor 2500/' "$wf" > "$d/floor-2b.yml"
  assert_eq "the 2b floor mutation changes one line" "1" "$(diff "$wf" "$d/floor-2b.yml" | grep -c '^>')"
  assert_eq "a changed 2b floor is caught" "1" "$(check_pass_table "$d/floor-2b.yml" >/dev/null 2>&1; echo $?)"
  sed "s/\[A-O\]/[A-N]/g" "$wf" > "$d/filter.yml"
  assert_eq "a changed filter is caught" "1" "$(check_pass_table "$d/filter.yml" >/dev/null 2>&1; echo $?)"
  sed "s/ --no-parallel / /" "$wf" > "$d/par.yml"
  assert_eq "a changed parallelism flag is caught" "1" "$(check_pass_table "$d/par.yml" >/dev/null 2>&1; echo $?)"
  : > "$d/empty.yml"
  assert_eq "a workflow with no invocations is caught" "1" "$(check_pass_table "$d/empty.yml" >/dev/null 2>&1; echo $?)"
  rm -rf "$d"
}

# The argument after flag $3 (`--filter` or `--skip`) on pass $2's line of
# workflow $1's pass table, or nothing.
pass_arg() {
  local line i
  local -a parts
  line="$(pass_table_from_workflow "$1" | grep "^$2|")"
  read -r -a parts <<< "${line#*|*|}"
  for ((i = 0; i + 1 < ${#parts[@]}; i++)); do
    [[ "${parts[i]}" == "$3" ]] && { printf '%s' "${parts[i + 1]}"; return 0; }
  done
  return 1
}

# 2a's `[X-Y]` range, read from a `--filter` that must be exactly
# `^TBDAppTests\.[X-Y]`, or nothing.
app_cut_range() {
  local filter re='^\^TBDAppTests\\\.(\[[^]]+\])$'
  filter="$(pass_arg "$1" fast-pass-app-a --filter)" || return 1
  [[ "$filter" =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# The `--skip` 2b must carry for 2a's range $1: the two daemon targets and that
# range of TBDAppTests, and nothing else.
expected_app_b_skip() { printf '^(TBDDaemonTests\\.|TBDDaemonLiveTests\\.|TBDAppTests\\.%s)' "$1"; }

# Exit 0 when 2b's whole `--skip` in workflow $1 is the one 2a's range asks
# for. Comparing the whole regex, not one group of it, is what catches an
# extra alternative.
check_app_cut() {
  local range skip
  range="$(app_cut_range "$1")" && [[ -n "$range" ]] || return 1
  skip="$(pass_arg "$1" fast-pass-app-b --skip)" || return 1
  [[ "$skip" == "$(expected_app_b_skip "$range")" ]]
}

# 2a runs the TBDAppTests suites in one letter range, and 2b skips exactly that
# range beside the two daemon targets, so every TBDAppTests suite runs in one
# half. Move 2a's range alone and the suites between the two ranges run twice
# or nowhere; add a TBDAppTests alternative to 2b's skip and the suites it
# names run nowhere.
test_the_app_halves_cut_at_one_range() {
  local wf="$HERE/../.github/workflows/test.yml" d
  assert_eq "2a's filter is one TBDAppTests range" "1" "$(app_cut_range "$wf" | grep -c '^\[.*\]$')"
  assert_eq "2b skips the daemon targets and exactly 2a's range" \
    "$(expected_app_b_skip "$(app_cut_range "$wf")")" "$(pass_arg "$wf" fast-pass-app-b --skip)"
  assert_eq "real test.yml cuts at one range" "0" "$(check_app_cut "$wf"; echo $?)"
  d="$(mktmpd)"
  # MUTATION: only 2a's range moves to [A-Q].
  sed '/--name fast-pass-app-a /,/xunit-app-a\.xml/ s/\[A-P\]/[A-Q]/' "$wf" > "$d/a.yml"
  assert_eq "the mutant moved 2a's range" "[A-Q]" "$(app_cut_range "$d/a.yml")"
  assert_contains "and left 2b's" "$(pass_arg "$d/a.yml" fast-pass-app-b --skip)" "TBDAppTests\\.[A-P])"
  assert_eq "mutation: 2a's range moved alone is caught" "1" "$(check_app_cut "$d/a.yml"; echo $?)"
  # MUTATION: only 2b's range moves to [A-Q].
  sed '/--name fast-pass-app-b /,/xunit-app-b\.xml/ s/\[A-P\]/[A-Q]/' "$wf" > "$d/b.yml"
  assert_contains "the mutant moved 2b's range" "$(pass_arg "$d/b.yml" fast-pass-app-b --skip)" "TBDAppTests\\.[A-Q])"
  assert_eq "and left 2a's" "[A-P]" "$(app_cut_range "$d/b.yml")"
  assert_eq "mutation: 2b's range moved alone is caught" "1" "$(check_app_cut "$d/b.yml"; echo $?)"
  # MUTATION: an extra TBDAppTests alternative in 2b's skip only. Its first
  # TBDAppTests group still matches 2a's range, so a check that read one group
  # would pass it.
  sed '/--name fast-pass-app-b /,/xunit-app-b\.xml/ s/TBDAppTests\\\.\[A-P\])/TBDAppTests\\.[A-P]|TBDAppTests\\.Q)/' \
    "$wf" > "$d/extra.yml"
  assert_contains "the mutant added an alternative" "$(pass_arg "$d/extra.yml" fast-pass-app-b --skip)" \
    "TBDAppTests\\.[A-P]|TBDAppTests\\.Q)"
  assert_eq "and left 2a's range" "[A-P]" "$(app_cut_range "$d/extra.yml")"
  assert_eq "mutation: an extra TBDAppTests alternative in 2b's skip is caught" "1" \
    "$(check_app_cut "$d/extra.yml"; echo $?)"
  # Both moved together is a re-cut, not drift: the check compares the two,
  # it does not pin one range.
  sed '/--name fast-pass-app-[ab] /,/xunit-app-[ab]\.xml/ s/\[A-P\]/[A-Q]/' "$wf" > "$d/both.yml"
  assert_eq "the mutant moved 2a's range" "[A-Q]" "$(app_cut_range "$d/both.yml")"
  assert_contains "and 2b's" "$(pass_arg "$d/both.yml" fast-pass-app-b --skip)" "TBDAppTests\\.[A-Q])"
  assert_eq "a re-cut that moves both ranges passes" "0" "$(check_app_cut "$d/both.yml"; echo $?)"
  rm -rf "$d"
}

# CI builds once, in a step of its own, and every pass runs with `--skip-build`.
# This harness builds before its first iteration and must never inherit the
# flag: carried into CI_PASSES it would test whatever bundle the tree last
# built. So the parser drops it, and the mutation proves the drop is what keeps
# the real test.yml in agreement rather than the flag being absent.
test_the_pass_table_drops_skip_build() {
  local wf="$HERE/../.github/workflows/test.yml" mutant rc
  assert_eq "every CI pass in test.yml carries --skip-build" "5" \
    "$(grep -c -e '-- --fingerprint --skip-build ' "$wf")"
  assert_eq "no parsed pass carries it" "0" \
    "$(pass_table_from_workflow "$wf" | grep -c -e '--skip-build')"
  assert_eq "and none of CI_PASSES does" "0" \
    "$(printf '%s\n' "${CI_PASSES[@]}" | grep -c -e '--skip-build')"
  # MUTATION: stop dropping --skip-build. The real test.yml then disagrees.
  mutant_of mutant check_pass_table 's/--fingerprint\|--skip-build\|/--fingerprint|/' || return
  assert_contains "the mutant really stopped dropping it" \
    "$(grep -e '--fingerprint|' "$mutant" | head -1)" "--fingerprint|--experimental"
  rc=0
  bash -c "source '$mutant'; check_pass_table '$wf'" >/dev/null 2>&1 || rc=$?
  assert_eq "mutation: without the drop, test.yml no longer agrees" "1" "$rc"
}

# The other half of that flag, and the dangerous one. A pass with `--skip-build`
# runs whatever test bundle `.build/` holds, so after a failed or killed build it
# would test the cache's bundle instead of the commit — and could go green. Every
# step that forwards the flag must therefore name the build step's success in its
# own `if:`. It lives here because this harness already reads test.yml's pass
# invocations and owns the drop above, and the `script-harnesses` job runs it.
#
# One line per step that forwards `--skip-build` as an argument: `gated <name>`
# or `UNGATED <name>`. Comment lines are ignored, so prose that mentions the flag
# does not count as forwarding it, and the first `if:` of the step is the one
# judged.
skip_build_gates() {
  awk -v gate="steps.build.outcome == 'success'" '
    function flush() {
      if (name != "" && skip) print (index(cond, gate) ? "gated" : "UNGATED"), name
      name = ""; cond = ""; skip = 0
    }
    /^      - / { flush(); name = $0; sub(/^      - (name: )?/, "", name); next }
    /^[^ #]/ || /^  [^ #]/ { flush(); next }
    name == "" || /^[ \t]*#/ { next }
    /^        if:/ { if (cond == "") cond = $0; next }
    { for (i = 1; i <= NF; i++) if ($i == "--skip-build") skip = 1 }
    END { flush() }
  ' "$1"
}

test_every_skip_build_pass_is_gated_on_the_build() {
  local wf="$HERE/../.github/workflows/test.yml" d
  assert_eq "five steps in test.yml forward --skip-build" "5" \
    "$(skip_build_gates "$wf" | grep -c .)"
  assert_eq "every one names the build step's success in its if:" "" \
    "$(skip_build_gates "$wf" | grep '^UNGATED')"
  d="$(mktmpd)"
  # MUTATION: drop the build clause from the passes that run after a red 1a.
  # Their `!cancelled()` would then run them after a failed build too.
  sed "s/steps\.build\.outcome == 'success' && //" "$wf" > "$d/later.yml"
  assert_eq "mutation: 1b, 2a, 2b and the quiet pass without the clause are caught" "4" \
    "$(skip_build_gates "$d/later.yml" | grep -c '^UNGATED')"
  # MUTATION: 1a gated on `!cancelled()` alone, which would run it after a
  # failed build.
  sed "s/if: \${{ !cancelled() && steps\.build\.outcome == 'success' }}/if: \${{ !cancelled() }}/" "$wf" > "$d/first.yml"
  assert_contains "mutation: 1a without the clause is caught" \
    "$(skip_build_gates "$d/first.yml" | grep '^UNGATED')" "pass 1a"
  # MUTATION: 1a with no `if:` at all.
  sed "/if: \${{ !cancelled() && steps\.build\.outcome == 'success' }}/d" "$wf" > "$d/none.yml"
  assert_contains "mutation: 1a with no if: is caught" \
    "$(skip_build_gates "$d/none.yml" | grep '^UNGATED')" "pass 1a"
  rm -rf "$d"
}

# CI's build flags are the other word every pass carries that this harness must
# never inherit: CI compiles with less debug information than SwiftPM's default,
# this script builds with the default, and its iterations run without
# `--skip-build`, so an iteration carrying the flags would compile the whole
# package again. The parser drops the word, and the mutation proves the drop is
# what keeps the real test.yml in agreement rather than the word being absent.
test_the_pass_table_drops_the_ci_build_flags() {
  local wf="$HERE/../.github/workflows/test.yml" mutant rc
  assert_eq "every CI pass in test.yml carries the flags right after --skip-build" "5" \
    "$(grep -c -F -e "-- --fingerprint --skip-build $CI_SWIFTPM_FLAGS_WORD " "$wf")"
  assert_eq "no parsed pass carries them" "0" \
    "$(pass_table_from_workflow "$wf" | grep -c -F -e "$CI_SWIFTPM_FLAGS_WORD")"
  assert_eq "and none of CI_PASSES does" "0" \
    "$(printf '%s\n' "${CI_PASSES[@]}" | grep -c -F -e 'swiftpm_flags')"
  # MUTATION: stop dropping the flags word. The real test.yml then disagrees.
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  mutant_of mutant check_pass_table '/^ *"\$CI_SWIFTPM_FLAGS_WORD"\) ;;$/d' || return
  # shellcheck disable=SC2016 # the script's own text, matched literally
  assert_eq "the mutant really stopped dropping them" "0" \
    "$(grep -c -F -e '"$CI_SWIFTPM_FLAGS_WORD") ;;' "$mutant")"
  rc=0
  bash -c "source '$mutant'; check_pass_table '$wf'" >/dev/null 2>&1 || rc=$?
  assert_eq "mutation: without the drop, test.yml no longer agrees" "1" "$rc"
}

# The CI build flags are defined once, as the `test` job's CI_SWIFTPM_FLAGS, and
# must reach every command in that job that reaches SwiftPM: the build and every
# pass, which re-plans the build graph from its own command line. A step that
# leaves them out builds or plans with SwiftPM's defaults, and nothing red says
# so. This lives here for the reason `skip_build_gates` does: this harness
# already reads test.yml's pass invocations and owns the drop above, and the
# `script-harnesses` job runs it.
#
# One line per command in the `test` job that runs `scripts/swift-safe`,
# `scripts/test.sh` or `scripts/ci/watched-test-pass.sh`, continuation lines
# joined: `carries <step>` when the step has read the variable into
# `swiftpm_flags` with the `:?` guard before that command and the command
# expands the array, `DROPS <step>` otherwise. Expanding the array without the
# read would pass nothing, which is why the read is required too. Comment lines
# are ignored, so prose that names a script does not count as running it.
swiftpm_flag_carriers() {
  awk -v word="$CI_SWIFTPM_FLAGS_WORD" -v sq="'" '
    function new_step() { reads = 0; acc = "" }
    /^  [^ #]/ { job = $1; sub(/:.*$/, "", job); name = ""; new_step(); next }
    /^[^ #]/ { job = ""; name = ""; new_step(); next }
    /^      - / { name = $0; sub(/^      - (name: )?/, "", name); new_step(); next }
    job != "test" || name == "" || /^[ \t]*#/ { next }
    {
      line = $0
      cont = sub(/\\[ \t]*$/, "", line)
      acc = acc " " line
      if (cont) next
      if (index(acc, "read -r -a swiftpm_flags <<< \"${CI_SWIFTPM_FLAGS:?")) reads = 1
      n = split(acc, w, /[ \t]+/)
      runs = 0; carries = 0
      for (i = 1; i <= n; i++) {
        if (w[i] == word) carries = 1
        t = w[i]; gsub(/"/, "", t); gsub(sq, "", t)
        if (t ~ /(^|\/)scripts\/(swift-safe|test\.sh|ci\/watched-test-pass\.sh)$/) runs = 1
      }
      acc = ""
      if (runs) print ((reads && carries) ? "carries" : "DROPS"), name
    }
  ' "$1"
}

# The `CI_SWIFTPM_FLAGS:` lines of the `test` job's env block whose value is
# quoted and non-blank.
ci_flags_definitions() {
  awk '/^  [^ #]/ { job = $1 } job == "test:" && /^      CI_SWIFTPM_FLAGS: "[^" ]/' "$1"
}

test_every_swiftpm_command_in_the_test_job_carries_the_ci_build_flags() {
  local wf="$HERE/../.github/workflows/test.yml" d
  assert_eq "the test job defines CI_SWIFTPM_FLAGS, non-empty" "1" \
    "$(ci_flags_definitions "$wf" | grep -c .)"
  assert_eq "six commands in the test job reach SwiftPM: the build and five passes" "6" \
    "$(swiftpm_flag_carriers "$wf" | grep -c .)"
  assert_eq "every one carries the flags" "" "$(swiftpm_flag_carriers "$wf" | grep '^DROPS')"
  assert_contains "the build step is one of them" "$(swiftpm_flag_carriers "$wf")" "carries Build ("
  d="$(mktmpd)"
  # MUTATION: the definition emptied. Every step's `:?` would then fail it at
  # run time; this says so before a run.
  sed 's/^      CI_SWIFTPM_FLAGS: ".*"$/      CI_SWIFTPM_FLAGS: ""/' "$wf" > "$d/empty.yml"
  assert_eq "mutation: an empty definition is caught" "0" \
    "$(ci_flags_definitions "$d/empty.yml" | grep -c .)"
  # MUTATION: no command expands the array.
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  sed 's/ "\${swiftpm_flags\[@\]}"//' "$wf" > "$d/unexpanded.yml"
  assert_eq "mutation: every command without the expansion is caught" "6" \
    "$(swiftpm_flag_carriers "$d/unexpanded.yml" | grep -c '^DROPS')"
  # MUTATION: the build alone loses them, which would leave every pass planning
  # flags the build never compiled with.
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  sed 's/-j "\$TBD_SWIFT_JOBS" "\${swiftpm_flags\[@\]}"/-j "$TBD_SWIFT_JOBS"/' "$wf" > "$d/build.yml"
  assert_contains "mutation: the build step without them is caught" \
    "$(swiftpm_flag_carriers "$d/build.yml" | grep '^DROPS')" "DROPS Build ("
  # MUTATION: the array expanded but never read — it would expand to nothing.
  sed '/read -r -a swiftpm_flags/d' "$wf" > "$d/unread.yml"
  assert_eq "mutation: expanding an array no step read is caught" "6" \
    "$(swiftpm_flag_carriers "$d/unread.yml" | grep -c '^DROPS')"
  # MUTATION: a retry step added after the passes, copied without the flags.
  { cat "$wf"
    cat <<'RETRY'
      - name: Retry the quiet pass
        run: |
          scripts/ci/watched-test-pass.sh \
            --name quiet-retry --budget-seconds 720 --floor 35 --floor-message 'x' \
            -- --fingerprint --skip-build --filter '^TBDDaemonLiveTests\.' --no-parallel
RETRY
  } > "$d/retry.yml"
  assert_eq "mutation: a retry without the flags is caught" "DROPS Retry the quiet pass" \
    "$(swiftpm_flag_carriers "$d/retry.yml" | grep '^DROPS')"
  rm -rf "$d"
}

test_pass_of_filters_match_test_yml_verbatim() {
  # The pass map must not drift from CI. Each filter string, as CI spells it
  # inside single quotes, has to appear in test.yml along with its floor.
  local wf="$HERE/../.github/workflows/test.yml" body; body="$(cat "$wf")"
  assert_contains "1a filter in test.yml"  "$body" "--parallel --filter '^TBDDaemonTests\.[A-O]'"
  assert_contains "1b filter in test.yml"  "$body" "--parallel --filter '^TBDDaemonTests\.' --skip '^TBDDaemonTests\.[A-O]'"
  assert_contains "2a filter in test.yml"  "$body" "--parallel --filter '^TBDAppTests\.[A-P]'"
  assert_contains "2b filter in test.yml"  "$body" "--parallel --skip '^(TBDDaemonTests\.|TBDDaemonLiveTests\.|TBDAppTests\.[A-P])'"
  assert_contains "quiet filter in test.yml" "$body" "--filter '^TBDDaemonLiveTests\.' --no-parallel"
  # Once each: no two steps share a floor, so a change to one step's floor
  # cannot hide behind another step's copy of the same number.
  local floor; for floor in 1200 1500 1400 3200 35; do
    assert_eq "floor $floor once in test.yml" "1" "$(grep -cE -- "--floor $floor( |\$)" "$wf")"
  done
  # And the harness's own copies equal those strings once CI's quotes are removed.
  assert_eq "harness 1a args" "--parallel --filter ^TBDDaemonTests\.[A-O]" "$(spec_field "$(pass_spec_of 'TBDDaemonTests.A/x()')" 2)"
}

test_pass_of_first_iteration_gets_the_warmup_deadline() {
  pass_spec_of 'TBDSharedTests.X/y()' > /dev/null
  assert_eq "first iteration" "$PASS_FIRST_ITERATION_DEADLINE_S" "$(iteration_deadline_for 1)"
  assert_eq "later iteration" "$PASS_ITERATION_DEADLINE_S" "$(iteration_deadline_for 2)"
  pass_spec_of 'TBDDaemonLiveTests.X/y()' > /dev/null
  assert_eq "quiet pass first iteration" "$QUIET_FIRST_ITERATION_DEADLINE_S" "$(iteration_deadline_for 1)"
  assert_eq "quiet pass later iteration" "$QUIET_ITERATION_DEADLINE_S" "$(iteration_deadline_for 2)"
  ADHOC_FIRST_DEADLINE_S=""; ADHOC_DEADLINE_S=""; ADHOC_INDUCE_LOAD=1
  assert_eq "a TARGETS entry keeps the ordinary deadline" "$ITERATION_DEADLINE_S" "$(iteration_deadline_for 1)"
}

test_the_quiet_pass_runs_without_induced_load() {
  # Both branches of the gate: the quiet pass turns load off, a fast pass and a
  # single test leave it on, and --no-load still wins everywhere.
  pass_spec_of 'TBDDaemonLiveTests.GitManagerTimeoutTests/a()' > /dev/null
  assert_eq "quiet pass: no spinners" "off" "$(should_induce_load 1 && echo on || echo off)"
  pass_spec_of 'TBDDaemonTests.HolderTests/a()' > /dev/null
  assert_eq "fast pass: spinners" "on" "$(should_induce_load 1 && echo on || echo off)"
  assert_eq "fast pass with --no-load: none" "off" "$(should_induce_load 0 && echo on || echo off)"
  adhoc_test_spec 'TBDDaemonTests.HolderTests/a()' > /dev/null
  assert_eq "test alone: spinners" "on" "$(should_induce_load 1 && echo on || echo off)"
  # Test scope loads whatever pass the test is in: a quiet-pass test alone,
  # right after its pass turned load off, still gets spinners.
  pass_spec_of 'TBDDaemonLiveTests.GitManagerTimeoutTests/a()' > /dev/null
  adhoc_test_spec 'TBDDaemonLiveTests.GitManagerTimeoutTests/a()' > /dev/null
  assert_eq "a live-suite test alone: spinners" "on" "$(should_induce_load 1 && echo on || echo off)"
  ADHOC_INDUCE_LOAD=1
  assert_eq "a TARGETS run: spinners" "on" "$(should_induce_load 1 && echo on || echo off)"
}

test_test_and_pass_of_are_exclusive() {
  local out rc=0
  out="$(bash "$SCRIPT" --test 'A.B/c()' --pass-of 'A.B/c()' 2>&1)" || rc=$?
  assert_eq "both modes refused with exit 2" "2" "$rc"
  assert_contains "and says why" "$out" "mutually exclusive"
  rc=0
  out="$(bash "$SCRIPT" --test 'A.B/c()' --target FastPassWhole 2>&1)" || rc=$?
  assert_eq "--test with --target refused" "2" "$rc"
  assert_contains "and says why" "$out" "mutually exclusive"
  rc=0
  out="$(bash "$SCRIPT" --pass-of 'not-an-id' 2>&1)" || rc=$?
  assert_eq "an ID without a / is refused" "2" "$rc"
  assert_contains "and says what an ID looks like" "$out" "<xunit classname>/<name>"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
