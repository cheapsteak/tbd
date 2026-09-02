#!/usr/bin/env bash
# Tests for scripts/restart-build-lib.sh — run: bash scripts/restart-build-lib.test.sh
#
# The invariant under test: restart.sh may only ship .build/debug when the
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

# --- restart.sh wiring --------------------------------------------------------
#
# Static checks: the guard is worth nothing if restart.sh stops calling it, and
# the pipeline is an easy "simplification" for a future editor to reintroduce.

test_restart_sh_routes_the_build_through_the_guard() {
    local body; body="$(cat "$HERE/restart.sh")"
    assert_contains "restart.sh sources the build lib" "$body" 'scripts/restart-build-lib.sh'
    # shellcheck disable=SC2016 # literal, unexpanded strings searched in restart.sh
    assert_contains "restart.sh runs the governed build" "$body" 'run_governed_build "$REPO_ROOT"'
    # shellcheck disable=SC2016
    assert_contains "a non-zero build status exits restart.sh" "$body" 'run_governed_build "$REPO_ROOT" || exit $?'
}

test_restart_sh_never_pipes_the_build_status_away() {
    local piped
    piped="$(grep -nE 'swift-safe build.*\|' "$HERE/restart.sh" || true)"
    assert_eq "no swift-safe build invocation is piped in restart.sh" "" "$piped"
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
