#!/usr/bin/env bash
# scripts/nightly-flake-stress.sh — run the historically flaky suites repeatedly
# under induced CPU load. Step 2 of the nightly workflow
# (docs/specs/2026-07-24-test-hardening-design.md §9).
#
# Each target is attached to an OPEN issue that names the flake. A failure here
# lands as a comment on that issue, so the evidence accumulates where the
# diagnosis lives instead of in a log nobody reads.
#
# WHAT THIS CANNOT TELL YOU, stated here because the report repeats it and the
# tracking issue repeats it again: CI is ~4 cores on an otherwise idle runner.
# The GitManagerTimeout flake's reproduction regime (#503, continued in #961) is
# loadavg ~150 on a 12-core box shared by four agents. A zero-failure night is
# NOT evidence that any of these flakes is fixed — it is one sample from a much
# gentler regime. The word "fixed" does not appear in this script's output by
# design; the numbers it reports are iterations, observed loadavg, and core
# count, so a reader can judge the regime for themselves.
#
# Usage:
#   scripts/nightly-flake-stress.sh [--iterations N] [--spinners K]
#                                   [--target NAME] [--report-dir DIR] [--no-load]
#                                   [--xunit-dir DIR] [--metrics-dir DIR]
#                                   [--log-dir DIR] [--results-tsv FILE]
#                                   [--test ID | --pass-of ID]
#
# Ad hoc targets, used by the flake fixer's verifier (spec §6.2, §6.4). ID is the
# flake ledger's xunit form, <classname>/<name>. Either replaces the TARGETS loop
# with one target, reported to REPORT_DIR/adhoc.md; they exclude each other and
# --target.
#   --test ID      that test alone, executed-test floor 1.
#   --pass-of ID   the filter, parallelism and floor of the CI pass in test.yml
#                  that runs ID, with deadlines sized for a whole pass. The quiet
#                  pass runs without induced load, as it does in CI.
#
# Structured outputs, one per iteration i of target T (the flake ledger and the
# flake fixer's verifier read these instead of console text —
# docs/specs/2026-10-07-flake-autofix-design.md §4.1 and §6.4):
#   --xunit-dir DIR      SwiftPM writes DIR/T-i.xml (XCTest cases) AND
#                        DIR/T-i-swift-testing.xml (Swift Testing cases). A
#                        reader that globs only T-i.xml sees no Swift Testing case.
#   --metrics-dir DIR    the iteration runs with TBD_RETRY_METRICS_PATH=DIR/T-i.jsonl,
#                        created EMPTY first: the writer opens it only on its first
#                        record, so a missing file would not distinguish "no .flaky
#                        test ran" from "the variable never reached the test process".
#   --log-dir DIR        keep iteration logs at DIR/T-i.log (default: a mktemp dir).
#   --results-tsv FILE   append one tab-separated row per iteration, no header:
#                        target iteration PASS|FAIL count rc load1m spinners cores seconds reason
#
# Exit: 0 = every target clean, 1 = at least one target FAILED, 2 = harness error.
#
# KILL DISCIPLINE (Tests/CLAUDE.md "The kill hazards" — every line paid for):
#   - spinner PIDs are CAPTURED AT SPAWN into an array; cleanup kills those only
#   - never `jobs -p` (job control is off in a non-interactive shell)
#   - never `trap 'kill 0'` (signals this shell's own process group)
#   - never `pkill -f <pattern>` (matches sibling worktrees' identical bundles)
#   - the deadline kills the iteration's whole process TREE, leaves first, by
#     walking `pgrep -P` from the captured pid — one level would orphan the
#     grandchild swift-frontend / test bundle under scripts/test.sh
#   - post-cleanup verification is `ps -p <captured pid>`, never `pgrep -x yes`
#   - trap on INT/TERM as well as EXIT, so an externally killed run still cleans up

set -uo pipefail

# Absolute, so the wrapper is found regardless of the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# target|swift-test-filter-args|floor|issue|description
#
# Floors are MEASURED, never guessed. `swift test --filter` exits GREEN when it
# matches nothing, and the filter matches the TYPE name rather than the @Suite
# display string — so a renamed suite silently runs zero tests and passes. A
# floor copied from a grep of `@Test` is a floor that has never been checked
# against the runner.
#
# Measured 2026-07-27 on this tree (swift 6.3.3, unloaded):
#   ControlModeInputHealth  10 tests      GitManagerTimeout  6 tests
#   AppearanceDebounce       7 tests      whole fast pass    4308 tests
#
# The floors sit BELOW those, following test.yml's precedent: they exist to fire
# when a pass collapses to near-nothing, not to break every time somebody adds or
# deletes a test. A floor pinned to the exact count would make ordinary test
# churn look like a filter defect.
#
# No filter carries `-j`: the compile job count belongs to `scripts/swift-safe`,
# which supplies it (2 by default) and refuses a command line asking for more
# than TBD_SWIFT_JOBS allows. A hardcoded `-j 2` here would abort every
# iteration on a box whose owner lowered that bound.
TARGETS=(
  "ControlModeInputHealth|--parallel --filter ControlModeInputHealthTests|5|494|control-mode input health: two contention races"
  "GitManagerTimeout|--no-parallel --filter ^TBDDaemonLiveTests\\.GitManagerTimeoutTests|3|961|60s hang under load: polled clock handshake starved (#870 moved it to EventDrivenTestClock)"
  "AppearanceDebounce|--parallel --filter AppearanceDebounceTests|4|496|clock-driven wedge: megaYield at background QoS"
  "FastPassWhole|--parallel --skip ^TBDDaemonLiveTests\\.|3000|962|whole fast pass under load: catch-all until failures are split per test"
)

