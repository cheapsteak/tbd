# Worktree deletion queue

Archiving a worktree is supposed to remove its directory from disk. Often it
does not, and nothing notices. This design replaces the deletion step with a
rename into a per-pool `.deleting/` queue, drained without a deadline, and
teaches the orphan-GC sweep to finish deletions that were interrupted.

## The problem

`completeArchiveWorktree` removes the directory with a single
`git worktree remove --force` subprocess. Every git subprocess is capped at
`GitManager.commandTimeout` (120 s) and escalated SIGTERM → SIGKILL when it
overruns. Removing a worktree means `unlink()`ing every file in it, and a
worktree of a large app repo is 200,000–235,000 filesystem entries and
3.5–7.5 GB — only about 3% of which (6,173 files) are tracked repo content.
The rest is `node_modules`, `.venv`, and `.direnv`.

Measured unlink throughput on a developer machine ranges from 587 entries/s
(six concurrent removals) to 3,100 entries/s (one removal, machine otherwise
quiet). One worktree therefore takes somewhere between 70 seconds and several
minutes. The 120 s cap sits inside that range rather than above it, so the
outcome is a coin flip that tilts with machine load.

Nothing about the machine makes this slow: Spotlight indexing is disabled on
both volumes, no Endpoint Security system extensions are registered, and there
are no APFS local snapshots. The cost is the file count itself.

When the cap is hit, git is killed partway through `remove_dir_recursively`.
Because git deletes the `.git/worktrees/<id>` administrative entry only after
the working-tree removal returns success, a killed removal leaves both a
half-deleted directory and a live git registration. The resulting
`GitTimeoutError` is discarded by a `try?` with no logging, inside a
fire-and-forget `Task.detached` whose failure no one observes. The row was
already flipped to `.archived` in phase 1, so the database reports the worktree
gone while gigabytes remain on disk.

The failure is silent, unbounded, and self-amplifying: each disk crisis
prompts mass archiving, mass archiving produces more surviving directories, and
those directories consume the disk that provoked the next crisis. A single
2026-08-06 batch archived twelve worktrees in two minutes; ten left husks,
stopping at scattered points between 20,000 and 190,000 entries deleted.

One consumer already defends against this. `OrphanGC.scratchpadCleanup`
re-checks that the directory is really gone before classifying a scratchpad as
orphaned, with a comment noting the removal is "`try?`-swallowed". The failure
mode was known at the boundary and never fixed at the source.

## Why deleting faster is not the fix

At the best throughput measured, a 225,000-entry worktree still needs about 73
seconds. Deleting a quarter-million files is inherently a minutes-long
operation on APFS, and concurrency does not rescue it — running six removals at
once raises aggregate throughput to 3,519 entries/s but drops each process to
587 entries/s, so no individual removal gets meaningfully closer to a deadline.
Any design that tries to fit this work inside a timeout is building on an
assumption the filesystem will not honor.

Renaming, by contrast, is one syscall. Moving a 199,690-entry, 7.5 GB tree took
**2.4 ms**, independent of its size.

## Design

### The commit point

The rename is the moment archiving becomes true. Once the directory has been
renamed out of its pool slot and `git worktree prune` has dropped the
registration, the worktree no longer exists as far as TBD and git are
concerned. Only byte reclamation remains, and that can take as long as it
needs.

`completeArchiveWorktree` becomes:

1. Run the archive hook, unchanged.
2. `deletionQueue.enqueue(worktreePath:)` — rename the directory into
   `<pool>/.deleting/<uuid>`.
3. `git worktree prune` in the owning repo — drops the registration. The branch
   survives, so revive still works.
4. Fire `onWorktreeRemoved`. This callback is finally truthful; today it fires
   even when removal failed, which is why its consumer had to re-check.
5. Detached, with no deadline: drain the queued entry.

This also unblocks revive. Today a surviving directory trips the
`worktreePathAlreadyExists` preflight, so a failed archive poisons the path
against the worktree that owns it.

### Failure stops being terminal

Every step logs on failure; the `try?` is removed. More importantly, an
interrupted drain is no longer a dead end. What remains is a directory inside
`.deleting/`, which is unambiguously garbage that TBD placed there itself. The
sweep finishes it. Compare today's outcome — a half-deleted directory sitting
in a live pool slot, still registered with git, distinguishable from a real
worktree only by cross-referencing the database.

### `WorktreeDeletionQueue`

A new type under `Sources/TBDDaemon/Lifecycle/` owning the queue contract and
nothing else:

- `queueDir(forPool:)` — `<pool>/.deleting`
- `enqueue(worktreePath:) throws -> QueuedDeletion` — rename into the queue
  under a fresh UUID
- `pending(pool:) -> [QueuedDeletion]` — enumerate entries awaiting reclamation
- `drain(_:) async` — delete an entry's bytes, resumable

No database access, no git, no timers. Testable on a temp directory.

The queue is a per-pool sibling of the worktree directories rather than one
global location, because `rename()` fails across filesystems (`EXDEV`) and pools
can live outside `TBD_HOME` — `<repo>/.tbd/worktrees/` may sit on another
volume. A sibling directory is same-volume by construction. Every loop that
enumerates a pool must skip the leading-dot entry.

### `DeletionQueueCollector`

A third collector under `Sources/TBDDaemon/GC/`, alongside
`AgentWorktreeCollector` and `ScratchpadCollector`, following their
`candidates` / `decide` / `reap` shape and their rule that every failure
direction favors keeping. It produces two kinds of work:

- **Queued deletions** — anything under a pool's `.deleting/`. Always
  reclaimable; TBD put it there.
