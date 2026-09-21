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
#
# A build that has not finished yet is the other thing this file has to
# report. `Building...` followed by nothing tells a human neither whether the
# build is queued, compiling, or wedged, nor what to look at. So the build is
# watched while it runs: scripts/swift-safe's own `swift-safe:` lines reach
# the terminal as they are written, and a build that emits nothing at all for
# several minutes gets its live processes described. Compiler output stays
# buffered and trimmed — see `run_governed_build`.

# Statuses that mean scripts/swift-safe never got the shared build slot: 75
# (EX_TEMPFAIL — the wait timed out or the requester went away) and 76 (the
# wait yielded its place in the queue). Both compiled nothing at all.
SWIFT_SAFE_SLOT_NOT_OBTAINED_STATUSES=(75 76)

# Every line scripts/swift-safe writes about itself carries this prefix, and
# that is what makes a build's progress separable from its compiler output:
# these lines go to the terminal the moment they are written, everything else
# stays buffered and trimmed. See `run_governed_build`.
SWIFT_SAFE_PROGRESS_PREFIX='swift-safe: '

# How often the build log is drained while the build runs. A second is far
# below the cadence of anything being watched for (a 60s wait heartbeat, a
# multi-minute silence) and costs one `date` per second next to a compiler.
DEFAULT_BUILD_POLL_SECONDS=1

# How long the build may produce NO output at all before the silence itself is
# reported. Deliberately well above scripts/swift-safe's 60s wait heartbeat: a
# build still QUEUED for the shared slot says so every minute, so silence past
# this bound means the slot is held and the holder is doing nothing visible.
DEFAULT_BUILD_SILENCE_SECONDS=300

# The only process whose presence proves a compiler is running. `swift-build`
# and `swift-driver` sit at 0% CPU by design while they wait on their jobs, so
# a process list without this in it is a build that is not compiling — the
# discriminator this repo already uses to judge build liveness by hand.
COMPILER_LEAF_PROCESS=swift-frontend

# At most this many of the build's live processes are named in a report. A
# stalled build has a handful; a compiling one can have dozens, and the point
# is a human-readable line, not a process listing.
MAX_REPORTED_BUILD_PROCESSES=6

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

# A positive integer setting, or its default when the environment's value is
# missing or not one. A typo in a diagnostic knob must never fail a build.
positive_integer_setting() {
    local value="${1-}" fallback="$2"
    case "$value" in
        "" | *[!0-9]*) printf '%s' "$fallback" ;;
        0) printf '%s' "$fallback" ;;
        *) printf '%s' "$value" ;;
    esac
}

# The poll interval is only ever handed to `sleep`, so a fraction is allowed
# here where the silence bound (which is compared with integer arithmetic) is
# not. Anything that is not a positive number — including all-zero, which
# would spin a core — falls back to the default.
build_poll_seconds() {
    local value="${TBD_RESTART_BUILD_POLL_SECONDS-}"
    case "$value" in
        *[!0-9.]* | *.*.*) ;;
        *[1-9]*) printf '%s' "$value"; return 0 ;;
        *) ;;
    esac
    printf '%s' "$DEFAULT_BUILD_POLL_SECONDS"
}

build_silence_seconds() {
    positive_integer_setting "${TBD_RESTART_BUILD_SILENCE_SECONDS-}" "$DEFAULT_BUILD_SILENCE_SECONDS"
}

# Where scripts/swift-safe's machine-global lock lives, for a message that
# tells a human what to inspect. Mirrors the wrapper's own resolution order.
swift_build_lock_path() {
    if [ -n "${TBD_SWIFT_LOCK_PATH-}" ]; then
        printf '%s' "$TBD_SWIFT_LOCK_PATH"
    else
        printf '%s/runtime/swift-build.lock' "${TBD_HOME:-$HOME/tbd}"
    fi
}

# "<pid> <command>" for every live process below pid $1, itself excluded.
# One `ps` answers the whole walk; macOS has no /proc. Best effort — a `ps`
# that fails prints nothing, and the caller says only what it can see.
build_descendant_processes() {
    local root="$1"
    ps -Ao pid=,ppid=,comm= 2>/dev/null | awk -v root="$root" '
        {
            pid = $1; parent[pid] = $2
            $1 = ""; $2 = ""; sub(/^ +/, "")
            comm[pid] = $0
            pids[count++] = pid
        }
        END {
            descendant[root] = 1
            # Repeat until no new descendant appears: `ps` output is in no
            # useful order, so one pass down the list would miss a child
            # listed before its parent.
            changed = 1
            while (changed) {
                changed = 0
                for (i = 0; i < count; i++) {
                    pid = pids[i]
                    if (!(pid in descendant) && (parent[pid] in descendant)) {
                        descendant[pid] = 1
                        changed = 1
                    }
                }
            }
            for (i = 0; i < count; i++) {
                pid = pids[i]
                if (pid != root && (pid in descendant)) print pid, comm[pid]
            }
        }'
}

