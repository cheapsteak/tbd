# Bound the growth of state.db

TBD's database, `~/tbd/state.db`, only grows. Two things never shrink: the `notification`
table and the full copies of the database that TBD writes before risky schema changes. This
spec bounds both, and adds the one index the notification reads lack.

## Why

Measured read-only on one machine after seven months of use:

- **Notifications are never removed.** The table held about 56,700 rows — about 82 MB of a
  95 MB database. About 50,000 were `response_complete`, one per turn end of every session,
  each storing that turn's whole final assistant message. About 98% were read.
- **Nothing reads a notification after it is marked read.** The only production reader is the
  per-worktree unread summary the app polls every 2 seconds
  (`NotificationStore.unreadSummaryByWorktree`). Read rows and the stored message text are
  never read back, and nothing depends on notification ids or counts.
- **The reads scan the whole table.** `notification` has no index besides its primary key, so
  that 2-second poll and every mark-read walk every row.
- **Database copies are never removed.** `TBDDatabase.takePreMigrationSnapshot` writes
  `state.db.pre-migration.<UTC stamp>` with `VACUUM INTO` at daemon start whenever a migration
  is pending, and `RetiredColumnReconciler` writes `state.db.pre-column-drop.<UTC stamp>` the
  same way. The docs leave both for a person to delete ("safe to delete … once the upgrade
  looks clean", "reclaimed by hand"), and in practice nobody does: about 50 copies of 25–93 MB
  each had built up, about 5 GB.

Unbounded growth is a bug, so this ships as a fix with no feature flag.

The maintainer chose the values in this spec while brainstorming it: the 7-day window for read
notifications, deleting every notification on an archived worktree, keeping 3 copies of each
kind, and shipping with no flag.

## Design

### Notification sweep

A new OrphanGC leg, run on every hourly sweep while `gcEnabled` is on:

- **Read notifications older than 7 days are deleted.** The window is one named constant; the
  sweep takes the current date from its injected `now`, like the retained-transcript leg.
- **Every notification on an archived worktree is deleted**, read or unread, at the next
  sweep. Once a worktree is archived its notifications no longer matter: nobody sees its
  badges, and a revived worktree comes back without them. This includes the unread
  "Archived <name> — PR #N merged" notice that auto-archive writes on the worktree it has
  just archived. A running app gets that notice as a live event when it is written, and posts
  it as a macOS notification when those are on; the sweep removes only the stored row. Do not
  narrow this rule to read rows or exempt that notice.
- **Unread notifications on active worktrees are never deleted**, so an unread badge on a
  worktree that is not archived never vanishes on its own.

Notifications of a deleted worktree need no rule: `notification.worktreeID` references
`worktree(id)` with `ON DELETE CASCADE`.

The leg runs before OrphanGC's `lsof` gate, which skips the rest of a sweep when `lsof` fails;
a database-only leg does not need `lsof`.

### Index

One migration adds
`CREATE INDEX IF NOT EXISTS idx_notification_unread_worktree ON notification(worktreeID) WHERE read = 0`.
The unread summary and mark-read then cost about the number of unread rows rather than the
size of the table. It changes no behavior.

### Database copies

TBD keeps the newest 3 copies of each kind — `state.db.pre-migration.*` and
`state.db.pre-column-drop.*`, counted separately — and deletes older ones. Each kind is
pruned by the code that writes it, and only once that code's step has succeeded:

- **Only TBD's own names are touched.** A file is a copy only if its whole name, from first
  character to last, is `state.db.pre-migration.<stamp>` or `state.db.pre-column-drop.<stamp>`,
  where the stamp is the `YYYYMMDDTHHMMSSZ` form `snapshotTimestamp` writes, in ASCII digits.
  Anything else beside the database — backups made by hand, files with suffixes (a trailing
  newline included), other tools' files — is never touched.
- **Newest is read from the name's timestamp**, not the file date.
- **A prune never deletes the copy just written.** It takes one of the 3 places and the newest
  of the others fill the rest, so a clock running behind an older stamp cannot delete the
  newest copy of the database.
- **Pre-migration copies are pruned at daemon start, once migrations have succeeded**, whether
  or not the start wrote a copy. A start whose migration fails prunes nothing: the app keeps
  relaunching a daemon that cannot come up, each start writes another copy of the
  half-migrated database, and pruning then would push out the clean copy taken before the
  upgrade. Those copies accumulate, one per attempted start, until the migration is fixed.
- **Pre-column-drop copies are pruned at the end of every `RetiredColumnReconciler` run in
  which nothing failed**, whether or not the run wrote a copy. A run with any failure prunes
  nothing, so the older copies, among them any that still holds a column an earlier run
  dropped, stay while the failure, logged at error level, waits to be fixed. A run that drops
  some columns and fails on others keeps its own copy as well.
- **A column-drop run that dropped nothing deletes the copy it wrote.** The reconciler writes
  its copy before the first drop, so when every due drop fails, the copy holds nothing the
  database lacks. The run deletes that one file, the exact path it wrote and nothing else,
  and reports no copy. A drop that fails at every start, such as one SQLite refuses because
  the column is in an index, therefore adds a copy only at a start where some other column
  drops, and the copies stay bounded until it is fixed.
- **Pruning at every start clears a backlog at once** rather than at the next copy. It only
  lists one directory and deletes files, so it adds little to startup.
- **A failed delete is logged and skipped**; it never blocks startup or a migration.

This is cleanup at creation time, which the named-reconciler doctrine allows when a spec
chooses it: copies only accumulate when TBD writes one, and every write path prunes once its
step succeeds.

### The file's size

There is no `VACUUM`. Deleting rows stops the growth, and SQLite reuses the freed pages, so the
file stays at its high-water mark rather than shrinking. A `VACUUM` inside the daemon would make
every write wait while it runs, and the large disk cost was the copies, which `VACUUM INTO`
already writes compactly.

### Docs

The places that describe the copies — the root `CLAUDE.md` (beside the named reconcilers),
`Sources/TBDDaemon/Database/CLAUDE.md` ("Pre-migration snapshot" and "Retiring a column"),
`docs/updating.md` and the reconciler section of
`docs/specs/2026-10-24-column-retirement-design.md` — state this retention rather than leaving
the copies for a person to delete.

## Testing

All tests run under `scripts/test.sh`; the copy prune takes its directory as a parameter, and
the sweep takes `now`.

- **Sweep:** a read row older than 7 days is deleted; a read row inside the window is kept; an
  unread row on an active worktree is kept at any age; read and unread rows on an archived
  worktree are deleted; the leg runs when `lsof` fails.
- **Index:** the migration creates it; old rows read unchanged.
- **Prune:** with 5 copies of each kind, the newest 3 of each remain; a file that merely starts
  with the prefix, or has a suffix, is untouched; a hand-named backup is untouched; a name with
  another character in place of the database name's `.`, a trailing newline, or a stamp in
  non-ASCII digits is untouched; ordering follows the name's timestamp when file dates
  disagree; the protected copy survives when its stamp sorts oldest; a delete failure is
  logged and the rest continue.
- **Startup:** it clears a backlog of pre-migration copies without a new copy being written
  and leaves pre-column-drop copies alone; a start whose migration fails leaves every copy; the
  copy a start just wrote survives when every other copy carries a later stamp.
- **Reconciler:** a run in which nothing failed leaves 3 copies, its own among them even when
  every seeded copy is stamped later; a run that drops one column and fails on another keeps
  its copy and prunes nothing; a run whose only due drop fails leaves no copy and reports
  none; a run whose only remaining due drop fails deletes its own copy and no older one; a run
  that holds one column and fails to drop another deletes its own copy; a run with nothing to
  drop still clears a backlog.

## Rejected alternatives

- **Deleting read notifications as soon as they are read.** Simplest, but it leaves no history
  for any future notification view; a 7-day window costs little.
- **Dropping unread notifications after a long window.** It bounds the table tighter, but a
  badge could vanish without anyone having seen it.
- **Pruning in the same transaction as each insert,** the way `terminal_history` keeps its cap.
  It runs on every turn end of every session, and archived worktrees would still need a sweep.
- **Pruning copies from the hourly sweep.** Copies change a few times a month; pruning where
  they are written needs no timer and no knowledge of copy files in OrphanGC.
- **A `VACUUM` at startup or on demand.** It would shrink a file of about 100 MB at the cost of
  blocking writes or delaying the socket; the multi-gigabyte cost was the copies.
- **A feature flag.** This removes data nothing reads and files TBD's docs already called safe
  to delete; the growth it stops is the defect.
