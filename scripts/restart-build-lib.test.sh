#!/usr/bin/env bash
# Tests for scripts/restart-build-lib.sh — run: bash scripts/restart-build-lib.test.sh
#
# The invariant under test: restart.sh may only ship .build/<config> when the
# build it just ran actually succeeded. The failure this guards against is a
# pipeline swallowing the status — `scripts/swift-safe build … | tail -3`
# exits with tail's status (0) even when swift-safe exited 75 having compiled
# nothing, and restart.sh then relaunched the app and daemon machine-wide from
# whatever stale binaries happened to be lying around.
#
# shellcheck disable=SC2329 # test_* helpers are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/restart-build-lib.sh"   # pure function defs, no side effects

# The shipped poll interval is a second, which is right next to a compiler and
# wrong inside a harness that runs a dozen builds: every case would pay it once
# waiting for the watcher's last pass. The parsing of the knob (including its
# default) has its own case; these run fast.
export TBD_RESTART_BUILD_POLL_SECONDS=0.05

FAIL=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAIL=1; }

assert_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d: expected success"; fi; }
assert_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d: expected failure"; else pass "$d"; fi; }
assert_eq()   { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$2] got [$3]"; fi; }
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1: [$3] not found in [$2]"; fi
}
assert_missing() {
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1: [$3] unexpectedly present"; fi
}

# Build a throwaway "worktree" whose scripts/swift-safe is a stub that exits
# with $1 after writing $2 lines to stdout and one line to stderr (the shape
# of the real wrapper's final "exit status N" line). Every invocation appends
# its arguments to $d/args.txt so pass-through can be asserted. Echoes $d.
mkfakeworktree() {
    local status="$1" stdout_lines="${2:-1}"
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/restart-build-test.XXXXXX")"
    mkdir -p "$d/scripts"
    cat > "$d/scripts/swift-safe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$d/args.txt"
for i in \$(seq 1 $stdout_lines); do echo "compiler output line \$i"; done
echo "swift-safe: exit status $status" >&2
exit $status
EOF
    chmod +x "$d/scripts/swift-safe"
    echo "$d"
}

# Build a throwaway "worktree" whose scripts/swift-safe stub BLOCKS until the
# test releases it, so anything asserted while it blocks is provably asserted
# mid-build. It writes, in order: $2 lines of compiler noise, one `swift-safe:`
# progress line, then nothing until $d/release exists, then a final noise line
# and the wrapper's own exit-status line. Echoes $d.
mkblockingworktree() {
    local noise_lines="${1:-1}"
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/restart-build-block.XXXXXX")"
    mkdir -p "$d/scripts"
    cat > "$d/scripts/swift-safe" <<EOF
#!/usr/bin/env bash
for i in \$(seq 1 $noise_lines); do echo "compiler output line \$i"; done
echo "swift-safe: still waiting for the shared build slot after 60s of 1800s (held by pid 1)" >&2
while [ ! -e "$d/release" ]; do sleep 0.05; done
echo "compiler output line after release"
echo "swift-safe: exit status 0" >&2
exit 0
EOF
    chmod +x "$d/scripts/swift-safe"
    echo "$d"
}

# Wait up to ~10s for $2 to appear in file $1. Echoes "found" or "missing".
await_text() {
    local file="$1" needle="$2" waited=0
    while [ "$waited" -lt 200 ]; do
        if [ -e "$file" ] && grep -qF -- "$needle" "$file" 2>/dev/null; then
            echo found; return 0
        fi
        sleep 0.05
        waited=$((waited + 1))
    done
    echo missing
}

# `sleep` reached through a SYMLINK named e.g. `swift-frontend`, so a fixture
# process really carries that name in the process table. Echoes the pid of the
# wrapper the fixture runs UNDER, which is what a walk is rooted at.
#
# A symlink and not a copy: darwin SIGKILLs a copied system binary on exec —
# the copy is no longer a platform binary and fails its signature check — so a
# `cp` fixture dies before the walk can see it, and the test then fails for a
# reason that has nothing to do with the walk. Nor a shell script: `ps comm`
# names the interpreter, not the script.
#
# The fixture self-reaps in 20s, so even a teardown that loses the pid bounds
# the leak — a process nothing can reclaim is this repo's most common one.
fake_process() {
    local dir="$1" name="$2"
    ln -s "$(command -v sleep)" "$dir/$name"
    # `; true` keeps bash from exec'ing the command into its own pid, so the
    # fixture really is a DESCENDANT of the pid the walk is rooted at. Its
    # output goes to /dev/null because this function is called inside a
    # command substitution: a background job left holding that pipe keeps it
    # open, and `$(fake_process …)` then blocks for the fixture's whole life.
    bash -c "\"$dir/$name\" 20; true" >/dev/null 2>&1 &
    echo $!
}

