#!/usr/bin/env bash
# TBD update script — move the whole installation to the latest main.
#
# `tbd update` is a thin wrapper that execs this file out of the running
# daemon's source worktree. The procedure itself lives here, in user-land,
# because the policy in it is the part most likely to want changing: how many
# sessions to wake at once, whether to restart the app, which configuration to
# build. See docs/updating.md for the operator's view and
# docs/specs/2026-09-04-automatic-version-updates-design.md for why.
#
# Usage:
#   scripts/update.sh              # build the latest main and hand the fleet over
#   scripts/update.sh --check      # report how far behind the daemon is, then stop
#   scripts/update.sh --dry-run    # fetch and build, install nothing
#   scripts/update.sh --debug      # build the debug configuration
#   scripts/update.sh --no-app     # leave the running app alone
#   scripts/update.sh --no-wake    # install, but wake no parked session
#   scripts/update.sh --wake-only  # wake recovery-parked sessions, update nothing
#   scripts/update.sh --auto       # non-interactive; what the daemon launches
#   scripts/update.sh --remote <url>  # fetch from this URL instead of the default
#   scripts/update.sh --from-release  # install CI's published build instead of compiling

# MARK: - Constants
#
# The theories of this procedure, all in one place. An operator changes any of
# them by editing this file; none needs a rebuild, a migration, or a setting.

# How many `claude --resume` respawns may start at once, and how long to leave
# between batches. Three matches the app's wakeAllBatchSize. N simultaneous
# respawns have taken this machine down twice (#284, #367), which is the whole
# reason the wake is paced rather than a loop.
WAKE_CONCURRENCY=3
WAKE_STAGGER_SECONDS=2

# Where the update clone, the log and the lock live. A dedicated clone, not a
# worktree of anyone's checkout: it must not appear in a `git worktree list`,
# must not be reaped by scripts/reclaim-build.sh, and must be safe to
# `checkout --detach` at any moment.
UPDATE_HOME="${TBD_HOME:-$HOME/tbd}/updates"

# Release, because this is the installation an operator lives in rather than a
# dev loop. `--debug` overrides it.
BUILD_CONFIG=release

# How long the handover gets, in seconds: for the predecessor daemon to exit
# and the successor to report itself, one budget across both. The successor
# gives its predecessor 35 seconds at most before it gives up, and a cold
# start behind a release build has taken tens of seconds; two minutes is
# generously past the two together and still bounded.
HANDOVER_TIMEOUT=120

# How long a successor that has to be stopped gets to exit on SIGTERM before
# it is killed, in seconds. It only runs on the failure path, so it is short:
# the process being stopped has already missed a two-minute deadline.
HANDOVER_STOP_GRACE=5

# How long the app gets to exit on SIGTERM before it is killed, in seconds.
# The app is a viewer that holds no session, so it has nothing to finish; the
# grace only spares it a SIGKILL while it tears down its windows.
APP_STOP_GRACE=5

# Where the new binaries come from. `build` compiles them here, as every update
# always has. `release` downloads the build the release workflow published for
# a commit on main, verifies it, and installs that instead, so the update
# spends no local CPU on the compile. Shipped as `build`: installing binaries
# this machine did not compile replaces a load-bearing path, so it soaks
# opt-in first. Graduation is flipping this constant. An operator opts in
# without editing it — the update clone is checked out afresh by every update,
# so an edit here would not survive — with, in order of precedence:
#   --from-release                          this run only
#   TBD_UPDATE_SOURCE=release               this environment
#   echo release > ~/tbd/updates/update-source   every run, `auto` included
# See docs/specs/2026-09-23-release-pipeline-design.md.
UPDATE_SOURCE_DEFAULT=build

# The rolling prerelease the release workflow publishes to. Its tag is moved to
# each newly published commit, so it doubles as the ref the daemon's update
# check compares against while the source is `release`.
RELEASE_TAG=main-builds

# How many commits back along main's first-parent history to look for a
# published build when the head has none yet — a push whose build is still
# running, or one CI cancelled because a newer push superseded it. It must
# stay below the number of commits the release keeps assets for (RELEASE_KEEP,
# 20, in scripts/ci/publish-release.sh), so every commit the walk can reach
# still has its asset. At roughly 140 pushes to main a month, 10 commits is
# about two days of main; a machine further behind than that is better served
# by a local build of the head than by an older binary.
# shellcheck disable=SC2034 # read by scripts/update-release-lib.sh
RELEASE_WALKBACK=10

# The workflow a verified attestation must name as its signer.
# shellcheck disable=SC2034 # read by scripts/update-release-lib.sh
RELEASE_WORKFLOW_PATH=.github/workflows/release.yml

# MARK: - Derived paths

UPDATE_SRC="$UPDATE_HOME/src"
UPDATE_LOG="$UPDATE_HOME/update.log"
# The full compiler output of the latest run's builds, overwritten per run.
# update.log carries only the first errors and a pointer here.
UPDATE_BUILD_LOG="$UPDATE_HOME/build.log"
UPDATE_LOCK="$UPDATE_HOME/update.lock"
TBD_HOME_DIR="${TBD_HOME:-$HOME/tbd}"
DAEMON_PID_FILE="$TBD_HOME_DIR/tbdd.pid"
DAEMON_LOG="/tmp/tbdd.log"
APP_LOG="/tmp/tbdapp.log"
INSTALLED_BUNDLE="/Applications/TBD.app"
PREVIOUS_BUNDLE="$UPDATE_HOME/previous/TBD.app"
CLI_INSTALL_PATH="$HOME/.local/bin/tbd"
PREBUILT_HOME="$UPDATE_HOME/prebuilt"
UPDATE_SOURCE_FILE="$UPDATE_HOME/update-source"
# The ref the daemon's update check compares against. Written by this script
# from the resolved update source: present and naming the release tag while
# the source is `release`, absent (the daemon then reads main) otherwise.
CHECK_REF_FILE="$UPDATE_HOME/check-ref"

UPDATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# MARK: - Options (set by parse_args)

OPT_CHECK=false
OPT_DRY_RUN=false
OPT_DEBUG=false
OPT_NO_APP=false
OPT_NO_WAKE=false
OPT_WAKE_ONLY=false
OPT_AUTO=false
OPT_REMOTE=""
OPT_FROM_RELEASE=false

usage() {
    cat << 'EOF'
Usage: tbd update [options]

Builds the latest main out of place and hands the running installation over to
it without killing live sessions. Sessions the new daemon's startup reconcile
parks anyway are woken afterwards, a few at a time.

Options:
  --check          Report the running daemon's commit against the latest main
                   and exit. Changes nothing.
  --dry-run        Fetch and build, then stop. Installs nothing, hands nothing
                   over, and leaves the running installation untouched.
  --debug          Build the debug configuration instead of release.
  --no-app         Leave the running TBDApp alone: it is neither stopped for
                   the handover nor restarted. The daemon still hands over.
  --no-wake        Do not wake sessions the new daemon parked.
  --wake-only      Wake recovery-parked sessions against the daemon that is
                   already running. Builds and installs nothing.
  --auto           Non-interactive. Logs to the update log only, and refuses
                   to run while another update holds the lock.
  --from-release   Install the build CI published for the newest commit on
                   main that has one, verified, instead of compiling. Falls
                   back to a local build when none is published.
  --remote <url>   Fetch from this URL instead of the daemon worktree's
                   upstream (else origin) remote.
  --help           Show this message.

Log:   ~/tbd/updates/update.log
Clone: ~/tbd/updates/src
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) OPT_CHECK=true ;;
            --dry-run) OPT_DRY_RUN=true ;;
            --debug) OPT_DEBUG=true ;;
            --no-app) OPT_NO_APP=true ;;
            --no-wake) OPT_NO_WAKE=true ;;
            --wake-only) OPT_WAKE_ONLY=true ;;
            --auto) OPT_AUTO=true ;;
            --remote)
                shift
                OPT_REMOTE="${1-}"
                if [ -z "$OPT_REMOTE" ]; then
                    echo "error: --remote needs a URL" >&2
                    return 2
                fi
                ;;
            --remote=*) OPT_REMOTE="${1#--remote=}" ;;
            --from-release) OPT_FROM_RELEASE=true ;;
            --help|-h) usage; return 10 ;;
            *)
                echo "error: unknown option $1" >&2
                usage >&2
                return 2
                ;;
        esac
        shift
    done

    if [ "$OPT_DEBUG" = true ]; then
        BUILD_CONFIG=debug
    fi
    return 0
}

# MARK: - Logging

# Every step is timestamped into the update log. Under --auto the daemon has
# already pointed our stdout at that same file, so printing as well would
# double every line.
log() {
    local ts line
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line="[$ts] $*"
    mkdir -p "$UPDATE_HOME" 2>/dev/null || true
    printf '%s\n' "$line" >> "$UPDATE_LOG" 2>/dev/null || true
    if [ "$OPT_AUTO" = false ]; then
        printf '%s\n' "$line"
    fi
}

# A failure is a log line plus a non-zero status. Named log_error rather than
# `fail` so a test harness that sources this file can keep its own assertion
# helpers without shadowing it.
#
# Nothing is written to stderr under --auto: the daemon points our stdout and
# stderr at the same log file `log` appends to, so a second copy through that
# inherited descriptor would duplicate the line, and a descriptor opened
# without O_APPEND writes at its own offset rather than the file's end.
log_error() {
    log "ERROR: $*"
    return 1
}

# MARK: - Lock