DEFAULT_ITERATIONS=10
# The whole-target arm is minutes per iteration rather than seconds, so it gets
# its own much smaller count. Sized from the step budget, not from ambition.
WHOLE_TARGET_ITERATIONS=3
ITERATION_DEADLINE_S=600
# Ad hoc targets (`--test`, `--pass-of`; docs/specs/2026-10-07-flake-autofix-design.md
# §6.2 and §6.4). A test alone must execute at least itself.
TEST_SCOPE_FLOOR=1
# Execution deadlines for a whole CI pass, per iteration. Sized from spec §9's
# figures for the nightly's whole-fast-pass arm, which runs all three fast passes
# in one process under induced load: about 38 minutes for its FIRST iteration
# (first-build and warm-up cost included) and about 8 minutes for each warm one.
# One fast pass is a subset of that arm, so those are upper bounds; the deadlines
# sit above them so a slow-but-healthy iteration is not scored as wedged. The
# quiet pass is not in the arm: its healthy CI run takes about 2 minutes.
# Task 1.4 of the flake-autofix plan re-measures all four on CI; the constants
# follow the measurement.
PASS_FIRST_ITERATION_DEADLINE_S=2700
PASS_ITERATION_DEADLINE_S=1200
QUIET_FIRST_ITERATION_DEADLINE_S=1800
QUIET_ITERATION_DEADLINE_S=900
BUILD_DEADLINE_S=1800
SWIFT_LOCK_TIMEOUT_S=1800
SWIFT_DEADLINE_GRACE_S=30

# THE REMOTE VERIFICATION VALVE IS TURNED OFF FOR EVERY RUN THIS HARNESS
# GOVERNS, AND THE RIGHT FIX WAS "DON'T", NOT "WIDEN THE DEADLINE".
# (docs/specs/2026-08-16-remote-verification-valve-design.md.)
#
# `scripts/test.sh` opts into the valve when `TBD_REMOTE_VERIFY=1` is in its
# environment, and this harness invokes `test.sh`. So a night started from a shell
# that had the valve exported would route iterations to GitHub — and that is wrong
# on the merits before it is wrong on any deadline:
#
#   THIS HARNESS MEASURES LOCAL FLAKINESS UNDER CONTENTION. That is its entire
#   purpose: reproduce the regime the GitManagerTimeout flake (#503, continued in
#   #961) was characterised in — spinners pinning the cores, several agents'
#   compiles queueing on the machine-global lock — and see which suites come apart
#   under it. An iteration that leaves the local queue and gets its verdict from a
#   quiet CI runner measures NOTHING this program was built to measure, and it
#   scores a green for a regime nobody was testing.
#
# Two concrete ways the routed iteration also breaks the reporting, recorded so
# nobody "fixes" them by widening a bound instead:
#
#   THE OUTER DEADLINE CANNOT COVER A ROUND TRIP. `governed_outer_deadline` is
#   sized for lock wait + local execution — 1800 + 600 + 30 = 2430s. A valve round
#   trip is the yield (up to 300s), then correlating the dispatched run (up to
#   180s), then the run itself (ceiling ~2700s): past 3100s. The iteration is
#   killed at 2430, scored rc=124, and reported as "FAIL wedged" — a false red
#   attributed to a wedged test, which is exactly the diagnosis this harness exists
#   to produce truthfully.
#
#   THE SIGNATURES WOULD NAME THE WRONG TESTS. `failing_tests_from` greps the
#   iteration log for failure markers, and on the narrowed-red path the valve
#   prints the WHOLE suite's failures into that same log before the local re-run
#   happens. A failing iteration's "Signatures" block would then name tests outside
#   the target's filter and attach them to that target's GitHub issue.
#
# `TBD_REMOTE_VERIFY=0` because `test.sh` tests it against the literal `1`;
# clearing `TBD_SWIFT_QUEUE_YIELD_SECONDS` because it is a documented `swift-safe`
# knob in its own right, and an inherited one would make the test leg yield 76
# with the valve off — a status `test.sh` then propagates, and `judge_iteration`
# reads as a truncated log. Both are ASSIGNED rather than left alone: an inherited
# value must not decide what this harness measures.
NO_VALVE_ENV=(TBD_REMOTE_VERIFY=0 TBD_SWIFT_QUEUE_YIELD_SECONDS=)

SPINNER_PIDS=()
REPORT_DIR=""
FAILED_TARGETS=0
NCPU=""

# Structured per-iteration outputs; each is off when empty. See the Usage block.
XUNIT_DIR=""
METRICS_DIR=""
LOG_DIR=""
RESULTS_TSV=""
ITER_METRICS_PATH=""   # set per iteration by run_target when METRICS_DIR is set

# Set by pass_spec_of / adhoc_test_spec for an ad hoc target; empty otherwise.
ADHOC_FIRST_DEADLINE_S=""
ADHOC_DEADLINE_S=""
ADHOC_INDUCE_LOAD=1