# Wait up to ~5s for a process named $2 to appear below pid $1. `fake_process`
# returns as soon as bash is forked, which is before it has exec'd anything.
await_process() {
    local root="$1" name="$2" waited=0
    while [ "$waited" -lt 100 ]; do
        if build_descendant_processes "$root" | grep -q -- "$name"; then
            echo found; return 0
        fi
        sleep 0.05
        waited=$((waited + 1))
    done
    echo missing
}

# Tear a fixture tree down by pid — never by name. Patterns on this machine
# match every sibling worktree's processes.
kill_tree() {
    local root="$1" pid
    for pid in $(build_descendant_processes "$root" | awk '{print $1}'); do
        kill "$pid" 2>/dev/null
    done
    kill "$root" 2>/dev/null
    wait "$root" 2>/dev/null
}

# Run run_governed_build under RESTART.SH's shell options, not this harness's.
# This file sets `pipefail`; restart.sh sets only `set -e`, and without
# pipefail a pipeline reports its LAST command's status — the entire bug. A
# test that called the function directly would inherit this harness's pipefail
# and pass even against the piped implementation, which is worthless. So the
# call goes through a subshell configured exactly like restart.sh, and the
# subshell's own exit status is the answer.
run_under_restart_shell() {
    local repo="$1"; shift
    bash -c '
        set -e
        # shellcheck source=/dev/null
        source "$0/restart-build-lib.sh"
        repo="$1"; shift
        run_governed_build "$repo" "$@"
    ' "$HERE" "$repo" "$@"
}

# --- the ship/no-ship decision ------------------------------------------------

test_only_zero_permits_shipping() {
    assert_ok   "status 0 permits shipping" build_status_permits_ship 0
    assert_fail "status 1 does not permit shipping" build_status_permits_ship 1
    assert_fail "status 75 does not permit shipping" build_status_permits_ship 75
    assert_fail "status 76 does not permit shipping" build_status_permits_ship 76
    # An unrecognized status is still a build that did not finish: the
    # decision is a whitelist of known-good, never a blacklist of known-bad.
    assert_fail "unknown status 42 does not permit shipping" build_status_permits_ship 42
    assert_fail "empty status does not permit shipping" build_status_permits_ship ""
}

test_slot_not_obtained_statuses() {
    assert_ok   "75 is slot-not-obtained" build_status_is_slot_not_obtained 75
    assert_ok   "76 is slot-not-obtained" build_status_is_slot_not_obtained 76
    assert_fail "0 is not slot-not-obtained" build_status_is_slot_not_obtained 0
    assert_fail "1 is not slot-not-obtained" build_status_is_slot_not_obtained 1
    assert_fail "69 is not slot-not-obtained" build_status_is_slot_not_obtained 69
}

# --- the failure message ------------------------------------------------------

test_message_for_lock_timeout_says_nothing_compiled() {
    local msg; msg="$(describe_build_failure 75)"
    assert_contains "75 names its status" "$msg" "exited 75"
    assert_contains "75 uses swift-safe's EX_TEMPFAIL vocabulary" "$msg" "EX_TEMPFAIL"
    assert_contains "75 says nothing was compiled" "$msg" "nothing was compiled"
    assert_contains "75 says it is retryable" "$msg" "retryable"
    assert_contains "75 says nothing was shipped" "$msg" "Nothing was shipped"
    assert_contains "75 says the running processes were untouched" "$msg" "running app and daemon were left"
    # A lock that was never obtained is NOT a compile failure; saying so would
    # send the reader hunting for a compiler error that does not exist.
    assert_missing "75 does not claim the build failed" "$msg" "the build FAILED"
}

test_message_for_queue_yield_says_nothing_compiled() {
    local msg; msg="$(describe_build_failure 76)"
    assert_contains "76 names its status" "$msg" "exited 76"
    assert_contains "76 uses swift-safe's yield vocabulary" "$msg" "yielded its place in the queue"
    assert_contains "76 says nothing was compiled" "$msg" "nothing was compiled"
    assert_missing "76 does not claim the build failed" "$msg" "the build FAILED"
}

