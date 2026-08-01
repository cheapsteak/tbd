#!/usr/bin/env bash
#
# Prints a stable fingerprint of the REAL `~/tbd` — deliberately `$HOME/tbd`,
# never `$TBD_HOME`, because the whole point is to observe the directory a test
# run is supposed to leave alone even while `TBD_HOME` points somewhere else.
#
# Bracket a test run with two calls and diff them: any added or removed entry
# means something wrote into the developer's real config dir, which
# `CLAUDE.md` ("Tests must not touch ~/tbd") forbids. Once cost 18k orphan
# profile dirs and ~2.9k fake worktrees before anyone noticed.
#
# Depth 3 covers the whole tree, not just `profiles/`:
#   depth 1  a brand-new top-level directory nobody has thought of yet
#   depth 2  profiles/<id>, repos/<id>, scratch/<id>, worktrees/<slot>
#   depth 3  worktrees/<slot>/<name> — the shape the worktree leak took, and
#            invisible at depth 2 because the slot dir already existed
# It stops there on purpose: descending into a worktree means walking a full
# checkout, and a leak always announces itself at the root of one.
#
# NAMES ONLY — never sizes, never mtimes. `state.db`, `state.db-wal` and
# `state.db-shm` change size continuously while a daemon is live, so a
# size- or mtime-based fingerprint would go red on every run and be switched
# off inside a week. Their *names* are stable, which is what makes including
# them free: a migration run against the real `~/tbd` drops a brand-new
# `state.db.pre-migration.<timestamp>` next to them (63 such files, 1.0 GB,
# have accumulated on one box), and a new name is exactly what this catches.
set -euo pipefail

real_home="${HOME}/tbd"

if [ ! -d "$real_home" ]; then
  # Not "nothing to report": a run that CREATES ~/tbd must go red, so emit a
  # marker the comparison can see change.
  echo "<absent>"
  exit 0
fi

# Written by a live daemon on a developer box while an unrelated test run is in
# flight, so their churn is noise rather than signal. Each is a name in the
# TOP-LEVEL directory whose *contents* are skipped — the entry itself is still
# fingerprinted, so deleting one is still caught. Keep this list short: every
# name added here is a place a future leak could hide.
volatile_dirs=(
  runtime           # per-session runtime files, rewritten continuously
  terminal-history  # scrollback capture
  claude-tokens     # per-profile credential material
)

# The one name excluded outright. Finder creates and deletes `.DS_Store`
# wherever someone happens to browse, which has nothing to do with a test run.
#
# `sock`, `vend.sock`, `port` and `tbdd.pid` are deliberately NOT excluded:
# a daemon restart recreates them under the same names, so they are stable
# between two snapshots, and a test that opens a socket in the real config dir
# is precisely the kind of leak worth failing on.
volatile_names=(
  .DS_Store
)

prune_args=()
for d in "${volatile_dirs[@]}"; do
  prune_args+=(-path "$real_home/$d/*" -prune -o)
done

name_args=()
for n in "${volatile_names[@]}"; do
  name_args+=(! -name "$n")
done

find "$real_home" -maxdepth 3 \
  "${prune_args[@]}" \
  \( "${name_args[@]}" -print \) \
  2>/dev/null \
  | sed "s|^${real_home}|~/tbd|" \
  | LC_ALL=C sort
