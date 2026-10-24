# Column retirement

## Problem

A column, once added, stays in the schema forever. Migrations are frozen, the migration lint forbids `DROP COLUMN`, and nothing else removes one. So every column a feature stops using becomes permanent weight. `config.nightwatch_mode` and `terminal.watch_desk_role` lost their last reader when Nightwatch was removed, and each graduated feature flag leaves another.

Dropping a column is the first schema change an older build cannot tolerate. Adding a column is safe in both directions: an older build never names the new column, and SQLite fills it with its default or NULL. Dropping is not. A GRDB record writes every property it declares, so an older build that still declares the column fails every insert and update into that table once the column is gone. For `terminal` that means every session spawn.

That older build is not hypothetical. `tbd update` moves the bundle it replaces to `~/tbd/updates/previous/TBD.app` and keeps it there as the no-rebuild route back ([`docs/updating.md`](../updating.md)). An update that installs a new build and then cannot bring the new daemon up restores that bundle automatically. By then the new daemon may already have run, so a drop it made would leave the restored build broken.

## Decision

A column leaves the schema in two steps.

- **Retire** – a pull request that deletes every read and write of the column, adds it to the daemon's retired-column list with the current schema epoch, and bumps that epoch.
- **Drop** – no pull request. A reconciler at daemon startup drops each listed column once the build kept for rollback no longer uses it.

The guarantee is about the kept bundle: a drop never runs while the bundle in `~/tbd/updates/previous` might still read or write the column. Other routes back are not covered. Checking out an arbitrary older commit and building it can still meet a schema it does not understand, as it can after any change that is not additive.

## The schema epoch

`SchemaEpoch.current`, a single integer in `Sources/TBDShared/SchemaEpoch.swift`, counts column retirements. The first retirement sets it to 1, and each later retirement pull request increments it.

Every build records its epoch in its build identity. `write_build_identity` in `scripts/restart-bundle-lib.sh` reads the value from `SchemaEpoch.swift` and writes it into `TBDBuildIdentity.json` as `schemaEpoch`, alongside the commit and branch it already records. The script fails loudly when it cannot find the value, since a bundle without an epoch blocks every drop. `BuildIdentity` gains an optional `schemaEpoch`.

The daemon reads the kept bundle's epoch from `<updatesDir>/previous/TBD.app/Contents/TBDBuildIdentity.json`, where `updatesDir` is `TBDConstants.updatesDir` and so follows `TBD_HOME`:

- **No kept bundle** – nothing to protect, so every listed column may drop. That covers a fresh install and a developer install that has never run `tbd update`.
- **A kept bundle with no `schemaEpoch`** – it was built before this design landed, so it reads as epoch 0 and blocks every drop until the next update replaces it. A kept bundle whose identity file is missing or unreadable reads the same way.
- **Otherwise** – a column may drop once the kept bundle's epoch is at least the column's retirement epoch. That bundle was built from a tree that had already retired the column, so it never names it.

This covers the automatic rollback exactly. When the new daemon starts, the kept bundle is the build that rollback would restore.

A user who updates once after a retirement does not get the drop on that update: the kept bundle is the build just replaced, which predates the retirement. The drop lands at the next update. Nothing is lost by waiting: the column costs a few bytes per row until then.

## The reconciler

`RetiredColumnReconciler`, in `Sources/TBDDaemon/Database/`, runs once per daemon start, after migrations and before the RPC server or any background sweep starts. It reads `RetiredColumns.all`, a list of `(table, column, epoch)` entries beside it.

For each entry it:

1. Skips the entry when `PRAGMA table_info(<table>)` has no such column. A column already dropped is the common case and not an event.
2. Skips the entry when the kept bundle's epoch is below the entry's epoch, and logs that the drop is held, naming the column, both epochs and the kept bundle's path.
3. Otherwise runs `ALTER TABLE <table> DROP COLUMN <column>` and logs the drop.

Before its first drop in a run, it writes a copy of the database to `state.db.pre-column-drop.<UTC-timestamp>` with `VACUUM INTO`, the mechanism the pre-migration snapshot already uses. The copy is the way back for someone who discovers they still needed the data. Like the pre-migration snapshot, it is reclaimed by hand. It is bounded: a run writes at most one, and only when it drops something, which happens once per retirement on each install.

