#!/usr/bin/env bash
#
# Prints a stable fingerprint of the REAL `~/tbd`, `~/.claude`, `~/.codex`, the
# tmux socket directory and `~/Library/Preferences` — deliberately `$HOME/...`
# and the CALLER's `$TMUX_TMPDIR`, never `$TBD_HOME` / `$TBD_CLAUDE_HOST_HOME` /
# `$TBD_TEST_CODEX_HOME` or the fenced socket dir, because the whole point is
# to observe the directories a test run is supposed to leave alone even while
# those overrides point somewhere else.
#
# The last of those five is the one no override could have redirected anyway:
# `cfprefsd` resolves preference paths over XPC and ignores both home variables,
# so a leaked `UserDefaults(suiteName:)` plist lands in the developer's real
# `~/Library/Preferences` however the run is fenced. Its two arms at the bottom
# are the only layer that can see one — and the second half of that guard is
# the container reclaim in `scripts/test.sh`, which is what keeps the count at
# zero rather than merely reporting it.
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
real_codex="${HOME}/.codex"
# The shared tmux socket directory, resolved exactly as tmux resolves it for a
# `-L <name>` invocation. Read from the CALLER's environment, the same
# deliberate choice as `$HOME` above: `scripts/test.sh` applies its overrides
# as an `env` prefix on the run rather than exporting them, so this script sees
# the real directory on both sides of the run while the run itself sees the
# fenced one.
real_tmux="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"

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

# ~/.codex — the third host store, reachable by the same class of leak.
# `CodexHomeManager.ensureProfilePlugin()` creates directories under it and
# writes a plugin manifest, a hooks file, a skill and a `tbd.config.toml`. It
# was outside every layer of the fence until the `.codex` decoy and
# `TBD_TEST_CODEX_HOME` landed in `scripts/test.sh`, and isolation depended on
# individual tests remembering to override it.
#
# TWO arms, for the same reason `~/.claude` has two, and depth 1 on both.
#
#   `~/.codex` at depth 1 — catches `tbd.config.toml`, which
#   `CodexProfileWriter.ensureProfile` writes right there, and a run that
#   creates `~/.codex` itself. A deeper walk would report the machine rather
#   than the run: Codex rewrites `.tmp/`, `shell_snapshots/`, `sessions/` and
#   several multi-hundred-MB sqlite sidecars continuously while any Codex
#   session is live.
#
#   `~/.codex/plugins/cache` at depth 1 — the `<marketplace>` entries, where
#   `CodexPluginWriter.writePlugin` lands (`plugins/cache/tbd/tbd/local/...`).
#   That is depth 3 overall and invisible to the arm above on any box that
#   already has a `plugins` directory.
if [ -d "$real_codex" ]; then
  find "$real_codex" -maxdepth 1 \
    \( "${name_args[@]}" -print \) \
    2>/dev/null \
    | sed "s|^${real_codex}|~/.codex|" \
    | LC_ALL=C sort
else
  echo "~/.codex <absent>"
fi

# `-mindepth 1`, so the `plugins` entry itself is not printed twice.
if [ -d "$real_codex/plugins/cache" ]; then
  find "$real_codex/plugins/cache" -mindepth 1 -maxdepth 1 \
    \( "${name_args[@]}" -print \) \
    2>/dev/null \
    | sed "s|^${real_codex}|~/.codex|" \
    | LC_ALL=C sort
else
  echo "~/.codex/plugins/cache <absent>"
fi

# The tmux socket directory — the fourth root, and the only one that is not a
# dot-directory in `$HOME`. It is flat, so depth 1 sees everything: one socket
# file per server, named after the `-L <name>` it was started with.
#
# WHAT IT CATCHES. A run that starts a tmux server with `TMUX_TMPDIR` dropped
# from its environment leaves a socket file here — and leaves it FOREVER, because
# tmux does not unlink its socket when the server exits; it unlinks a stale one
# lazily at bind time, when a new server claims that exact path. Since every
# test mints a fresh UUID-suffixed name, nothing ever reclaims one. ~7,100 dead
# files accumulated in one real socket directory over nine days that way, behind
# 7 live servers. A new name here is therefore permanent litter, which is exactly
# the shape this detector is good at seeing.
#
# WHAT IT CANNOT SEE, and why detection stays CI-only. On a developer box a live
# daemon and every live TBD session legitimately create `tbd-<hex>` sockets here
# throughout a run, so this arm reports the machine rather than the run and would
# be switched off within a week. On a runner nothing else creates them, and any
# entry appearing between the two snapshots came from the suite. It also cannot
# attribute: it names the socket, not the code that opened it — that is what
# `TMUX_TMPDIR` in the fence is for, since a fenced run cannot produce the entry
# at all.
if [ -d "$real_tmux" ]; then
  find "$real_tmux" -maxdepth 1 \
    \( "${name_args[@]}" -print \) \
    2>/dev/null \
    | sed "s|^${real_tmux}|<tmux-sockets>|" \
    | LC_ALL=C sort