# True when the lock file exists and names a process that is still running. A
# lock left by a crashed run names a pid that is gone and is taken over.
lock_is_live() {
    local lock_file="${1-}"
    local pid
    [ -f "$lock_file" ] || return 1
    pid="$(lock_holder_pid "$lock_file")"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

# The pid named in a lock file, or nothing.
lock_holder_pid() {
    head -1 "${1-}" 2>/dev/null | tr -dc '0-9'
}

# The create IS the decision. Under `set -C` bash opens the redirection target
# with O_EXCL, so of any number of runs starting at once — a manual
# `tbd update` racing the daemon's auto-launch — exactly one create succeeds
# and every loser sees a file that is already there. A check followed by a
# separate write would let two callers both pass the check and the second
# clobber the first, and both would then build and install against the same
# clone.
#
# True when a takeover mutex directory is old enough to be suspect and its
# creator is gone. Never true for a young directory, and never true while the
# pid in `owner` is still running.
takeover_mutex_is_abandoned() {
    local dir="${1-}" owner
    [ -d "$dir" ] || return 1
    [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
    owner="$(head -1 "$dir/owner" 2>/dev/null | tr -dc '0-9')"
    [ -z "$owner" ] && return 0
    ! kill -0 "$owner" 2>/dev/null
}

# Taking over a stale lock has two requirements the create alone cannot meet,
# and each gets its own atomic primitive.
#
# The lock path must never be vacant. If a takeover removed the lock, or moved
# it aside and put it back, a third run's noclobber create could land in that
# gap and believe it holds an exclusive lock while somebody else believes the
# same. So the replacement is a rename over the path: the temp file is written
# beside the lock as `<lock>.new.<pid>` and `mv`d onto it, and rename(2)
# replaces the entry atomically — every create attempt in flight either sees
# the old file or the new one, and none of them ever sees nothing there.
#
# Only one run at a time may replace it. Deciding a lock is stale and then
# replacing it is a read followed by a write, and two runs can both read the
# same dead pid. The takeover critical section is guarded by `mkdir` on
# `<lock>.takeover`, which is atomic on every filesystem worth having: whoever
# creates the directory owns the right to replace the lock, and re-reads it
# inside the section, so a lock that turned live in the meantime is refused
# rather than stolen. Runs that lose the mkdir go back to the create.
#
# An abandoned mutex must not deadlock every later run, and a live one must
# never be taken from under its holder. The directory records its creator's
# pid in `owner` the instant it exists, and is reclaimed only when it is older
# than a minute AND that pid is gone (or was never written, which is a run
# that died between the mkdir and the write). The critical section is a read
# and a rename, so a minute is generous — but a holder stalled inside it by a
# suspended machine or a hung filesystem still owns the section for as long
# as its process lives.
# The create itself IS the decision for the ordinary path. Under `set -C` bash
# opens the redirection target with O_EXCL, so of any number of runs starting
# at once — a manual `tbd update` racing the daemon's auto-launch — exactly one
# create succeeds and every loser sees a file that is already there. A check
# followed by a separate write would let two callers both pass the check and
# the second clobber the first, and both would then build and install against
# the same clone.
#
# A lock naming THIS process is one we already hold. `exec` keeps the pid, so
# the self-re-exec in maybe_reexec arrives here still holding it; the
# alternative — releasing before the exec — opens a window in which a second
# update can start against the same clone.
acquire_lock() {
    local holder attempt takeover_dir tmp_lock
    mkdir -p "$UPDATE_HOME" || return 1

    takeover_dir="$UPDATE_LOCK.takeover"
    attempt=0
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))

        if ( set -C; printf '%s\n' "$$" > "$UPDATE_LOCK" ) 2>/dev/null; then
            UPDATE_LOCK_HELD=true
            return 0
        fi

        holder="$(lock_holder_pid "$UPDATE_LOCK")"
        if [ "$holder" = "$$" ]; then
            UPDATE_LOCK_HELD=true
            return 0
        fi
        if lock_is_live "$UPDATE_LOCK"; then
            log_error "another update is already running (pid $holder). Its log is $UPDATE_LOG"
            return 1
        fi

        # Stale: a dead pid, or garbage with no pid in it at all. Reclaim a
        # mutex left behind by a run that died mid-takeover: old by `find
        # -mmin` (the portable age test; BSD and GNU `stat` disagree on their
        # flags) and with a creator that is no longer running.
        if takeover_mutex_is_abandoned "$takeover_dir"; then
            rm -rf "$takeover_dir" 2>/dev/null || true
        fi
        # Losing the mutex means another run is replacing the lock right now.
        # Give it a moment and go back to the create, which is what decides.
        if ! mkdir "$takeover_dir" 2>/dev/null; then
            sleep 0.1
            continue
        fi
        printf '%s\n' "$$" > "$takeover_dir/owner" 2>/dev/null || true

        # Inside the critical section. Re-read: the lock we judged stale may
        # have been replaced by the run that held the mutex before us.
        holder="$(lock_holder_pid "$UPDATE_LOCK")"
        if [ ! -f "$UPDATE_LOCK" ]; then
            # Released rather than replaced. The create is the way in.
            rm -rf "$takeover_dir" 2>/dev/null || true
            continue
        fi
        if [ "$holder" = "$$" ]; then
            rm -rf "$takeover_dir" 2>/dev/null || true
            UPDATE_LOCK_HELD=true
            return 0
        fi
        if lock_is_live "$UPDATE_LOCK"; then
            rm -rf "$takeover_dir" 2>/dev/null || true
            log_error "another update is already running (pid $holder). Its log is $UPDATE_LOG"
            return 1
        fi

        # Only the mutex holder writes a `.new.<pid>` file, so while we hold
        # it every such file is a stray from a run killed between its write
        # and its rename. Sweep them here rather than name a reconciler for a
        # file that only ever exists inside this critical section.
        for tmp_lock in "$UPDATE_LOCK".new.*; do
            [ -e "$tmp_lock" ] && rm -f "$tmp_lock"
        done
        tmp_lock="$UPDATE_LOCK.new.$$"
        if ! printf '%s\n' "$$" > "$tmp_lock" 2>/dev/null ||
            ! mv "$tmp_lock" "$UPDATE_LOCK" 2>/dev/null; then
            rm -f "$tmp_lock"
            rm -rf "$takeover_dir" 2>/dev/null || true
            continue
        fi
        rm -rf "$takeover_dir" 2>/dev/null || true
        UPDATE_LOCK_HELD=true
        return 0
    done

    log_error "could not take the update lock at $UPDATE_LOCK"
    return 1
}

release_lock() {
    if [ "${UPDATE_LOCK_HELD:-false}" = true ]; then
        rm -f "$UPDATE_LOCK"
        UPDATE_LOCK_HELD=false
    fi
}

# Set once main knows where the clone's .build/release is; the exit trap
# reconciles ~/tbd/updates/prebuilt only after that point, under the lock.
PREBUILT_RECONCILE_LINK=""
PREBUILT_START_LIVE=""

# Every exit from a run that took the lock: relaunch an app the run stopped
# and never brought back, reconcile the prebuilt trees, remove the copy of the
# running scripts, then drop the lock. Whatever branch the run left by — a dry
# run, a failed build, a failed handover, a verification failure, a completed
# install — nothing it downloaded outlives it unless it is now what
# .build/release points at.
on_update_exit() {
    # Main relaunches the app itself on every return it expects. This catches
    # the ones it does not — an exit from inside a step, or a signal — so no
    # run ends with the app stopped for a handover and never started again.
    # Except while the installation is moving: an exit then leaves a state
    # this run cannot name, and launching an app into it could pair a new app
    # with an old daemon. That exit is reported instead.
    if [ "$INSTALL_IN_FLIGHT" = true ]; then
        report_interrupted_install
    else
        relaunch_stopped_app || true
    fi
    if [ -n "$PREBUILT_RECONCILE_LINK" ]; then
        reconcile_prebuilt "$PREBUILT_HOME" "$PREBUILT_RECONCILE_LINK" "$PREBUILT_START_LIVE" \
            || log "WARNING: could not reconcile $PREBUILT_HOME"
    fi
    remove_running_snapshot
    release_lock
}

# MARK: - Reading the running daemon

# One field out of a JSON object, by dotted path. Empty output and a non-zero
# status when the path is absent or the input is not JSON, so a caller can tell
# "no daemon" from "daemon with no build identity".
json_field() {
    local path="${2-}"
    printf '%s' "${1-}" | python3 -c '
import json, sys
path = sys.argv[1].split(".")
try:
    value = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for key in path:
    if not isinstance(value, dict) or key not in value:
        sys.exit(1)
    value = value[key]
if value is None:
    sys.exit(1)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
' "$path" 2>/dev/null
}

daemon_status_json() {
    tbd daemon status --json 2>/dev/null
}

