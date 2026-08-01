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
# #503's reproduction regime is loadavg ~150 on a 12-core box shared by four
# agents. A zero-failure night is NOT evidence that any of these flakes is
# fixed — it is one sample from a much gentler regime. The word "fixed" does not
# appear in this script's output by design; the numbers it reports are
# iterations, observed loadavg, and core count, so a reader can judge the regime
# for themselves.
#
# Usage:
#   scripts/nightly-flake-stress.sh [--iterations N] [--spinners K]
#                                   [--target NAME] [--report-dir DIR] [--no-load]
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
TARGETS=(
  "ControlModeInputHealth|--parallel -j 2 --filter ControlModeInputHealthTests|5|494|control-mode input health: two contention races"
  "GitManagerTimeout|--no-parallel --filter ^TBDDaemonLiveTests\\.GitManagerTimeoutTests|3|503|60s hang at ~1/22 under heavy load, mechanism unknown"
  "AppearanceDebounce|--parallel -j 2 --filter AppearanceDebounceTests|4|496|clock-driven wedge: megaYield at background QoS"
  "FastPassWhole|--parallel -j 2 --skip ^TBDDaemonLiveTests\\.|3000|503|#503's actual reproduction shape: whole fast pass under load"
)

DEFAULT_ITERATIONS=10
# The whole-target arm is minutes per iteration rather than seconds, so it gets
# its own much smaller count. Sized from the step budget, not from ambition.
WHOLE_TARGET_ITERATIONS=3
ITERATION_DEADLINE_S=600
BUILD_DEADLINE_S=1800
SWIFT_LOCK_TIMEOUT_S=1800
SWIFT_DEADLINE_GRACE_S=30

SPINNER_PIDS=()
REPORT_DIR=""
FAILED_TARGETS=0

die() { echo "nightly-flake-stress: $*" >&2; exit 2; }

# --- load generation ----------------------------------------------------------

start_spinners() {
  local count="$1" i
  for ((i = 0; i < count; i++)); do
    yes > /dev/null 2>&1 &
    SPINNER_PIDS+=("$!")          # captured at spawn — the only reliable handle
  done
  echo "load: started ${#SPINNER_PIDS[@]} spinner(s) [pids: ${SPINNER_PIDS[*]}]"
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
    TBD_SWIFT_LOCK_TIMEOUT_SECONDS="$SWIFT_LOCK_TIMEOUT_S" \
    "$REPO_ROOT/scripts/swift-safe" "$@"
}

