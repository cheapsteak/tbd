#!/usr/bin/env bash
# Tests for scripts/ci/watched-test-pass.sh — run: /bin/bash scripts/ci/watched-test-pass.test.sh
#
# MACOS ONLY, AND VERIFIED WITH `/bin/bash`, WHICH ON MACOS IS 3.2. The script
# under test drives BSD `ps`, BSD `script(1)` and `/usr/bin/sample`, all of
# which take different arguments or do not exist on Linux — which is why this
# harness runs in the macOS `test` job rather than joining the Linux collection
# in `plans-guard`. A developer with Homebrew's bash first on `PATH` is running
# 5.x, where constructs 3.2 cannot parse work fine and fail at RUN time from
# inside a command substitution, where `bash -n` on 5.x never sees them.
#
# ZERO BUILDS, ZERO SwiftPM, AND NOTHING REAL IS TOUCHED. Every case runs the
# script against a fixture directory holding a STUB `scripts/test.sh` this file
# controls, a stub `sample` first on PATH, and its own out-dir. Nothing here
# compiles, reads `~/tbd`, or signals a process it did not itself start.
#
# THE STUB SLEEPER IS `caffeinate -t 60`, NOT `sleep`, AND THAT IS LOAD-BEARING.
# The script's fallback selection skips known plumbing by `comm` basename, and
# `sleep` is on that list — a `sleep` sleeper would be filtered out and the
# stall cases would assert nothing. `/usr/bin/caffeinate` ships with macOS,
# needs no privileges, self-terminates after its `-t` seconds so a case that
# dies early cannot leak it, and its basename is on no exclusion list. The
# primary-path case execs it through a SYMLINK under a `TBDPackageTests`-bearing
# directory, so the process's argv matches the same way a real
# `swiftpm-testing-helper` does.
#
# ALL SIGNALS GO TO CAPTURED PIDS. The sleeper writes its own pid to a file
# before it execs, the EXIT trap kills exactly those, and no case ever matches a
# process by name — see `Tests/CLAUDE.md` "The kill hazards".
#
# EACH COMPLETED-RUN CASE COSTS ABOUT FIVE SECONDS, because the script polls the
# pipeline in 5-second steps and a stub that finishes instantly is still
# observed alive on the first look. The whole file is well under a minute.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/watched-test-pass.sh"

