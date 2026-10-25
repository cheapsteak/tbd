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

## Design

### Notification sweep

A new OrphanGC leg, run on every hourly sweep while `gcEnabled` is on:

- **Read notifications older than 7 days are deleted.** The window is one named constant; the
  sweep takes the current date from its injected `now`, like the retained-transcript leg.
- **Every notification on an archived worktree is deleted**, read or unread. Nobody can see
  those badges, and a revived worktree comes back without them.
- **Unread notifications on active worktrees are never deleted**, so a badge someone can still
  see never vanishes on its own.

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
`state.db.pre-column-drop.*`, counted separately — and deletes older ones:

- **Only TBD's own names are touched.** A file is a copy only if its whole name matches
  `state.db.pre-migration.\d{8}T\d{6}Z` or `state.db.pre-column-drop.\d{8}T\d{6}Z` (the format
  `snapshotTimestamp` writes). Anything else beside the database — backups made by hand, files
  with suffixes, other tools' files — is never touched.
- **Newest is read from the name's timestamp**, not the file date.
- **The prune runs at every daemon start, right after the pre-migration snapshot step**,
  whether or not a copy was written, and again right after `RetiredColumnReconciler` writes a
  copy. Running it at each start clears a backlog at once rather than at the next migration.
  It only lists one directory and deletes files, so it adds little to startup.
- **A failed delete is logged and skipped**; it never blocks startup or a migration.

This is cleanup at creation time, which the named-reconciler doctrine allows when a spec
chooses it: copies only accumulate when TBD writes one, and every write path prunes.

### The file's size

There is no `VACUUM`. Deleting rows stops the growth, and SQLite reuses the freed pages, so the
file stays at its high-water mark rather than shrinking. A `VACUUM` inside the daemon would make
every write wait while it runs, and the large disk cost was the copies, which `VACUUM INTO`
already writes compactly.

### Docs

The places that say the copies are reclaimed by hand — `Sources/TBDDaemon/Database/CLAUDE.md`
("Pre-migration snapshot") and `docs/updating.md` — state the retention instead.

## Testing

All tests run under `scripts/test.sh`; the copy prune takes its directory as a parameter, and
the sweep takes `now`.

- **Sweep:** a read row older than 7 days is deleted; a read row inside the window is kept; an
  unread row on an active worktree is kept at any age; read and unread rows on an archived
  worktree are deleted; the leg runs when `lsof` fails.
- **Index:** the migration creates it; old rows read unchanged.
- **Prune:** with 5 copies of each kind, the newest 3 of each remain; a file that merely starts
  with the prefix, or has a suffix, is untouched; a hand-named backup is untouched; ordering
  follows the name's timestamp when file dates disagree; a delete failure is logged and the
  rest continue; the startup step clears a backlog without a new copy being written.

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
