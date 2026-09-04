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

# MARK: - Derived paths

UPDATE_SRC="$UPDATE_HOME/src"
UPDATE_LOG="$UPDATE_HOME/update.log"
UPDATE_LOCK="$UPDATE_HOME/update.lock"
TBD_HOME_DIR="${TBD_HOME:-$HOME/tbd}"
DAEMON_PID_FILE="$TBD_HOME_DIR/tbdd.pid"
DAEMON_LOG="/tmp/tbdd.log"
APP_LOG="/tmp/tbdapp.log"
INSTALLED_BUNDLE="/Applications/TBD.app"
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
log_error() {
    log "ERROR: $*"
    if [ "$OPT_AUTO" = true ]; then
        printf 'error: %s\n' "$*" >&2
    fi
    return 1
}

# MARK: - Lock

# True when the lock file exists and names a process that is still running. A
# lock left by a crashed run names a pid that is gone and is taken over.
lock_is_live() {
    local lock_file="${1-}"
    local pid
    [ -f "$lock_file" ] || return 1
    pid="$(head -1 "$lock_file" 2>/dev/null | tr -dc '0-9')"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

acquire_lock() {
    mkdir -p "$UPDATE_HOME" || return 1
    if lock_is_live "$UPDATE_LOCK"; then
        log_error "another update is already running (pid $(head -1 "$UPDATE_LOCK")). Its log is $UPDATE_LOG"
        return 1
    fi
    printf '%s\n' "$$" > "$UPDATE_LOCK" || return 1
    UPDATE_LOCK_HELD=true
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
        release_lock
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
handover() {
    local new_daemon="${1-}"
    local old_pid

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

    if wait_for_daemon_executable "$new_daemon" "$HANDOVER_TIMEOUT"; then
        log "daemon is serving from $new_daemon"
        return 0
    fi
    log_error "the new daemon did not report itself within ${HANDOVER_TIMEOUT}s — see $DAEMON_LOG"
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

    rows=""
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        local one
        one="$(tbd terminal list "$id" --json 2>/dev/null)" || continue
        rows="$rows$one"$'\n'
    done <<< "$ids"

    printf '%s' "$rows" | python3 -c '
import json, sys
out = []
buffer = ""
depth = 0
for chunk in sys.stdin.read().splitlines():
    buffer += chunk + "\n"
    depth += chunk.count("[") - chunk.count("]")
    if buffer.strip() and depth == 0:
        try:
            out.extend(json.loads(buffer))
        except Exception:
            pass
        buffer = ""
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

    result_dir="$(mktemp -d "${TMPDIR:-/tmp}/tbd-update-wake.XXXXXX")" || return 1

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
                if [ -n "$running" ] && [ "$running" = "$head" ]; then
                    relation="upToDate"
                else
                    relation="behind"
                fi
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
        *) log "Unknown — the daemon has not compared itself to main yet." ;;
    esac
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
    install_app_bundle "$bundle_dir" "$INSTALLED_BUNDLE" || {
        log_error "could not install to $INSTALLED_BUNDLE"
        return 1
    }

    # Everything above this line is reversible by walking away; the handover is
    # where the running installation changes.
    local handover_started
    handover_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    handover "$build_dir/TBDDaemon" || return 1

    refresh_installed_cli "$build_dir/TBDCLI"

    run_app_stage

    run_wake_stage "$handover_started"

    print_summary "$old_commit" "$new_commit" "$advanced" \
        "${WAKE_CANDIDATES:-0}" "${WAKE_WOKEN:-0}" "${WAKE_FAILED:-0}"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    main "$@"
    exit $?
fi
