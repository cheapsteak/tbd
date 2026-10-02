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
#
# Watching a build means the build cannot be in the foreground, and an
# asynchronous job is deaf to the one signal a human sends by hand. So the
# interrupt has to be caught and the tree signalled deliberately — see
# `terminate_build_tree`, whose comment carries the whole argument.

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
# points into an installed Xcode, the Command Line Tools or the active developer
# directory (see sdk_path_is_apple_toolchain). TBD_KEEP_BUILD_ENV=1
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

# True when $1 names one of the standard Apple toolchain locations: an Xcode
# under /Applications or the Command Line Tools. A pure string test.
sdk_path_has_apple_prefix() {
    case "${1-}" in
        /Applications/Xcode*.app|/Applications/Xcode*.app/*) return 0 ;;
        /Library/Developer/CommandLineTools|/Library/Developer/CommandLineTools/*) return 0 ;;
    esac
    return 1
}

# Print $1 with every symlink resolved, or nothing when it is not an existing
# directory. `cd -P` rather than `realpath`, which older macOS lacks.
sdk_resolve_dir() {
    [ -d "${1-}" ] || return 1
    (cd -P "$1" 2>/dev/null && pwd -P)
}

# Print the active developer directory, as `xcode-select -p` reports it, with
# symlinks resolved; nothing when xcode-select is missing or has no answer.
# DEVELOPER_DIR is removed from xcode-select's environment because xcode-select
# reports DEVELOPER_DIR back when it is set — which would make every inherited
# DEVELOPER_DIR, a dev shell's included, look like the user's own selection.
sdk_active_developer_dir() {
    command -v xcode-select >/dev/null 2>&1 || return 1
    local dir
    dir="$(env -u DEVELOPER_DIR xcode-select -p 2>/dev/null)" || return 1
    [ -n "$dir" ] || return 1
    sdk_resolve_dir "$dir"
}

# True when $1 is a path inside an installed Xcode or the Command Line Tools —
# an SDK selection a person makes on purpose, as opposed to a dev shell's. It
# qualifies when any of these holds:
#   - it lies under /Applications/Xcode*.app or /Library/Developer/CommandLineTools;
#   - it resolves, through symlinks, to a path under one of those;
#   - it resolves to a path under the active developer directory
#     (`xcode-select -p`), which covers an Xcode installed somewhere else.
# Only absolute paths qualify; an empty value never does.
sdk_path_is_apple_toolchain() {
    local path="${1-}" resolved active
    case "$path" in /*) ;; *) return 1 ;; esac
    sdk_path_has_apple_prefix "$path" && return 0
    resolved="$(sdk_resolve_dir "$path")" || resolved=""
    [ -n "$resolved" ] || return 1
    sdk_path_has_apple_prefix "$resolved" && return 0
    active="$(sdk_active_developer_dir)" || active=""
    [ -n "$active" ] || return 1
    case "$resolved" in
        "$active"|"$active"/*) return 0 ;;
    esac
    return 1
}

# Print, one per line, the names of the inherited variables the build would
# clear — only the ones actually set. Prints nothing under TBD_KEEP_BUILD_ENV=1.
sdk_override_names() {
    [ "${TBD_KEEP_BUILD_ENV-}" = "1" ] && return 0
    local name prefix value
    for name in "${SDK_OVERRIDE_VARS[@]}"; do
        # Set, even to the empty string, counts. Plain `eval` over a name from
        # the fixed list above rather than `${!name+x}`, so the test reads the
        # same in every bash, 3.2 included.
        eval "[ \"\${$name+x}\" = x ]" || continue
        eval "value=\"\${$name}\""
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

# How long the process-table snapshot may take before it is abandoned.
#
# This is the bound that keeps the watchdog from becoming the hang. The
# snapshot is taken from inside the loop that watches the build, and that loop
# must return for `run_governed_build` to reach the `wait` that collects the
# build's exit status at all. An unbounded `ps` that wedges rather than
# failing would therefore strand a build whose own status may already be a
# clean zero — a watchdog taking down the thing it was watching. The sibling
# probes in scripts/swift-safe are bounded for exactly this reason; so is
# this one.
#
# Five seconds because the snapshot is a diagnostic and the thing it describes
# has by then been silent for minutes: a probe worth waiting on is one that
# answers immediately, and one that has not answered in five seconds is not
# going to.
DEFAULT_PROCESS_PROBE_SECONDS=5

# How long a torn-down build tree is given to leave on SIGTERM before SIGKILL.
# Short on purpose: a human has pressed Ctrl-C and is waiting, and the only
# thing SIGTERM buys over SIGKILL is letting SwiftPM unlink its own partial
# products. That is worth half a second and not worth more.
BUILD_TEARDOWN_GRACE_SECONDS=0.5

# The status an interrupted build reports: 128 + SIGINT, which is what a shell
# reports for a command a signal ended. Non-zero, so restart.sh's own gate
# ships nothing — see `build_status_permits_ship`.
BUILD_INTERRUPTED_STATUS=130

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

process_probe_seconds() {
    positive_integer_setting "${TBD_RESTART_PROCESS_PROBE_SECONDS-}" "$DEFAULT_PROCESS_PROBE_SECONDS"
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

# A `ps` snapshot of the whole process table on stdout, or NOTHING and a
# non-zero status when it could not be taken within `process_probe_seconds`.
# The two outcomes are deliberately distinguishable: "the table says no
# process is running" and "the table could not be read" are opposite
# conclusions, and a diagnostic that confuses them points the wrong way.
#
# The bound is a background job and a poll, not `timeout(1)`: that binary is
# not present on every machine this runs on (a stock macOS has none), so
# reaching for it would leave the bound silently absent exactly where it is
# needed. Nothing here is more than bash plus `ps` itself.
#
# Every teardown step is unconditional-safe (`|| true`, `2>/dev/null`)
# because callers run under restart.sh's `set -e`: a failing `kill` on a
# process that just exited must not take the build down with it.
build_process_table() {
    local limit snapshot probe waited status=0
    limit="$(process_probe_seconds)"
    snapshot="$(mktemp "${TMPDIR:-/tmp}/tbd-ps-probe.XXXXXX")" || return 1

    ps -Ao pid=,ppid=,comm= > "$snapshot" 2>/dev/null &
    probe=$!
    # Tenths, so a probe that answers promptly — which is every healthy one —
    # is not billed a whole second by the polling itself.
    waited=0
    while kill -0 "$probe" 2>/dev/null && [ "$waited" -lt "$((limit * 10))" ]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    if kill -0 "$probe" 2>/dev/null; then
        # Abandoned. SIGTERM first, then SIGKILL, because a `ps` wedged in
        # the kernel may not take the first — and a probe that leaked a
        # process would be its own unreclaimed resource.
        kill "$probe" 2>/dev/null || true
        sleep 0.1
        kill -9 "$probe" 2>/dev/null || true
        wait "$probe" 2>/dev/null || true
        rm -f "$snapshot"
        return 1
    fi

    wait "$probe" || status=$?
    if [ "$status" = 0 ]; then
        cat "$snapshot"
    fi
    rm -f "$snapshot"
    return "$status"
}

# "<pid> <command>" for every live process below pid $1, itself excluded.
# One `ps` answers the whole walk; macOS has no /proc.
#
# Returns non-zero, having printed nothing, when the snapshot could not be
# taken — which a caller must report as "could not enumerate" rather than as
# an empty process tree. Empty output with a ZERO status is the other thing,
# and means the build really has no live children.
build_descendant_processes() {
    local root="$1" table
    table="$(build_process_table)" || return 1
    printf '%s\n' "$table" | awk -v root="$root" '
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
    local processes compilers listed enumerated=1
    processes="$(build_descendant_processes "$builder")" || enumerated=0

    # The probe gave up. Say only that, and in particular do NOT fall through
    # to the no-compiler branch: "no swift-frontend is running" and "I could
    # not look" are opposite conclusions, and a silent build is the one
    # moment where reporting the first for the second would send a human off
    # to kill a build that was compiling.
    if [ "$enumerated" = 0 ]; then
        printf 'restart.sh: no build output for %ss, and the process table could not be enumerated within %ss.\n' \
            "$silent_for" "$(process_probe_seconds)"
        printf '  Could not enumerate descendants, so nothing is known about what the build is doing.\n'
        printf '  Inspect the holder by hand: lsof %s\n' "$(swift_build_lock_path)"
        return 0
    fi

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

# Stop the build running as pid $1 and everything below it.
#
# WHY THIS IS NEEDED AT ALL. The build is an asynchronous job, and bash gives
# such a job an IGNORED SIGINT whenever job control is off — which it is in
# every script. SIG_IGN is inherited across both fork and exec, so
# scripts/swift-safe, SwiftPM and every compiler below them ignore SIGINT too.
# A terminal delivers Ctrl-C to the whole foreground process group, so the
# signal does reach the entire tree and is discarded by all of it: restart.sh
# exits and the compiler runs on, holding the machine-global build slot. That
# is the stuck-lock incident this file exists to diagnose, produced by the
# diagnostic itself. (scripts/swift-safe's own requester-death check does not
# cover it: that check only runs while the wrapper WAITS for the slot, and the
# build being abandoned here already has it.)
#
# THE PROCESS GROUP IS THE MECHANISM, and that is why `run_governed_build`
# launches the build under job control: the job is then a process-group leader
# whose group id IS its own pid, so one `kill -TERM -<pid>` reaches every
# process below it. Group membership is inherited and survives re-parenting, so
# it covers descendants that have already orphaned to launchd — and it needs no
# process table at all, which is the point: the machine this runs on is the one
# where `ps` is slowest, and a teardown that could only enumerate what `ps`
# would tell it would fail exactly when it is needed. A pid-directed kill of
# the root alone is not a substitute: its children simply re-parent and carry
# on holding the slot.
#
# Signalling `-$builder` is safe whether or not job control took. When it did,
# that is the build's group; when it did not, the build shares the caller's
# group and no group with that id exists at all, so the kill is an ESRCH no-op
# rather than a signal to the shell doing the killing. Measured in bash 3.2 and
# 5.2 alike. The pid and walk legs below are what carry the teardown in that
# case, and they also cover anything that left the group by starting a session
# of its own.
#
# The walk is therefore a supplement, not the mechanism — but its ORDER still
# matters: descendants are enumerated BEFORE anything is signalled, because a
# walk rooted at a dead root reports an empty tree. It is repeated after the
# grace period for anything forked while the first round was in flight.
#
# SIGTERM THEN SIGKILL, AND NEVER SIGINT. SIGINT is the one signal this tree
# has been made deaf to, so sending it would be a teardown that tears nothing
# down. SIGTERM first so SwiftPM can unlink its partial products; SIGKILL
# after, because nothing here is obliged to honour SIGTERM.
#
# Always returns 0. Callers run under restart.sh's `set -e`, and a kill that
# lost a race with a process leaving on its own must not become a failure.
terminate_build_tree() {
    local builder="$1" signal victims pid
    victims="$(build_descendant_processes "$builder" 2>/dev/null | awk '{print $1}')" \
        || victims=""
    for signal in TERM KILL; do
        kill -"$signal" "-$builder" 2>/dev/null || true
        kill -"$signal" "$builder" 2>/dev/null || true
        for pid in $victims; do
            kill -"$signal" "$pid" 2>/dev/null || true
        done
        [ "$signal" = TERM ] || break
        sleep "$BUILD_TEARDOWN_GRACE_SECONDS"
        victims="$victims $(build_descendant_processes "$builder" 2>/dev/null \
            | awk '{print $1}')"
    done
    # The job is ours, so collect it: an unreaped child is the smallest
    # unreclaimed resource there is, and this path exists to leave none.
    wait "$builder" 2>/dev/null || true
    return 0
}

# Handle an interrupt that arrived while the build running as pid $1 was being
# watched, with its output log at $2.
#
# Exits rather than returning: returning would let the watcher loop resume and
# go on waiting for a build that is already gone.
interrupt_governed_build() {
    local builder="$1" build_log="$2"
    # Disarmed first, so a second Ctrl-C arriving while the teardown runs ends
    # restart.sh outright instead of re-entering this.
    trap - INT TERM HUP
    printf 'restart.sh: interrupted — stopping the build so it cannot go on holding the shared build slot.\n' >&2
    terminate_build_tree "$builder"
    rm -f "$build_log"
    exit "$BUILD_INTERRUPTED_STATUS"
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
# A line that arrives in two writes is rejoined rather than lost. `read`
# consumes a newline-less tail and hands it back through its variable while
# reporting failure, so letting that failure drop the variable throws the bytes
# away: the second write would then arrive as a bare remainder with no
# `swift-safe:` on it, match nothing, and never be streamed — and the fragment
# would not count as output either, which lets the silence watchdog call a
# build stalled in the middle of writing. swift-safe writes whole lines, so
# this is rare rather than theoretical; it costs one variable.
#
# The silence deadline is armed a second beyond the bound because `date +%s`
# truncates: two readings a hair apart can straddle a second boundary and
# differ by one, so arming at exactly `now + silence` lets a report fire after
# as little as no time at all. The deadline is therefore [silence, silence+1),
# rounded the safe way — a build is never called silent before it has been.
# (The elapsed figure the report prints comes from the same truncated clock
# and may understate by under a second, which no reader acts on.)
#
# Everything that is not a `swift-safe:` line stays in the file for the trim —
# streaming raw compiler output would flood the agent context `run_governed_build`
# exists to protect. Always returns 0: under restart.sh's `set -e` a watcher
# that failed must not take the build down with it.
follow_build_progress() {
    local build_log="$1" builder="$2"
    local poll silence line alive read_any now last_output_at next_report pending
    pending=""
    poll="$(build_poll_seconds)"
    silence="$(build_silence_seconds)"
    now="$(date +%s)"
    last_output_at="$now"
    next_report=$((now + silence + 1))

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
            # Rejoined with whatever the previous pass could not finish; empty
            # in the ordinary case of a whole line arriving at once.
            line="$pending$line"
            pending=""
            case "$line" in
                "$SWIFT_SAFE_PROGRESS_PREFIX"*) printf '%s\n' "$line" >&2 ;;
            esac
        done
        # A newline-less tail is CONSUMED by the `read` that failed on it and
        # left in the variable, so dropping it here loses those bytes for good:
        # a `swift-safe:` line split across two writes would arrive next pass as
        # its own second half, no longer match the prefix, and never be streamed.
        # Carry it instead. It also counts as output — a build caught mid-write
        # is not a silent one, and leaving `read_any` at 0 for it would let the
        # watchdog call a writing build stalled.
        #
        # APPENDED, not assigned. A line can arrive in more than two writes, and
        # a pass that reads only a fragment never enters the loop above that
        # clears `pending` — so assigning here would drop every piece but the
        # last and lose the prefix with the first. The loop above is the only
        # thing that clears the carry, and it does so exactly when it has
        # consumed it.
        if [ -n "$line" ]; then
            pending="$pending$line"
            read_any=1
        fi
        [ "$alive" = 1 ] || break
        now="$(date +%s)"
        if [ "$read_any" = 1 ]; then
            last_output_at="$now"
            next_report=$((now + silence + 1))
        elif [ "$now" -ge "$next_report" ]; then
            describe_silent_build "$builder" "$((now - last_output_at))" >&2
            next_report=$((now + silence + 1))
        fi
        sleep "$poll"
    done
    # The only way to arrive here holding anything is a writer that died
    # mid-line. Print it rather than drop it: half a progress line still says
    # more than nothing, and the build is over, so nothing is coming to
    # complete it.
    case "$pending" in
        "$SWIFT_SAFE_PROGRESS_PREFIX"*) printf '%s\n' "$pending" >&2 ;;
    esac
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
#
# An interrupt arriving while the build is watched is caught and the build torn
# down (`interrupt_governed_build`). The caller's own handlers for those signals
# are saved and put back, so a caller that installed its own cleanup still has
# it once the build is over.
run_governed_build() {
    local repo_root="$1"
    shift
    local build_log status builder saved_traps
    build_log="$(mktemp "${TMPDIR:-/tmp}/tbd-restart-build.XXXXXX")" || return 1

    # Say what the build ignores before it runs, so a failure that survives the
    # scrub is not read as "the shell's SDK was used".
    local sdk_note
    sdk_note="$(describe_sdk_overrides)"
    [ -z "$sdk_note" ] || printf 'note: %s\n' "$sdk_note" >&2

    status=0
    # Job control, for the length of the launch and nothing else. With it on,
    # bash puts the asynchronous job in a process group of its own whose id is
    # the job's pid, which is what lets `terminate_build_tree` reach the whole
    # tree with one signal and no process table. Restored immediately, and only
    # to what the caller had: it is wanted for the `&` below and for nothing
    # after it.
    #
    # The cost, stated because it is a real change: the build is no longer in
    # the terminal's foreground process group, so a Ctrl-C or a hangup no longer
    # reaches the compiler directly — the trap below is what ends it. That is
    # the trade this makes deliberately, since the signal that did reach the
    # tree was SIGINT, which the tree ignores. A `kill -9` aimed at restart.sh's
    # own process group no longer reaches the build either; aim it at the
    # build's own pid, which `ps` shows as its group leader.
    local had_monitor=0
    case "$-" in *m*) had_monitor=1 ;; esac
    set -m
    (clear_sdk_overrides; cd "$repo_root" && scripts/swift-safe build "$@") > "$build_log" 2>&1 &
    builder=$!
    [ "$had_monitor" = 1 ] || set +m
    # Saved before arming, and restored below, so this borrows the three
    # signals for the length of the build rather than taking them from a caller
    # that had its own use for them. An empty save means the caller had none,
    # and `trap -` then returns them to their default.
    saved_traps="$(trap -p INT TERM HUP)"
    # Single-quoted: the handler must read `builder` and `build_log` when the
    # signal arrives, not freeze whatever they held at arming time.
    trap 'interrupt_governed_build "$builder" "$build_log"' INT TERM HUP
    follow_build_progress "$build_log" "$builder"
    wait "$builder" || status=$?
    trap - INT TERM HUP
    [ -z "$saved_traps" ] || eval "$saved_traps"

    tail -3 "$build_log"
    rm -f "$build_log"

    if ! build_status_permits_ship "$status"; then
        describe_build_failure "$status" >&2
        return "$status"
    fi
    return 0
}
