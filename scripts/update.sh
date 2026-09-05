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

# How long to wait for the successor daemon to report itself, in seconds. A
# cold start behind a release build has taken tens of seconds; two minutes is
# generously past that and still bounded.
HANDOVER_TIMEOUT=120

# How long a successor that has to be stopped gets to exit on SIGTERM before
# it is killed, in seconds. It only runs on the failure path, so it is short:
# the process being stopped has already missed a two-minute deadline.
HANDOVER_STOP_GRACE=5

# MARK: - Derived paths

UPDATE_SRC="$UPDATE_HOME/src"
UPDATE_LOG="$UPDATE_HOME/update.log"
UPDATE_LOCK="$UPDATE_HOME/update.lock"
TBD_HOME_DIR="${TBD_HOME:-$HOME/tbd}"
DAEMON_PID_FILE="$TBD_HOME_DIR/tbdd.pid"
DAEMON_LOG="/tmp/tbdd.log"
APP_LOG="/tmp/tbdapp.log"
INSTALLED_BUNDLE="/Applications/TBD.app"
PREVIOUS_BUNDLE="$UPDATE_HOME/previous/TBD.app"
CLI_INSTALL_PATH="$HOME/.local/bin/tbd"

UPDATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT_PATH="$UPDATE_SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# MARK: - Options (set by parse_args)

OPT_CHECK=false
OPT_DRY_RUN=false
OPT_DEBUG=false
OPT_NO_APP=false
OPT_NO_WAKE=false
OPT_WAKE_ONLY=false
OPT_AUTO=false
OPT_REMOTE=""

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
  --no-app         Do not restart TBDApp. The daemon still hands over.
  --no-wake        Do not wake sessions the new daemon parked.
  --wake-only      Wake recovery-parked sessions against the daemon that is
                   already running. Builds and installs nothing.
  --auto           Non-interactive. Logs to the update log only, and refuses
                   to run while another update holds the lock.
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
    local fetched="$UPDATE_SRC/scripts/update.sh"
    if should_reexec "$fetched" "$UPDATE_SCRIPT_PATH"; then
        log "re-exec: the fetched update.sh differs from the running one"
        # Carry the lock across. `exec` replaces the image but keeps the pid,
        # so the file already names the process that is about to run; clearing
        # the trap stops the outgoing image from deleting it on the way out.
        trap - EXIT
        TBD_UPDATE_REEXEC=1 exec bash "$fetched" "$@"
    fi
}

# MARK: - Build

