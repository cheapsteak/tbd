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
# observed alive on the first look. The escalation case costs the 30-second
# grace window on top, because that window is the thing it is measuring, which
# puts the whole file at about 90 seconds.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # the sed mutation expression must NOT expand here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/watched-test-pass.sh"

FAIL=0
assert_eq()       { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1 ;; esac; }
assert_file_has() { if [ -f "$2" ] && grep -q -- "$3" "$2"; then echo "ok   - $1"; else echo "FAIL - $1: $2 lacks [$3]"; FAIL=1; fi; }
assert_true()     { local label="$1"; shift; if "$@"; then echo "ok   - $label"; else echo "FAIL - $label"; FAIL=1; fi; }
assert_ok()       { if [ "$2" = "0" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected exit 0, got $2"; FAIL=1; fi; }
assert_dead()     { case "$2" in ''|*[!0-9]*) echo "FAIL - $1: '$2' is not a pid, so nothing was checked"; FAIL=1; return ;; esac
                    if kill -0 "$2" 2>/dev/null; then echo "FAIL - $1: pid $2 is still alive"; FAIL=1; else echo "ok   - $1"; fi; }
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
#   cap      spawn STUB_SLEEPER_COUNT sleepers that all match the primary path,
#            record every pid, and wait on them. More candidates than the
#            sampling cap, so the cap's counting and its skip line are driven.
#   escalate stop the PIPELINE SUBSHELL — the script's own background job, this
#            stub's grandparent — then block on a sleeper nothing will sample.
#            The sweep signals only the subshell's descendants, so a stopped
#            subshell is alive when the grace window opens and still alive when
#            it closes, which is the one shape that reaches the SIGKILL
#            escalation. Stopping the pty wrapper instead does NOT work and it
#            is worth knowing why: a stopped process does not hold a fatal
#            signal pending on this platform, the kernel wakes it to die, so the
#            sweep's SIGTERM takes the wrapper down, `tee` sees EOF and the
#            subshell finishes inside the grace like any healthy teardown.
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
  cap)
    spawned=0
    while [ "$spawned" -lt "${STUB_SLEEPER_COUNT:-6}" ]; do
      "$STUB_SLEEPER" -t 60 &
      echo "$!" >> "$STUB_PID_FILE"
      spawned=$((spawned + 1))
    done
    wait
    ;;
  escalate)
    echo "$$" > "$STUB_PID_FILE"
    # $PPID is the pty wrapper; its parent is the pipeline subshell.
    subshell=$(ps -o ppid= -p "$PPID" | tr -d ' ')
    echo "$subshell" > "$STUB_PIPELINE_FILE"
    kill -STOP "$subshell"
    exec "$STUB_PLAIN_SLEEPER" 60
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
#
# RUN_SCRIPT names the copy to run, so a case can run a MUTANT of the script in
# place of the real one. Empty means the fixture's faithful copy, which is every
# case but the ordering mutation.
RUN_ENV=()
RUN_SCRIPT=""
run_pass() {
  local fix="$1"; shift
  RUN_OUT="$(PATH="$fix/bin:$PATH" \
    SAMPLE_ARGV_FILE="$fix/sample-argv" \
    STUB_PID_FILE="$fix/sleeper.pid" \
    STUB_PIPELINE_FILE="$fix/pipeline.pid" \
    STUB_SLEEPER="/usr/bin/caffeinate" \
    STUB_PLAIN_SLEEPER="/bin/sleep" \
    env ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    /bin/bash "${RUN_SCRIPT:-$fix/scripts/ci/watched-test-pass.sh}" "$@" 2>&1)"
  RUN_RC=$?
}