- **Interrupted archives** — worktree rows with status `.archived` whose
  directory still exists, subject to the provenance gate below.

An interrupted archive is reclaimed by the same mechanism as a fresh one:
enqueue, prune, drain. Adoption is finishing an archive that stopped early, not
a second way to delete things.

`OrphanGC.sweep` gains a section for this collector, inheriting its hourly
cadence, its `gcEnabled` master switch, and its `ReapRecord` persistence, which
surfaces reclaimed directories in the existing history UI. The sweep already
loads every archived row in `reconcileScratchpads` and filters for directories
that are *gone*; the directories that remain are the exact inverse of a filter
it already computes.

`ReapKind` gains a case. It persists as a text column and unknown values are
skipped with a warning on decode, so no migration is required.

### Provenance gate

A database row is not proof that TBD created a directory. `adoptWorktree` can
point a row at a worktree TBD never made, and adopted worktrees may live
anywhere on disk. Reclaiming an interrupted archive therefore requires all of:

- The path lies under a TBD-owned prefix — `~/tbd/worktrees/<slot>/`,
  `<repo>/.tbd/worktrees/`, or `~/tbd/scratch/`. This is the same prefix notion
  `reconcile` already uses to decide what it may re-adopt.
- For a repo-backed worktree, `git.isLinkedWorktree(candidatePath:repoPath:)`
  passes — the directory's `.git` file resolves into `<repo>/.git/worktrees/`,
  proving it is a linked worktree of the repo the row names.
- For a scratch space, `repoID` is nil and the path is under `~/tbd/scratch/`.
  Scratch spaces are not linked worktrees of any repo, so linkage cannot apply;
  the namespace is TBD's own and is the available proof.
- The existing `locked` and live-cwd (`lsof`) gates pass, so a directory a live
  process is sitting in is never reclaimed.

Anything failing the gate is logged and skipped permanently. Measuring the
directories present when this was written, every repo-backed one satisfied the
linkage check.

`forgetWorktree` needs no special handling. It hard-deletes the row rather than
flipping it to `.archived`, so a directory the user deliberately kept can never
match "archived row whose directory exists."

### Error handling

- Enqueue fails (`EXDEV`, permissions) — fall back to `git worktree remove`
  with a raised timeout, and log at error level. The row stays archived; the
  sweep retries later.
- Prune fails — log; the next sweep prunes.
- Drain interrupted — the entry stays in `.deleting/`; the next sweep resumes.
- Provenance gate fails — log once per path; never reclaim.

No path silently swallows a failure.

## Flag policy

CLAUDE.md requires large or risky new behavior to ship behind a default-off
flag, and this qualifies on two counts: it replaces a load-bearing path and it
deletes state from a background sweep.

It ships without a new flag by maintainer decision. The reasoning: the bug is
actively destroying disk and worsening under its own effects, and a default-off
flag would leave the buggy path as the shipping default until graduation. The
behavior runs under the existing `gcEnabled` master switch, which already
defaults to true and already governs every other GC deletion, so the escape
hatch exists and is one toggle.

Two properties limit the risk. Reclamation touches only directories that pass
the provenance gate, and the enqueue step is strictly less destructive than the
`git worktree remove` it replaces — a rename is reversible until the drain
runs.

## Testing

`WorktreeDeletionQueue`: enqueue renames rather than copies; enqueue across
filesystems surfaces `EXDEV` rather than partially completing; drain is
resumable after interruption; `pending` enumerates what a previous run left.

`DeletionQueueCollector`: one test per keep-reason, matching the existing
collectors' style of a test per spec invariant — a worktree outside every
TBD-owned prefix, a repo-backed directory failing linkage, a locked worktree, a
directory with a live cwd. Plus the reclaim case, and a test that a forgotten
worktree's directory is never a candidate.

Archive path: enqueue is used on the success path; the `git worktree remove`
fallback is used when enqueue throws; `onWorktreeRemoved` fires only once the
path is actually gone.

Integration: archive a worktree and assert the pool slot is empty, `.deleting/`
drains, and `git worktree list` no longer registers it. Then assert an
interrupted archive — a directory restored into a pool slot under an archived
row — is reclaimed by one sweep.

Tests run under `scripts/test.sh` so `TBD_HOME` and the host stores stay
fenced. Any retry or poll takes an injected clock, per CLAUDE.md.

## Rejected alternatives

**Raise or remove the git timeout.** The cheapest change, and it addresses the
proximate cause. Rejected because it only widens a window that the filesystem
decides the width of: a slower machine, a larger dependency tree, or more
concurrent archives puts the operation back over any fixed bound, and the
failure mode returns unchanged. It survives only as the fallback when a rename
cannot be performed.

**Serialize archive deletions.** Running one removal at a time gives each the
full throughput of the volume. Rejected because the best measured single-stream
rate still needs about 73 seconds for a full worktree, so the largest cases
remain near the cap while every archive now waits behind the queue.

**Delete in place and reconcile afterwards.** Skip the rename; let the sweep
find and finish half-deleted directories. Rejected because it leaves the hard
problem intact — a half-deleted directory in a live pool slot is
indistinguishable from a real worktree without consulting the database, so
every reconciliation decision has to be made on inference. The rename converts
that inference into a fact about where the directory is.

**A grace period before reclaiming bytes.** Hold interrupted archives in
`.deleting/` for some days so a mistake could be noticed. Rejected because
archiving already promises the directory will be deleted; content that survived
did so only because of this bug, and a grace period would defer the disk
reclamation that motivates the work.