build_products() {
    local repo_root="${1-}"
    local shared_module_cache="$HOME/Library/Caches/tbd/swift-module-cache"
    local module_cache_flags product build_out

    mkdir -p "$shared_module_cache"
    # The same shared clang/Swift module cache restart.sh uses: without it
    # every tree accumulates its own ~640 MB of near-identical modules.
    module_cache_flags=(
        -Xswiftc -module-cache-path -Xswiftc "$shared_module_cache"
        -Xcc "-fmodules-cache-path=$shared_module_cache"
    )

    # SwiftPM honors only the last --product, so these are separate
    # invocations. TBDCLI is built too: `tbd update` is run through that binary,
    # and an update that leaves the CLI behind reports a version it is not.
    for product in TBDDaemon TBDApp TBDCLI; do
        log "building $product ($BUILD_CONFIG)"
        # Capture the status, THEN print. Piping the build into `tail` would
        # make the pipeline's status tail's, which is always zero.
        if ! build_out="$( (cd "$repo_root" && scripts/swift-safe build \
                -c "$BUILD_CONFIG" --product "$product" \
                "${module_cache_flags[@]}") 2>&1 )"; then
            printf '%s\n' "$build_out" | tail -20 >&2
            log_error "build of $product failed — the running installation is untouched"
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
stash_installed_bundle() {
    local installed_bundle="${1:-$INSTALLED_BUNDLE}"
    if [ ! -d "$installed_bundle" ]; then
        log "nothing installed at $installed_bundle — keeping no previous bundle"
        return 0
    fi
    mkdir -p "$(dirname "$PREVIOUS_BUNDLE")" || return 1
    rm -rf "$PREVIOUS_BUNDLE"
    if ! mv "$installed_bundle" "$PREVIOUS_BUNDLE"; then
        log_error "could not move $installed_bundle aside — installing nothing"
        return 1
    fi
    log "kept the previous app bundle at $PREVIOUS_BUNDLE"
}

# Put the kept bundle back where it was and tell LaunchServices. Called when
# the installation is in place but the daemon behind it is not, which would
# otherwise leave a new app talking to an old daemon.
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

# Put the new bundle in place and move the fleet onto it, undoing the
# installation if the successor daemon never arrives.
#
#   install_and_handover <bundle_dir> <installed_bundle> <new_daemon>
#
# Sets HANDOVER_STARTED to the moment the handover began, which is the cutoff
# the wake sweep filters parked sessions against.
install_and_handover() {
    local bundle_dir="${1-}"
    local installed_bundle="${2-}"
    local new_daemon="${3-}"

    # Keeping the previous bundle: undone by moving it back, which is what the
    # two failure paths below do.
    stash_installed_bundle "$installed_bundle" || return 1

    # Installing: the new bundle replaces the old one on disk. The RUNNING app
    # is untouched — it holds its executable by inode — so this is still
    # reversible until something launches from the new path.
    #
    # It happens BEFORE the handover on purpose. During the socket gap the app
    # may decide the daemon is missing and spawn one, and the daemon it spawns
    # is the one named by the bundle's SourceWorktreePath. That must already be
    # the update clone, or a rescue spawn in that window reinstates the old
    # binary underneath the new install.
    if ! install_app_bundle "$bundle_dir" "$installed_bundle"; then
        log_error "could not install to $installed_bundle"
        restore_previous_bundle "$installed_bundle"
        return 1
    fi

    # The handover is the one step with no undo: the predecessor daemon is
    # gone. Everything before it can still be put back, and a handover that
    # never completes does exactly that with the bundle, leaving the operator
    # on the build they started the day with rather than a new app driving an
    # old daemon.
    HANDOVER_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! handover "$new_daemon"; then
        restore_previous_bundle "$installed_bundle"
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

# Poll `tbd daemon status` until it reports the executable we just installed.
wait_for_daemon_executable() {
    local expected="${1-}"
    local timeout="${2:-$HANDOVER_TIMEOUT}"
    local waited=0
    local reported

    while [ "$waited" -lt "$timeout" ]; do
        reported="$(json_field "$(daemon_status_json)" executablePath)"
        if [ -n "$reported" ] && paths_match "$reported" "$expected"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Start the successor with TBD_HANDOVER_FROM_PID set. It claims the pid file
# before it signals its predecessor, so the app's respawn watchdog — and any
# stray restart.sh — finds a live daemon in that file from the first instant
# and exits at the single-instance gate instead of racing us.
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

    if wait_for_daemon_executable "$new_daemon" "$HANDOVER_TIMEOUT"; then
        log "daemon is serving from $new_daemon"
        return 0
    fi
    log_error "the new daemon did not report itself within ${HANDOVER_TIMEOUT}s — see $DAEMON_LOG"
    stop_handover_successor "$new_pid" || true
    return 1
}

# Stop the successor a failed handover started, so that after the caller puts
# the previous bundle back no daemon from the new build is left running.
#
#   stop_handover_successor <pid>
#
# SIGTERM first, then a bounded wait, then SIGKILL. Every outcome is logged,
# including the one this cannot fix: a process that survives SIGKILL, where
# the operator has to be told which pid to look at. A pid that is already gone
# is the ordinary case for a successor that crashed rather than stalled.
stop_handover_successor() {
    local pid="${1-}"
    local waited=0

    [ -n "$pid" ] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
        log "the new daemon (pid $pid) is not running; nothing to stop"
        return 0
    fi

    log "stopping the new daemon (pid $pid) so the rollback leaves no daemon from the new build"
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$waited" -lt "$HANDOVER_STOP_GRACE" ]; do
        sleep 1
        waited=$((waited + 1))
        if ! kill -0 "$pid" 2>/dev/null; then
            log "the new daemon (pid $pid) stopped"
            return 0
        fi
    done

    log "the new daemon (pid $pid) ignored SIGTERM for ${HANDOVER_STOP_GRACE}s — killing it"
    kill -KILL "$pid" 2>/dev/null || true
    waited=0
    while [ "$waited" -lt 3 ]; do
        sleep 1
        waited=$((waited + 1))
        if ! kill -0 "$pid" 2>/dev/null; then
            log "the new daemon (pid $pid) stopped after SIGKILL"
            return 0
        fi
    done
    log "WARNING: the new daemon (pid $pid) is still running after SIGKILL"
    return 1
}

# MARK: - The app

# The app restart, with its opt-out. Separate from restart_app so both branches
# are reachable from a test. A failed relaunch is logged, not fatal: the daemon
# has already handed over and the app is only a viewer.
run_app_stage() {
    if [ "$OPT_NO_APP" = true ]; then
        log "--no-app: leaving the running app alone"
        return 0
    fi
    restart_app || true
}

restart_app() {
    local pattern pid
    pattern="$(escape_exec_pattern "$INSTALLED_BUNDLE/Contents/MacOS/TBDApp")"
    log "restarting the app"
    stop_app_process "$pattern"
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
    local batch_ids id result_dir

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

        for id in "${batch_ids[@]}"; do
            (
                if out="$(tbd terminal wake --terminal "$id" --json 2>&1)"; then
                    printf 'ok %s\n' "$id" > "$result_dir/$id"
                else
                    printf 'fail %s %s\n' "$id" "$(printf '%s' "$out" | tr '\n' ' ')" \
                        > "$result_dir/$id"
                fi
            ) &
        done
        wait
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
            head="$(git ls-remote "$remote_url" refs/heads/main 2>/dev/null | awk '{print $1}')"
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

# MARK: - main

main() {
    local rc=0
    parse_args "$@" || { rc=$?; [ "$rc" -eq 10 ] && return 0; return "$rc"; }

    # shellcheck source=/dev/null
    source "$UPDATE_SCRIPT_DIR/restart-bundle-lib.sh"

    if [ "$OPT_CHECK" = true ]; then
        run_check
        return 0
    fi

    acquire_lock || return 1
    trap release_lock EXIT

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
    fetch_latest || return 1
    maybe_reexec "$@"

    local new_commit build_dir
    new_commit="$(git -C "$UPDATE_SRC" rev-parse HEAD 2>/dev/null || true)"
    log "latest main is ${new_commit:-unknown}"
    build_dir="$UPDATE_SRC/.build/$BUILD_CONFIG"

    # Stamp before the compiler runs so the sidecar and the binaries beside it
    # name the same commit. A clone that has never been built has no
    # .build/<config> yet and the stamp defers — expected, and silenced here
    # because the retry below covers it.
    write_build_identity "$UPDATE_SRC" "$build_dir" >/dev/null 2>&1 || true
    build_products "$UPDATE_SRC" || return 1
    if [ ! -f "$build_dir/TBDBuildIdentity.json" ]; then
        write_build_identity "$UPDATE_SRC" "$build_dir" || log "WARNING: no build identity stamped"
    fi

    local advanced
    advanced="$(commits_advanced "$old_commit" "$new_commit" || true)"

    if [ "$OPT_DRY_RUN" = true ]; then
        log "dry run: built $BUILD_CONFIG at ${new_commit:-unknown}, installing nothing"
        print_summary "$old_commit" "$new_commit" "$advanced" 0 0 0
        return 0
    fi

    log "assembling and installing the app bundle"
    assemble_app_bundle "$UPDATE_SRC" "$build_dir" "$PATH" || {
        log_error "could not assemble the app bundle"
        return 1
    }
    local bundle_dir
    bundle_dir="$(bundle_dir_for_build "$build_dir")"
    sign_app_bundle "$bundle_dir" || { log_error "could not sign the app bundle"; return 1; }

    # Up to here nothing outside the update clone has changed: walking away
    # costs a wasted build and nothing else. install_and_handover is where the
    # running installation moves, and it says at each line what undoing that
    # line costs.
    install_and_handover "$bundle_dir" "$INSTALLED_BUNDLE" "$build_dir/TBDDaemon" \
        || return 1

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