# A copy of the script with one guard weakened by `sed`, run exactly as the real
# one is. A green mutant means the assertion above it was not testing that guard.
# It is written NEXT TO the fixture's faithful copy, because the script resolves
# `scripts/test.sh` relative to its own directory.
MUTANT_SEQ=0
mutant_of() {
  local fix="$1" sed_expr="$2" out
  MUTANT_SEQ=$((MUTANT_SEQ + 1))
  out="$fix/scripts/ci/mutant.$MUTANT_SEQ.sh"
  sed -E "$sed_expr" "$SCRIPT" > "$out"
  chmod +x "$out"
  echo "$out"
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
# 5. More candidates than the cap: four get stacks, the rest get swept
# ---------------------------------------------------------------------------

# The line the script writes into the ps file before each sweep, e.g.
# "=== SIGTERM order, deepest first and tee last === 900(sleep) 890(sh) …".
kill_order_line_of() { grep -m1 "=== $2 order" "$1" 2>/dev/null; }

# One entry of that line, by position, with the pid stripped so only the process
# name is compared — the pids differ every run.
order_entry() {
  printf '%s\n' "$1" | sed 's/.*=== //' | awk -v want="$2" '
    { n = NF
      if (want == "first")       { print $1 }
      else if (want == "last")   { print $n }
      else if (want == "penultimate" && n > 1) { print $(n - 1) } }
  ' | sed 's/^[0-9]*//'
}

# Six sleepers whose argv all match the primary path, against a cap of four. The
# cap's arithmetic, its skip line and the split between "sampled, then SIGKILLed"
# and "left to the graceful sweep" are only reachable with more candidates than
# the cap, which the one-descendant cases above cannot produce.
test_sampling_cap_takes_four_and_sweeps_the_rest() {
  local fix started ps_file order spawned sampled pid swept=""
  fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=cap STUB_SLEEPER="$fix/TBDPackageTests-bin/sleep" STUB_SLEEPER_COUNT=6)
  started=$(date +%s)
  run_pass "$fix" --name capped --budget-seconds 3 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  spawned="$(cat "$fix/sleeper.pid" 2>/dev/null | tr '\n' ' ')"
  SLEEPERS="$SLEEPERS $spawned"
  ps_file="$fix/out/capped-stall-ps.txt"

  assert_eq "cap: a stall is red" "1" "$RUN_RC"
  assert_eq "cap: six candidates were spawned" "6" "$(echo "$spawned" | wc -w | tr -d ' ')"
  assert_eq "cap: exactly four were sampled" "4" \
    "$(wc -l < "$fix/sample-argv" 2>/dev/null | tr -d ' ')"
  assert_eq "cap: exactly four sample files were written" "4" \
    "$(find "$fix/out" -name 'capped-stall-sample-*.txt' | wc -l | tr -d ' ')"
  assert_file_has "cap: the ps file records what the cap dropped" "$ps_file" \
    'primary sampling capped at 4 targets; 2 further candidates skipped'

  sampled="$(cut -d' ' -f1 "$fix/sample-argv" 2>/dev/null | tr '\n' ' ')"
  for pid in $sampled; do
    case " $spawned " in
      *" $pid "*) ;;
      *) echo "FAIL - cap: sampled pid $pid is not one of the spawned sleepers"; FAIL=1 ;;
    esac
  done
  echo "ok   - cap: every sampled pid is one of the spawned sleepers"
  for pid in $spawned; do
    case " $sampled " in
      *" $pid "*) ;;
      *) swept="$swept $pid" ;;
    esac
  done
  assert_eq "cap: the two the cap dropped were left to the sweep" "2" \
    "$(echo "$swept" | wc -w | tr -d ' ')"
  # The four sampled die to the sampling loop's own SIGKILL, the other two to
  # the graceful sweep — either way none may survive the step.
  for pid in $spawned; do
    assert_dead "cap: sleeper $pid is gone" "$pid"
  done

  # The order the sweep was built in, which is also the tee-dies-last property:
  # `tee` owns the far end of the log pipe, so it must be signalled after the
  # pty wrapper and after everything below it.
  order="$(kill_order_line_of "$ps_file" SIGTERM)"
  assert_contains "cap: the sweep order is recorded for a reader" "$order" "=== SIGTERM order"
  assert_eq "cap: tee is signalled last" "(tee)" "$(order_entry "$order" last)"
  assert_eq "cap: the pty wrapper is signalled just before tee" "(script)" \
    "$(order_entry "$order" penultimate)"
}