# Say what a build that has produced no output for $2 seconds is actually
# doing, given the pid $1 it was launched as. Printed on stdout; callers
# redirect it to stderr.
#
# THE QUESTION THIS ANSWERS. A build that cannot get the shared slot says so
# every 60s, so scripts/swift-safe already covers "queued behind someone". The
# uncovered case is a build that HOLDS the slot and makes no progress — the
# shape of a real incident, where Gatekeeper assessment was pegged and every
# freshly linked binary hung at `_dyld_start` before executing an instruction.
# SwiftPM compiles Package.swift into a manifest binary and runs it before any
# real work, so the build sat at 0% CPU with no compiler running at all, for
# days, holding the machine-global lock. Nothing in TBD's tooling said so.
describe_silent_build() {
    local builder="$1" silent_for="$2"
    local processes compilers listed
    processes="$(build_descendant_processes "$builder")"
    compilers="$(printf '%s\n' "$processes" | grep -c -- "$COMPILER_LEAF_PROCESS")" \
        || compilers=0

    if [ "$compilers" -gt 0 ]; then
        printf 'restart.sh: no build output for %ss, but %s %s %s running — the compiler is working.\n' \
            "$silent_for" "$compilers" "$COMPILER_LEAF_PROCESS" \
            "$([ "$compilers" -eq 1 ] && echo "process is" || echo "processes are")"
        return 0
    fi

    printf 'restart.sh: no build output for %ss, and NO %s process is running.\n' \
        "$silent_for" "$COMPILER_LEAF_PROCESS"
    if [ -n "$processes" ]; then
        listed="$(printf '%s\n' "$processes" | head -n "$MAX_REPORTED_BUILD_PROCESSES" | tr '\n' ';')"
        printf '  Live processes under the build: %s\n' "$listed"
    else
        printf '  The build has no live child processes at all.\n'
    fi
    printf '  swift-build and swift-driver idle at 0%% CPU by design, so only %s leaves prove a compiler is running.\n' \
        "$COMPILER_LEAF_PROCESS"
    printf '  A build still WAITING for the shared slot heartbeats every 60s, so this silence means it HOLDS the slot.\n'
    printf '  Inspect the holder: lsof %s\n' "$(swift_build_lock_path)"
    return 0
}

# Watch the build log at $1 while the build running as pid $2 lives.
#
# Two jobs, one loop, and both are about a build that is not finishing:
#  - scripts/swift-safe's own lines (its wait announcement and its 60s
#    heartbeat) reach the terminal AS THEY ARE WRITTEN. They used to land in
#    a file nobody saw until the build ended, which is when they stop being
#    worth anything: the wrapper's comments say the heartbeat exists so a wait
#    is not silent for the full 30-minute timeout, and buffering it made it
#    silent anyway.
#  - output of ANY kind resets a silence timer, and silence past the bound is
#    reported by `describe_silent_build`.
#
# Everything that is not a `swift-safe:` line stays in the file for the trim —
# streaming raw compiler output would flood the agent context `run_governed_build`
# exists to protect. Always returns 0: under restart.sh's `set -e` a watcher
# that failed must not take the build down with it.
follow_build_progress() {
    local build_log="$1" builder="$2"
    local poll silence line alive read_any now last_output_at next_report
    poll="$(build_poll_seconds)"
    silence="$(build_silence_seconds)"
    now="$(date +%s)"
    last_output_at="$now"
    next_report=$((now + silence))

    exec 3< "$build_log"
    while :; do
        # Liveness FIRST, so the drain that follows a dead builder is the last
        # one and sees the whole file: checking afterwards could miss lines
        # written between the drain and the check.
        #
        # `kill -0` answers this only because bash reaps a background job as
        # soon as SIGCHLD reaches it — an unreaped child is a zombie, and a
        # zombie still answers `kill -0`. The `wait` that collects the status
        # runs after this loop, so the reaping this depends on is the shell's
        # own, not ours.
        alive=0
        kill -0 "$builder" 2>/dev/null && alive=1
        read_any=0
        # `read` returns non-zero at EOF but leaves the offset where it is, so
        # the next pass resumes from the same place.
        while IFS= read -r line <&3; do
            read_any=1
            case "$line" in
                "$SWIFT_SAFE_PROGRESS_PREFIX"*) printf '%s\n' "$line" >&2 ;;
            esac
        done
        [ "$alive" = 1 ] || break
        now="$(date +%s)"
        if [ "$read_any" = 1 ]; then
            last_output_at="$now"
            next_report=$((now + silence))
        elif [ "$now" -ge "$next_report" ]; then
            describe_silent_build "$builder" "$((now - last_output_at))" >&2
            next_report=$((now + silence))
        fi
        sleep "$poll"
    done
    exec 3<&-
    return 0
}

# Run the governed build for the worktree at $1, passing the remaining
# arguments through to `scripts/swift-safe build`. Streams the wrapper's own
# progress lines live, prints the last few lines of the build output, and
# returns scripts/swift-safe's real exit status.
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
# The build therefore runs in the BACKGROUND and its status comes from `wait`,
# which reports that job and no other command. A foreground build could not be
# watched while it ran, and a pipeline into the watcher would put the status
# back at the mercy of the last command in the pipe.
#
# The trimming itself is deliberate and must stay: full compiler output is
# thousands of lines and restart.sh is nearly always run by an agent, whose
# context window it would otherwise flood. swift-safe's final "exit status N"
# line is the last thing it writes, so the tail keeps it. A `swift-safe:` line
# near the end is therefore both streamed and trimmed; the duplicate is worth
# less than either copy would be alone.
run_governed_build() {
    local repo_root="$1"
    shift
    local build_log status builder
    build_log="$(mktemp "${TMPDIR:-/tmp}/tbd-restart-build.XXXXXX")" || return 1

    status=0
    (cd "$repo_root" && scripts/swift-safe build "$@") > "$build_log" 2>&1 &
    builder=$!
    follow_build_progress "$build_log" "$builder"
    wait "$builder" || status=$?

    tail -3 "$build_log"
    rm -f "$build_log"

    if ! build_status_permits_ship "$status"; then
        describe_build_failure "$status" >&2
        return "$status"
    fi
    return 0
}