else
  echo "<tmux-sockets> <absent>"
fi

# ~/Library/Preferences — the fifth root, and the only one the fence cannot
# reach at all. `UserDefaults(suiteName: "X")` is backed by
# `$HOME/Library/Preferences/X.plist` (never `ByHost/`, measured at the
# CFPreferences level), and that `~` is the REAL user home whatever this run's
# `HOME` and `CFFIXED_USER_HOME` say: `cfprefsd` resolves preference paths over
# XPC, in its own process, so both variables are simply not in the lookup.
# `Tests/CLAUDE.md` had said so all along and the leak shipped anyway —
# ~520,000 orphaned files, ~2.1 GB, accumulated over months.
#
# THE SHAPE THIS WATCHES IS A CONTAINER, NOT A SCATTER, and that is what makes
# the arm affordable. `Tests/TestSupport/UserDefaultsTestSupport.swift` names
# every suite `TBDTests.suites/<label>.<uuid>`; a `/` in a suite name makes
# `cfprefsd` write into a SUBDIRECTORY of `~/Library/Preferences`, so every
# backing file this repo can produce lands in one directory that can be read,
# and reclaimed, without ever enumerating the parent.
#
# WHY THE FILES OUTLIVE THE TEST PROCESS AT ALL, which is the fact the whole
# design turns on: no in-process teardown order can win. Six orderings were
# measured, ten trials each — remove/sync/unlink, unlink-first, poll-until-
# flushed, `removeSuite(named:)`, per-key `removeObject`, and an
# `atexit`-registered second unlink — and all 60 files were back after the
# process exited. `cfprefsd` holds the domain in memory and flushes it when its
# client DISCONNECTS, strictly after every `atexit` handler a process can run.
# The unlink is real (the file is gone the moment teardown returns); it is just
# never the last word. So the reclaim has to happen after the test process is
# gone, which is `scripts/test.sh`'s job, and this arm is what proves it did it.
#
# THE SHAPE, AS OBSERVED rather than assumed — read out of a binary compiled
# from the committed helper:
#
#   containerDirectory = <real home>/Library/Preferences/TBDTests.suites
#   suite.name         = TBDTests.suites/<label>.<uuid>
#   backingPlistPath   = <containerDirectory>/<label>.<uuid>.plist
#   container is a DIR = true
#   depth-1 TBDTests.* = ["TBDTests.suites"]  ← exactly one match, the container
#
# That last line is why the obvious arm does not work. A flat
# `-name 'TBDTests.*'` count at depth 1 reads 1 before the run and 1 after it,
# forever, and can never go red: the only thing it can see is the container
# directory, which is not the population. The count has to go INSIDE.
#
# TWO ARMS, AND THEY ASK DIFFERENT QUESTIONS AT DIFFERENT PRICES.
#
#   `<preferences>/TBDTests.suites` — how many suite plists are in the
#   container. The steady state is 0, on BOTH sides: `scripts/test.sh` reclaims
#   the container before the first snapshot and again after the run, so a
#   non-zero count here means the reclaim did not happen or could not finish.
#   This is the arm that sees the leak this file exists for, and it is CHEAP —
#   it reads one small directory we own, never the parent.
#
#   `<preferences> stray TBDTests.*` — a depth-1 `TBDTests.*` entry that is NOT
#   the container: a suite minted with the historical flat name, by hand,
#   without the helper. The reclaim cannot remove one (it deletes exactly one
#   path and never a glob), so this count is not self-clearing, and a stray is
#   permanent litter until somebody removes it. This is the EXPENSIVE arm, and
#   the only expensive thing this script does to `~/Library/Preferences`: the
#   filter still costs one readdir of a directory that holds tens of thousands
#   of entries on an ordinary box. It earns that: it is the only thing standing
#   between one hand-rolled `UserDefaults(suiteName:)` and another half-million
#   files.
#
# COUNTS, NOT LISTINGS, in both arms — the one deliberate departure from every
# other arm in this file. `~/Library/Preferences` holds tens of thousands of
# entries on an ordinary box and half a million on a box that has been leaking;
# printing them would bury the diff and the report both. A leak reads as
# `count=0` becoming `count=1`, which is all a bracketing comparison needs.
#
# AND AN ABSENT CONTAINER IS `count=0`, NOT `<absent>` — the second departure,
# and it is deliberate. Every other arm treats "the directory is not there" as
# its own state, because a run that CREATES `~/tbd` must go red. Here the
# reclaim's success IS the directory being gone, so `<absent>` would be the
# steady state; and an empty container (a concurrent run that just minted one
# and leaked nothing) would then differ from an absent one and redden a run
# that did nothing wrong. Absent and empty are the same fact — no test
# preference files exist — so they get the same line.
#
# WHAT IT CANNOT SEE, stated plainly rather than dressed up:
#
#   - WHICH suite leaked. The count says a leak happened, not who did it. The
#     names are in the container when it goes red; read them there, from the
#     one directory it is safe to list.
#   - A suite minted with neither the helper nor the `TBDTests.` prefix. The
#     patterns are exact, and they have to be: `com.apple.*` and every other
#     domain on the box churn continuously while a run is in flight, so an arm
#     that counted them would report the machine rather than the run and be
#     switched off within a week. The helper in `Tests/TestSupport` is
#     therefore the only sanctioned way to mint a suite, and this arm covers
#     TBD's own tests exactly to the extent that rule is followed.
#   - Anything at all under CONCURRENCY. ~40 worktrees share one real
#     `~/Library/Preferences`, and one run's `fingerprint_after` can see
#     another run's in-flight container files. Wiping the container underneath a
#     live run is safe — `cfprefsd` serves a live domain from memory, measured —
#     but the COUNT is shared state, so a developer box can read a number that
#     belongs to somebody else's run. That is one more reason detection is
#     CI-only, where there is one run per machine.
#   - A non-`.plist` entry inside the container. The count is narrowed to
#     `*.plist` so a temp file cfprefsd is midway through writing — one of
#     ~40 concurrent worktrees, on a developer box — is not read as a leak.
#     Anything else in there is still REMOVED by the reclaim, which deletes the
#     directory wholesale and does not care what it is named; it is just not
#     counted.
#   - Anything quickly, on a box that already has a pile — for the stray arm
#     only. It has to readdir the whole parent to filter it, and a bare `ls -f`
#     on the leaking box above took over two minutes. The container arm reads
#     one small directory and is free anywhere. On a runner both are free.
real_prefs="${HOME}/Library/Preferences"
# DUPLICATED FROM SWIFT, DELIBERATELY, AND PINNED BY A TEST. The name lives in
# `TestDefaults.containerName` (`Tests/TestSupport/UserDefaultsTestSupport.swift`)
# and is repeated here and in `scripts/test.sh`, because the only ways to
# derive it at runtime are worse than the duplication: reading the Swift file
# needs a repo-relative path this script does not have (the harness runs
# mutated COPIES of it from a temp directory), and an environment override
# would make a guard that a caller can silently disarm.
# `scripts/test.test.sh`'s `test_the_container_name_matches_the_swift_helper`
# asserts all three copies agree, so a rename reddens the `lint` job rather
# than quietly emptying this arm.
prefs_container_name='TBDTests.suites'
prefs_container="$real_prefs/$prefs_container_name"

# `-name '*.plist'` doubles as the reason no `-mindepth` is needed: the
# container directory does not match its own filter.
if [ -d "$prefs_container" ]; then
  prefs_container_count="$(find "$prefs_container" -maxdepth 1 -name '*.plist' -print 2>/dev/null | wc -l | tr -d ' ')"
else
  prefs_container_count=0
fi
echo "<preferences>/$prefs_container_name count=$prefs_container_count"

# The container is excluded only when it is the DIRECTORY it is supposed to be:
# a regular file sitting at that exact path is not a container, it is litter,
# and the arm above cannot see it either.
if [ -d "$real_prefs" ]; then
  prefs_stray_count="$(find "$real_prefs" -mindepth 1 -maxdepth 1 \
      -name 'TBDTests.*' ! \( -name "$prefs_container_name" -a -type d \) -print 2>/dev/null \
    | wc -l | tr -d ' ')"
else
  prefs_stray_count=0
fi
echo "<preferences> stray TBDTests.* count=$prefs_stray_count"
