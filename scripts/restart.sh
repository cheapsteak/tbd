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
#   TBD_INSTALL_WIP=1 scripts/restart.sh # same as --wip

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/debug"

app_only=false
daemon_only=false
skip_build=false
dry_run=false
force_wip=false

for arg in "$@"; do
    case "$arg" in
        --app) app_only=true ;;
        --daemon) daemon_only=true ;;
        --quick) skip_build=true ;;
        --dry-run) dry_run=true ;;
        --wip) force_wip=true ;;
    esac
done

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
            echo "Would launch app from .build/debug/TBD.app instead."
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

if [ "$skip_build" = false ]; then
    echo "Building..."
    t0=$SECONDS
    (cd "$REPO_ROOT" && scripts/swift-safe build "${MODULE_CACHE_FLAGS[@]}") 2>&1 | tail -3
    echo "  Build: $((SECONDS - t0))s"
fi

# MARK: - Assemble TBD.app bundle
#
# macOS resolves tbd:// URLs via LaunchServices, which requires a
# CFBundleURLTypes entry in an Info.plist inside a .app bundle. We assemble
# a minimal bundle in .build/debug/TBD.app whose binary is a symlink to
# .build/debug/TBDApp, so the governed Swift build updates it directly.

BUNDLE_DIR="$BUILD_DIR/TBD.app"
BUNDLE_MACOS="$BUNDLE_DIR/Contents/MacOS"
BUNDLE_PLIST="$BUNDLE_DIR/Contents/Info.plist"
SOURCE_PLIST="$REPO_ROOT/Resources/TBDApp.Info.plist"

mkdir -p "$BUNDLE_MACOS"

# Resolve the absolute real path of the swift-build output. We need this
# first so we can pass an absolute path to `ln` below (sidesteps any
# cwd-relative resolution issues) and so we have a stable pgrep/pkill
# match target later.
APP_EXEC_PATH="$(/usr/bin/readlink -f "$BUILD_DIR/TBDApp")"

# Hard link (not symlink) the binary into the bundle. Required for
# Bundle.main to resolve at runtime: open(1) resolves symlinks before
# exec, which would otherwise leave the process appearing to run from
# .build/.../TBDApp with no surrounding .app, so APIs that depend on
# CFBundleIdentifier (UNUserNotificationCenter for banners, etc.) silently
# fail. A hard link shares the same inode as the swift-build output —
# zero extra disk and the governed Swift build updates it directly —
# while keeping the kernel-reported exec path inside the .app bundle.
# `ln -f` replaces any existing entry (including a stale symlink from
# previous restart.sh versions) idempotently.
ln -f "$APP_EXEC_PATH" "$BUNDLE_MACOS/TBDApp"

# Copy the Info.plist if missing or older than the source.
if [ ! -f "$BUNDLE_PLIST" ] || [ "$SOURCE_PLIST" -nt "$BUNDLE_PLIST" ]; then
    cp "$SOURCE_PLIST" "$BUNDLE_PLIST"
fi

# Copy the on-disk AppIcon.icns into the bundle. macOS reads this for
# Notification Center banners, System Settings → Notifications, and Finder —
# none of those paths look at NSApp.applicationIconImage (which still drives
# the per-worktree Dock icon at runtime). Bake a new one with
# `swift run IconBaker Resources/AppIcon.icns` after changing
# Sources/TBDAppIcon/AppIcon.swift.
BUNDLE_RESOURCES="$BUNDLE_DIR/Contents/Resources"
SOURCE_ICON="$REPO_ROOT/Resources/AppIcon.icns"
BUNDLE_ICON="$BUNDLE_RESOURCES/AppIcon.icns"
mkdir -p "$BUNDLE_RESOURCES"
if [ ! -f "$BUNDLE_ICON" ] || [ "$SOURCE_ICON" -nt "$BUNDLE_ICON" ]; then
    cp "$SOURCE_ICON" "$BUNDLE_ICON"
fi

# Copy the TBD_TBDApp.bundle (resource bundle with localized strings and assets).
# SPM produces it in .build/arm64-apple-macosx/debug; it must be in the .app bundle
# or app launch fails with "could not load resource bundle".
# NOTE: $BUILD_DIR is a symlink to arm64-apple-macosx/debug, so we reach the bundle
# via $BUILD_DIR/TBD_TBDApp.bundle, not by composing a path with ../arm64-apple-macosx/debug.
SOURCE_RESOURCE_BUNDLE="$BUILD_DIR/TBD_TBDApp.bundle"
BUNDLE_RESOURCE_BUNDLE="$BUNDLE_RESOURCES/TBD_TBDApp.bundle"
if [ -d "$SOURCE_RESOURCE_BUNDLE" ]; then
    rm -rf "$BUNDLE_RESOURCE_BUNDLE"
    cp -R "$SOURCE_RESOURCE_BUNDLE" "$BUNDLE_RESOURCE_BUNDLE"
else
    echo "warning: TBD_TBDApp.bundle not found at $SOURCE_RESOURCE_BUNDLE" >&2
fi

