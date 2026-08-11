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
5. Drain the queued entry inline, with no deadline attached.

Step 5 runs inline rather than in a task of its own because
`completeArchiveWorktree` is already the detached half of archiving: every
production caller — `worktree.archive`, `repo.remove`'s cascade, auto-archive
on merge — invokes it from a detached task, so a drain that takes minutes
blocks nothing an RPC waits on. Detaching again would only add a second
untracked task, and it would break the one caller that wants the wait: the
synchronous `archiveWorktree(worktreeID:force:)` wrapper, where archive
completion is meant to mean the bytes are gone.

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

A sweep drains its entries one at a time. Deleting several at once raises
aggregate throughput about fourfold (938 entries/s alone against 3,519 across
six concurrent deletions), but a background sweep that saturates the disk
competes with whatever the developer is doing, and nothing depends on the queue
draining quickly — an entry that waits an hour costs only the disk it already
occupies. Bounded concurrency stays available if serial draining proves too
slow in practice.

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
- **Stale registrations** — the mirror image: an archived row whose directory
  is gone while `git worktree list` still names it. That is what a prune
  failure (or a daemon killed between the rename and the prune) leaves behind,
  and it is the failure class this design exists to remove, so the sweep
  prunes the owning repo rather than letting the registration outlive its
  directory forever. Left in place it is permanent: revive's preflight refuses
  a path git still has registered.

An interrupted archive is reclaimed by the same mechanism as a fresh one:
measure, enqueue, prune, drain. Adoption is finishing an archive that stopped
early, not a second way to delete things. The measurement is `du -sk` before
the rename, exactly as the other two collectors measure before their removal,
so the reclaim shows up in the History UI as the gigabytes it actually was
rather than as zero.

Which pools get drained is a wider question than which directories may be
*reclaimed*. An adopted worktree can live anywhere, and archiving it puts a
`.deleting/` queue beside it, outside every layout prefix; a queue left there
by an interrupted drain would otherwise sit in the user's own directory
forever. So the sweep enumerates the layout prefixes, the scratch dir, and the
parent directory of every archived row's path. Draining needs no provenance
gate — a `.deleting/<uuid>` entry is there because TBD renamed it there — so
widening the pool list costs nothing in safety.

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
- The row names a repo. A repoless candidate — a scratch space, `repoID` nil —
  is **never** reclaimed, whatever namespace it sits in. Archiving a scratch
  space deliberately leaves its folder on disk (`scratch.archive` flips the row
  to `.archived` and moves nothing; unlike `scratch.delete`, nothing goes to
  Trash), and `scratch.revive` needs that folder to bring the space back. So
  "archived row whose directory exists" is the *normal, supported* state of an
  archived scratch space, not the signature of an interrupted archive, and a
  sweep that reclaimed on that signature would delete every archived scratch
  space on the machine. Linkage cannot substitute for the row either: a scratch
  space is not a linked worktree of any repo, so there is nothing to prove
  against.
- The existing `locked` and live-cwd (`lsof`) gates pass, so a directory a live
  process is sitting in is never reclaimed.

Anything failing the gate is logged and skipped permanently. Measuring the
directories present when this was written, every repo-backed one satisfied the
linkage check.

### Not stealing a directory from a running archive

Archiving flips the row to `.archived` in phase 1 and only reaches the rename
in phase 2, which can spend a minute in the archive hook first. In that window
an archive that is proceeding normally is indistinguishable, by row and
directory alone, from one that was interrupted — and a sweep landing there
would rename the directory out from under the running hook. `repo.remove`'s
cascade puts many such archives in flight at once, so the window is not
theoretical.

Interrupted archives therefore also pass an age gate on the row's persisted
`archivedAt`: a candidate archived within the sweep's grace window
(`gcGraceSeconds`, the same knob `AgentWorktreeCollector` uses) is kept, with
keep-reason `grace`. Nothing is lost by waiting — a genuinely interrupted
archive is reclaimed by the next hourly sweep instead of this one. A row with
no `archivedAt` is not held: both archive paths stamp it in the same
transaction that sets the status, so an unstamped row cannot be an archive
that is running right now.

`forgetWorktree` needs no special handling. It hard-deletes the row rather than
flipping it to `.archived`, so a directory the user deliberately kept can never
match "archived row whose directory exists."

### Error handling

