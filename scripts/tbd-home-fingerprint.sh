#!/usr/bin/env bash
#
# Prints a stable fingerprint of the REAL `~/tbd` and the REAL `~/.claude` —
# deliberately `$HOME/...`, never `$TBD_HOME` / `$TBD_CLAUDE_HOST_HOME`, because
# the whole point is to observe the directories a test run is supposed to leave
# alone even while those overrides point somewhere else.
#
# Bracket a test run with two calls and diff them: any added or removed entry
# means something wrote into a real store the run should not have touched, which
# `CLAUDE.md` ("Tests must not touch ~/tbd") forbids. Once cost 18k orphan
# profile dirs and ~2.9k fake worktrees before anyone noticed.
#
# Only `scripts/test.sh` — and only when its detection layer is enabled — should
# be diffing these. See that script's header for why detection is CI-only.
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
real_claude="${HOME}/.claude"

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

if [ -d "$real_home" ]; then
  find "$real_home" -maxdepth 3 \
    "${prune_args[@]}" \
    \( "${name_args[@]}" -print \) \
    2>/dev/null \
    | sed "s|^${real_home}|~/tbd|" \
    | LC_ALL=C sort
else
  # Not "nothing to report": a run that CREATES ~/tbd must go red, so emit a
  # marker the comparison can see change.
  echo "~/tbd <absent>"
fi

# ~/.claude — one directory over, and reachable by the same class of leak. A
# default-constructed `ClaudeProfileConfigDirManager` mirrors slots FROM this
# store into each profile dir, and `ensureMirrorSlot` creates directories in it,
# MOVES whole subtrees within it, and writes symlinks into it. Fencing only
# `TBD_HOME` looks complete and leaves this wide open, so the detector covers
# both or the same leak one directory over stays invisible.
#
# TWO arms, and the second is the one that catches the leak this code can
# actually produce.
#
#   `~/.claude` at depth 1 — the top-level shape. A leak cannot invent a name
#   here: `ensureMirrorSlot` opens with `guard fm.fileExists(atPath:
#   hostEntry.path) else { return }`, so every host-side write requires the
#   depth-1 slot to exist already. What this arm catches is a run that creates
#   `~/.claude` itself, or one that deletes/renames a slot out from under the
#   user — not a new slot appearing.
#
#   `~/.claude/projects` at depth 1 — the `<cwd-hash>` entries. THIS is where
#   the mutation lands: `mergeRecursive(src: cwdHashPath, dst: hostCwdHashPath)`
#   moves a profile's whole `projects/<cwd-hash>/` subtree into the host store,
#   which is depth 2 overall and invisible to the arm above.
#
# It stops there. Claude Code writes `projects/<slug>/*.jsonl` continuously
# while any session is live, so a deeper walk would report the machine rather
# than the run and get switched off within a week. A new `<cwd-hash>` directory
# is rare enough on a runner to be signal — which is also why detection is
# CI-only (see `scripts/test.sh`).
#
# On a CI runner `~/.claude` typically does not exist at all, so both arms read
# `<absent>` on either side. That is thinner coverage than on a populated box,
# not zero: a run that CREATES either directory flips `<absent>` to a listing
# and goes red. Stated plainly rather than dressed up.
if [ -d "$real_claude" ]; then
  find "$real_claude" -maxdepth 1 \
    \( "${name_args[@]}" -print \) \
    2>/dev/null \
    | sed "s|^${real_claude}|~/.claude|" \
    | LC_ALL=C sort
else
  echo "~/.claude <absent>"
fi

# `-mindepth 1`, so the `projects` entry itself is not printed twice — the arm
# above already covers it.
if [ -d "$real_claude/projects" ]; then
  find "$real_claude/projects" -mindepth 1 -maxdepth 1 \
    \( "${name_args[@]}" -print \) \
    2>/dev/null \
    | sed "s|^${real_claude}|~/.claude|" \
    | LC_ALL=C sort
else
  echo "~/.claude/projects <absent>"
fi