# Stash the source worktree path inside the bundle so the running app can
# show it in the status bar — it can no longer infer this from its own
# exec path now that it runs from /Applications instead of .build/.
printf '%s' "$REPO_ROOT" > "$BUNDLE_DIR/Contents/SourceWorktreePath.txt"

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
WORKTREE_EXEC_PATH="$(/usr/bin/readlink -f "$BUNDLE_MACOS/TBDApp")"
WORKTREE_EXEC_PATTERN="$(printf '%s' "$WORKTREE_EXEC_PATH" | sed 's/[.+*?()\[\]^$|\\]/\\&/g')"

if [ "$install_to_applications" = true ]; then
    # Sign + install to /Applications to satisfy macOS UNUserNotificationCenter:
    #  - Re-signing with --force --deep makes the codesign identifier match
    #    CFBundleIdentifier (com.tbd.app); SPM's default ad-hoc signature uses
    #    TBDApp-<hash>, which macOS uses for permission tracking and rejects.
    #  - /Applications is the only path macOS 15 accepts for requestAuthorization;
    #    bundles elsewhere return UNErrorDomain Code=1 with no permission dialog.
    #  - cp -cR uses APFS clonefile (copy-on-write, ~zero disk cost).
    #  - All TBD worktrees share CFBundleIdentifier=com.tbd.app, so whichever
    #    worktree most recently ran restart.sh "wins" /Applications — same
    #    last-restart-wins behavior already documented for tbd:// URL routing.
    # Prefer a stable self-signed identity so TCC permission grants/denials persist
    # across rebuilds. Ad-hoc signing (`--sign -`) gives TCC only a bare cdhash with
    # no stable anchor, so every rebuild — and even repeated accesses within one
    # build, when access is attributed via a spawned child like a `claude` session —
    # fails the stored code-requirement check and re-prompts (Desktop/Documents/
    # Downloads/Photos/etc.). A persistent leaf-cert anchor fixes that.
    # One-time setup creates the "TBD Dev Signing" identity in a dedicated
    # tbd-signing keychain (see docs/tcc-signing.md). If it's absent (e.g. a fresh
    # clone or another contributor's machine), fall back to ad-hoc so restart still works.
    SIGN_KEYCHAIN="$HOME/Library/Keychains/tbd-signing.keychain-db"
    SIGN_IDENTITY="TBD Dev Signing"
    if security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
        security unlock-keychain -p tbd-signing "$SIGN_KEYCHAIN" 2>/dev/null || true
        codesign --force --deep --identifier com.github.cheapsteak.tbd \
            --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$BUNDLE_DIR" >/dev/null
    else
        codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null
    fi

    rm -rf "$INSTALLED_BUNDLE"
    cp -cR "$BUNDLE_DIR" "$INSTALLED_BUNDLE"

    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -f "$INSTALLED_BUNDLE" >/dev/null 2>&1 || true
    fi

    # Bump the installed bundle's mtime so Notification Center / System Settings
    # pick up an updated AppIcon.icns instead of serving a stale icon-cache entry.
    # `lsregister -f` alone doesn't always invalidate those caches; `touch` does.
    touch "$INSTALLED_BUNDLE"

    # The running TBDApp's command line is the installed bundle's binary, since
    # we launch from /Applications below. Match against that for pgrep/pkill so
    # we only ever affect THIS worktree's running TBDApp (it's the one that most
    # recently won /Applications). Sibling worktrees launched from their own
    # .build/.../TBD.app would not match.
    APP_EXEC_PATTERN="$(printf '%s' "$BUNDLED_EXEC_PATH" | sed 's/[.+*?()\[\]^$|\\]/\\&/g')"
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
    if [ -n "$APP_EXEC_PATTERN" ]; then
        pkill -f "^${APP_EXEC_PATTERN}\$" 2>/dev/null && sleep 0.3 || true
    fi
    # On a full install, also kill a leftover WIP instance launched from THIS
    # worktree's own .build bundle (before the install), or two TBDApp
    # processes survive. Still never touches sibling worktrees. On the WIP
    # path the patterns are identical, so this is skipped — no double-kill.
    if [ "$install_to_applications" = true ] && [ -n "$WORKTREE_EXEC_PATTERN" ] \
        && [ "$WORKTREE_EXEC_PATTERN" != "$APP_EXEC_PATTERN" ]; then
        pkill -f "^${WORKTREE_EXEC_PATTERN}\$" 2>/dev/null && sleep 0.3 || true
    fi

    echo "Starting app..."
    if [ "$install_to_applications" = true ]; then
        # Launch from /Applications (install-ready or --wip override)
        open "$INSTALLED_BUNDLE" --stdout /tmp/tbdapp.log --stderr /tmp/tbdapp.log
    else
        # Launch from .build/debug (WIP worktree, no install to /Applications)
        open "$BUNDLE_DIR" --stdout /tmp/tbdapp.log --stderr /tmp/tbdapp.log
    fi

    # `open` returns immediately after asking LaunchServices to spawn the app.
    # Give it a moment, then verify the process is alive.
    sleep 0.5
    if [ -n "$APP_EXEC_PATTERN" ] && pgrep -f "^${APP_EXEC_PATTERN}\$" >/dev/null; then
        APP_PID=$(pgrep -f "^${APP_EXEC_PATTERN}\$" | head -1)
        if [ "$install_to_applications" = true ]; then
            echo "  App launched from /Applications (PID $APP_PID) — logs: /tmp/tbdapp.log"
        else
            echo "  App launched from .build/debug (PID $APP_PID) — logs: /tmp/tbdapp.log"
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