test_message_for_compile_failure_points_at_output() {
    local msg; msg="$(describe_build_failure 1)"
    assert_contains "compile failure says the build failed" "$msg" "the build FAILED"
    assert_contains "compile failure names its status" "$msg" "exited 1"
    assert_contains "compile failure points at the printed output" "$msg" "output printed above"
    assert_missing "compile failure does not claim a lock timeout" "$msg" "EX_TEMPFAIL"
    assert_contains "compile failure still says nothing was shipped" "$msg" "Nothing was shipped"
}

test_no_automatic_retry_is_stated() {
    local msg; msg="$(describe_build_failure 75)"
    assert_contains "message explains why there is no auto-retry" "$msg" "Not retried automatically"
}

# --- running the governed build ----------------------------------------------

# THE REGRESSION: swift-safe timed out waiting for the machine-wide build lock
# and exited 75 having compiled nothing. Piped into `tail -3`, that surfaced as
# status 0 and restart.sh shipped stale binaries. The real status must survive.
test_lock_timeout_status_survives() {
    local d; d="$(mkfakeworktree 75)"
    local out status=0
    out="$(run_under_restart_shell "$d" -Xswiftc -foo 2>/dev/null)" || status=$?
    assert_eq "run_governed_build returns swift-safe's 75, not tail's 0" "75" "$status"
    rm -rf "$d"
}

test_queue_yield_status_survives() {
    local d; d="$(mkfakeworktree 76)"
    local status=0
    run_under_restart_shell "$d" >/dev/null 2>&1 || status=$?
    assert_eq "run_governed_build returns 76" "76" "$status"
    rm -rf "$d"
}

test_compile_failure_status_survives() {
    local d; d="$(mkfakeworktree 1)"
    local status=0
    run_under_restart_shell "$d" >/dev/null 2>&1 || status=$?
    assert_eq "run_governed_build returns 1 on a compile failure" "1" "$status"
    rm -rf "$d"
}

test_successful_build_returns_zero() {
    local d; d="$(mkfakeworktree 0)"
    local status=0
    run_under_restart_shell "$d" >/dev/null 2>&1 || status=$?
    assert_eq "run_governed_build returns 0 on success" "0" "$status"
    rm -rf "$d"
}

test_failure_explanation_reaches_stderr() {
    local d; d="$(mkfakeworktree 75)"
    local err; err="$(run_under_restart_shell "$d" 2>&1 >/dev/null)" || true
    assert_contains "explanation goes to stderr" "$err" "EX_TEMPFAIL"
    rm -rf "$d"
}

# swift-safe's own final stderr line — the one it prints so the number
# survives a pipe — must still reach the human through the trimmed output.
test_swift_safe_status_line_reaches_the_human() {
    local d; d="$(mkfakeworktree 75)"
    local out; out="$(run_under_restart_shell "$d" 2>/dev/null)" || true
    assert_contains "swift-safe's exit-status line survives the trim" "$out" "swift-safe: exit status 75"
    rm -rf "$d"
}

# The trimming is the whole reason the old pipeline existed: restart.sh is
# nearly always run by an agent, and full compiler output floods its context.
test_output_is_trimmed_to_three_lines() {
    local d; d="$(mkfakeworktree 0 200)"
    local out; out="$(run_under_restart_shell "$d" 2>/dev/null)"
    assert_eq "only the last 3 lines are printed" "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    assert_contains "the trimmed output is the TAIL" "$out" "compiler output line 200"
    assert_missing "the head of the output is dropped" "$out" "compiler output line 1 "
    rm -rf "$d"
}

# restart.sh passes no extra arguments today, but the lib's contract is that
# whatever it is given reaches the wrapper unmangled — flags and their values
# alike. (The module cache is deliberately NOT among them: scripts/swift-safe
# decides that for every governed build. See
# docs/specs/2026-08-30-shared-module-cache-design.md.)
test_arguments_pass_through_to_swift_safe() {
    local d; d="$(mkfakeworktree 0)"
    run_under_restart_shell "$d" --product TBDApp -Xswiftc -DEXAMPLE >/dev/null 2>&1
    local args; args="$(cat "$d/args.txt")"
    assert_contains "the subcommand is build" "$args" "build"
    # The stub records one argument per line, so each is asserted on its own.
    assert_contains "flags reach swift-safe" "$args" "-Xswiftc"
    assert_contains "flag values reach swift-safe" "$args" "-DEXAMPLE"
    assert_contains "options reach swift-safe" "$args" "--product"
    assert_contains "option values reach swift-safe" "$args" "TBDApp"
    rm -rf "$d"
}

