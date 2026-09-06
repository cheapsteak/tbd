#!/usr/bin/env bash
set -e

# TBD restart script
# Rebuilds, restarts daemon and app. Tmux sessions survive.
#
# Usage:
#   scripts/restart.sh          # rebuild + restart everything
#   scripts/restart.sh --app    # restart app only (no rebuild, no daemon restart)
#   scripts/restart.sh --daemon # restart daemon only (no rebuild, no app restart)
#   scripts/restart.sh --quick  # skip rebuild, restart everything
#   scripts/restart.sh --dry-run # print install-ready/not-install-ready decision, touch nothing
#   scripts/restart.sh --wip    # force install even if on a WIP branch
#   scripts/restart.sh --release # build/launch optimized (-c release) instead of debug
#   TBD_INSTALL_WIP=1 scripts/restart.sh # same as --wip

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

# The shell that installs this bundle defines the PATH contract for every TBD
# process launched from it. Reject a missing contract before any build or
# installation work begins.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/restart-environment-lib.sh"
require_restart_path "${PATH-}"

# Bundle assembly, signing, installation and app process control. Shared with
# scripts/update.sh so both installers produce the same bundle.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/restart-bundle-lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

app_only=false
daemon_only=false
skip_build=false
dry_run=false
force_wip=false
build_config=debug

for arg in "$@"; do
    case "$arg" in
        --app) app_only=true ;;
        --daemon) daemon_only=true ;;
        --quick) skip_build=true ;;
        --dry-run) dry_run=true ;;
        --wip) force_wip=true ;;
        --release) build_config=release ;;
    esac
done

# Everything downstream (bundle assembly, daemon launch, pgrep patterns)
# derives from BUILD_DIR, so pointing it at the release layout is the whole
# of --release. Set after arg parsing since the flag decides it.
BUILD_DIR="$REPO_ROOT/.build/$build_config"

# Check TBD_INSTALL_WIP env var as well
if [ -n "${TBD_INSTALL_WIP:-}" ]; then
    force_wip=true
fi

# MARK: - WIP Guard
#
# Install-ready builds (clean install-affecting paths + HEAD on/before main)
# install to /Applications and restart the shared daemon. WIP builds warn and
# launch from .build only. Escape hatch: --wip / TBD_INSTALL_WIP=1. Helpers
# live in a sourceable lib so they can be unit-tested
# (scripts/restart-guard-lib.test.sh).
source "$REPO_ROOT/scripts/restart-guard-lib.sh"

# Determine install strategy and possibly print dry-run summary.
build_is_install_ready=false
install_to_applications=true

if ! is_build_install_ready; then
    build_is_install_ready=false
    if [ "$force_wip" = false ]; then
        install_to_applications=false
    fi
else
    build_is_install_ready=true
fi

if [ "$dry_run" = true ]; then
    if [ "$build_is_install_ready" = true ]; then
        echo "INSTALL-READY: Install-affecting paths are clean and HEAD is on/before main."
        echo "Would install to /Applications and restart daemon."
    else
        echo "NOT INSTALL-READY: WIP branch or dirty install-affecting paths."
        if [ "$force_wip" = true ]; then
            echo "Would install to /Applications and restart daemon (--wip override)."
        else
            echo "Would SKIP /Applications install and daemon restart."
            echo "Would launch app from .build/$build_config/TBD.app instead."
        fi
    fi
    exit 0
fi

# Print warning if not install-ready (unless --wip forces it).
if [ "$build_is_install_ready" = false ] && [ "$force_wip" = false ]; then
    warn_wip_build
fi