# The worktree a daemon executable was built from: the parent of its `.build`
# directory. Used when the daemon reports no build identity, which is every
# daemon built before the sidecar existed.
worktree_from_executable() {
    local exec_path="${1-}"
    case "$exec_path" in
        */.build/*) printf '%s\n' "${exec_path%%/.build/*}" ;;
        *) return 1 ;;
    esac
}

# Where the running daemon came from. The build identity is authoritative; the
# executable path is the fallback.
resolve_source_worktree() {
    local status_json="${1-}"
    local worktree exec_path
    worktree="$(json_field "$status_json" buildIdentity.sourceWorktree)"
    if [ -n "$worktree" ]; then
        printf '%s\n' "$worktree"
        return 0
    fi
    exec_path="$(json_field "$status_json" executablePath)"
    [ -n "$exec_path" ] || return 1
    worktree_from_executable "$exec_path"
}

# --remote wins, then the source worktree's `upstream`, then its `origin`. An
# update clone that already exists keeps its own origin, so a machine whose
# daemon worktree has gone away still updates.
resolve_remote_url() {
    local worktree="${1-}"
    local override="${2-}"
    local url
    if [ -n "$override" ]; then
        printf '%s\n' "$override"
        return 0
    fi
    for remote in upstream origin; do
        if [ -n "$worktree" ] \
            && url="$(git -C "$worktree" remote get-url "$remote" 2>/dev/null)" \
            && [ -n "$url" ]; then
            printf '%s\n' "$url"
            return 0
        fi
    done
    if [ -d "$UPDATE_SRC/.git" ] \
        && url="$(git -C "$UPDATE_SRC" remote get-url origin 2>/dev/null)" \
        && [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
    fi
    return 1
}

# MARK: - The update clone

ensure_clone() {
    local remote_url="${1-}"
    [ -n "$remote_url" ] || return 1
    mkdir -p "$UPDATE_HOME" || return 1

    if [ ! -d "$UPDATE_SRC/.git" ]; then
        log "cloning $remote_url into $UPDATE_SRC"
        git clone --no-checkout "$remote_url" "$UPDATE_SRC" >/dev/null 2>&1 \
            || { log_error "could not clone $remote_url"; return 1; }
    else
        # Repoint an existing clone if the resolved remote moved.
        local current
        current="$(git -C "$UPDATE_SRC" remote get-url origin 2>/dev/null || true)"
        if [ -n "$current" ] && [ "$current" != "$remote_url" ]; then
            log "update clone origin moves from $current to $remote_url"
            git -C "$UPDATE_SRC" remote set-url origin "$remote_url" || return 1
        fi
    fi
}

fetch_latest() {
    log "fetching origin/main"
    git -C "$UPDATE_SRC" fetch --quiet origin main \
        || { log_error "could not fetch origin main"; return 1; }
    git -C "$UPDATE_SRC" checkout --quiet --detach origin/main \
        || { log_error "could not check out origin/main"; return 1; }
}

# MARK: - Self re-exec

# This script and the libraries it sources, directly or through another
# library: the files whose fetched copy, differing from the running one, hands
# the run over to the fetched script.
REEXEC_SCRIPTS=(update.sh restart-bundle-lib.sh restart-environment-lib.sh restart-build-lib.sh update-release-lib.sh)

# A private copy of REEXEC_SCRIPTS as this run loaded them. Empty until
# snapshot_running_scripts makes it.
RUNNING_SNAPSHOT=""

# Copy REEXEC_SCRIPTS out of the tree this run loaded them from, before the
# fetch can rewrite them. On any installation that has updated before, that
# tree is the update clone itself — the running daemon was built there — and
# fetch_latest checks the clone out in place: from then on the files there are
# the fetched ones, and comparing against them compares the fetched copy with
# itself.
#
# Under $TMPDIR, never ~/tbd, and removed on every way out: by on_update_exit,
# or by maybe_reexec on its way into the fetched script, which clears that trap.
snapshot_running_scripts() {
    local name
    RUNNING_SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/tbd-update-running.XXXXXX")" \
        || { log_error "could not make a directory for a copy of the running scripts"; return 1; }
    for name in "${REEXEC_SCRIPTS[@]}"; do
        # A file this tree lacks stays absent, which should_reexec reads as
        # nothing to compare.
        [ -f "$UPDATE_SCRIPT_DIR/$name" ] || continue
        cp "$UPDATE_SCRIPT_DIR/$name" "$RUNNING_SNAPSHOT/$name" \
            || { log_error "could not copy the running $name"; return 1; }
    done
}

remove_running_snapshot() {
    if [ -n "$RUNNING_SNAPSHOT" ]; then
        rm -rf "$RUNNING_SNAPSHOT"
        RUNNING_SNAPSHOT=""
    fi
}

# The procedure updates itself: when the fetched copy of this script differs
# from the one running, hand over to the fetched one. The env marker keeps it
# to a single hop, so a script that keeps differing (a checkout the fetch
# cannot reach, a filesystem that rewrites bytes) cannot loop.
should_reexec() {
    local fetched="${1-}"
    local running="${2-}"
    [ "${TBD_UPDATE_REEXEC:-}" != "1" ] || return 1
    [ -f "$fetched" ] || return 1
    [ -f "$running" ] || return 1
    ! cmp -s "$fetched" "$running"
}

maybe_reexec() {
    # The libraries this script sources count as much as the script: main
    # read them before the fetch, so a change that lands only in one of them —
    # the product list in restart-bundle-lib.sh, say — would otherwise run the
    # old copy against the new sources with nothing to trigger the hop. Each
    # fetched file is compared with the copy of what was running, not with the
    # file it was loaded from, which the fetch may have just rewritten.
    local name
    for name in "${REEXEC_SCRIPTS[@]}"; do
        if should_reexec "$UPDATE_SRC/scripts/$name" "$RUNNING_SNAPSHOT/$name"; then
            log "re-exec: the fetched $name differs from the running one"
            # Carry the lock across. `exec` replaces the image but keeps the
            # pid, so the file already names the process that is about to run;
            # clearing the trap stops the outgoing image from deleting it on
            # the way out. With the trap gone, removing the copy of the running
            # scripts falls to this image; the fetched script makes its own.
            trap - EXIT
            remove_running_snapshot
            TBD_UPDATE_REEXEC=1 exec bash "$UPDATE_SRC/scripts/update.sh" "$@"
        fi
    done
}

# MARK: - Build

# Explain a failed build in update.log (and on stderr when a person is
# watching), then point at the full output in $UPDATE_BUILD_LOG. The compiler's
# first `error:` lines are the part a reader needs; the last lines of SwiftPM's
# output rarely are. Status 75 is scripts/swift-safe's "never got the
# machine-wide build slot" — nothing was compiled, so it is reported as a wait
# that ran out, not as a compile failure.
report_build_failure() {
    local product="$1" status="$2" build_out="$3"
    local excerpt line
    if [ "$status" -eq 75 ]; then
        excerpt="$(printf '%s\n' "$build_out" | tail -3)"
        log_error "build of $product timed out waiting for the build slot (scripts/swift-safe exited 75): nothing was compiled; another build held the slot. Retry once it is free"
    else
        excerpt="$(printf '%s\n' "$build_out" | grep -m 10 'error:')"
        [ -n "$excerpt" ] || excerpt="$(printf '%s\n' "$build_out" | tail -20)"
        log_error "build of $product failed (exit $status)"
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Into update.log only; a watching person gets the line on stderr.
        OPT_AUTO=true log "  $line"
        if [ "$OPT_AUTO" = false ]; then
            printf '  %s\n' "$line" >&2
        fi
    done <<< "$excerpt"
    log "full build output: $UPDATE_BUILD_LOG"
    log_error "the running installation is untouched"
    return 0
}

build_products() {
    local repo_root="${1-}"
    shift
    local product build_out
    # The products to build: the arguments, else every runtime product. A
    # release install passes only the ones the download does not carry.
    local products=("$@")
    [ "${#products[@]}" -gt 0 ] || products=("${RUNTIME_PRODUCTS[@]}")

    # The shared clang/Swift module cache is NOT selected here.
    # scripts/swift-safe points every governed compile at it, so this script,
    # scripts/restart.sh and scripts/test.sh all plan identically. Naming it a
    # second time is how that agreement gets lost: SwiftPM bakes the path into
    # the build plan, so two callers that spell it differently make every
    # transition between them a full recompile. See
    # docs/specs/2026-08-30-shared-module-cache-design.md.

    # SwiftPM honors only the last --product, so these are separate
    # invocations. The list is RUNTIME_PRODUCTS in restart-bundle-lib.sh, shared
    # with scripts/restart.sh; it includes TBDCLI because `tbd update` is run
    # through that binary, and an update that leaves the CLI behind reports a
    # version it is not.
    local status
    mkdir -p "$UPDATE_HOME" 2>/dev/null || true
    : > "$UPDATE_BUILD_LOG" 2>/dev/null || true
    for product in "${products[@]}"; do
        log "building $product ($BUILD_CONFIG)"
        # Capture the status, THEN print. Piping the build into `tail` would
        # make the pipeline's status tail's, which is always zero.
        status=0
        build_out="$( (cd "$repo_root" && scripts/swift-safe build \
                -c "$BUILD_CONFIG" --product "$product") 2>&1 )" || status=$?
        {
            printf '=== %s (%s) ===\n' "$product" "$BUILD_CONFIG"
            printf '%s\n' "$build_out"
        } >> "$UPDATE_BUILD_LOG" 2>/dev/null || true
        if [ "$status" -ne 0 ]; then
            report_build_failure "$product" "$status" "$build_out"
            return 1
        fi
        printf '%s\n' "$build_out" | tail -2 | while IFS= read -r line; do
            [ -n "$line" ] && log "  $line"
        done
    done
}

# MARK: - Keeping the previous app bundle

# Move the installed bundle out of the way, keeping it whole at
# $UPDATE_HOME/previous/TBD.app. Two jobs: it is what a failed handover puts
# back, and it is the fastest route to the previous build afterwards — a
# reinstall with no rebuild (see docs/updating.md).
#
# A move, not a copy: the bundle is small, the move is atomic within a volume,
# and a half-copied "previous" is worse than none. The running app is
# unaffected either way — it holds its executable by inode, not by path.
#
# With nothing installed there is nothing to keep, and a bundle an earlier
# update kept is left where it is: it is still a route back for the operator,
# but it is not this run's to restore (see BUNDLE_STASHED).
stash_installed_bundle() {
    local installed_bundle="${1:-$INSTALLED_BUNDLE}"
    BUNDLE_STASHED=false
    if [ ! -d "$installed_bundle" ]; then
        log "nothing installed at $installed_bundle — keeping no previous bundle"
        if [ -d "$PREVIOUS_BUNDLE" ]; then
            log "leaving $PREVIOUS_BUNDLE, which an earlier update kept, where it is"
        fi
        return 0
    fi
    mkdir -p "$(dirname "$PREVIOUS_BUNDLE")" || return 1
    rm -rf "$PREVIOUS_BUNDLE"
    if ! mv "$installed_bundle" "$PREVIOUS_BUNDLE"; then
        log_error "could not move $installed_bundle aside — installing nothing"
        return 1
    fi
    BUNDLE_STASHED=true
    log "kept the previous app bundle at $PREVIOUS_BUNDLE"
}

# True once stash_installed_bundle has moved the installed bundle to
# $PREVIOUS_BUNDLE in this run. Only then is the bundle there the build this
# run replaced. Otherwise anything at $PREVIOUS_BUNDLE was kept by an earlier
# update and may be any older build, and moving it into $INSTALLED_BUNDLE
# would install that build in front of whichever daemon is left, and let main
# relaunch it as a rollback that worked.
BUNDLE_STASHED=false

# Put the kept bundle back where it was and tell LaunchServices. Called when
# the installation is in place but the daemon behind it is not, which would
# otherwise leave a new app talking to an old daemon. Only for a bundle this
# run kept; roll_back_bundle checks that first.
restore_previous_bundle() {
    local installed_bundle="${1:-$INSTALLED_BUNDLE}"
    if [ ! -d "$PREVIOUS_BUNDLE" ]; then
        log_error "no previous app bundle to restore — $installed_bundle is the new build"
        return 1
    fi
    rm -rf "$installed_bundle"
    if ! mv "$PREVIOUS_BUNDLE" "$installed_bundle"; then
        log_error "could not restore the previous app bundle from $PREVIOUS_BUNDLE"
        return 1
    fi
    register_app_bundle "$installed_bundle"
    log "restored previous app bundle"
}

# True once a failed install_and_handover could not put the previous bundle
# back, or kept none of its own to put back, so $INSTALLED_BUNDLE may still be
# the new build, or nothing. main reads it before relaunching the app it
# stopped: launched from there, that app would drive the old daemon, or start
# the new one if none is running, which is the mismatch the rollback exists to
# prevent.
BUNDLE_RESTORE_FAILED=false

# install_and_handover's rollback of the bundle: restore_previous_bundle, with
# a failure recorded in BUNDLE_RESTORE_FAILED for main.
#
# It restores only a bundle this run kept (BUNDLE_STASHED). A run that found
# nothing installed has nothing of its own to put back, and that counts as a
# rollback that did not complete: main leaves the app stopped and logs the
# recovery steps. Whatever this run installed stays installed, as on a first
# update, rather than being removed. Removing it would restore the empty
# install the run began with, but the stopped app already keeps this run from
# launching it, and removing it takes away the bundle the recovery steps tell
# the operator to open once it and the daemon are the same build.
roll_back_bundle() {
    local installed_bundle="${1:-$INSTALLED_BUNDLE}"
    if [ "$BUNDLE_STASHED" = true ]; then
        restore_previous_bundle "$installed_bundle" || BUNDLE_RESTORE_FAILED=true
        return 0
    fi
    BUNDLE_RESTORE_FAILED=true
    log_error "no previous app bundle to restore — this run found nothing installed at $installed_bundle, so what it installed there stays"
    if [ -d "$PREVIOUS_BUNDLE" ]; then
        log "not restoring $PREVIOUS_BUNDLE: an earlier update kept it, and it is not the build this run replaced"
    fi
}

# Put the new bundle in place and move the fleet onto it, undoing the
# installation if the successor daemon never arrives.
#
#   install_and_handover <bundle_dir> <installed_bundle> <new_daemon>
#
# Sets HANDOVER_STARTED to the moment the handover began, which is the cutoff
# the wake sweep filters parked sessions against, and BUNDLE_RESTORE_FAILED
# when a failure could not be rolled back.
install_and_handover() {
    local bundle_dir="${1-}"
    local installed_bundle="${2-}"
    local new_daemon="${3-}"
    BUNDLE_RESTORE_FAILED=false

    # Keeping the previous bundle: undone by moving it back, which is what the
    # two failure paths below do when this run kept one. A failure here has
    # moved nothing, so there is nothing to roll back.
    stash_installed_bundle "$installed_bundle" || return 1

    # Installing: the new bundle replaces the old one on disk. The RUNNING app
    # is untouched — it holds its executable by inode — so this is still
    # reversible until something launches from the new path.
    #
    # It happens BEFORE the handover on purpose. During the socket gap an app
    # may decide the daemon is missing and spawn one (main stops the installed
    # app first, but not under --no-app), and the daemon it spawns is the one
    # named by the bundle's SourceWorktreePath. That must already be the update
    # clone, or a rescue spawn in that window reinstates the old binary
    # underneath the new install.
    if ! install_app_bundle "$bundle_dir" "$installed_bundle"; then
        log_error "could not install to $installed_bundle"
        roll_back_bundle "$installed_bundle"
        return 1
    fi

    # The handover is the one step with no undo: the predecessor daemon is
    # gone. Everything before it can still be put back, and a handover that
    # never completes does exactly that with the bundle, leaving the operator
    # on the build they started the day with rather than a new app driving an
    # old daemon. The caller relaunches the app it stopped once that worked,
    # and leaves it stopped when it did not (BUNDLE_RESTORE_FAILED).
    HANDOVER_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! handover "$new_daemon"; then
        roll_back_bundle "$installed_bundle"
        return 1
    fi
}

# MARK: - Handover

running_daemon_pid() {
    local pid
    [ -f "$DAEMON_PID_FILE" ] || return 1
    pid="$(head -1 "$DAEMON_PID_FILE" 2>/dev/null | tr -dc '0-9')"
    [ -n "$pid" ] || return 1
    printf '%s\n' "$pid"
}

# True when two paths name the same file after symlink resolution. The daemon
# reports the path it was executed from; ours came out of the build directory,
# which is itself a symlink.
paths_match() {
    local a b
    a="$(/usr/bin/readlink -f "${1-}" 2>/dev/null || printf '%s' "${1-}")"
    b="$(/usr/bin/readlink -f "${2-}" 2>/dev/null || printf '%s' "${2-}")"
    [ -n "$a" ] && [ "$a" = "$b" ]
}

# True when `tbd daemon status` names <expected> as the daemon's executable.
# One question, asked once; wait_for_handover polls it.
daemon_reports_executable() {
    local reported
    reported="$(json_field "$(daemon_status_json)" executablePath)"
    [ -n "$reported" ] && paths_match "$reported" "${1-}"
}

# Wait until the daemon that answers is the successor: the predecessor has
# exited, and `tbd daemon status` then reports the executable just installed.
#
#   wait_for_handover <old_pid> <new_pid> <expected_executable> [timeout]
#
# The status answer alone cannot say which daemon gave it. A local build runs
# the old and the new daemon from the same file, the update clone's
# .build/release/TBDDaemon, so the predecessor reports the expected path, and
# it goes on answering on its socket for the whole of its shutdown, after it
# has already let go of every session. An app launched on that answer attaches
# to a daemon that refuses it, and the wake stage reads the fleet off a daemon
# on its way out. The successor binds only once its predecessor is gone —
# Daemon.start() retires it before opening the database, let alone the socket
# — so from the predecessor's exit on, the daemon that answers is the
# successor, and the path confirms it serves the build just installed. The
# status reports no pid, which is why the exit is what tells the two apart.
#
# The two phases are wait_for_predecessor_exit and wait_until_daemon_ready
# (scripts/restart-bundle-lib.sh), under one deadline. Each line logged here
# says how a phase ended, so update.log times the predecessor's exit and the
# successor's first answer separately. A successor that dies ends the wait at
# once, in either phase: it would never retire the predecessor, and the run
# would otherwise sit out the whole budget with the app stopped.
wait_for_handover() {
    local old_pid="${1:-0}"
    local new_pid="${2-}"
    local expected="${3-}"
    local timeout="${4:-$HANDOVER_TIMEOUT}"
    local deadline outcome

    if ! _is_whole_number "$timeout"; then
        log "the handover budget is not a whole number of seconds: [$timeout]"
        return 1
    fi
    deadline=$((SECONDS + timeout))

    outcome="$(wait_for_predecessor_exit "$old_pid" "$new_pid" "$deadline")"
    case "$outcome" in
        exited)
            log "the previous daemon (pid $old_pid) has exited"
            ;;
        none)
            # A cold start needs no line: handover() has said it starts cold.
            if [ "$old_pid" != 0 ]; then
                log "pid $old_pid named no running daemon when the wait began; there was no predecessor to wait for"
            fi
            ;;
        successor-exited)
            log "the new daemon (pid $new_pid) exited while the previous daemon (pid $old_pid) was still running"
            return 1
            ;;
        timeout)
            log "the previous daemon (pid $old_pid) is still running after ${timeout}s"
            return 1
            ;;
        *)
            log "waiting for the previous daemon ended in an unrecognised way: [$outcome]"
            return 1
            ;;
    esac

    outcome="$(wait_until_daemon_ready "$new_pid" "$deadline" 1 daemon_reports_executable "$expected")"
    case "$outcome" in
        ready)
            return 0
            ;;
        successor-exited)
            log "the new daemon (pid $new_pid) exited before it reported itself"
            return 1
            ;;
        timeout)
            log "the daemon never reported $expected as its executable"
            return 1
            ;;
        *)
            log "waiting for the new daemon ended in an unrecognised way: [$outcome]"
            return 1
            ;;
    esac
}

# Start the successor with TBD_HANDOVER_FROM_PID set. It claims the pid file
# before it signals its predecessor, so the app's respawn watchdog finds a
# live daemon in that file from the first instant and starts no daemon of its
# own to race us.
#
# It returns once the successor is the daemon that answers
# (wait_for_handover), never while the predecessor is still shutting down:
# the app relaunch and the wake stage that follow must reach the new daemon.
#
# A handover that times out has not necessarily started a dead daemon: a
# successor that is merely slow is still running, already holds the pid file,
# and would go on to bind and serve from the new build long after the caller
# rolled the installed bundle back to the previous one. Installed bundle and
# running daemon would then disagree about which build is live. So the
# successor's pid is captured at the moment it is backgrounded, and a handover
# that fails stops it before it returns — see stop_handover_successor.
handover() {
    local new_daemon="${1-}"
    local old_pid new_pid

    if [ ! -x "$new_daemon" ]; then
        log_error "no daemon binary at $new_daemon"
        return 1
    fi

    old_pid="$(running_daemon_pid || true)"
    if [ -z "$old_pid" ]; then
        log "no running daemon in $DAEMON_PID_FILE — starting the new one cold"
        old_pid=0
    else
        log "handing over from daemon pid $old_pid"
    fi

    # Preserve the predecessor's log. The daemon does not persist os.Logger
    # output, so this file is the only record of a crash before the handover.
    [ -f "$DAEMON_LOG" ] && mv "$DAEMON_LOG" "$DAEMON_LOG.1"
    TBD_HANDOVER_FROM_PID="$old_pid" "$new_daemon" > "$DAEMON_LOG" 2>&1 &
    new_pid=$!

    if wait_for_handover "$old_pid" "$new_pid" "$new_daemon" "$HANDOVER_TIMEOUT"; then
        log "daemon is serving from $new_daemon"
        return 0
    fi
    log_error "the handover did not complete within ${HANDOVER_TIMEOUT}s — see $DAEMON_LOG"
    stop_handover_successor "$new_pid" || true
    return 1
}

# Stop the successor a failed handover started, so that after the caller puts
# the previous bundle back no daemon from the new build is left running.
#
#   stop_handover_successor <pid>
#
# stop_daemon_process does the work: SIGTERM, HANDOVER_STOP_GRACE seconds,
# then SIGKILL and three more, signalling only a pid that is a running daemon.
# Its outcome word is logged, including the one this cannot fix: a process
# that survives SIGKILL, where the operator has to be told which pid to look
# at. A pid that is already gone is the ordinary case for a successor that
# crashed rather than stalled.
stop_handover_successor() {
    local pid="${1-}"
    local outcome status=0

    [ -n "$pid" ] || return 0
    outcome="$(stop_daemon_process "$pid" "$HANDOVER_STOP_GRACE" 3)" || status=$?
    case "$outcome" in
        none)
            log "the new daemon (pid $pid) is not running; nothing to stop"
            ;;
        stopped | killed)
            log "stopped the new daemon (pid $pid) so the rollback leaves no daemon from the new build: $outcome"
            ;;
        *)
            log "WARNING: could not stop the new daemon (pid $pid): $outcome"
            ;;
    esac
    return "$status"
}

# MARK: - The app

# True from the moment this run stops the app ahead of the handover until it
# launches the app again. Every way out of the run that finds it still true
# relaunches the app — see relaunch_stopped_app and on_update_exit — except
# two that leave it stopped and say so (leave_app_stopped_for_recovery): an
# exit while the installation is moving, and a failed handover whose rollback
# did not complete.
APP_RELAUNCH_PENDING=false

# True while install_and_handover is moving the installation: from just before
# the installed bundle is moved aside until main knows where the run stands
# again. Read by on_update_exit, which must not relaunch the app into a
# half-moved installation.
INSTALL_IN_FLIGHT=false

# How the stop before the handover ended: none, stopped, killed, survived or
# unknown. The second stop in restart_app keeps its outcome to itself, so this stays
# the answer to whether an app was running when the run began to move things.
APP_STOP_OUTCOME=none

# Stop the app running from the installed bundle and wait until it has exited.
# Prints how that ended — none, stopped, killed, survived or unknown — and logs
# nothing, so each caller decides which outcomes earn a line. Non-zero when it
# may still be running: still there after SIGKILL, or pgrep could not say.
stop_installed_app() {
    local pattern
    pattern="$(escape_exec_pattern "$INSTALLED_BUNDLE/Contents/MacOS/TBDApp")"
    stop_app_process "$pattern" "$APP_STOP_GRACE"
}

# Log how a stop_installed_app ended, in the wording restart.sh shares.
log_app_stop() {
    log "$(describe_app_stop "${1-}" "$APP_STOP_GRACE" "$INSTALLED_BUNDLE")"
}

# Stop the app before the daemon is handed over, unless --no-app.
#
# An app left running through the handover sees its daemon go, reconnects to
# the successor, and re-attaches the session it has on screen. The restart
# after the handover then kills it, and the successor goes on holding that
# dead viewer's claim on the session's terminal, refusing the attach of the
# app that replaces it. Stopped here, the app is gone before the successor
# exists.
#
# Under --no-app the app is left alone: an app that stays alive owns its
# claims legitimately.
stop_app_before_handover() {
    if [ "$OPT_NO_APP" = true ]; then
        log "--no-app: the running app stays up through the handover"
        return 0
    fi
    log "stopping the app before the handover"
    local status=0
    APP_STOP_OUTCOME="$(stop_installed_app)" || status=$?
    log_app_stop "$APP_STOP_OUTCOME"
    if [ "$status" -ne 0 ]; then
        log "WARNING: handing over anyway — an app still running may re-attach to the new daemon"
    fi
    # Anything but `none` means an app was running, or (`unknown`) may have
    # been, and the run owes the operator one again however it ends. A
    # relaunch of an app that is in fact still running only brings it forward.
    if [ "$APP_STOP_OUTCOME" != none ]; then
        APP_RELAUNCH_PENDING=true
    fi
}

# Launch the installed bundle and report whether it came up. A failed launch
# is logged, not fatal: the app is a viewer the operator can open by hand.
launch_installed_app() {
    local pattern pid
    pattern="$(escape_exec_pattern "$INSTALLED_BUNDLE/Contents/MacOS/TBDApp")"
    launch_app_bundle "$INSTALLED_BUNDLE" "$PATH" "$APP_LOG" || {
        log_error "could not launch $INSTALLED_BUNDLE"
        return 1
    }
    sleep 0.5
    if pid="$(app_process_pid "$pattern")"; then
        log "app running as pid $pid — logs: $APP_LOG"
    else
        log "WARNING: the app did not come back up — see $APP_LOG"
    fi
}

# Bring back an app this run stopped for a handover that did not complete. It
# launches whatever is at $INSTALLED_BUNDLE, so it is right only once the
# rollback has put the previous build back there.
#
# The relaunch matters for more than the window on screen. A failed handover
# can leave no daemon running at all — the successor stops its predecessor
# before it reports itself, and is then stopped in turn — and an app that
# finds no daemon socket starts one from its bundle's source worktree. That is
# why main calls this only once both halves of the rollback have worked — the
# previous bundle is back, and .build/release names the build that was
# running before the update — and why on_update_exit never calls it while
# INSTALL_IN_FLIGHT is set.
relaunch_stopped_app() {
    [ "$APP_RELAUNCH_PENDING" = true ] || return 0
    APP_RELAUNCH_PENDING=false
    log "relaunching the app this run stopped before the handover"
    launch_installed_app
}

# Leave the app this run stopped where it is, and say how to recover. For a
# run that ends with an installation it cannot vouch for, where the bundle at
# $INSTALLED_BUNDLE and the daemon an app launched from it would reach, or
# start, may be different builds: an exit while the installation is moving
# (report_interrupted_install), and a failed handover whose rollback did not
# complete (main). Each logs its own error before calling this.
#
# APP_RELAUNCH_PENDING comes down before INSTALL_IN_FLIGHT, so an exit between
# the two still finds nothing to relaunch.
leave_app_stopped_for_recovery() {
    local was_stopped="$APP_RELAUNCH_PENDING"
    APP_RELAUNCH_PENDING=false
    INSTALL_IN_FLIGHT=false
    if [ "$was_stopped" = true ]; then
        log "the app was stopped for the handover and is not running; it is not relaunched, because which build it would start and which daemon it would reach are unknown"
    fi
    log "to recover: run 'tbd version' to see which build the daemon is running, then run 'tbd update' again"
    log "or open $INSTALLED_BUNDLE yourself once it and the daemon are the same build ($INSTALLED_BUNDLE/Contents/TBDBuildIdentity.json names the bundle's commit)"
    log "the bundle this run replaced, if there was one, is kept at $PREVIOUS_BUNDLE — see 'Going back to the previous build' in docs/updating.md"
}

# Report a run that ended while install_and_handover was moving the
# installation, and leave the app this run stopped where it is.
#
# Relaunching would be a guess. The run left from somewhere between moving the
# installed bundle aside and the successor daemon reporting itself, so
# $INSTALLED_BUNDLE may hold the new build, the old one or nothing, and the
# daemon may be the predecessor, the successor or neither. Rolling back from
# here is no safer: with the successor possibly serving, putting the old
# bundle back puts the old app in front of the new daemon, the mirror image of
# the mismatch the rollback exists to prevent. An app launched into any of
# that reaches, or starts, whichever daemon it finds. So the run says what
# happened and how to recover, and the operator chooses.
report_interrupted_install() {
    log_error "the run was interrupted while installing and handing over; the installation may be part old build, part new"
    leave_app_stopped_for_recovery
}

# The app restart, with its opt-out. Separate from restart_app so both branches
# are reachable from a test. A failed relaunch is logged, not fatal: the daemon
# has already handed over and the app is only a viewer.
run_app_stage() {
    # Before the opt-out: the next login relaunch ignores LSEnvironment.PATH
    # and needs the saved tmux fallback whether or not this run relaunches.
    # Only a run from the user's shell seeds: an --auto run's PATH is the
    # daemon's plus UpdateLauncher.pathFallbacks, so its tmux is a guess.
    if [ "$OPT_AUTO" = false ]; then
        seed_tmux_fallback "$TBD_HOME_DIR"
    fi
    if [ "$OPT_NO_APP" = true ]; then
        log "--no-app: leaving the running app alone"
        return 0
    fi
    restart_app || true
}

restart_app() {
    local outcome
    log "restarting the app"
    # Normally there is nothing left to stop: stop_app_before_handover already
    # did, and logged how. This catches an app launched since and waits for it
    # to exit. Only a stop that found one is worth a line; "no app running"
    # here is the expected answer, and logged it reads as if the stop before
    # the handover had found nothing either.
    outcome="$(stop_installed_app)" || true
    [ "$outcome" = none ] || log_app_stop "$outcome"
    APP_RELAUNCH_PENDING=false
    launch_installed_app
}

# Re-point an existing ~/.local/bin/tbd at the CLI we just built. Only when the
# operator already installed one: creating it here would be a gesture they
# never made. A hard link for the same reason the app uses one — the target
# keeps working when a build directory goes away.
refresh_installed_cli() {
    local new_cli="${1-}"
    if [ ! -f "$CLI_INSTALL_PATH" ] || [ -L "$CLI_INSTALL_PATH" ]; then
        return 0
    fi
    if [ ! -x "$new_cli" ]; then
        return 0
    fi
    if ln -f "$new_cli" "$CLI_INSTALL_PATH" 2>/dev/null; then
        log "refreshed $CLI_INSTALL_PATH"
    else
        log "WARNING: could not refresh $CLI_INSTALL_PATH — run tbd from the app's CLI installer"
    fi
}

# MARK: - Waking what the reconcile parked

# Every terminal row the daemon knows about, as one JSON array. There is no CLI
# that lists terminals across worktrees — `tbd terminal list` takes a worktree
# — so this walks the worktrees and concatenates.
all_terminals_json() {
    local worktrees ids id rows
    worktrees="$(tbd worktree list --status active --json 2>/dev/null)" || return 1
    ids="$(printf '%s' "$worktrees" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for row in rows:
    if isinstance(row, dict) and row.get("id"):
        print(row["id"])
' 2>/dev/null)" || return 1

    # One document per worktree, separated by ASCII record separator (0x1e).
    # JSON forbids an unescaped control character inside a string, so the
    # separator cannot occur in a document, whatever a label contains; each
    # document is then parsed whole. Counting brackets line by line would let
    # one `[` in a tab label swallow every row after it, silently.
    rows=""
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        local one
        one="$(tbd terminal list "$id" --json 2>/dev/null)" || continue
        rows="$rows$one"$'\x1e'
    done <<< "$ids"

    printf '%s' "$rows" | python3 -c '
import json, sys
out = []
for document in sys.stdin.read().split("\x1e"):
    if not document.strip():
        continue
    try:
        rows = json.loads(document)
    except Exception:
        print("update: skipping a terminal list that did not parse as JSON", file=sys.stderr)
        continue
    if isinstance(rows, list):
        out.extend(row for row in rows if isinstance(row, dict))
print(json.dumps(out))
'
}

# The rows this update is responsible for: parked by a startup reconcile
# (hibernateReason "recovery") at or after the moment the handover began. An
# empty <since> means every recovery-parked row, which is what --wake-only
# does — it runs against a daemon whose start it did not witness.
select_wake_candidates() {
    local since="${1-}"
    python3 -c '
import json, sys

since = sys.argv[1] if len(sys.argv) > 1 else ""

def normalize(stamp):
    # Swift encodes dates as ISO-8601 UTC. Compare as strings after dropping
    # any fractional seconds, which sort the same way instants do.
    if not stamp:
        return ""
    stamp = stamp.replace("+00:00", "Z")
    if "." in stamp:
        head, _, tail = stamp.partition(".")
        stamp = head + "Z" if tail.endswith("Z") else head
    return stamp

try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(1)

for row in rows:
    if not isinstance(row, dict):
        continue
    if row.get("hibernateReason") != "recovery":
        continue
    parked = normalize(row.get("hibernatedAt"))
    if not parked:
        continue
    if since and parked < normalize(since):
        continue
    if row.get("id"):
        print(row["id"])
' "$since" 2>/dev/null
}

# Wake the given terminal ids, WAKE_CONCURRENCY at a time with
# WAKE_STAGGER_SECONDS between batches. Sets WAKE_WOKEN and WAKE_FAILED.
wake_terminals() {
    local ids=("$@")
    local total=${#ids[@]}
    local index=0 batch=0 first_batch=true
    local batch_ids batch_pids id result_dir

    WAKE_WOKEN=0
    WAKE_FAILED=0
    [ "$total" -gt 0 ] || return 0

    # A fixed path under the update home rather than a per-invocation mktemp:
    # one directory, emptied at the start of every wake and removed at the end,
    # so a run killed mid-wait leaves nothing a reconciler would have to find.
    result_dir="$UPDATE_HOME/wake"
    rm -rf "$result_dir"
    mkdir -p "$result_dir" || return 1

    while [ "$index" -lt "$total" ]; do
        batch_ids=("${ids[@]:index:WAKE_CONCURRENCY}")
        batch=$((batch + 1))
        if [ "$first_batch" = false ] && [ "$WAKE_STAGGER_SECONDS" -gt 0 ]; then
            sleep "$WAKE_STAGGER_SECONDS"
        fi
        first_batch=false
        log "waking batch $batch (${#batch_ids[@]} of $total): ${batch_ids[*]}"

        batch_pids=()
        for id in "${batch_ids[@]}"; do
            (
                if out="$(tbd terminal wake --terminal "$id" --json 2>&1)"; then
                    printf 'ok %s\n' "$id" > "$result_dir/$id"
                else
                    printf 'fail %s %s\n' "$id" "$(printf '%s' "$out" | tr '\n' ' ')" \
                        > "$result_dir/$id"
                fi
            ) &
            batch_pids+=("$!")
        done
        # This batch's wakes only. A bare `wait` also waits for every other
        # background child of this shell, and the handover starts the new
        # daemon as one: it runs until the machine stops, so the run would
        # never finish and would hold the update lock until then.
        wait "${batch_pids[@]}"
        index=$((index + WAKE_CONCURRENCY))
    done

    local line
    for id in "${ids[@]}"; do
        line="$(cat "$result_dir/$id" 2>/dev/null || printf 'fail %s no result\n' "$id")"
        case "$line" in
            ok\ *) WAKE_WOKEN=$((WAKE_WOKEN + 1)) ;;
            *)
                WAKE_FAILED=$((WAKE_FAILED + 1))
                log "  wake failed: ${line#fail }"
                ;;
        esac
    done
    rm -rf "$result_dir"
}

# The wake step, with its opt-out. Separate from wake_sweep so both branches
# are reachable from a test without a live daemon.
run_wake_stage() {
    local since="${1-}"
    if [ "$OPT_NO_WAKE" = true ]; then
        log "--no-wake: leaving parked sessions alone"
        WAKE_CANDIDATES=0
        WAKE_WOKEN=0
        WAKE_FAILED=0
        return 0
    fi
    wake_sweep "$since"
}

wake_sweep() {
    local since="${1-}"
    local candidates ids=()

    candidates="$(all_terminals_json | select_wake_candidates "$since")"
    while IFS= read -r id; do
        [ -n "$id" ] && ids+=("$id")
    done <<< "$candidates"

    WAKE_CANDIDATES=${#ids[@]}
    if [ "$WAKE_CANDIDATES" -eq 0 ]; then
        log "no session was left parked by the reconcile"
        WAKE_WOKEN=0
        WAKE_FAILED=0
        return 0
    fi
    log "$WAKE_CANDIDATES session(s) parked with reason recovery — waking $WAKE_CONCURRENCY at a time"
    wake_terminals "${ids[@]}"
}

# MARK: - Reporting

short_commit() {
    printf '%s\n' "${1:0:7}"
}

# How many commits the clone advanced. Empty when either end is unknown or the
# range is not in the clone's history.
commits_advanced() {
    local old="${1-}"
    local new="${2-}"
    [ -n "$old" ] && [ -n "$new" ] || return 1
    git -C "$UPDATE_SRC" rev-list --count "$old..$new" 2>/dev/null
}

print_summary() {
    local old="${1-}" new="${2-}" advanced="${3-}" candidates="${4-}" woken="${5-}" failed="${6-}"
    log "Update summary"
    log "  Previous commit:  ${old:-unknown}"
    log "  New commit:       ${new:-unknown}"
    log "  Commits advanced: ${advanced:-unknown}"
    log "  Sessions parked by the reconcile: ${candidates:-0}"
    log "  Sessions woken:   ${woken:-0}"
    log "  Wake failures:    ${failed:-0}"
    log "  Log:              $UPDATE_LOG"
}

# MARK: - --check

run_check() {
    local status_json relation latest running behind
    status_json="$(daemon_status_json)"
    running="$(json_field "$status_json" buildIdentity.commit)"
    relation="$(json_field "$status_json" update.relation)"
    latest="$(json_field "$status_json" update.latestCommit)"
    behind="$(json_field "$status_json" update.behindBy)"

    if [ -z "$relation" ] || [ "$relation" = "unknown" ]; then
        # The daemon has not checked, or is too old to. Ask the remote directly.
        local worktree remote_url head
        worktree="$(resolve_source_worktree "$status_json" || true)"
        remote_url="$(resolve_remote_url "$worktree" "$OPT_REMOTE" || true)"
        if [ -n "$remote_url" ]; then
            head="$(git ls-remote "$remote_url" "$(check_ref_for_source "$(resolve_update_source)")" 2>/dev/null | awk '{print $1}')"
            if [ -n "$head" ]; then
                latest="$head"
                relation="$(local_relation "$worktree" "$running" "$head")"
            fi
        fi
    fi

    log "Running commit: ${running:-unknown}"
    log "Latest main:    ${latest:-unknown}"
    case "$relation" in
        upToDate) log "Up to date." ;;
        behind)
            if [ -n "$behind" ]; then
                log "Update available: $(short_commit "$running") to $(short_commit "$latest") ($behind commits behind). Run: tbd update"
            else
                log "Update available: $(short_commit "$running") to $(short_commit "$latest"). Run: tbd update"
            fi
            ;;
        *)
            if [ -n "$latest" ]; then
                log "Unknown — could not decide how ${running:-this build} relates to main from here. Run tbd version --check, or tbd update from a checkout that has both commits."
            else
                log "Unknown — the daemon has not compared itself to main yet."
            fi
            ;;
    esac
}

# How the running commit relates to main's head, decided in the source
# worktree. Mirrors `UpdateRelation.compute` in TBDShared, and for the same
# reason: equality is not the only way to be up to date. A build ahead of or
# diverged from main holds commits main does not, and telling it to update
# would replace those with plain main. So:
#
#   running == head                      upToDate
#   running is an ancestor of head       behind
#   running is not an ancestor           upToDate (ahead or diverged)
#   git could not decide, head unknown   behind   (never fetched = do not have)
#   git could not decide otherwise       unknown  (a bad ref or a broken
#                                                 store is evidence of nothing)
#
# Prints one of upToDate, behind, unknown.
local_relation() {
    local worktree="${1-}" running="${2-}" head="${3-}" rc
    if [ -z "$running" ] || [ -z "$head" ]; then
        printf 'unknown\n'
        return 0
    fi
    if [ "$running" = "$head" ]; then
        printf 'upToDate\n'
        return 0
    fi
    if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
        printf 'unknown\n'
        return 0
    fi
    rc=0
    git -C "$worktree" merge-base --is-ancestor "$running" "$head" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) printf 'behind\n'; return 0 ;;
        1) printf 'upToDate\n'; return 0 ;;
    esac
    # `rev-parse --verify --quiet` exits 1 for a commit this store does not
    # hold and 128 for a store that cannot answer; `cat-file -e` uses 128 for
    # both and cannot draw the line.
    rc=0
    git -C "$worktree" rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 1 ]; then
        printf 'behind\n'
    else
        printf 'unknown\n'
    fi
}

# MARK: - Update source

# `build` or `release`: the --from-release flag, else TBD_UPDATE_SOURCE, else
# the update-source file, else the shipped default. Anything unrecognized
# reads as `build`, the path that installs nothing it did not compile.
resolve_update_source() {
    local value=""
    if [ "$OPT_FROM_RELEASE" = true ]; then
        value=release
    elif [ -n "${TBD_UPDATE_SOURCE:-}" ]; then
        value="$TBD_UPDATE_SOURCE"
    elif [ -f "$UPDATE_SOURCE_FILE" ]; then
        value="$(tr -d '[:space:]' < "$UPDATE_SOURCE_FILE" 2>/dev/null || true)"
    else
        value="$UPDATE_SOURCE_DEFAULT"
    fi
    case "$value" in
        release|build) printf '%s\n' "$value" ;;
        *)
            log "WARNING: unknown update source '$value' — building locally" >&2
            printf 'build\n'
            ;;
    esac
}

# The ref "latest" means for a given source. While the source is `release`,
# only a published build is installable, so the check compares against the
# tag the release workflow moves after each publish.
check_ref_for_source() {
    if [ "${1-}" = release ]; then
        printf 'refs/tags/%s\n' "$RELEASE_TAG"
    else
        printf 'refs/heads/main\n'
    fi
}

# Tell the daemon's update check which ref to compare against. The file is
# the whole interface: present means "this ref", absent means main. A
# one-off --from-release leaves it alone — the check follows the standing
# choice, not a single run's flag.
sync_check_ref() {
    local standing
    standing="$(OPT_FROM_RELEASE=false resolve_update_source)"
    if [ "$standing" = release ]; then
        mkdir -p "$UPDATE_HOME" 2>/dev/null || return 0
        check_ref_for_source release > "$CHECK_REF_FILE" 2>/dev/null || true
    else
        rm -f "$CHECK_REF_FILE"
    fi
}

# MARK: - main

main() {
    local rc=0
    parse_args "$@" || { rc=$?; [ "$rc" -eq 10 ] && return 0; return "$rc"; }

    # shellcheck source=/dev/null
    source "$UPDATE_SCRIPT_DIR/restart-bundle-lib.sh"
    # shellcheck source=/dev/null
    source "$UPDATE_SCRIPT_DIR/restart-build-lib.sh"
    # shellcheck source=/dev/null
    source "$UPDATE_SCRIPT_DIR/update-release-lib.sh"

    # Run from inside another project's dev shell (nix/direnv, say), this
    # process inherits that shell's SDK and header overrides. They point the
    # compiler at an SDK that lacks what TBD's dependencies need, and
    # DEVELOPER_DIR also breaks the xcode-select git shim; see
    # restart-build-lib.sh. Clear them for the whole run rather than only
    # around the build, so the fetch, the build and the daemon this hands over
    # to all see the system toolchain. Only this process is affected.
    local sdk_note
    sdk_note="$(describe_sdk_overrides)"
    [ -z "$sdk_note" ] || log "note: $sdk_note"
    clear_sdk_overrides

    if [ "$OPT_CHECK" = true ]; then
        sync_check_ref
        run_check
        return 0
    fi

    acquire_lock || return 1
    trap on_update_exit EXIT

    local status_json source_worktree old_commit
    status_json="$(daemon_status_json)"
    old_commit="$(json_field "$status_json" buildIdentity.commit || true)"
    source_worktree="$(resolve_source_worktree "$status_json" || true)"

    if [ "$OPT_WAKE_ONLY" = true ]; then
        log "wake-only: waking every recovery-parked session against the running daemon"
        run_wake_stage ""
        print_summary "$old_commit" "$old_commit" 0 \
            "${WAKE_CANDIDATES:-0}" "${WAKE_WOKEN:-0}" "${WAKE_FAILED:-0}"
        [ "${WAKE_FAILED:-0}" -eq 0 ] || return 1
        return 0
    fi

    local remote_url
    if ! remote_url="$(resolve_remote_url "$source_worktree" "$OPT_REMOTE")"; then
        log_error "could not resolve an update remote. Pass --remote <url>."
        return 1
    fi
    log "update remote: $remote_url"

    ensure_clone "$remote_url" || return 1
    # Copied here, just before the fetch, rather than where main sources the
    # scripts: from here on on_update_exit is armed to remove the copy, and
    # nothing in between rewrites those files. This run's first checkout of
    # the clone is fetch_latest's, and another run checks it out only under
    # the lock, which this run took a moment after sourcing.
    snapshot_running_scripts || return 1
    fetch_latest || return 1
    maybe_reexec "$@"

    local new_commit build_dir update_source release_link previous_release_target=""
    local release_link_moved=false
    new_commit="$(git -C "$UPDATE_SRC" rev-parse HEAD 2>/dev/null || true)"
    log "latest main is ${new_commit:-unknown}"
    build_dir="$UPDATE_SRC/.build/$BUILD_CONFIG"
    release_link="$UPDATE_SRC/.build/release"

    # Reconcile the prebuilt trees before anything is downloaded, and arm the
    # same reconcile for every exit (on_update_exit). The tree live now is
    # kept on the way out even when the link no longer names it, because
    # until an install completes it is still what the daemon runs from.
    PREBUILT_START_LIVE="$(link_target "$release_link" || true)"
    PREBUILT_RECONCILE_LINK="$release_link"
    reconcile_prebuilt "$PREBUILT_HOME" "$release_link"

    update_source="$(resolve_update_source)"
    sync_check_ref

    # MARK: Where the binaries come from
    #
    # `release` tries the published build first. What happens when there is
    # none depends on who asked: a person running `tbd update` gets the local
    # build they would have had anyway, while an unattended `--auto` run skips,
    # because the whole point of the download is that nothing unattended
    # compiles here, and the next check tries again. A machine the workflow
    # does not publish for builds locally in both cases — "try again later"
    # would mean never. A download that fails verification is neither: it
    # stops the run, loudly, and nothing is built or installed.
    local use_release=false release_status
    if [ "$update_source" = release ] && [ "$BUILD_CONFIG" != release ]; then
        log "--debug always builds locally: the release workflow publishes release builds only"
    elif [ "$update_source" = release ]; then
        release_status=0
        acquire_release_build "$UPDATE_SRC" "$remote_url" "$old_commit" \
            "$PREBUILT_HOME" "$OPT_AUTO" || release_status=$?
        case "$release_status" in
            "$RELEASE_OK")
                use_release=true
                new_commit="$RELEASE_COMMIT"
                ;;
            "$RELEASE_ALREADY_CURRENT")
                log "the running build ${old_commit:-unknown} is already at or past the newest published build — nothing to install"
                print_summary "$old_commit" "$old_commit" 0 0 0 0
                return 0
                ;;
            "$RELEASE_UNSUPPORTED_ARCH")
                log "building locally instead"
                ;;
            "$RELEASE_UNAVAILABLE")
                if [ "$OPT_AUTO" = true ]; then
                    log "no published build to install — skipping this unattended update; the next check tries again"
                    return 0
                fi
                log "building locally instead"
                ;;
            *)
                log_error "the published build failed verification — nothing was installed, and nothing will be built in its place"
                return 1
                ;;
        esac
    fi

    if [ "$use_release" = true ]; then
        # The download is the build. Stamp its identity from the clone, which
        # acquire_release_build left detached at the commit being installed,
        # then record where it came from.
        if write_build_identity "$UPDATE_SRC" "$RELEASE_TREE"; then
            stamp_release_provenance "$RELEASE_TREE/TBDBuildIdentity.json" \
                "$(manifest_field "$RELEASE_TREE" runUrl || true)" \
                "$(manifest_field "$RELEASE_TREE" builtAt || true)" \
                || log "WARNING: could not record the release provenance"
        else
            log "WARNING: no build identity stamped"
        fi
        # The products the download does not carry are built here, into
        # SwiftPM's own directory, and copied into the tree. The link is
        # handed to SwiftPM for the build and put back on failure, so a
        # failed compile leaves a reboot respawning what is running now.
        previous_release_target="$(link_target "$release_link" || true)"
        release_link_yield_to_swiftpm "$release_link" "$PREBUILT_HOME"
        local local_build_dir
        if ! build_products "$UPDATE_SRC" "${RELEASE_LOCAL_PRODUCTS[@]}" ||
            ! local_build_dir="$(swiftpm_build_dir "$UPDATE_SRC" "$BUILD_CONFIG")" ||
            ! merge_local_products "$local_build_dir" "$RELEASE_TREE"; then
            restore_release_link "$release_link" "$previous_release_target"
            log_error "could not build ${RELEASE_LOCAL_PRODUCTS[*]} to go with the download — the running installation is untouched"
            return 1
        fi
        if [ "$OPT_DRY_RUN" = true ]; then
            restore_release_link "$release_link" "$previous_release_target"
            log "dry run: downloaded and verified ${new_commit:-unknown} into $RELEASE_TREE, installing nothing"
            print_summary "$old_commit" "$new_commit" \
                "$(commits_advanced "$old_commit" "$new_commit" || true)" 0 0 0
            return 0
        fi
        # Installing the download on disk is pointing .build/release at it:
        # the handover, the app's reboot respawn and the CLI link all look
        # there already. What it pointed at before is kept above, so a failed
        # link or a failed handover can put it back.
        if ! point_release_link "$release_link" "$RELEASE_TREE"; then
            restore_release_link "$release_link" "$previous_release_target"
            log_error "could not point $release_link at $RELEASE_TREE (a real directory there, or a failed rename) — the running installation is untouched"
            return 1
        fi
        release_link_moved=true
        log "pointed $release_link at $RELEASE_TREE"
    else
        # A local build owns .build/release: hand it back to SwiftPM if a
        # download holds it. What it named is kept, and every exit short of a
        # completed install puts it back, so a failed compile or handover
        # leaves a reboot respawning the downloaded tree that is running now
        # rather than a partial or missing TBDDaemon.
        previous_release_target="$(link_target "$release_link" || true)"
        release_link_yield_to_swiftpm "$release_link" "$PREBUILT_HOME"
        if ! build_products "$UPDATE_SRC"; then
            restore_release_link "$release_link" "$previous_release_target"
            return 1
        fi

        # Stamp only now that the build actually succeeded. This used to run
        # BEFORE build_products, on the theory that the sidecar should always
        # name the same commit as the binaries beside it — but a build that then
        # FAILED left the opposite: a sidecar naming the commit that was
        # attempted, sitting next to binaries that were never touched, with
        # nothing to ever put it right, since the only later write in this same
        # clone is the next update's — success or failure. `$UPDATE_SRC` is one
        # long-lived clone every update reuses (see docs/updating.md), so that
        # wrong sidecar persists until this clone next builds successfully: any
        # `tbd version` or manual inspection pointed at it in the meantime learns
        # about a commit whose fix, or whose bug, was never actually built.
        # Moving the write here removes the premature half entirely — there is
        # now one write site, sequenced after success, so there is nothing to
        # roll back on failure and no separate temp file to manage.
        write_build_identity "$UPDATE_SRC" "$build_dir" || log "WARNING: no build identity stamped"
    fi

    local advanced
    advanced="$(commits_advanced "$old_commit" "$new_commit" || true)"

    # Put .build/release back where it was when this run started. After the
    # link was pointed at the download it goes back to exactly what it named;
    # before that (and on the local-build path) only a download it was taken
    # from needs putting back, since SwiftPM's own directory is SwiftPM's.
    #
    # Non-zero, with the failure logged, when the link could not be put back.
    # It then still names the new build, and an app that finds no daemon
    # starts one from it, so the failed-handover path relaunches nothing.
    put_release_link_back() {
        if [ "$release_link_moved" = true ]; then
            if [ -n "$previous_release_target" ]; then
                if ! point_release_link "$release_link" "$previous_release_target"; then
                    log_error "could not point $release_link back at $previous_release_target"
                    return 1
                fi
                log "pointed $release_link back at $previous_release_target"
            elif ! rm -f "$release_link"; then
                log_error "could not remove $release_link, which names the new build"
                return 1
            fi
        elif ! restore_release_link "$release_link" "$previous_release_target"; then
            log_error "could not point $release_link back at $previous_release_target"
            return 1
        fi
    }

    if [ "$OPT_DRY_RUN" = true ]; then
        put_release_link_back
        log "dry run: built $BUILD_CONFIG at ${new_commit:-unknown}, installing nothing"
        print_summary "$old_commit" "$new_commit" "$advanced" 0 0 0
        return 0
    fi

    log "assembling and installing the app bundle"
    assemble_app_bundle "$UPDATE_SRC" "$build_dir" "$PATH" || {
        put_release_link_back
        log_error "could not assemble the app bundle"
        return 1
    }
    local bundle_dir
    bundle_dir="$(bundle_dir_for_build "$build_dir")"
    sign_app_bundle "$bundle_dir" || {
        put_release_link_back
        log_error "could not sign the app bundle"
        return 1
    }

    # Up to here nothing outside the update clone has changed: walking away
    # costs a wasted build and nothing else. From here the running
    # installation moves. The app goes first, so that no viewer is attached
    # when the daemon changes hands (see stop_app_before_handover); from this
    # line on, every way out of the run launches it again, save an
    # interruption while the installation is moving and a failed handover
    # whose rollback did not complete.
    stop_app_before_handover

    # install_and_handover says at each line what undoing that line costs.
    # INSTALL_IN_FLIGHT covers the stretch where an exit it never returns from
    # (a signal, or an `exit` inside it) would leave an installation this run
    # cannot name: on_update_exit then reports it and leaves the app stopped
    # rather than relaunching into it. It goes up before the first thing moves
    # and comes down once the run knows where it stands again.
    INSTALL_IN_FLIGHT=true
    if ! install_and_handover "$bundle_dir" "$INSTALLED_BUNDLE" "$build_dir/TBDDaemon"; then
        # install_and_handover has put the previous app bundle back, or set
        # BUNDLE_RESTORE_FAILED. Put the daemon path back with it, so a reboot
        # respawns the build that is still running. Then the app, in that
        # order: an app that finds no daemon starts one from that path. The
        # flag stays up until both halves are known to have worked, so an exit
        # before then still leaves the app stopped rather than launching it
        # against a bundle or a path that may name the new build.
        local link_restored=true
        put_release_link_back || link_restored=false
        if [ "$BUNDLE_RESTORE_FAILED" = false ] && [ "$link_restored" = true ]; then
            INSTALL_IN_FLIGHT=false
            relaunch_stopped_app
        else
            # Half a rollback leaves what an interruption does: an app
            # launched now could drive, or start, a daemon from another
            # build. restore_previous_bundle and put_release_link_back have
            # each logged which half failed.
            log_error "the rollback of the failed install did not complete; the installed app and the daemon it would reach or start may be different builds"
            leave_app_stopped_for_recovery
        fi
        return 1
    fi
    INSTALL_IN_FLIGHT=false

    # The install completed. The tree that was live when this run started is
    # now the rollback, paired with ~/tbd/updates/previous/TBD.app; the exit
    # reconcile keeps it and the new live tree and removes everything older.
    record_prebuilt_rollback "$PREBUILT_HOME" "$PREBUILT_START_LIVE"

    refresh_installed_cli "$build_dir/TBDCLI"

    run_app_stage

    run_wake_stage "${HANDOVER_STARTED:-}"

    print_summary "$old_commit" "$new_commit" "$advanced" \
        "${WAKE_CANDIDATES:-0}" "${WAKE_WOKEN:-0}" "${WAKE_FAILED:-0}"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    main "$@"
    exit $?
fi