- Enqueue fails (`EXDEV`, permissions) — fall back to `git worktree remove`
  with a raised timeout, and log at error level. The row stays archived; the
  sweep retries later.
- Prune fails — log; the next sweep prunes, because it looks for archived rows
  whose directory is gone and whose path git still lists.
- Drain interrupted — the entry stays in `.deleting/`; the next sweep resumes.
- Provenance gate fails — log once per path; never reclaim.

No path silently swallows a failure.

## Flag policy

CLAUDE.md requires large or risky new behavior to ship behind a default-off
flag, and this qualifies on two counts: it replaces a load-bearing path and it
deletes state from a background sweep.

It ships without a new flag by maintainer decision, and the two halves are
mitigated differently — the toggle covers one of them, not both.

**The sweep-side additions are gated.** Draining queued entries, reclaiming
interrupted archives, and pruning stale registrations all run inside
`OrphanGC.sweep`, under the existing `gcEnabled` master switch. That switch
already defaults to true and already governs every other GC deletion, so the
escape hatch for the autonomous, state-deleting half is one toggle, and both
branches are tested.

**The archive-path replacement is ungated**, and there is no honest way to
describe it otherwise: `completeArchiveWorktree` enqueues and drains on every
`worktree.archive`, `repo.remove` cascade, and auto-archive on merge, with no
`gcEnabled` check. `gcEnabled` mitigates nothing there. What justifies leaving
it ungated is that the code it replaces was equally ungated: the deletion step
of archiving has never been behind a flag, and the change swaps one
unconditional deletion mechanism for another on the same path. A flag would not
have added a safety margin that previously existed; it would have made the
buggy path the shipping default until graduation, while the bug is actively
destroying disk and worsening under its own effects.

Two properties limit the risk that remains. Reclamation touches only
directories that pass the provenance gate, and the enqueue step trades a
partial unlink for a rename: where an interrupted `git worktree remove` left a
tree half-deleted in its pool slot, an interrupted archive now leaves it whole
inside `.deleting/`. That is a crash-recovery property, not a window in which a
user could change their mind — every call path drains immediately after
enqueuing, and a holding period is rejected below.

## Testing

`WorktreeDeletionQueue`: enqueue renames rather than copies; enqueue across
filesystems surfaces `EXDEV` rather than partially completing; drain is
resumable after interruption; `pending` enumerates what a previous run left.

`DeletionQueueCollector`: one test per keep-reason, matching the existing
collectors' style of a test per spec invariant — a worktree outside every
TBD-owned prefix, a repo-backed directory failing linkage, a locked worktree, a
directory with a live cwd, an archived scratch space whose folder must survive,
and a row archived inside the grace window (with its counterpart old enough to
pass). Plus the reclaim case, a test that a forgotten worktree's directory is
never a candidate, and a symlink planted inside a pool pointing outside it —
the gate's authorization boundary, where a path that merely *reads* as
TBD-owned must still be refused.

Lock state is derived, not asserted by hand: one test locks a real worktree
with `git worktree lock` and expects the candidate to read as locked, and one
points a repo at a path git cannot list and expects that repo's candidates to
read as locked too, since a listing failure must never read as "nothing is
locked".

Archive path: enqueue is used on the success path; the `git worktree remove`
fallback is used when enqueue throws; `onWorktreeRemoved` fires only once the
path is actually gone; the fallback's raised timeout is really the one armed —
asserted by giving the `GitManager` an instance deadline so short that a
removal which fell back to it could not possibly complete.

Integration: archive a worktree and assert the pool slot is empty, `.deleting/`
drains, and `git worktree list` no longer registers it. Then assert an
interrupted archive — a directory restored into a pool slot under an archived
row — is reclaimed by one sweep, with a non-zero byte count on its reap record.
Assert too that the inverse — a registration whose directory is gone — is
pruned by one sweep and that the worktree revives afterwards, and that a
`.deleting/` entry beside an adopted worktree, outside every layout prefix, is
drained.

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

**A quarantine period before reclaiming bytes.** Hold queued entries in
`.deleting/` for some days so a mistake could be noticed. Rejected because
archiving already promises the directory will be deleted; content that survived
did so only because of this bug, and quarantine would defer the disk
reclamation that motivates the work. This is a different question from the age
gate above: that one refuses to touch a directory whose archive may still be
running, and holds nothing back once the archive is provably over.