# The output file is an implementation detail of not-piping; it must not
# accumulate in TMPDIR on either the success or the failure path.
test_temp_output_file_is_cleaned_up() {
    local scratch; scratch="$(mktemp -d "${TMPDIR:-/tmp}/restart-build-tmpdir.XXXXXX")"
    local d0 d75
    d0="$(mkfakeworktree 0)"; d75="$(mkfakeworktree 75)"
    ( TMPDIR="$scratch"; run_under_restart_shell "$d0" >/dev/null 2>&1 ) || true
    ( TMPDIR="$scratch"; run_under_restart_shell "$d75" >/dev/null 2>&1 ) || true
    local leftovers; leftovers="$(find "$scratch" -name 'tbd-restart-build.*' | wc -l | tr -d ' ')"
    assert_eq "no build-output temp files left behind" "0" "$leftovers"
    rm -rf "$scratch" "$d0" "$d75"
}

# --- reporting a build that has not finished ----------------------------------
#
# THE REGRESSION: `Building...` and then nothing, for as long as it took. The
# wait announcement and 60s heartbeat scripts/swift-safe writes exist so that a
# queued build is not silent for its whole 30-minute timeout — and they landed
# in a temp file that was read only after the build ended, which is precisely
# when they have stopped being worth anything. A developer watching a build
# blocked behind an 11-day-stale lock saw the same blank terminal as one
# watching a healthy compile.

test_swift_safe_progress_reaches_the_terminal_while_the_build_runs() {
    local d; d="$(mkblockingworktree 200)"
    local out="$d/stdout.txt" err="$d/stderr.txt"
    run_under_restart_shell "$d" > "$out" 2> "$err" &
    local runner=$!

    local seen; seen="$(await_text "$err" "still waiting for the shared build slot")"
    assert_eq "the wait line arrives before the build ends" "found" "$seen"
    # Proof that it arrived MID-BUILD and not at the end: the stub cannot
    # return until $d/release exists, and nothing has created it yet.
    assert_fail "the build had not been released yet" test -e "$d/release"
    assert_eq "nothing has been trimmed yet — the build has not ended" "" "$(cat "$out")"
    # Compiler output is what floods an agent's context; only the wrapper's
    # own prefixed lines are separable, and only they may be streamed.
    assert_missing "compiler output is not streamed live" "$(cat "$err")" "compiler output line 1"

    : > "$d/release"
    local status=0; wait "$runner" || status=$?
    assert_eq "the released build still returns 0" "0" "$status"
    assert_contains "the trim still runs at the end" "$(cat "$out")" "compiler output line after release"
    rm -rf "$d"
}

test_a_silent_build_is_described_while_it_runs() {
    local d; d="$(mkblockingworktree 1)"
    local out="$d/stdout.txt" err="$d/stderr.txt"
    (
        export TBD_RESTART_BUILD_SILENCE_SECONDS=1
        run_under_restart_shell "$d" > "$out" 2> "$err"
    ) &
    local runner=$!

    local seen; seen="$(await_text "$err" "no build output for")"
    assert_eq "silence is reported while the build is still blocked" "found" "$seen"
    assert_fail "the build had not been released yet" test -e "$d/release"
    assert_contains "the report applies the compiler discriminator" \
        "$(cat "$err")" "NO swift-frontend process is running"

    : > "$d/release"
    local status=0; wait "$runner" || status=$?
    assert_eq "a build that was merely slow still returns its own status" "0" "$status"
    rm -rf "$d"
}

test_a_finishing_build_is_never_called_silent() {
    local d; d="$(mkfakeworktree 0)"
    local err
    err="$( (
        export TBD_RESTART_BUILD_SILENCE_SECONDS=1
        run_under_restart_shell "$d" 2>&1 >/dev/null
    ) )"
    assert_missing "a build that produced output is not reported silent" "$err" "no build output for"
    rm -rf "$d"
}

# The liveness discriminator this repo already uses by hand: swift-build and
# swift-driver sit at 0% CPU by design while they wait on their jobs, so only
# swift-frontend leaves prove a compiler is running. The real incident had a
# SwiftPM manifest binary wedged before it executed an instruction — a process
# tree with no compiler in it at all, holding the machine-global slot.