# MARK: - Opportunistic background disk reclaim
#
# Every restart is a good moment to garbage-collect stale .build directories
# across all worktrees (scripts/reclaim-build.sh) — it's already safe to run
# at any time (skips active builds and anything touched <10 min ago), and
# RECLAIM_EXCLUDE_PATH pins this worktree out of the sweep entirely, so the
# reclaim can never race the swift build it overlaps (a ≥48h-stale .build
# here — a revived dormant worktree — would otherwise be Tier-2 eligible at
# plan time, before the new build has touched it). So kick it off now,
# before the build below, so the two overlap instead of the reclaim adding
# to wall-clock time. Fully async and fire-and-forget: never
# blocks restart.sh, never fails it, and outlives this script (and the
# terminal). nohup alone is sufficient detachment here: this shell is
# non-interactive (job control / monitor mode is off, so the child is never
# tied to a terminal job), nohup makes it immune to SIGHUP, and all three
# fds are redirected away from the terminal. Silent — output appends to
# ~/Library/Logs/tbd-reclaim-build.log, the same file the hourly launchd
# agent writes to. Opt out with TBD_SKIP_RECLAIM=1.
RECLAIM_SCRIPT="$REPO_ROOT/scripts/reclaim-build.sh"
if [ -z "${TBD_SKIP_RECLAIM:-}" ] && [ -x "$RECLAIM_SCRIPT" ]; then
    RECLAIM_EXCLUDE_PATH="$REPO_ROOT" nohup "$RECLAIM_SCRIPT" >> "$HOME/Library/Logs/tbd-reclaim-build.log" 2>&1 < /dev/null &
fi

# MARK: - Opportunistic background scratchpad sweep
#
# Same fire-and-forget contract as the reclaim above: remove orphaned Claude
# Code per-worktree scratchpads under /private/tmp/claude-<uid> whose worktree
# is gone and which have been untouched for days (scripts/sweep-scratchpads.sh).
# Shares the reclaim log file and the TBD_SKIP_RECLAIM opt-out.
SWEEP_SCRIPT="$REPO_ROOT/scripts/sweep-scratchpads.sh"
if [ -z "${TBD_SKIP_RECLAIM:-}" ] && [ -x "$SWEEP_SCRIPT" ]; then
    nohup "$SWEEP_SCRIPT" >> "$HOME/Library/Logs/tbd-reclaim-build.log" 2>&1 < /dev/null &
fi

# MARK: - Build
#
# Shared clang/Swift module cache across ALL TBD worktrees. By default every
# worktree's `.build` accumulates its own ~640 MB ModuleCache with near-
# identical contents; pointing both the Swift frontend (-module-cache-path)
# and clang (-fmodules-cache-path, reaches the C-shim dependency targets like
# CNIOAtomics) at one $HOME-level directory keeps a single ~610 MB copy total,
# concurrency-safe across parallel builds. Verified empirically (Swift 6.2.4):
# local ModuleCache drops to ~0 MB with this flag combo.
#
# Stickiness note: SwiftPM bakes the cache path into .build/debug.yaml at plan
# time, so a later build in this worktree silently keeps using
# the shared cache until a manifest re-plan — expected, not a bug. See
# docs/reclaim-build.md ("Shared module cache").
SHARED_MODULE_CACHE="$HOME/Library/Caches/tbd/swift-module-cache"
mkdir -p "$SHARED_MODULE_CACHE"
MODULE_CACHE_FLAGS=(
    -Xswiftc -module-cache-path -Xswiftc "$SHARED_MODULE_CACHE"
    -Xcc -fmodules-cache-path="$SHARED_MODULE_CACHE"
)

# Stamp the build identity BEFORE the compiler runs, so the sidecar beside a
# binary always names the tree that binary came from. A build that skips this
# (a tree with no git HEAD) leaves no sidecar, and the loader falls back to the
# worktree's own HEAD — see docs/updating.md.
if ! write_build_identity "$REPO_ROOT" "$BUILD_DIR"; then
    echo "warning: build identity not stamped — binaries will report a fallback identity" >&2
fi

