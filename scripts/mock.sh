#!/usr/bin/env bash
set -euo pipefail

# TBD mock harness: launches an ISOLATED daemon+app pair seeded from a committed
# fixture, for UI development and staged screenshots. It never touches ~/tbd or
# the /Applications bundle, so the developer's real instance is undisturbed.
#
#   scripts/mock.sh up [scenario]   # build if needed, seed, launch daemon+app
#   scripts/mock.sh down            # kill the mock pair, remove its scratch home
#   scripts/mock.sh shot <name>     # screenshot the mock window -> artifacts/mock/
#   scripts/mock.sh restart [scen]  # rebuild, then down + up

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/debug"
STATE_DIR="/tmp/tbd-mock"            # short paths keep the socket under sun_path's ~104-byte cap
MOCK_HOME="$STATE_DIR/home"
MOCK_SOCK="$STATE_DIR/sock"
DAEMON_PIDFILE="$STATE_DIR/daemon.pid"
APP_PIDFILE="$STATE_DIR/app.pid"
DAEMON_LOG="$STATE_DIR/daemon.log"
APP_LOG="$STATE_DIR/app.log"
ARTIFACTS="$REPO_ROOT/artifacts/mock"

cmd="${1:-}"; shift || true

kill_pidfile() { # $1 = pidfile
    if [ -f "$1" ]; then
        local pid; pid="$(cat "$1" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "$1"
    fi
}

assemble_bundle() {
    # Minimal .build/debug/TBD.app so direct-exec resolves Bundle.main. Does NOT
    # install to /Applications or re-sign — the real instance keeps LaunchServices.
    local bundle="$BUILD_DIR/TBD.app"
    mkdir -p "$bundle/Contents/MacOS"
    local exec_path; exec_path="$(/usr/bin/readlink -f "$BUILD_DIR/TBDApp")"
    ln -f "$exec_path" "$bundle/Contents/MacOS/TBDApp"
    local src_plist="$REPO_ROOT/Resources/TBDApp.Info.plist"
    if [ ! -f "$bundle/Contents/Info.plist" ] || [ "$src_plist" -nt "$bundle/Contents/Info.plist" ]; then
        cp "$src_plist" "$bundle/Contents/Info.plist"
    fi
}

up() {
    local scenario="${1:-default}"
    local fixture="$REPO_ROOT/Tests/Fixtures/mock-state/scenario-$scenario.json"
    [ -f "$fixture" ] || { echo "No fixture: $fixture" >&2; exit 1; }

    echo "Building..."
    (cd "$REPO_ROOT" && swift build) 2>&1 | tail -3

    down_quiet
    mkdir -p "$STATE_DIR" "$MOCK_HOME"
    assemble_bundle

    export TBD_HOME="$MOCK_HOME"
    export TBD_SOCKET_PATH="$MOCK_SOCK"
    export TBD_MOCK=1
    export TBD_MOCK_FIXTURE="$fixture"

    echo "Starting mock daemon..."
    "$BUILD_DIR/TBDDaemon" > "$DAEMON_LOG" 2>&1 &
    echo $! > "$DAEMON_PIDFILE"
    for _ in $(seq 1 30); do [ -S "$MOCK_SOCK" ] && break; sleep 0.1; done
    [ -S "$MOCK_SOCK" ] || { echo "Daemon socket not ready; see $DAEMON_LOG" >&2; exit 1; }

    echo "Starting mock app (scenario: $scenario)..."
    "$BUILD_DIR/TBD.app/Contents/MacOS/TBDApp" > "$APP_LOG" 2>&1 &
    echo $! > "$APP_PIDFILE"
    sleep 1
    echo "  daemon PID $(cat "$DAEMON_PIDFILE")  app PID $(cat "$APP_PIDFILE")"
    echo "  home: $MOCK_HOME  logs: $DAEMON_LOG / $APP_LOG"
}

down_quiet() { kill_pidfile "$APP_PIDFILE"; kill_pidfile "$DAEMON_PIDFILE"; rm -f "$MOCK_SOCK"; }

down() {
    down_quiet
    rm -rf "$MOCK_HOME"
    echo "Mock instance down; ~/tbd untouched."
}

shot() {
    local name="${1:?usage: mock.sh shot <name>}"
    [ -f "$APP_PIDFILE" ] || { echo "No mock app running (run: mock.sh up)" >&2; exit 1; }
    local pid; pid="$(cat "$APP_PIDFILE")"
    mkdir -p "$ARTIFACTS"
    local window_id
    window_id="$(swift "$REPO_ROOT/scripts/mock-window-id.swift" "$pid")" \
        || { echo "Could not find a window for PID $pid" >&2; exit 1; }
    screencapture -o -x -l"$window_id" "$ARTIFACTS/$name.png"
    echo "Saved $ARTIFACTS/$name.png (window $window_id)"
}

case "$cmd" in
    up)      up "${1:-default}" ;;
    down)    down ;;
    shot)    shot "${1:-}" ;;
    restart) (cd "$REPO_ROOT" && swift build) 2>&1 | tail -3; down; up "${1:-default}" ;;
    *) echo "usage: mock.sh {up [scenario]|down|shot <name>|restart [scenario]}" >&2; exit 1 ;;
esac