die() { echo "nightly-flake-stress: $*" >&2; exit 2; }

# --- ad hoc targets: one test, or the CI pass that contains it ----------------
#
# THREE SPELLINGS OF ONE TEST. IDs on this script's command line are the flake
# ledger's xunit form, `<classname>/<name>`, where classname is the module and
# every enclosing suite joined by `.`. SwiftPM's `--filter` — and therefore CI's
# pass regexes — match a different string: the module and the FIRST suite joined
# by `.`, every further suite after a `/`, and a test outside any suite as
# `<module>.<name>` (spec §4.2). So every ID is converted before anything is
# matched against it. This mirrors `flake_lib.filter_id`.
#   M.S/f()    -> M.S/f()        top-level suite: the two forms agree
#   M.A.B/f()  -> M.A/B/f()      nested suite
#   M/f()      -> M.f()          no suite
filter_form_of() {
  local id="$1" classname name module rest
  name="${id##*/}"; classname="${id%/*}"
  module="${classname%%.*}"
  if [[ "$classname" == "$module" ]]; then
    printf '%s.%s' "$module" "$name"
    return
  fi
  rest="${classname#*.}"
  # `tr`, not `${rest//./\/}`: bash 3.2 keeps the backslash in that replacement.
  printf '%s.%s/%s' "$module" "$(printf '%s' "$rest" | tr . /)" "$name"
}

# `^<form>(/|$)`, the filter form with every ERE metacharacter escaped (spec
# §6.4). The start anchor stops a match inside a longer ID; the trailing group
# stops `testFoo` (an XCTest name, which has no `()`) from also matching
# `testFooBar`, while still allowing a trailing source-location component.
# (Not named `test_…`: the harness runs every function with that prefix.)
exact_id_filter() {
  printf '^%s(/|$)' "$(filter_form_of "$1" | sed -e 's/[][\.^$*+?(){}|]/\\&/g')"
}

# The TARGETS-format line for `--test ID`: that test alone, floor 1.
adhoc_test_spec() {
  ADHOC_FIRST_DEADLINE_S=""; ADHOC_DEADLINE_S=""; ADHOC_INDUCE_LOAD=1
  printf 'Test|--filter %s|%s|adhoc|ad hoc: %s alone\n' "$(exact_id_filter "$1")" "$TEST_SCOPE_FLOOR" "$1"
}

# THE CI PASSES, AS DATA: name|floor|swift-test args. These are `test.yml`'s four
# `scripts/ci/watched-test-pass.sh` invocations with CI's single quotes removed
# and the three args that do not decide which tests run or how dropped:
# `--fingerprint` (it guards the developer's home directories) and the
# `--xunit-output` pair (this script adds its own). `check_pass_table` compares
# this table with the invocations parsed out of `test.yml`, and the `plans-guard` job
# runs that check, so a CI pass that changes without this table changing fails.
CI_PASSES=(
  "fast-pass-daemon-a|1200|--parallel --filter ^TBDDaemonTests\\.[A-O]"
  "fast-pass-daemon-b|1500|--parallel --filter ^TBDDaemonTests\\. --skip ^TBDDaemonTests\\.[A-O]"
  "fast-pass-app|1900|--parallel --skip ^(TBDDaemonTests|TBDDaemonLiveTests)\\."
  "quiet-pass|35|--filter ^TBDDaemonLiveTests\\. --no-parallel"
)