# Same governance as `run_governed_swift`, but through `scripts/test.sh` so the
# run is also fenced off the developer's real `~/tbd`, `~/.claude` and
# `~/.codex`. The two wrappers are orthogonal and stack: `test.sh` sets the
# fence and then invokes SwiftPM via `swift-safe`, so the admission lock and the
# lock-timeout env var below still apply. This harness is documented for local
# use, where an unfenced run would write into the real config dirs.
run_governed_fenced() {
  local command_deadline_s="$1" log="$2"; shift 2
  local outer_deadline_s; outer_deadline_s="$(governed_outer_deadline "$command_deadline_s")"
  run_with_deadline "$outer_deadline_s" "$log" env \
    TBD_SWIFT_LOCK_TIMEOUT_SECONDS="$SWIFT_LOCK_TIMEOUT_S" \
    "$REPO_ROOT/scripts/test.sh" "$@"
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
  local rc="$1" log="$2" floor="$3"
  local count
  count="$(grep -oE 'Test run with [0-9]+ tests?' "$log" | grep -oE '[0-9]+' | head -1)"

  if [[ "$rc" -eq 124 ]]; then
    echo "FAIL wedged — no completion within the governed outer deadline (lock wait + ${ITERATION_DEADLINE_S}s execution budget + grace)"
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

failing_tests_from() {
  # Swift Testing's failure lines, deduplicated, capped so one bad run cannot
  # produce a comment nobody will read.
  grep -E '✘|Expectation failed|Issue recorded|Test .* failed' "$1" 2>/dev/null \
    | sed 's/^[[:space:]]*//' | sort -u | head -12
}

# --- one target ---------------------------------------------------------------

run_target() {
  local spec="$1" iterations="$2" work_dir="$3"
  local name filter floor issue description
  IFS='|' read -r name filter floor issue description <<< "$spec"

  [[ "$name" == "FastPassWhole" ]] && iterations="$WHOLE_TARGET_ITERATIONS"

  echo
  echo "═══ $name — issue #$issue — $iterations iteration(s), floor $floor"
  echo "    $description"

  local failures=0 pass_counts=() signatures=() i verdict log load_before
  for ((i = 1; i <= iterations; i++)); do
    log="$work_dir/$name-$i.log"
    load_before="$(loadavg)"
    local rc=0
    # Through scripts/test.sh, not bare `swift test`: this script's documented
    # use is LOCAL reproduction under induced load, where a bare run writes into
    # the developer's real ~/tbd and ~/.claude. `--no-fingerprint` for the same
    # reason the pre-push hook uses it — a live daemon writes to ~/tbd
    # legitimately across the many minutes these iterations take, so the
    # detection layer would report the machine rather than the run. The fence,
    # which is what actually prevents the leak, is always on.
    # shellcheck disable=SC2086 # $filter is a deliberately word-split arg list
    run_governed_fenced "$ITERATION_DEADLINE_S" "$log" --no-fingerprint $filter || rc=$?
    verdict="$(judge_iteration "$rc" "$log" "$floor")"
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
    echo "- Execution budget: ${ITERATION_DEADLINE_S}s after admission; lock wait: up to ${SWIFT_LOCK_TIMEOUT_S}s; outer backstop: $(governed_outer_deadline "$ITERATION_DEADLINE_S")s"
    echo
    echo "Signatures:"
    echo
    local s
    for s in "${signatures[@]}"; do echo "$s"; done
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
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iterations) iterations="${2:-}"; shift 2 ;;
      --spinners)   spinners="${2:-}"; shift 2 ;;
      --target)     only_target="${2:-}"; shift 2 ;;
      --report-dir) REPORT_DIR="${2:-}"; shift 2 ;;
      --no-load)    induce_load=0; shift ;;
      *) die "unknown argument $1" ;;
    esac
  done

  command -v swift >/dev/null 2>&1 || die "swift not found"
  [[ -n "$REPORT_DIR" ]] || REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flake-stress-reports.XXXXXX")"
  mkdir -p "$REPORT_DIR" || die "cannot create report dir $REPORT_DIR"
  local work_dir; work_dir="$(mktemp -d "${TMPDIR:-/tmp}/flake-stress.XXXXXX")" || die "cannot create work dir"

  local ncpu; ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
  [[ -n "$spinners" ]] || spinners="$ncpu"

  echo "nightly-flake-stress: $ncpu cores, baseline load $(loadavg)"
  echo "logs: $work_dir   reports: $REPORT_DIR"

  # Build ONCE up front so the first iteration's timing is not dominated by the
  # compile. `swift build` alone does NOT build test targets — `--build-tests` does.
  echo
  echo "building test targets (swift-safe build --build-tests -j 2)…"
  if ! run_governed_swift "$BUILD_DEADLINE_S" "$work_dir/build.log" \
    build --build-tests -j 2; then
    echo "nightly-flake-stress: BUILD FAILED — see $work_dir/build.log" >&2
    tail -30 "$work_dir/build.log" >&2
    exit 2
  fi
  echo "build ok."

  [[ "$induce_load" -eq 1 ]] && start_spinners "$spinners"

  local spec name
  for spec in "${TARGETS[@]}"; do
    name="${spec%%|*}"
    [[ -n "$only_target" && "$name" != "$only_target" ]] && continue
    run_target "$spec" "$iterations" "$work_dir"
  done

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