A drop that fails is logged at error level and skipped, and startup continues. SQLite refuses to drop a column that is part of a key, a `UNIQUE` or `CHECK` constraint, a foreign key, an index, a view or a trigger. Such a column cannot be retired by this mechanism, and the retirement checklist says so. When the snapshot fails, the reconciler logs it and drops nothing in that run.

The list is permanent, like migration history. A fresh install still creates every retired column, through the frozen migrations that added it, and relies on the reconciler to drop it again. Removing an entry would leave that column on every later fresh install.

Drops happen only here. The `.sql` statement allowlist keeps refusing `DROP COLUMN`, so a migration cannot drop a column without the kept-bundle check.

## Retiring a column

`Sources/TBDDaemon/Database/CLAUDE.md` gains a "Retiring a column" section with this checklist. Review is the enforcement; there is no lint or test that checks it.

1. Delete every read and write of the column: the GRDB record's property, its `CodingKeys`, any hand-written SQL that names it, and the shared model field it fed.
2. Confirm the column is nullable or has a default, so inserts that no longer name it still succeed. Confirm it is not part of a key, constraint, index, view or trigger.
3. Increment `SchemaEpoch.current`.
4. Append `(table, column, epoch)` to `RetiredColumns.all`, with the new epoch.
5. Make all four changes in one commit.

Two branches that each retire a column can both bump the epoch from N to N+1 identically, and Git merges that without a conflict. The merged result is correct. A build from either branch alone, though, claims epoch N+1 while still using the other branch's column. That matters only if such a branch build becomes the kept bundle, which a developer can arrange and `tbd update` never does. It is accepted rather than guarded.

## First retirements

Both at epoch 1:

- `config.nightwatch_mode` – added by the frozen `v38_nightwatch_mode`, `TEXT DEFAULT 'off'`. Nothing has read or written it since Nightwatch was removed.
- `terminal.watch_desk_role` – added by the frozen `v68_watch_desk_judge_lease`, `TEXT DEFAULT NULL`. Nothing has read or written it since Nightwatch was removed. A kept bundle from before that removal writes it on every terminal insert, which is the case the epoch exists for.

## Testing

- **The decision**, as a pure function of the kept bundle's identity and an entry: no kept bundle drops; a kept bundle without an epoch holds; a kept bundle below the entry's epoch holds; one at or above it drops.
- **Reading the kept bundle**: an absent file, a file without `schemaEpoch`, a malformed file (read as no epoch, so it holds), and a well-formed one. The path comes from an injected updates directory, never the real `~/tbd`.
- **The reconciler**, against a database migrated to head: both columns dropped with no kept bundle; neither dropped behind an epoch-0 kept bundle; a second run against already-dropped columns is a no-op that writes no snapshot; a failing drop is logged and does not throw; the snapshot is written before the first drop and only then.
- **The stores after the drop**: insert and fetch a config row and a terminal row through `ConfigStore` and `TerminalStore`.
- **The script**: the `restart-bundle-lib.sh` harness checks that `schemaEpoch` reaches the sidecar and that a missing constant fails the build identity step.

## Rejected alternatives

- **Restore the pre-migration snapshot on rollback.** Going back across a drop would mean restoring the database copy taken before the update and losing everything written since. That is acceptable minutes after a failed update and not days later, when the snapshot no longer describes the user's worktrees.
- **A fixed time window.** Dropping a column some weeks after its retirement needs no runtime check, but someone who updates rarely can still have a kept bundle older than the window and roll back into a broken build.
- **Commit ancestry.** Recording the retiring commit and asking Git whether the kept bundle's commit contains it is precise, but needs Git and the update clone at daemon startup, and must hold every drop when either is missing.
- **A column manifest in each bundle.** A generated list of the columns a build's records use would say exactly what the kept bundle needs, at the cost of a build step and of every bundle from before it holding all drops.
- **Dropping in an ordinary migration, gated by the lint.** The lint runs on the author's machine and in CI and cannot see the kept bundle on a user's machine, so it cannot give the guarantee.
- **A migration that fails until the drop is safe.** GRDB records a migration as applied the first time it runs, so the only way to retry is to throw, and a throwing migration holds back every migration ordered after it.
- **Mechanical enforcement of the checklist.** A lint that rejects the column's name in Swift sources, or a test that drops every retired column and then exercises each store, would catch a forgotten reference before a user's daemon does. Neither was adopted; retirement relies on review against the checklist above.