# True when SwiftPM, given these args, would run the test whose filter form is
# $1: some `--filter` matches (or there is none) and no `--skip` does.
# `LC_ALL=C` because `[A-O]` is a code-point range in SwiftPM's matcher but a
# collation range in some bash locales, where it also admits lowercase letters.
pass_runs() {
  local id="$1" LC_ALL=C
  local -a parts
  read -r -a parts <<< "$2"
  local i has_filter=0 matched=0
  for ((i = 0; i < ${#parts[@]}; i++)); do
    case "${parts[i]}" in
      --filter) has_filter=1; [[ "$id" =~ ${parts[i + 1]} ]] && matched=1 ;;
      --skip)   [[ "$id" =~ ${parts[i + 1]} ]] && return 1 ;;
    esac
  done
  [[ "$has_filter" -eq 0 || "$matched" -eq 1 ]]
}

# The TARGETS-format line for `--pass-of ID`: the CI pass that runs ID, found by
# applying each pass's own filter and skip regexes to the ID's filter form, as
# SwiftPM does in CI. So a test outside any suite
# (`TBDDaemonTests/nilPreferredKeepsOrder()`, filter form
# `TBDDaemonTests.nilPreferredKeepsOrder()`) lands in 1b exactly as in CI, and a
# nested suite lands with its top-level parent. The passes partition the package;
# an ID that lands in no pass or in two is an error, never a guess.
#
# Also sets the ad hoc deadlines, and turns induced load OFF for the quiet pass:
# CI runs that pass serially on an otherwise quiet runner, and a failure that
# only spinners produce is not the flake the ledger saw there.
pass_spec_of() {
  local id="$1" form entry name floor args found=""
  form="$(filter_form_of "$id")"
  for entry in "${CI_PASSES[@]}"; do
    IFS='|' read -r name floor args <<< "$entry"
    pass_runs "$form" "$args" || continue
    [[ -z "$found" ]] || { echo "nightly-flake-stress: $id is run by two CI passes ($found, $name)" >&2; return 1; }
    found="$name|$floor|$args"
  done
  [[ -n "$found" ]] || { echo "nightly-flake-stress: no CI pass runs $id" >&2; return 1; }
  IFS='|' read -r name floor args <<< "$found"
  if [[ "$name" == quiet-pass ]]; then
    ADHOC_FIRST_DEADLINE_S="$QUIET_FIRST_ITERATION_DEADLINE_S"; ADHOC_DEADLINE_S="$QUIET_ITERATION_DEADLINE_S"
    ADHOC_INDUCE_LOAD=0
  else
    ADHOC_FIRST_DEADLINE_S="$PASS_FIRST_ITERATION_DEADLINE_S"; ADHOC_DEADLINE_S="$PASS_ITERATION_DEADLINE_S"
    ADHOC_INDUCE_LOAD=1
  fi
  printf 'Pass-%s|%s|%s|adhoc|the CI pass %s, which runs %s\n' "$name" "$args" "$floor" "$name" "$id"
}

# The execution deadline for iteration $1 of the current target.
iteration_deadline_for() {
  if [[ "$1" -eq 1 && -n "$ADHOC_FIRST_DEADLINE_S" ]]; then
    echo "$ADHOC_FIRST_DEADLINE_S"
  elif [[ -n "$ADHOC_DEADLINE_S" ]]; then
    echo "$ADHOC_DEADLINE_S"
  else
    echo "$ITERATION_DEADLINE_S"
  fi
}

# Whether to start spinners: the caller asked for load ($1) and the target allows it.
should_induce_load() {
  [[ "$1" -eq 1 && "$ADHOC_INDUCE_LOAD" -eq 1 ]]
}

# `name|floor|args` for each `scripts/ci/watched-test-pass.sh` invocation in a
# workflow file, in the CI_PASSES form: continuation lines joined, CI's single
# quotes removed, and `--fingerprint` and the xunit args dropped.
pass_table_from_workflow() {
  local joined name floor args tok skip_next
  local -a parts kept
  while IFS= read -r joined; do
    joined="$(printf '%s' "$joined" | sed "s/--floor-message '[^']*'//")"
    name="$(printf '%s' "$joined" | sed -n 's/.*--name \([^ ]*\).*/\1/p')"
    floor="$(printf '%s' "$joined" | sed -n 's/.*--floor \([0-9]*\).*/\1/p')"
    args="${joined#* -- }"
    args="${args//\'/}"
    read -r -a parts <<< "$args"
    kept=(); skip_next=0
    for tok in ${parts[@]+"${parts[@]}"}; do
      if [[ "$skip_next" -eq 1 ]]; then skip_next=0; continue; fi
      case "$tok" in
        --fingerprint|--experimental-xunit-message-failure) ;;
        --xunit-output) skip_next=1 ;;
        *) kept+=("$tok") ;;
      esac
    done
    printf '%s|%s|%s\n' "$name" "$floor" "${kept[*]:-}"
  done < <(awk '
    /^[ \t]*scripts\/ci\/watched-test-pass\.sh/ { acc = ""; on = 1 }
    on {
      line = $0
      cont = sub(/\\[ \t]*$/, "", line)
      acc = acc " " line
      if (!cont) { print acc; on = 0 }
    }' "$1")
}

# Exit 1, printing the difference, when CI_PASSES and the workflow disagree.
check_pass_table() {
  local ours theirs
  ours="$(printf '%s\n' "${CI_PASSES[@]}" | sort)"
  theirs="$(pass_table_from_workflow "$1" | sort)"
  if [[ -z "$theirs" || "$ours" != "$theirs" ]]; then
    echo "nightly-flake-stress: CI_PASSES does not match the watched-test-pass.sh invocations in $1" >&2
    diff <(printf '%s\n' "$ours") <(printf '%s\n' "$theirs") >&2
    return 1
  fi
}

# --- per-iteration arguments and results --------------------------------------

# Word-split a filter string into one arg per line WITHOUT pathname expansion.
# `read -a` splits on IFS and never globs; an unquoted `$filter` would, and
# `^TBDDaemonTests\.[A-O]` is a glob that a file of a matching name in the cwd
# would silently replace.
filter_args_of() {
  local -a parts
  read -r -a parts <<< "$1"
  # Guarded: an empty filter leaves no parts, which bash 3.2 calls unbound.
  printf '%s\n' ${parts[@]+"${parts[@]}"}
}

# The extra `swift test` args for iteration $2 of target $1, one per line.
iteration_args() {
  local name="$1" i="$2"
  [[ -n "$XUNIT_DIR" ]] || return 0
  printf '%s\n' --xunit-output "$XUNIT_DIR/$name-$i.xml" --experimental-xunit-message-failure
}

