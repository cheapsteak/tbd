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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/debug"

app_only=false
daemon_only=false
skip_build=false

for arg in "$@"; do
    case "$arg" in
        --app) app_only=true ;;
        --daemon) daemon_only=true ;;
        --quick) skip_build=true ;;
    esac
done

# MARK: - Build

if [ "$skip_build" = false ]; then
    echo "Building..."
    t0=$SECONDS
    (cd "$REPO_ROOT" && swift build) 2>&1 | tail -3
    echo "  Build: $((SECONDS - t0))s"
fi

# MARK: - Assemble TBD.app bundle
#
# macOS resolves tbd:// URLs via LaunchServices, which requires a
# CFBundleURLTypes entry in an Info.plist inside a .app bundle. We assemble
# a minimal bundle in .build/debug/TBD.app whose binary is a symlink to
# .build/debug/TBDApp, so swift build continues to update it directly.

BUNDLE_DIR="$BUILD_DIR/TBD.app"
BUNDLE_MACOS="$BUNDLE_DIR/Contents/MacOS"
BUNDLE_PLIST="$BUNDLE_DIR/Contents/Info.plist"
SOURCE_PLIST="$REPO_ROOT/Resources/TBDApp.Info.plist"

mkdir -p "$BUNDLE_MACOS"

# Symlink the binary (idempotent).
# Path is relative to $BUNDLE_MACOS (.build/debug/TBD.app/Contents/MacOS),
# so three "..") gets us back to .build/debug/.
ln -sf "../../../TBDApp" "$BUNDLE_MACOS/TBDApp"

# Resolve the symlink to the absolute real path the OS will exec (open(1)
# resolves symlinks before exec, so the running TBDApp's command line will
# contain this exact path). We use it as the pgrep/pkill match target so
# we never match unrelated processes whose command line happens to
# contain the repo path or the string "TBDApp".
APP_EXEC_PATH="$(/usr/bin/readlink -f "$BUNDLE_MACOS/TBDApp")"
APP_EXEC_PATTERN="$(printf '%s' "$APP_EXEC_PATH" | sed 's/\./\\./g')"

# Copy the Info.plist if missing or older than the source.
plist_changed=false
if [ ! -f "$BUNDLE_PLIST" ] || [ "$SOURCE_PLIST" -nt "$BUNDLE_PLIST" ]; then
    cp "$SOURCE_PLIST" "$BUNDLE_PLIST"
    plist_changed=true
fi

# Re-register with LaunchServices when the plist changes (URL scheme update).
if [ "$plist_changed" = true ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -f "$BUNDLE_DIR" >/dev/null 2>&1 || true
        echo "  Registered tbd:// URL scheme"
    fi
fi

# MARK: - Restart Daemon

if [ "$app_only" = false ]; then
    echo "Stopping daemon..."
    if [ -f ~/tbd/tbdd.pid ]; then
        pid=$(cat ~/tbd/tbdd.pid)
        kill "$pid" 2>/dev/null && sleep 0.5 || true
    fi
    # Clean stale files
    rm -f ~/tbd/sock ~/tbd/tbdd.pid ~/tbd/port

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
fi

# MARK: - Restart App

if [ "$daemon_only" = false ]; then
    echo "Stopping app..."
    # Match end-anchored against the resolved exec path so we only ever
    # affect THIS worktree's running TBDApp — never swift build subprocesses,
    # editors, or sibling worktrees whose command line contains "TBDApp".
    pkill -f "^${APP_EXEC_PATTERN}\$" 2>/dev/null && sleep 0.3 || true

    echo "Starting app..."
    open "$BUNDLE_DIR" --stdout /tmp/tbdapp.log --stderr /tmp/tbdapp.log
    # `open` returns immediately after asking LaunchServices to spawn the app.
    # Give it a moment, then verify the process is alive.
    sleep 0.5
    if pgrep -f "^${APP_EXEC_PATTERN}\$" >/dev/null; then
        APP_PID=$(pgrep -f "^${APP_EXEC_PATTERN}\$" | head -1)
        echo "  App launched (PID $APP_PID) — logs: /tmp/tbdapp.log"
    else
        echo "  ERROR: App failed to launch. Last lines of /tmp/tbdapp.log:"
        tail -20 /tmp/tbdapp.log
    fi
fi

echo "Done. Tmux sessions preserved."
