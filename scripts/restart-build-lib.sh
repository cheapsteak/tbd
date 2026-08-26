#!/usr/bin/env bash
# Governed-build helpers for restart.sh. Safe to source: defines functions
# only, launches nothing, installs nothing.
#
# restart.sh's job after the build is destructive and machine-wide — it
# assembles a bundle, copies it over /Applications/TBD.app, and restarts the
# shared daemon. Everything it ships comes out of .build/debug, so it may only
# run when the build it just asked for actually produced those binaries. That
# makes "did the build succeed?" a load-bearing decision rather than a
# formality, which is why it lives here as a pure function with its own
# harness (scripts/restart-build-lib.test.sh).
#
# Exit statuses come from scripts/swift-safe; its EXIT_MEANINGS dict is the
# authoritative list. Two of them mean the machine-wide build lock was never
# obtained, so *nothing was compiled* — those are retryable, and reporting
# them as a compile failure would send a reader hunting for a compiler error
# that does not exist.

# Statuses that mean scripts/swift-safe never got the shared build slot: 75
# (EX_TEMPFAIL — the wait timed out or the requester went away) and 76 (the
# wait yielded its place in the queue). Both compiled nothing at all.
SWIFT_SAFE_SLOT_NOT_OBTAINED_STATUSES=(75 76)

# May restart.sh ship what is in .build/debug, given the status of the build
# it just ran? Only a clean zero says yes. Deliberately not "is it one of the
# statuses I recognize" — an unrecognized non-zero is still a build that did
# not finish, and a whitelist of known-good is the only shape that stays safe
# when scripts/swift-safe grows a status this file has never heard of.
build_status_permits_ship() {
    [ "${1-}" = "0" ]
}

# True when the status means the shared build slot was never obtained.
build_status_is_slot_not_obtained() {
    local status="${1-}"
    local candidate
    for candidate in "${SWIFT_SAFE_SLOT_NOT_OBTAINED_STATUSES[@]}"; do
        [ "$status" = "$candidate" ] && return 0
    done
    return 1
}

# Explain a non-zero build status on stdout, in scripts/swift-safe's own
# vocabulary. Callers redirect this to stderr.
describe_build_failure() {
    local status="${1-}"
    if build_status_is_slot_not_obtained "$status"; then
        printf 'ERROR: nothing was compiled — scripts/swift-safe exited %s.\n' "$status"
        if [ "$status" = "75" ]; then
            printf '  75 = EX_TEMPFAIL: the shared build slot was not obtained.\n'
        else
            printf '  76 = the wait yielded its place in the queue.\n'
        fi
        printf '  The machine-wide build lock was never acquired, so no compiler ran.\n'
        printf '  This is retryable: re-run scripts/restart.sh once the machine is quieter.\n'
    else
        printf 'ERROR: the build FAILED — scripts/swift-safe exited %s.\n' "$status"
        printf '  See the build output printed above for the compiler error.\n'
    fi
    # The reassuring half, and the reason there is no automatic retry: a
    # 30-minute silent re-queue is worse than a clear failure, because the
    # human cannot tell it from a hang. Let them decide.
    printf '  Nothing was shipped: no bundle assembled, no install, and the\n'
    printf '  running app and daemon were left exactly as they were.\n'
    printf '  Not retried automatically — a silent 30-minute re-queue would be\n'
    printf '  indistinguishable from a hang. Re-run when you want it.\n'
}

# Run the governed build for the worktree at $1, passing the remaining
# arguments through to `scripts/swift-safe build`. Prints the last few lines
# of the build output and returns scripts/swift-safe's real exit status.
#
# The build output goes to a temp file rather than through `| tail -3`
# because the pipeline is exactly the bug this function exists to prevent:
# a pipeline's exit status is the LAST command's, so `swift-safe … | tail -3`
# always reports 0, `set -e` never fires, and restart.sh happily ships
# whatever stale binaries were already in .build/debug. That is not
# hypothetical — a 1800s lock timeout (exit 75, nothing compiled) was read as
# a successful build and the app and daemon were relaunched machine-wide.
# scripts/swift-safe prints its numeric status on a final stderr line
# precisely so it survives a pipe; capture the real status anyway and do not
# "simplify" this back into a pipeline.
#
# The trimming itself is deliberate and must stay: full compiler output is
# thousands of lines and restart.sh is nearly always run by an agent, whose
# context window it would otherwise flood. swift-safe's final "exit status N"
# line is the last thing it writes, so the tail keeps it.
run_governed_build() {
    local repo_root="$1"
    shift
    local build_log status
    build_log="$(mktemp "${TMPDIR:-/tmp}/tbd-restart-build.XXXXXX")" || return 1

    status=0
    (cd "$repo_root" && scripts/swift-safe build "$@") > "$build_log" 2>&1 || status=$?

    tail -3 "$build_log"
    rm -f "$build_log"

    if ! build_status_permits_ship "$status"; then
        describe_build_failure "$status" >&2
        return "$status"
    fi
    return 0
}