# Append one iteration's row to RESULTS_TSV (no-op when unset). `count` is the
# executed-test count when the verdict carried one, else empty.
record_result() {
  local name="$1" i="$2" verdict="$3" rc="$4" load="$5" spinners="$6" cores="$7" seconds="$8"
  [[ -n "$RESULTS_TSV" ]] || return 0
  local kind="${verdict%% *}" reason="${verdict#* }" count=""
  if [[ "$kind" == PASS ]]; then
    count="$reason"
  else
    count="$(printf '%s' "$reason" | sed -n 's/.*with \([0-9]*\) tests.*/\1/p; s/^ran \([0-9]*\) tests.*/\1/p' | head -1)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$i" "$kind" "$count" "$rc" "$load" "$spinners" "$cores" "$seconds" "$reason" >> "$RESULTS_TSV"
}

# --- load generation ----------------------------------------------------------

start_spinners() {
  local count="$1" i
  for ((i = 0; i < count; i++)); do
    yes > /dev/null 2>&1 &
    SPINNER_PIDS+=("$!")          # captured at spawn — the only reliable handle
  done
  echo "load: started ${#SPINNER_PIDS[@]} spinner(s) [pids: ${SPINNER_PIDS[*]:-}]"
}

stop_spinners() {
  local pid leaked=0
  for pid in "${SPINNER_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  sleep 0.5
  # VERIFY, by captured PID. `pgrep -x yes` would answer a different question:
  # a sibling worktree's spinners are not ours to count or to kill.
  for pid in "${SPINNER_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    if ps -p "$pid" >/dev/null 2>&1; then
      echo "load: WARNING spinner $pid survived SIGTERM, sending SIGKILL" >&2
      kill -9 "$pid" 2>/dev/null
      leaked=$((leaked + 1))
    fi
  done
  [[ ${#SPINNER_PIDS[@]} -gt 0 ]] && echo "load: stopped ${#SPINNER_PIDS[@]} spinner(s), $leaked needed SIGKILL"
  SPINNER_PIDS=()
}

cleanup() {
  local rc=$?
  stop_spinners
  exit "$rc"
}
trap cleanup EXIT INT TERM

# --- bounded execution --------------------------------------------------------

# Every descendant of $1, deepest first, one PID per line. `pgrep -P` walks the
# parent-PID edge only — it is NOT `pkill -f <pattern>`, which matches a sibling
# worktree's identically-named bundles (Tests/CLAUDE.md "The kill hazards").
descendants_of() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    descendants_of "$child"
    echo "$child"
  done
}

# Signal $1 to the whole tree rooted at $2, leaves first so nothing is orphaned
# by the death of its parent.
kill_tree() {
  local sig="$1" root="$2" pid
  for pid in $(descendants_of "$root"); do
    kill "-$sig" "$pid" 2>/dev/null
  done
  kill "-$sig" "$root" 2>/dev/null
}

# Run a command with an OUTER deadline. `.clockDriven` was measured failing to
# bound a hang (it sat past 10 minutes with the trait applied), so a stress
# harness cannot delegate its hang-guard to a test trait. Returns 124 on deadline.
run_with_deadline() {
  local deadline_s="$1" log="$2"; shift 2
  "$@" > "$log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$waited" -ge "$deadline_s" ]]; then
      # The WHOLE tree, not `pkill -P "$pid"`. $pid is `scripts/test.sh`, so
      # `swift test` is its child and swift-frontend / the test bundle are
      # GRANDchildren — one level of `pkill -P` leaves exactly the CPU burners
      # this harness exists to control orphaned to launchd. Re-enumerated
      # before the KILL pass because the TERM pass reparents survivors.
      kill_tree TERM "$pid"
      sleep 2
      kill_tree KILL "$pid"
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  return $?
}

governed_outer_deadline() {
  local command_deadline_s="$1"
  echo $((SWIFT_LOCK_TIMEOUT_S + command_deadline_s + SWIFT_DEADLINE_GRACE_S))
}

# The command deadline starts only after swift-safe wins the machine-global
# compile slot. The outer harness deadline must therefore cover both phases;
# otherwise ordinary contention is mislabeled as a wedged test.
run_governed_swift() {
  local command_deadline_s="$1" log="$2"; shift 2
  local outer_deadline_s; outer_deadline_s="$(governed_outer_deadline "$command_deadline_s")"
  run_with_deadline "$outer_deadline_s" "$log" env \
    "${NO_VALVE_ENV[@]}" \
    TBD_SWIFT_LOCK_TIMEOUT_SECONDS="$SWIFT_LOCK_TIMEOUT_S" \
    "$SCRIPT_DIR/swift-safe" "$@"
}

# Same governance as `run_governed_swift`, but through `scripts/test.sh` so the
# run is also fenced off the developer's real `~/tbd`, `~/.claude` and
# `~/.codex`. The two wrappers are orthogonal and stack: `test.sh` sets the
# fence, pins `TBD_SWIFT_LOCK_PATH` at the shared machine-global lock so its
# scratch `TBD_HOME` cannot turn that lock private, and then invokes SwiftPM via
# `swift-safe` — so the admission lock and the lock-timeout env var below apply
# exactly as they do to `run_governed_swift`. That matters most here: an
# iteration that took a private lock would run its whole compile alongside every
# sibling worktree's, which is the load this harness is trying to CONTROL rather
# than add to. This harness is documented for local use, where an unfenced run
# would write into the real config dirs.
#
# `NO_VALVE_ENV` matters most on THIS leg, because `test.sh` is the only caller
# that opts into the remote verification valve. See its definition above for why
# an iteration must never route.
#
# `ITER_METRICS_PATH`, when run_target set it, reaches the test process as
# `TBD_RETRY_METRICS_PATH` — the only way `.flaky` writes a record.
run_governed_fenced() {
  local command_deadline_s="$1" log="$2"; shift 2
  local outer_deadline_s; outer_deadline_s="$(governed_outer_deadline "$command_deadline_s")"
  run_with_deadline "$outer_deadline_s" "$log" env \
    "${NO_VALVE_ENV[@]}" \
    ${ITER_METRICS_PATH:+"TBD_RETRY_METRICS_PATH=$ITER_METRICS_PATH"} \
    TBD_SWIFT_LOCK_TIMEOUT_SECONDS="$SWIFT_LOCK_TIMEOUT_S" \
    "$SCRIPT_DIR/test.sh" "$@"
}