if [ "$skip_build" = false ]; then
    echo "Building..."
    t0=$SECONDS
    # Build the runtime PRODUCTS rather than the whole package.
    #
    # A whole-package build compiles the test targets too, and
    # Tests/TestSupport does `@testable import TBDDaemonLib`, which needs
    # testability enabled. Debug builds enable it by default; release builds
    # do NOT, so `swift build -c release` always fails with
    # ModuleNotTestable — after having already linked both products. That
    # made --release look like it worked (correct binaries on disk) while
    # reporting failure, and it is why the exit code below could not be
    # checked before this change.
    #
    # SwiftPM honors only the LAST --product, so each is its own invocation.
    # The list is RUNTIME_PRODUCTS in restart-bundle-lib.sh, shared with
    # scripts/update.sh: the daemon, the app, and every helper the daemon
    # looks for beside its own binary (see the list for what each one does
    # when it is missing). The test targets are scripts/test.sh's job, not
    # the restart path's.
    build_ok=true
    for product in "${RUNTIME_PRODUCTS[@]}"; do
        # Capture the status, THEN print. Piping the build straight into
        # `tail` would make the pipeline's status `tail`'s (always 0) — the
        # very status-discarding bug this block exists to fix.
        if ! build_out=$( (cd "$REPO_ROOT" && scripts/swift-safe build \
                -c "$build_config" --product "$product" \
                "${MODULE_CACHE_FLAGS[@]}") 2>&1 ); then
            build_ok=false
            # The rest would build behind the same machine-global lock and
            # scroll the failure off the screen, and the restart below is
            # abandoned either way.
            printf '%s\n' "$build_out" | tail -3
            break
        fi
        printf '%s\n' "$build_out" | tail -3
    done
    echo "  Build: $((SECONDS - t0))s"

    # Stop on a failed build. Previously the build was piped straight to
    # `tail`, discarding its status, so a broken build fell through to the
    # bundle assembly and daemon restart and silently relaunched the STALE
    # binary — a failed build that looked like a successful restart.
    if [ "$build_ok" = false ]; then
        echo "ERROR: build failed — not restarting. The running daemon/app are unchanged." >&2
        exit 1
    fi
fi

# MARK: - Assemble TBD.app bundle
#
# The assembly, signing and installation live in scripts/restart-bundle-lib.sh
# so scripts/update.sh produces the same bundle from the update clone. See
# that file for why the bundle exists (LaunchServices needs a real .app to
# deliver tbd:// URLs), why its binary is a hard link, and why installing to
# /Applications is what makes notification permissions stick.

# The build may have created .build/<config> for the first time, in which case
# the stamp above deferred. Stamp now, before the bundle copies the sidecar in.
if [ ! -f "$BUILD_DIR/TBDBuildIdentity.json" ]; then
    write_build_identity "$REPO_ROOT" "$BUILD_DIR" || true
fi

BUNDLE_DIR="$(bundle_dir_for_build "$BUILD_DIR")"
assemble_app_bundle "$REPO_ROOT" "$BUILD_DIR" "$PATH"

# Conditionally sign + install to /Applications (only if install-ready or --wip).
# For WIP builds not install-ready, we'll skip this and launch from .build/debug instead.
INSTALLED_BUNDLE="/Applications/TBD.app"
BUNDLED_EXEC_PATH="$INSTALLED_BUNDLE/Contents/MacOS/TBDApp"
APP_EXEC_PATTERN=""

# THIS worktree's bundle binary, resolved and escaped for end-anchored
# pgrep/pkill. Needed on both paths: it's the launch target on the WIP path,
# and on the install path it identifies a leftover WIP instance launched from
# this worktree's .build bundle before the install. Never matches sibling
# worktrees — their bundles live under their own paths.
WORKTREE_EXEC_PATH="$(resolve_exec_path "$BUNDLE_DIR/Contents/MacOS/TBDApp")"
WORKTREE_EXEC_PATTERN="$(escape_exec_pattern "$WORKTREE_EXEC_PATH")"

if [ "$install_to_applications" = true ]; then
    sign_app_bundle "$BUNDLE_DIR"
    install_app_bundle "$BUNDLE_DIR" "$INSTALLED_BUNDLE"

    # The running TBDApp's command line is the installed bundle's binary, since
    # we launch from /Applications below. Match against that for pgrep/pkill so
    # we only ever affect THIS worktree's running TBDApp (it's the one that most
    # recently won /Applications). Sibling worktrees launched from their own
    # .build/.../TBD.app would not match.
    APP_EXEC_PATTERN="$(escape_exec_pattern "$BUNDLED_EXEC_PATH")"
