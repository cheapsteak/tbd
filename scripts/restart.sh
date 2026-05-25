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
# zero extra disk and `swift build` continues to update it directly —
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

# Stash the source worktree path inside the bundle so the running app can
# show it in the status bar — it can no longer infer this from its own
# exec path now that it runs from /Applications instead of .build/.
printf '%s' "$REPO_ROOT" > "$BUNDLE_DIR/Contents/SourceWorktreePath.txt"

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
codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null

INSTALLED_BUNDLE="/Applications/TBD.app"
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
BUNDLED_EXEC_PATH="$INSTALLED_BUNDLE/Contents/MacOS/TBDApp"
APP_EXEC_PATTERN="$(printf '%s' "$BUNDLED_EXEC_PATH" | sed 's/[.+*?()\[\]^$|\\]/\\&/g')"

# MARK: - Restart Daemon

if [ "$app_only" = false ]; then
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
fi

# MARK: - Restart App

if [ "$daemon_only" = false ]; then
    echo "Stopping app..."
    # Match end-anchored against the resolved exec path so we only ever
    # affect THIS worktree's running TBDApp — never swift build subprocesses,
    # editors, or sibling worktrees whose command line contains "TBDApp".
    pkill -f "^${APP_EXEC_PATTERN}\$" 2>/dev/null && sleep 0.3 || true

    echo "Starting app..."
    open "$INSTALLED_BUNDLE" --stdout /tmp/tbdapp.log --stderr /tmp/tbdapp.log
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