# The 1-MINUTE load average, which LAGS: measured here, the first iterations
# after starting 6 spinners still reported ~7 while the run finished at ~24. It
# is reported as `load1m` everywhere so nobody reads an early figure as the load
# the iteration actually ran at. The induced-spinner count is the non-lagging
# half of the picture, so both are always printed together.
loadavg() { uptime | sed -n 's/.*load averages*: *\([0-9.]*\).*/\1/p'; }

# --- one iteration ------------------------------------------------------------

# Verdict is (summary present) AND (count >= floor) AND (rc == 0). Never rc alone.
# Echoes "PASS <count>" or "FAIL <reason>".
judge_iteration() {
  local rc="$1" log="$2" floor="$3" deadline_s="${4:-$ITERATION_DEADLINE_S}"
  local count
  count="$(grep -oE 'Test run with [0-9]+ tests?' "$log" | grep -oE '[0-9]+' | head -1)"

  if [[ "$rc" -eq 124 ]]; then
    echo "FAIL wedged — no completion within the governed outer deadline (lock wait + ${deadline_s}s execution budget + grace)"
    return
  fi
  # A TRUNCATED LOG IS A FAILURE, NOT A PASS. A wedged run exits with no summary
  # line and no seed, and a naive rc==0 check scores it green. This program hit
  # that repeatedly; it is the single most important line in this file.
  if [[ -z "$count" ]]; then
    echo "FAIL no 'Test run with N tests' summary — truncated log or wedged run (rc=$rc)"
    return
  fi
  if [[ "$count" -lt "$floor" ]]; then
    echo "FAIL ran $count tests, below the measured floor of $floor — the filter matched less than it should (it exits GREEN on zero matches)"
    return
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL rc=$rc with $count tests executed"
    return
  fi
  echo "PASS $count"
}

# THE ASSERTION LINES ARE THE PAYLOAD; THE SUITE LINES ARE A SUMMARY. Budget
# them separately, because a single shared cap filled in sort order discards
# exactly the wrong half. `✘ Suite` sorts ahead of `✘ Test` lexicographically,
# so on an iteration with twelve or more failing suites a single `sort -u |
# head -12` spent the entire budget on `✘ Suite "X" failed after N seconds with
# K issues` lines and cut every line naming an assertion. That is not
# hypothetical: two flakes were reported on 28 and 24 nights apiece and the
# ledger never once named a failing assertion, so the diagnosis had to be
# reconstructed from issue counts and suite durations. The whole-suite target is
# the one that hurts most, since it is also the one most likely to have many
# suites red at once.
#
# Bounding the total is the original constraint and it survives: at most
# SIGNATURE_DETAIL_LINES + SIGNATURE_SUITE_LINES lines reach a GitHub comment.
SIGNATURE_DETAIL_LINES=12
SIGNATURE_SUITE_LINES=4

failing_tests_from() {
  # Swift Testing's failure lines, deduplicated, partitioned by kind, and each
  # partition capped so one bad run cannot produce a comment nobody will read.
  # The priority is stated here rather than inherited from the glyph's sort order.
  local all detail suites
  all="$(grep -E '✘|Expectation failed|Issue recorded|Test .* failed' "$1" 2>/dev/null \
    | sed 's/^[[:space:]]*//' | sort -u)"
  [[ -n "$all" ]] || return 0

  # Detail first, so a truncated reader still sees the assertions.
  detail="$(printf '%s\n' "$all" | grep -vE '^✘ Suite ' | head -"$SIGNATURE_DETAIL_LINES")"
  suites="$(printf '%s\n' "$all" | grep -E '^✘ Suite ' | head -"$SIGNATURE_SUITE_LINES")"
  printf '%s\n' "$detail" "$suites" | grep -v '^[[:space:]]*$'
}

# --- one target ---------------------------------------------------------------

# Field $2 (1-5) of a TARGETS-format line, name|filter|floor|issue|description.
# The FILTER may itself contain `|` — fast pass 2 skips
# `^(TBDDaemonTests|TBDDaemonLiveTests)\.` — so a plain `IFS='|' read` would split
# inside it and read part of the regex as the floor. Name is the first field and
# the other three are the last three; the filter is whatever lies between.
spec_field() {
  local spec="$1" rest name description issue floor
  name="${spec%%|*}"; rest="${spec#*|}"
  description="${rest##*|}"; rest="${rest%|*}"
  issue="${rest##*|}"; rest="${rest%|*}"
  floor="${rest##*|}"; rest="${rest%|*}"
  case "$2" in
    1) printf '%s' "$name" ;;
    2) printf '%s' "$rest" ;;
    3) printf '%s' "$floor" ;;
    4) printf '%s' "$issue" ;;
    5) printf '%s' "$description" ;;
  esac
}

