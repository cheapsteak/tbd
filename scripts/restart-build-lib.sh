#!/usr/bin/env bash
# Governed-build helpers for restart.sh. Safe to source: defines functions
# only, launches nothing, installs nothing.
#
# restart.sh's job after the build is destructive and machine-wide — it
# assembles a bundle, copies it over /Applications/TBD.app, and restarts the
# shared daemon. Everything it ships comes out of .build/<config>, so it may only
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

# MARK: - Inherited SDK overrides
#
# `tbd update` and `scripts/restart.sh` are often run from a terminal that is
# inside some other project's dev shell (a nix/direnv shell, say). Such a shell
# exports variables that redirect the C toolchain at its own SDK — SDKROOT,
# DEVELOPER_DIR, CPATH and friends. SwiftPM then compiles TBD's dependencies
# against that SDK, which lacks headers they need, and the build dies in a
# dependency with an error like "'sqlite3.h' file not found" that names none of
# the variables responsible.
#
# TBD is built with the system toolchain, so the build steps clear those
# variables in the subshell that runs the compiler. Only there: the caller's own
# environment, and everything the caller launches afterwards, is left alone.
#
# What is deliberately NOT cleared: a toolchain selection the user made on
# purpose — TBD_SWIFT_BIN, TOOLCHAINS, and an SDKROOT or DEVELOPER_DIR that
# points into an installed Xcode or the Command Line Tools. TBD_KEEP_BUILD_ENV=1
# turns the whole scrub off.

# Variables that redirect the compiler's SDK, headers or libraries. NIX_*
# compiler-wrapper variables are matched by prefix below.
SDK_OVERRIDE_VARS=(
    SDKROOT DEVELOPER_DIR
    CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH OBJCPLUS_INCLUDE_PATH
    LIBRARY_PATH IN_NIX_SHELL
)
SDK_OVERRIDE_NIX_PREFIXES=(
    NIX_CFLAGS NIX_LDFLAGS NIX_CC NIX_BINTOOLS NIX_HARDENING NIX_ENFORCE
    NIX_APPLE NIX_DONT NIX_IGNORE
)

# True when $1 is a path inside an installed Xcode or the Command Line Tools —
# an SDK selection a person makes on purpose, as opposed to a dev shell's.
sdk_path_is_apple_toolchain() {
    case "${1-}" in
        /Applications/Xcode*.app|/Applications/Xcode*.app/*) return 0 ;;
        /Library/Developer/CommandLineTools|/Library/Developer/CommandLineTools/*) return 0 ;;
    esac
    return 1
}

# Print, one per line, the names of the inherited variables the build would
# clear — only the ones actually set. Prints nothing under TBD_KEEP_BUILD_ENV=1.
sdk_override_names() {
    [ "${TBD_KEEP_BUILD_ENV-}" = "1" ] && return 0
    local name prefix value
    for name in "${SDK_OVERRIDE_VARS[@]}"; do
        [ -n "${!name+x}" ] || continue
        value="${!name}"
        case "$name" in
            SDKROOT|DEVELOPER_DIR)
                sdk_path_is_apple_toolchain "$value" && continue ;;
        esac
        printf '%s\n' "$name"
    done
    for prefix in "${SDK_OVERRIDE_NIX_PREFIXES[@]}"; do
        compgen -v "$prefix" || true
    done
}

# Unset every variable sdk_override_names reports. Call it inside the subshell
# that runs the compiler, never in the caller's own shell.
clear_sdk_overrides() {
    local name
    while IFS= read -r name; do
        [ -n "$name" ] && unset "$name"
    done < <(sdk_override_names)
    return 0
}

# One line saying what will be ignored, for a caller to print. Empty when
# nothing is set.
describe_sdk_overrides() {
    local names
    names="$(sdk_override_names | sort -u | paste -sd, - | sed 's/,/, /g')"
    [ -n "$names" ] || return 0
    printf 'ignoring inherited compiler-environment variables for the build (%s) — a dev shell such as nix/direnv sets these; set TBD_KEEP_BUILD_ENV=1 to keep them\n' "$names"
}

# Statuses that mean scripts/swift-safe never got the shared build slot: 75
# (EX_TEMPFAIL — the wait timed out or the requester went away) and 76 (the
# wait yielded its place in the queue). Both compiled nothing at all.
SWIFT_SAFE_SLOT_NOT_OBTAINED_STATUSES=(75 76)

# May restart.sh ship what is in .build/<config>, given the status of the build
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
# whatever stale binaries were already in .build/<config>. That is not
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

    # Say what the build ignores before it runs, so a failure that survives the
    # scrub is not read as "the shell's SDK was used".
    local sdk_note
    sdk_note="$(describe_sdk_overrides)"
    [ -z "$sdk_note" ] || printf 'note: %s\n' "$sdk_note" >&2

    status=0
    (clear_sdk_overrides; cd "$repo_root" && scripts/swift-safe build "$@") > "$build_log" 2>&1 || status=$?

    tail -3 "$build_log"
    rm -f "$build_log"

    if ! build_status_permits_ship "$status"; then
        describe_build_failure "$status" >&2
        return "$status"
    fi
    return 0
}
