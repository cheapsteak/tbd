#!/usr/bin/env bash
set -euo pipefail

# One-shot: move TBD's home directory from ~/.tbd to ~/tbd.
#
# Why: TBD now uses a visible ~/tbd directory instead of the hidden ~/.tbd.
# This script does the safe stop -> rename -> symlink -> restart dance.
#
# Safe to re-run: it refuses if ~/tbd already exists.
#
# Leaves a transitional symlink at ~/.tbd -> tbd as a safety net for any
# stray reference. After a week or two of confidence, you can:
#     rm ~/.tbd

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

OLD="$HOME/.tbd"
NEW="$HOME/tbd"

# Refuse if already migrated.
if [ -d "$NEW" ] && [ ! -L "$NEW" ]; then
    echo "~/tbd already exists. Nothing to do."
    if [ -L "$OLD" ]; then
        echo "  (~/.tbd is already a symlink to tbd — looks fine.)"
    fi
    exit 0
fi

# Refuse if old doesn't exist.
if [ ! -d "$OLD" ] || [ -L "$OLD" ]; then
    echo "~/.tbd is not a real directory. Nothing to move."
    exit 1
fi

echo "Stopping TBDApp..."
pkill -x TBDApp 2>/dev/null || true
sleep 0.3

echo "Stopping daemon..."
if [ -f "$OLD/tbdd.pid" ]; then
    pid=$(cat "$OLD/tbdd.pid")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" || true
        # Wait up to 5s for clean exit.
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Daemon $pid did not exit cleanly. Aborting."
            echo "  Investigate manually before re-running. (Do not kill -9 without knowing why.)"
            exit 1
        fi
    fi
fi

# Final safety: nothing TBD should be left running.
if pgrep -x TBDDaemon >/dev/null || pgrep -x TBDApp >/dev/null; then
    echo "TBD processes still running:"
    pgrep -lf 'TBDDaemon|TBDApp' || true
    echo "Aborting."
    exit 1
fi

echo "Renaming $OLD -> $NEW..."
mv "$OLD" "$NEW"

echo "Creating safety symlink ~/.tbd -> tbd..."
ln -s tbd "$OLD"

echo "Done moving. Restarting via scripts/restart.sh..."
"$REPO_ROOT/scripts/restart.sh"

echo
echo "Migration complete."
echo "  State now lives in: $NEW"
echo "  Transitional symlink: $OLD -> tbd"
echo
echo "Smoke test: create a new worktree in TBD and confirm it lands at"
echo "  ~/tbd/worktrees/<repo>/<name>"
echo
echo "After a week or two, remove the symlink with: rm ~/.tbd"
