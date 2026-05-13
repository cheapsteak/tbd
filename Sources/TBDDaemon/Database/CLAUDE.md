# Database / Migrations

## Use the idempotent helpers in new migrations

New migrations that add columns, tables, or indexes MUST go through
`MigrationHelpers.swift`:

- `addColumnIfMissing(table:column:type:defaults:)`
- `createTableIfNotExists(_:body:)`
- `addIndexIfMissing(_:on:columns:unique:where:)`

Do not call `t.add(column:)`, `db.create(table:)`, or raw `CREATE INDEX`
directly in a new migration. Reason: parallel branches that renumber the same
additive migration have bricked the daemon twice (May 6 and May 13 2026). When
the schema already has the column but the renamed migration ID is unapplied,
GRDB re-runs the body and SQLite throws `duplicate column name`. The helpers
turn that scenario into a logged no-op.

## Migration ID convention

Continue `v<N>_descriptive_suffix` (e.g. `v23_repo_archived_at`). The numeric
prefix preserves ordering; the suffix makes parallel branch collisions
debuggable.

## Don't edit existing migration bodies

v1 through v22 are frozen. They have run on user machines; mutating them now
would either be a no-op (because GRDB skips them) or cause a fresh
divergence between dev and prod schemas. The helpers are for FUTURE
migrations only.

## Pre-migration snapshot

`init(path:)` automatically copies `~/tbd/state.db` to
`~/tbd/state.db.pre-migration.<UTC-timestamp>` (e.g.
`state.db.pre-migration.20260513T143055Z`) whenever there is pending
migration work AND the DB file already existed. Failures are logged at error
level but do not block the migration — best effort only. Safe to delete the
snapshot after confirming the upgrade was clean.