run_target() {
  local spec="$1" iterations="$2" work_dir="$3"
  local name filter floor issue description
  name="$(spec_field "$spec" 1)"; filter="$(spec_field "$spec" 2)"; floor="$(spec_field "$spec" 3)"
  issue="$(spec_field "$spec" 4)"; description="$(spec_field "$spec" 5)"

  [[ "$name" == "FastPassWhole" ]] && iterations="$WHOLE_TARGET_ITERATIONS"

  echo
  local attached="issue #$issue"
  [[ "$issue" == adhoc ]] && attached="ad hoc"
  echo "═══ $name — $attached — $iterations iteration(s), floor $floor"
  echo "    $description"

  local failures=0 pass_counts=() signatures=() i verdict log load_before t0 line deadline
  local -a args  # non-empty: set to (--no-fingerprint ...) before every use
  for ((i = 1; i <= iterations; i++)); do
    log="${LOG_DIR:-$work_dir}/$name-$i.log"
    # Built as an array, never from an unquoted `$filter`: see filter_args_of.
    # A `while read` loop because bash 3.2 has no `mapfile`.
    args=(--no-fingerprint)
    while IFS= read -r line; do args+=("$line"); done < <(filter_args_of "$filter"; iteration_args "$name" "$i")
    ITER_METRICS_PATH="${METRICS_DIR:+$METRICS_DIR/$name-$i.jsonl}"
    # Pre-created EMPTY, so a missing file after the iteration means the
    # variable never reached the test process (spec §6.4, the retry check).
    [[ -n "$ITER_METRICS_PATH" ]] && : > "$ITER_METRICS_PATH"
    load_before="$(loadavg)"
    t0=$SECONDS
    local rc=0
    # Through scripts/test.sh, not bare `swift test`: this script's documented
    # use is LOCAL reproduction under induced load, where a bare run writes into
    # the developer's real ~/tbd and ~/.claude. `--no-fingerprint` for the same
    # reason the pre-push hook uses it — a live daemon writes to ~/tbd
    # legitimately across the many minutes these iterations take, so the
    # detection layer would report the machine rather than the run. The fence,
    # which is what actually prevents the leak, is always on.
    deadline="$(iteration_deadline_for "$i")"
    run_governed_fenced "$deadline" "$log" "${args[@]}" || rc=$?
    verdict="$(judge_iteration "$rc" "$log" "$floor" "$deadline")"
    record_result "$name" "$i" "$verdict" "$rc" "$load_before" "${#SPINNER_PIDS[@]}" "$NCPU" "$((SECONDS - t0))"
    if [[ "$verdict" == PASS* ]]; then
      pass_counts+=("${verdict#PASS }")
      printf '    %2d/%d  pass (%s tests, load1m %s at start, %d spinners)\n' "$i" "$iterations" "${verdict#PASS }" "$load_before" "${#SPINNER_PIDS[@]}"
    else
      failures=$((failures + 1))
      printf '    %2d/%d  *** %s (load1m %s at start, %d spinners)\n' "$i" "$iterations" "${verdict#FAIL }" "$load_before" "${#SPINNER_PIDS[@]}"
      signatures+=("iteration $i (load1m $load_before at start, ${#SPINNER_PIDS[@]} spinners): ${verdict#FAIL }")
      local detail; detail="$(failing_tests_from "$log")"
      [[ -n "$detail" ]] && signatures+=("$(printf '%s' "$detail" | sed 's/^/      /')")
    fi
  done

  echo "    result: $failures/$iterations failed"
  [[ "$failures" -eq 0 ]] && return 0

  FAILED_TARGETS=$((FAILED_TARGETS + 1))
  # One report file per FAILING target, named by the issue it attaches to.
  {
    echo "**\`$name\` failed $failures of $iterations iteration(s) under induced load.**"
    echo
    echo "- Machine: $(sysctl -n hw.ncpu 2>/dev/null || nproc) cores, ${#SPINNER_PIDS[@]} induced spinners, load1m now: $(loadavg)"
    echo "  (\`load1m\` is the 1-minute average and LAGS the induced load — early iterations under-report it. The spinner count is the reliable half.)"
    echo "- Filter: \`scripts/test.sh --no-fingerprint $filter\`, executed-test floor $floor"
    echo "- Execution budget: $(iteration_deadline_for 1)s for the first iteration and $(iteration_deadline_for 2)s for each later one, after admission; lock wait: up to ${SWIFT_LOCK_TIMEOUT_S}s; outer backstop: $(governed_outer_deadline "$(iteration_deadline_for 1)")s"
    echo
    echo "Signatures:"
    echo
    local s
    for s in "${signatures[@]}"; do echo "$s"; done  # non-empty: every failing iteration adds one
    echo
    echo "> This is one night's sample from CI's regime (a few idle cores), not the"
    echo "> regime this flake was characterised in (loadavg ~150 on 12 shared cores)."
    echo "> Treat it as evidence the flake is still live, not as a rate."
  } >> "$REPORT_DIR/$issue.md"
  return 1
}