FAIL=0
assert_eq()       { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1 ;; esac; }
assert_file_has() { if [ -f "$2" ] && grep -q -- "$3" "$2"; then echo "ok   - $1"; else echo "FAIL - $1: $2 lacks [$3]"; FAIL=1; fi; }
assert_true()     { local label="$1"; shift; if "$@"; then echo "ok   - $label"; else echo "FAIL - $label"; FAIL=1; fi; }
assert_ok()       { if [ "$2" = "0" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected exit 0, got $2"; FAIL=1; fi; }
assert_dead()     { if kill -0 "$2" 2>/dev/null; then echo "FAIL - $1: pid $2 is still alive"; FAIL=1; else echo "ok   - $1"; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/watched-pass-test.XXXXXX"; }

# Fixtures and any sleeper this file started, reclaimed on the way out. The
# sleepers are killed BY THE PID THEY RECORDED, never by name, and each would
# expire on its own within a minute anyway.
FIXTURES=""
SLEEPERS=""
cleanup() {
  local pid dir
  for pid in $SLEEPERS; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  for dir in $FIXTURES; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A throwaway world: a copy of the script under test at the same relative
# position it occupies in the repo (so its `$(dirname "$0")/../test.sh` resolves
# to the stub next to it), the stub itself, a stub `sample`, an out-dir, and a
# symlink whose name carries the argv token the primary selection path matches.
mkfix() {
  local d; d="$(mktmpd)"
  FIXTURES="$FIXTURES $d"
  mkdir -p "$d/scripts/ci" "$d/bin" "$d/out"
  cp "$SCRIPT" "$d/scripts/ci/watched-test-pass.sh"
  chmod +x "$d/scripts/ci/watched-test-pass.sh"
  # The primary-path sleeper: its `comm` basename is `sleep`, which IS on the
  # fallback's plumbing list, while its argv carries `TBDPackageTests`. Only the
  # primary argv match can select it, so that case goes red outright if the argv
  # match stops working rather than quietly passing through the fallback.
  mkdir -p "$d/TBDPackageTests-bin"
  ln -s /usr/bin/caffeinate "$d/TBDPackageTests-bin/sleep"

  cat > "$d/scripts/test.sh" <<'STUB'
# Stands in for scripts/test.sh, run through the pty exactly as the real one is.
#
# DELIBERATELY WITHOUT A SHEBANG, so the exec falls back to `/bin/sh <file>`.
# Exec'ing a freshly created file goes through the system's provenance check
# before its first instruction runs, and on a developer machine whose
# `syspolicyd` is saturated that check does not return: the child sits in dyld
# and the pty session wedges before the stub's first line. Reading the file
# through an interpreter that is already validated sidesteps it entirely, costs
# nothing, and changes nothing this harness is testing. Keep this file POSIX sh.
#
# STUB_MODE picks the shape:
#   summary  print the population line six floor consumers grep for, then exit
#            STUB_RC. STUB_COUNT unset prints no summary line at all, which is
#            the truncated-run shape the floor exists to catch.
#   stall    record this pid (the exec below keeps it) and block until killed.
#            STUB_SLEEPER names the executable, which decides whether the
#            script's primary argv match or its fallback selection picks it up.
set -u
echo "stub test.sh argv: $*"
case "${STUB_MODE:-summary}" in
  summary)
    if [ -n "${STUB_COUNT:-}" ]; then
      echo "Test run with ${STUB_COUNT} tests in 3 suites passed after 1.0 seconds."
    fi
    exit "${STUB_RC:-0}"
    ;;
  stall)
    echo "$$" > "$STUB_PID_FILE"
    exec "$STUB_SLEEPER" -t 60
    ;;
esac
STUB
  chmod +x "$d/scripts/test.sh"

  cat > "$d/bin/sample" <<'SAMPLE'
# Stands in for /usr/bin/sample: records the argv it was handed and writes a
# file at the -file path, so a case can assert WHICH pid was sampled without
# waiting five seconds for a real stack capture.
#
# Shebang-less for the same reason the stub wrapper above is — see there.
echo "$*" >> "$SAMPLE_ARGV_FILE"
prev=""
for arg in "$@"; do
  if [ "$prev" = "-file" ]; then
    echo "fake sample of $1" > "$arg"
  fi
  prev="$arg"
done
exit 0
SAMPLE
  chmod +x "$d/bin/sample"
  echo "$d"
}

# Run the script under test against a fixture. Sets RUN_OUT and RUN_RC.
# Extra environment for the stub goes in RUN_ENV before the call.
RUN_ENV=()
run_pass() {
  local fix="$1"; shift
  RUN_OUT="$(PATH="$fix/bin:$PATH" \
    SAMPLE_ARGV_FILE="$fix/sample-argv" \
    STUB_PID_FILE="$fix/sleeper.pid" \
    STUB_SLEEPER="/usr/bin/caffeinate" \
    env ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    /bin/bash "$fix/scripts/ci/watched-test-pass.sh" "$@" 2>&1)"
  RUN_RC=$?
}

# ---------------------------------------------------------------------------
# 1. A green pass hands back its verdict, its count and its log
# ---------------------------------------------------------------------------

test_green_passthrough() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=summary STUB_COUNT=40 STUB_RC=0)
  run_pass "$fix" --name green --budget-seconds 60 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" \
    -- --fingerprint --marker-argument
  RUN_ENV=()
  assert_ok "green pass exits 0" "$RUN_RC"
  assert_contains "green pass names itself and its count" "$RUN_OUT" "green executed 40 tests."
  assert_file_has "the log keeps the summary line" "$fix/out/green.log" "Test run with 40 tests"
  # The `--` separator forwards everything after it to the wrapper untouched.
  assert_file_has "forwarded arguments reach the wrapper" "$fix/out/green.log" "--marker-argument"
  assert_file_has "the recorded status is the pass's own" "$fix/out/green.rc" "^0$"
}

# ---------------------------------------------------------------------------
# 2. A non-zero status reaches the caller untouched — 75 and 76 are the reason
# ---------------------------------------------------------------------------

test_status_76_survives() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=summary STUB_COUNT=40 STUB_RC=76)
  run_pass "$fix" --name yielded --budget-seconds 60 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  assert_eq "a 76 is returned as 76, not flattened to 1" "76" "$RUN_RC"
  assert_contains "the 76 is named in the error line" "$RUN_OUT" "::error::yielded exited 76"
}

test_status_3_survives() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=summary STUB_COUNT=40 STUB_RC=3)
  run_pass "$fix" --name failed --budget-seconds 60 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  assert_eq "an ordinary red status is returned as itself" "3" "$RUN_RC"
  assert_contains "the red status is named in the error line" "$RUN_OUT" "::error::failed exited 3"
}

# ---------------------------------------------------------------------------
# 3. The floor catches a run that claims success while executing nothing
# ---------------------------------------------------------------------------

test_floor_catches_a_short_run() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=summary STUB_COUNT=5 STUB_RC=0)
  run_pass "$fix" --name shortrun --budget-seconds 60 --floor 35 \
    --floor-message 'the --filter regex matched nothing or the target was renamed.' \
    --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  assert_eq "a run under the floor is red" "1" "$RUN_RC"
  assert_contains "the floor error names the count and the floor" "$RUN_OUT" \
    "::error::shortrun ran 5 tests (floor 35)"
  assert_contains "the floor error carries its explanation" "$RUN_OUT" \
    "the --filter regex matched nothing or the target was renamed."
}