test_the_process_walk_finds_a_process_below_the_root() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/restart-build-walk.XXXXXX")"
    local root; root="$(fake_process "$d" swift-frontend)"
    local found=missing waited=0
    while [ "$waited" -lt 100 ]; do
        if build_descendant_processes "$root" | grep -q "swift-frontend"; then
            found=found; break
        fi
        sleep 0.05; waited=$((waited + 1))
    done
    assert_eq "the walk sees a descendant of the build" "found" "$found"
    assert_eq "the root itself is not listed" "" \
        "$(build_descendant_processes "$root" | awk -v r="$root" '$1 == r')"
    kill_tree "$root"
    rm -rf "$d"
}

test_silence_with_a_live_compiler_says_the_build_is_working() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/restart-build-busy.XXXXXX")"
    local root; root="$(fake_process "$d" swift-frontend)"
    await_process "$root" swift-frontend >/dev/null
    local msg; msg="$(describe_silent_build "$root" 420)"
    assert_contains "silence with a compiler names the silence" "$msg" "no build output for 420s"
    assert_contains "silence with a compiler is reassuring" "$msg" "the compiler is working"
    assert_missing "no alarm is raised while a compiler runs" "$msg" "NO swift-frontend"
    kill_tree "$root"
    rm -rf "$d"
}

test_silence_with_no_compiler_names_what_is_actually_running() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/restart-build-stall.XXXXXX")"
    local root; root="$(fake_process "$d" tbd-manifest)"
    await_process "$root" tbd-manifest >/dev/null
    local msg; msg="$(describe_silent_build "$root" 660)"
    assert_contains "the stall names the silence" "$msg" "no build output for 660s"
    assert_contains "the stall says no compiler is running" "$msg" "NO swift-frontend process is running"
    assert_contains "the stall names the live process" "$msg" "tbd-manifest"
    assert_contains "the stall explains why an idle process proves nothing" "$msg" "idle at 0% CPU by design"
    assert_contains "the stall distinguishes holding from queueing" "$msg" "HOLDS the slot"
    assert_contains "the stall points at the lock to inspect" "$msg" "swift-build.lock"
    kill_tree "$root"
    rm -rf "$d"
}

test_silence_with_no_live_processes_says_so() {
    local dead; dead="$(bash -c 'echo $$')"
    # A pid that has exited: the walk finds nothing below it.
    local msg; msg="$(describe_silent_build "$dead" 900)"
    assert_contains "an empty process tree is reported as empty" "$msg" "no live child processes"
}

test_the_lock_path_follows_the_wrappers_own_resolution() {
    assert_eq "an explicit lock path wins" "/tmp/example.lock" \
        "$( TBD_SWIFT_LOCK_PATH=/tmp/example.lock swift_build_lock_path )"
    assert_eq "TBD_HOME is honored" "/tmp/fake-home/runtime/swift-build.lock" \
        "$( unset TBD_SWIFT_LOCK_PATH; TBD_HOME=/tmp/fake-home swift_build_lock_path )"
}

test_bad_diagnostic_knobs_fall_back_to_their_defaults() {
    assert_eq "a non-numeric poll falls back" "$DEFAULT_BUILD_POLL_SECONDS" \
        "$( TBD_RESTART_BUILD_POLL_SECONDS=soon build_poll_seconds )"
    assert_eq "a zero poll falls back rather than spinning" "$DEFAULT_BUILD_POLL_SECONDS" \
        "$( TBD_RESTART_BUILD_POLL_SECONDS=0 build_poll_seconds )"
    assert_eq "a fractional poll is accepted" "0.25" \
        "$( TBD_RESTART_BUILD_POLL_SECONDS=0.25 build_poll_seconds )"
    assert_eq "a non-numeric silence bound falls back" "$DEFAULT_BUILD_SILENCE_SECONDS" \
        "$( TBD_RESTART_BUILD_SILENCE_SECONDS=never build_silence_seconds )"
    assert_eq "a fractional silence bound falls back — it is integer arithmetic" \
        "$DEFAULT_BUILD_SILENCE_SECONDS" \
        "$( TBD_RESTART_BUILD_SILENCE_SECONDS=1.5 build_silence_seconds )"
    assert_eq "an explicit silence bound is honored" "42" \
        "$( TBD_RESTART_BUILD_SILENCE_SECONDS=42 build_silence_seconds )"
}