# The same fixture against a copy of the script whose kill order is the naive
# reversal the comment warns about — `tee` first, deepest last. The assertion
# above has to flip, or it was not testing the ordering.
test_reversing_the_kill_order_puts_tee_first() {
  local fix order spawned
  fix="$(mkfix)"
  RUN_SCRIPT="$(mutant_of "$fix" \
    's/kill_order="\$deeper_first \$direct_others \$tee_pids"/kill_order="$tee_pids $direct_others $deeper_first"/')"
  RUN_ENV=(STUB_MODE=cap STUB_SLEEPER="$fix/TBDPackageTests-bin/sleep" STUB_SLEEPER_COUNT=6)
  run_pass "$fix" --name reversed --budget-seconds 3 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  RUN_SCRIPT=""
  spawned="$(cat "$fix/sleeper.pid" 2>/dev/null | tr '\n' ' ')"
  SLEEPERS="$SLEEPERS $spawned"
  order="$(kill_order_line_of "$fix/out/reversed-stall-ps.txt" SIGTERM)"
  assert_contains "mutant: the reversed order was recorded" "$order" "=== SIGTERM order"
  assert_eq "mutant: tee is signalled FIRST, which is the bug" "(tee)" \
    "$(order_entry "$order" first)"
  if [ "$(order_entry "$order" last)" = "(tee)" ]; then
    echo "FAIL - mutant: tee is still last — the ordering assertion proves nothing"
    FAIL=1
  else
    echo "ok   - mutant: tee is no longer last, so the ordering assertion discriminates"
  fi
}

# ---------------------------------------------------------------------------
# 6. A pipeline still alive after the grace window is SIGKILLed
# ---------------------------------------------------------------------------

# The pipeline subshell's pid, which the escalate stub records before stopping it.
pipeline_pid_of() { cat "$1/pipeline.pid" 2>/dev/null; }

# The stub stops the pipeline subshell, which the sweep never signals — it walks
# and signals only that subshell's DESCENDANTS. So the subshell is alive when the
# grace window opens and still alive when it closes, and the only thing that can
# end the step is the escalation's `kill -KILL "$pipeline"`. That line is the
# guarantee the whole budget rests on: without it the script would sit in `wait`
# until the platform timeout, which is the outcome the budget exists to prevent.
#
# Nothing is sampled here on purpose — the sleeper's argv carries none of the
# matched tokens and its `comm` is `sleep`, which the fallback skips as plumbing,
# as do `script`, `sh` and `tee`. So the run also covers the
# "no sampleable descendants" path.
test_a_pipeline_outliving_the_grace_is_killed() {
  local fix started elapsed pipeline sleeper
  fix="$(mkfix)"
  RUN_ENV=(STUB_MODE=escalate)
  started=$(date +%s)
  run_pass "$fix" --name escalated --budget-seconds 3 --floor 35 \
    --floor-message 'the regex matched nothing.' --out-dir "$fix/out" -- --fingerprint
  RUN_ENV=()
  elapsed=$(( $(date +%s) - started ))
  pipeline="$(pipeline_pid_of "$fix")"
  sleeper="$(sleeper_pid_of "$fix")"
  SLEEPERS="$SLEEPERS $pipeline $sleeper"

  assert_eq "escalation: a stall is red" "1" "$RUN_RC"
  assert_contains "escalation: nothing was sampleable" "$RUN_OUT" \
    "The pipeline has no sampleable descendants"
  assert_eq "escalation: no sample file was written" "0" \
    "$(find "$fix/out" -name 'escalated-stall-sample-*.txt' | wc -l | tr -d ' ')"
  # Under 30 s would mean the graceful sweep ended it and the escalation never
  # ran; 60 s or more would mean something other than the grace window was being
  # waited on.
  if [ "$elapsed" -ge 30 ] && [ "$elapsed" -lt 60 ]; then
    echo "ok   - escalation: the step took ${elapsed}s, the grace window plus the poll"
  else
    echo "FAIL - escalation: the step took ${elapsed}s, which is not the 30 s grace"
    FAIL=1
  fi
  assert_file_has "escalation: the SIGKILL order was recorded" \
    "$fix/out/escalated-stall-ps.txt" "=== SIGKILL order"
  # The subshell was stopped and is signalled by nothing but the escalation, so
  # its death is proof that `kill -KILL "$pipeline"` ran.
  assert_dead "escalation: the stopped pipeline subshell was SIGKILLed" "$pipeline"
  assert_dead "escalation: its sleeper is gone too" "$sleeper"
}

# ---------------------------------------------------------------------------
# 7. A malformed invocation is refused by name, and never runs anything
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