else
    # WIP build: skip /Applications install, launch from .build/debug instead.
    # We launch via `open "$BUNDLE_DIR"` below, so the running process's
    # command line is the bundle binary (.../TBD.app/Contents/MacOS/TBDApp),
    # not the unwrapped swift-build output. Match pgrep/pkill against the
    # resolved bundle path so the end-anchored pattern actually hits.
    APP_EXEC_PATTERN="$WORKTREE_EXEC_PATTERN"
fi

# MARK: - Restart Daemon

if [ "$app_only" = false ] && [ "$install_to_applications" = true ]; then
    echo "Stopping daemon..."
    if [ -f ~/tbd/tbdd.pid ]; then
        pid=$(cat ~/tbd/tbdd.pid)
        kill "$pid" 2>/dev/null && sleep 0.5 || true
    fi
    # Clean stale files
    rm -f ~/tbd/sock ~/tbd/tbdd.pid ~/tbd/port

    # Preserve the previous daemon's log for post-mortem diagnostics — the
    # daemon does not persist os.Logger output, so this file is the only
    # record of a crash that happened before a restart.
    [ -f /tmp/tbdd.log ] && mv /tmp/tbdd.log /tmp/tbdd.log.1
    echo "Starting daemon..."
    "$BUILD_DIR/TBDDaemon" > /tmp/tbdd.log 2>&1 &
    # Wait for socket
    for i in $(seq 1 30); do
        [ -S ~/tbd/sock ] && break
        sleep 0.1
    done
    if [ -S ~/tbd/sock ]; then
        echo "  Daemon ready (PID $(cat ~/tbd/tbdd.pid 2>/dev/null))"
    else
        echo "  WARNING: Daemon socket not found after 3s"
    fi
elif [ "$app_only" = false ] && [ "$install_to_applications" = false ]; then
    echo "(Skipping daemon restart for WIP worktree)"
fi

# MARK: - Restart App

if [ "$daemon_only" = false ]; then
    echo "Stopping app..."
    # Match end-anchored against the resolved exec path so we only ever
    # affect THIS worktree's running TBDApp — never swift build subprocesses,
    # editors, or sibling worktrees whose command line contains "TBDApp".
    stop_app_process "$APP_EXEC_PATTERN"
    # On a full install, also kill a leftover WIP instance launched from THIS
    # worktree's own .build bundle (before the install), or two TBDApp
    # processes survive. Still never touches sibling worktrees. On the WIP
    # path the patterns are identical, so this is skipped — no double-kill.
    if [ "$install_to_applications" = true ] && [ -n "$WORKTREE_EXEC_PATTERN" ] \
        && [ "$WORKTREE_EXEC_PATTERN" != "$APP_EXEC_PATTERN" ]; then
        stop_app_process "$WORKTREE_EXEC_PATTERN"
    fi

    echo "Starting app..."
    if [ "$install_to_applications" = true ]; then
        # Launch from /Applications (install-ready or --wip override)
        launch_app_bundle "$INSTALLED_BUNDLE" "$PATH" /tmp/tbdapp.log
    else
        # Launch from .build/<config> (WIP worktree, no install to /Applications)
        launch_app_bundle "$BUNDLE_DIR" "$PATH" /tmp/tbdapp.log
    fi

    # `open` returns immediately after asking LaunchServices to spawn the app.
    # Give it a moment, then verify the process is alive.
    sleep 0.5
    if APP_PID="$(app_process_pid "$APP_EXEC_PATTERN")"; then
        if [ "$install_to_applications" = true ]; then
            echo "  App launched from /Applications (PID $APP_PID) — logs: /tmp/tbdapp.log"
        else
            echo "  App launched from .build/$build_config (PID $APP_PID) — logs: /tmp/tbdapp.log"
        fi
    else
        echo "  ERROR: App failed to launch. Last lines of /tmp/tbdapp.log:"
        tail -20 /tmp/tbdapp.log
    fi
fi

if [ "$install_to_applications" = false ] && [ "$daemon_only" = false ]; then
    echo ""
    echo "Note: Deep links (tbd://) will NOT route to this app. Restart the"
    echo "intended worktree to make it the handler for tbd:// URLs."
fi

echo "Done. Tmux sessions preserved."