# --- restart.sh wiring --------------------------------------------------------
#
# Static checks: the guard is worth nothing if restart.sh stops calling it, and
# the pipeline is an easy "simplification" for a future editor to reintroduce.

test_restart_sh_routes_the_build_through_the_guard() {
    local body; body="$(cat "$HERE/restart.sh")"
    assert_contains "restart.sh sources the build lib" "$body" 'scripts/restart-build-lib.sh'
    # shellcheck disable=SC2016 # literal, unexpanded strings searched in restart.sh
    assert_contains "restart.sh runs the governed build" "$body" 'run_governed_build "$REPO_ROOT"'
    # restart.sh builds one runtime product per invocation, so the invocation
    # spans several lines. Read the whole call — from the function name to the
    # line that keeps its status — rather than pinning one spelling of it.
    local call
    # shellcheck disable=SC2016
    call="$(sed -n '/run_governed_build "\$REPO_ROOT"/,/build_status=\$?/p' "$HERE/restart.sh")"
    # shellcheck disable=SC2016
    assert_contains "a non-zero build status is kept, not discarded" "$call" '|| build_status=$?'
    # ...and stops restart.sh with that same status, before anything ships.
    # shellcheck disable=SC2016
    assert_contains "a non-zero build status exits restart.sh" "$body" '[ "$build_status" -eq 0 ] || exit "$build_status"'
}

# The `swift-safe build` invocation lives in restart-build-lib.sh, so that is the
# file this grep has to read; pointed at restart.sh it can never match and the
# assertion passes unconditionally. Both files are scanned so the mistake cannot
# be reintroduced at the call's old home either.
# The status must come from the build job itself. Watching a build while it
# runs means the build cannot be in the foreground, and `wait` is then the
# only thing that reports THAT job's status and no other command's. Feeding
# the build into the watcher through a pipe would put the status back at the
# mercy of the last command in the pipe, which is the bug this file exists to
# prevent; the case above forbids the pipe, this one pins what replaced it.
test_the_build_status_comes_from_waiting_on_the_build_job() {
    local body; body="$(cat "$HERE/restart-build-lib.sh")"
    # shellcheck disable=SC2016 # literal, unexpanded strings searched in the lib
    assert_contains "the build runs in the background" "$body" '> "$build_log" 2>&1 &'
    # shellcheck disable=SC2016
    assert_contains "its status comes from waiting on it" "$body" 'wait "$builder" || status=$?'
}

test_the_build_invocation_never_pipes_the_status_away() {
    local f piped
    for f in restart-build-lib.sh restart.sh; do
        # `||` is not a pipe. Mask it before looking for a real one, or the
        # `|| status=$?` that KEEPS the build's status reads as the very bug
        # this guard exists to catch.
        piped="$(grep -nE 'swift-safe build' "$HERE/$f" | sed 's/||/OR/g' | grep -E '\|' || true)"
        assert_eq "no swift-safe build invocation is piped in $f" "" "$piped"
    done
}

# --skip-build (--quick) must keep shipping the existing binaries: no build was
# attempted, so there is no status to gate on. The guarded call must therefore
# sit inside the skip_build branch, not before it.
test_guard_applies_only_when_a_build_is_attempted() {
    local restart="$HERE/restart.sh"
    local skip_ln guard_ln bundle_ln
    # shellcheck disable=SC2016 # literal, unexpanded strings searched in restart.sh
    skip_ln="$(grep -nF 'if [ "$skip_build" = false ]; then' "$restart" | head -1 | cut -d: -f1)"
    # shellcheck disable=SC2016
    guard_ln="$(grep -nF 'run_governed_build "$REPO_ROOT"' "$restart" | head -1 | cut -d: -f1)"
    bundle_ln="$(grep -nF '# MARK: - Assemble TBD.app bundle' "$restart" | head -1 | cut -d: -f1)"
    local order="unknown"
    if [[ -n "$skip_ln" && -n "$guard_ln" && -n "$bundle_ln" ]] \
        && (( skip_ln < guard_ln )) && (( guard_ln < bundle_ln )); then
        order="inside-skip-build-branch"
    fi
    assert_eq "guarded build (line ${guard_ln:-?}) sits inside the skip_build branch (line ${skip_ln:-?}) and before the bundle (line ${bundle_ln:-?})" \
        "inside-skip-build-branch" "$order"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
if [ "$FAIL" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL RESTART-BUILD-LIB TESTS PASSED"