test_floor_catches_a_missing_summary() {
  local fix; fix="$(mkfix)"
  # STUB_COUNT unset: a truncated run that printed no population line at all.
  RUN_ENV=(STUB_MODE=summary STUB_RC=0)
  run_pass "$fix" --name nosummary --budget-seconds 60 --floor 35 \
    --floor-message 'the --filter regex matched nothing or the target was renamed.' \
    --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  assert_eq "a run with no summary line is red" "1" "$RUN_RC"
  assert_contains "the floor error says no tests were seen" "$RUN_OUT" \
    "::error::nosummary ran no tests (floor 35)"
}

# ---------------------------------------------------------------------------
# 4. A stall is sampled, killed and failed well before the platform timeout
# ---------------------------------------------------------------------------

# The pid the sample stub was handed, from its recorded argv.
sampled_pid_of() { sed -n '1s/ .*//p' "$1/sample-argv" 2>/dev/null; }

# The sleeper's own pid, recorded before it exec'd, so the case can also reclaim
# it if an assertion fails and the script never got to.
sleeper_pid_of() { cat "$1/sleeper.pid" 2>/dev/null; }

assert_stall() {
  local label="$1" fix="$2" name="$3" started="$4" elapsed sampled sleeper
  elapsed=$(( $(date +%s) - started ))
  assert_eq "$label: a stall is red" "1" "$RUN_RC"
  assert_contains "$label: the stall error names the pass and its budget" "$RUN_OUT" \
    "::error::$name has been running for 3s"
  # Ends on the watchdog's own budget, not on the 60-second sleeper expiring.
  if [ "$elapsed" -lt 30 ]; then
    echo "ok   - $label: the step ended after ${elapsed}s, well inside the sleeper's 60"
  else
    echo "FAIL - $label: the step took ${elapsed}s, which is not the watchdog acting"
    FAIL=1
  fi
  assert_file_has "$label: the ps file carries the lineage header" \
    "$fix/out/$name-stall-ps.txt" "descendants of the pipeline subshell"
  sampled="$(sampled_pid_of "$fix")"
  sleeper="$(sleeper_pid_of "$fix")"
  case "$sampled" in
    ''|*[!0-9]*) echo "FAIL - $label: no pid was sampled (got '$sampled')"; FAIL=1 ;;
    *) echo "ok   - $label: a pid was sampled" ;;
  esac
  assert_eq "$label: the sampled pid is the pipeline's own descendant" "$sleeper" "$sampled"
  if [ -n "$sampled" ]; then
    assert_true "$label: the sample landed at the -file path" \
      test -f "$fix/out/$name-stall-sample-$sampled.txt"
    assert_dead "$label: the sampled process was killed" "$sampled"
  fi
}

# The sleeper's argv is `/usr/bin/caffeinate -t 60`, which matches none of
# `swiftpm-testing`, `xctest` or `TBDPackageTests` — so this case exercises the
# FALLBACK selection, the one that samples every descendant that is not known
# plumbing.
test_stall_via_the_fallback_path() {
  local fix started; fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=stall)
  started=$(date +%s)
  run_pass "$fix" --name stallfallback --budget-seconds 3 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  SLEEPERS="$SLEEPERS $(sleeper_pid_of "$fix")"
  assert_stall "fallback stall" "$fix" stallfallback "$started"
}

# Same stall through a symlink under a `TBDPackageTests`-bearing directory, so
# the sleeper's argv carries the token the PRIMARY selection path matches — the
# shape a real `swiftpm-testing-helper` has. The symlink is named `sleep` on
# purpose: the fallback would skip it as plumbing, so only the argv match can
# reach it.
test_stall_via_the_primary_argv_match() {
  local fix started; fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=stall STUB_SLEEPER="$fix/TBDPackageTests-bin/sleep")
  started=$(date +%s)
  run_pass "$fix" --name stallprimary --budget-seconds 3 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  SLEEPERS="$SLEEPERS $(sleeper_pid_of "$fix")"
  assert_stall "primary stall" "$fix" stallprimary "$started"
}

# ---------------------------------------------------------------------------
# 5. A malformed invocation is refused by name, and never runs anything
# ---------------------------------------------------------------------------

test_usage_rejects_a_missing_name() {
  local fix; fix="$(mkfix)"
  run_pass "$fix" --budget-seconds 60 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  assert_eq "a missing --name exits 64" "64" "$RUN_RC"
  assert_contains "the refusal names the missing argument" "$RUN_OUT" "--name is required"
}

test_usage_rejects_a_non_numeric_budget() {
  local fix; fix="$(mkfix)"
  run_pass "$fix" --name bogus --budget-seconds soon --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  assert_eq "a non-numeric --budget-seconds exits 64" "64" "$RUN_RC"
  assert_contains "the refusal quotes the value it refused" "$RUN_OUT" "got 'soon'"
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "--- $t"
  "$t"
done

if [ "$FAIL" -eq 0 ]; then
  echo "All watched-test-pass tests passed."
else
  echo "Some watched-test-pass tests FAILED."
fi
exit "$FAIL"