# --- main ---------------------------------------------------------------------

main() {
  local iterations="$DEFAULT_ITERATIONS" spinners="" only_target="" induce_load=1
  local test_id="" pass_of_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iterations) iterations="${2:-}"; shift 2 ;;
      --spinners)   spinners="${2:-}"; shift 2 ;;
      --target)     only_target="${2:-}"; shift 2 ;;
      --report-dir) REPORT_DIR="${2:-}"; shift 2 ;;
      --no-load)    induce_load=0; shift ;;
      --xunit-dir)   XUNIT_DIR="${2:-}"; shift 2 ;;
      --metrics-dir) METRICS_DIR="${2:-}"; shift 2 ;;
      --log-dir)     LOG_DIR="${2:-}"; shift 2 ;;
      --results-tsv) RESULTS_TSV="${2:-}"; shift 2 ;;
      --test)        test_id="${2:-}"; shift 2 ;;
      --pass-of)     pass_of_id="${2:-}"; shift 2 ;;
      *) die "unknown argument $1" ;;
    esac
  done

  # Ad hoc modes replace the TARGETS loop with one target. Validated before
  # anything else, so a bad command line costs nothing.
  local modes=0 adhoc_id="" adhoc_spec=""
  [[ -n "$test_id" ]] && modes=$((modes + 1)) && adhoc_id="$test_id"
  [[ -n "$pass_of_id" ]] && modes=$((modes + 1)) && adhoc_id="$pass_of_id"
  [[ -n "$only_target" ]] && modes=$((modes + 1))
  [[ "$modes" -le 1 ]] || die "--test, --pass-of and --target are mutually exclusive"
  if [[ -n "$adhoc_id" ]]; then
    [[ "$adhoc_id" == ?*/?* ]] || die "a test ID is <xunit classname>/<name>, e.g. M.Suite/f(); got: $adhoc_id"
    # Each spec function also sets globals (deadlines, load), so it is called
    # once in this shell for those and once in a substitution for its line.
    if [[ -n "$test_id" ]]; then
      adhoc_test_spec "$adhoc_id" > /dev/null
      adhoc_spec="$(adhoc_test_spec "$adhoc_id")"
    else
      pass_spec_of "$adhoc_id" > /dev/null || exit 2
      adhoc_spec="$(pass_spec_of "$adhoc_id")"
    fi
  fi

  command -v swift >/dev/null 2>&1 || die "swift not found"
  [[ -n "$REPORT_DIR" ]] || REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flake-stress-reports.XXXXXX")"
  mkdir -p "$REPORT_DIR" || die "cannot create report dir $REPORT_DIR"
  local dir
  for dir in "$XUNIT_DIR" "$METRICS_DIR" "$LOG_DIR"; do
    [[ -z "$dir" ]] || mkdir -p "$dir" || die "cannot create $dir"
  done
  [[ -z "$RESULTS_TSV" ]] || mkdir -p "$(dirname "$RESULTS_TSV")" || die "cannot create the directory for $RESULTS_TSV"
  local work_dir; work_dir="$(mktemp -d "${TMPDIR:-/tmp}/flake-stress.XXXXXX")" || die "cannot create work dir"

  NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
  [[ -n "$spinners" ]] || spinners="$NCPU"

  echo "nightly-flake-stress: $NCPU cores, baseline load $(loadavg)"
  echo "logs: $work_dir   reports: $REPORT_DIR"

  # Build ONCE up front so the first iteration's timing is not dominated by the
  # compile. `swift build` alone does NOT build test targets — `--build-tests` does.
  echo
  echo "building test targets (swift-safe build --build-tests)…"
  # No `-j`: `swift-safe` supplies the machine's job count itself (2 unless
  # TBD_SWIFT_JOBS says otherwise) and REFUSES a command line above it, so a
  # box whose owner lowered TBD_SWIFT_JOBS would fail this build for a reason
  # that reads as a harness defect.
  if ! run_governed_swift "$BUILD_DEADLINE_S" "$work_dir/build.log" \
    build --build-tests; then
    echo "nightly-flake-stress: BUILD FAILED — see $work_dir/build.log" >&2
    tail -30 "$work_dir/build.log" >&2
    exit 2
  fi
  echo "build ok."

  if should_induce_load "$induce_load"; then
    start_spinners "$spinners"
  elif [[ "$induce_load" -eq 1 ]]; then
    echo "load: none — CI runs the quiet pass on an otherwise quiet runner"
  fi

  if [[ -n "$adhoc_spec" ]]; then
    # Report file: $REPORT_DIR/adhoc.md, since the spec's issue field is "adhoc".
    run_target "$adhoc_spec" "$iterations" "$work_dir"
  else
    local spec name
    for spec in "${TARGETS[@]}"; do
      name="${spec%%|*}"
      [[ -n "$only_target" && "$name" != "$only_target" ]] && continue
      run_target "$spec" "$iterations" "$work_dir"
    done
  fi

  stop_spinners

  echo
  if [[ "$FAILED_TARGETS" -eq 0 ]]; then
    echo "═══ every target clean this run."
    echo "    NOT evidence that these flakes are fixed — see the note in this script's header."
    return 0
  fi
  echo "═══ $FAILED_TARGETS target(s) FAILED; reports written to $REPORT_DIR"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
