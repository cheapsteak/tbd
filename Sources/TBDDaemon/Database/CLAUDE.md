# Database / Migrations

Migrations come in three shapes, and only one of them is for new work.

- **The frozen Swift block** in `Database.swift` — closures with hand-picked
  `vN` identifiers, `v1` through the identifier
  `SchemaBaselineDriftTests.frozenBlockLastIdentifier` names. Those identifiers
  have run on user machines. Read them, never edit them, never extend the
  sequence.
- **`.sql` files** under `Database/Migrations/`, named
  `YYYYMMDDHHMMSS_lower_snake_description.sql` and discovered from the
  `TBD_TBDDaemonLib` resource bundle at startup. **This is the default for
  every new migration.**
- **The Swift escape hatch** — an entry in
  `SQLMigrationLoader.inlineTimestampMigrations`, carrying the same 14-digit
  identifier a file would. For the rare migration that needs procedural Swift
  rather than DDL. Three of the legacy `vN` migrations are that kind (`v10`,
  `v14_worktree_location`, `v35_worktree_nullable_repo`) — a few percent of the
  block; expect roughly that rate.

The filename stem is the GRDB migration identifier:
`20260819143000_add_thing.sql` registers as `20260819143000_add_thing`. That is
the whole contract GRDB needs — it runs every registered migration whose
identifier is absent from `grdb_migrations`, and nothing else about the name is
load-bearing.

Design and rationale: [`docs/specs/2026-08-19-migration-identifier-scheme-design.md`](../../../docs/specs/2026-08-19-migration-identifier-scheme-design.md).

## Adding a migration

1. Mint an identifier: `date -u +%Y%m%d%H%M%S`. Seconds resolution earns its
   place — two agents on a parallel fleet plausibly author migrations in the
   same minute, and much less plausibly in the same second.
2. Write `Sources/TBDDaemon/Database/Migrations/<stamp>_<description>.sql`.
   Lower snake case after the stamp; nothing but `.sql` files may live in the
   directory.
3. Update the GRDB record type in this directory and the Codable model in
   `Sources/TBDShared/Models.swift`, in the same commit. See the root
   `CLAUDE.md`, "Database migrations must update the shared model".

Adding a migration touches one file no other branch has, so two branches can
neither pick the same identifier nor edit the same text.

## What a `.sql` file may contain

Every statement must lead with one of these forms; `scripts/lint-migrations.py`
rejects anything else:

`CREATE TABLE IF NOT EXISTS`, `CREATE [UNIQUE] INDEX IF NOT EXISTS`,
`ALTER TABLE … ADD [COLUMN]`, `DROP TABLE IF EXISTS`, `DROP INDEX IF EXISTS`,
`INSERT OR IGNORE`, `INSERT OR REPLACE`, `UPDATE`, `DELETE FROM`.

The list is a whitelist: it says what is permitted rather than what is banned.
Anything outside it either gets rewritten into one of these forms or takes the
Swift escape hatch. Widening the list is a deliberate edit with a reviewer,
because each addition claims that the new form is idempotent and
order-independent.

Two forms are absent for failing exactly that claim, and both are plausible
enough to be proposed again:

- **`ALTER TABLE … RENAME`** — no `IF EXISTS` spelling and no loader-side skip,
  so it can be neither replayed nor reordered.
- **`PRAGMA foreign_keys`** — a documented no-op inside a transaction, and GRDB
  runs every migration inside one. It would appear to work in any standalone
  replay and silently do nothing in production.

Both belong in the Swift escape hatch, where GRDB's `foreignKeyChecks:`
parameter handles the table-rebuild case properly.

`CREATE` needs `IF NOT EXISTS` and `DROP` needs `IF EXISTS`; the lint checks
that too. It also replays the whole chain against the committed baseline the
way the daemon will run it — one transaction per migration, foreign keys
enforced — so a migration that violates a foreign key reddens the lint rather
than a user's startup.

The file itself must be UTF-8 with LF line endings, no byte-order mark and no
NUL byte. The loader and the lint read the bytes rather than a normalized copy
of them, and a CR is the one byte they have split differently; rejecting it
outright keeps the two readers looking at the same statements.

## Idempotence is the load-bearing property

Every statement must be safe to run against a schema that already has the thing
it creates, and safe to run in any order relative to its siblings. Two
mechanisms deliver that:

- **In SQL** — the `IF NOT EXISTS` / `IF EXISTS` forms above.
- **In the loader** — `SQLMigrationLoader` splits the file into statements with
  SQLite's own `sqlite3_complete()`, then checks any statement matching a strict
  `ALTER TABLE <table> ADD [COLUMN] <column>` shape against
  `PRAGMA table_info(<table>)` and skips it with a log line when the column is
  already there. Anything the match does not recognize executes unmodified, so
  the guard can never silently swallow a statement it misread.

The splitting happens before SQLite prepares anything, because `duplicate column
name` is raised at prepare time. A loader that handed the whole file to
`execute(sql:)` and caught the error could not recover — earlier statements
would already have run, and the migration's transaction would roll back.

Idempotence is not decoration. Renumbering an additive migration bricked the
daemon twice: GRDB keys applied migrations by identifier string, so a
renamed-but-equivalent migration is unapplied under its new name while its
column already exists, and SQLite throws `duplicate column name`. Unique
timestamp identifiers remove that particular collision, but a second path to it
survives — two agents independently implementing the same feature write two
distinct migrations that add the same column. On a fleet of parallel agents
that is the normal workload, not an edge case.

## Application order differs between machines

A developer who has applied `20260901…` and then pulls a branch adding
`20260819…` runs the pair in a different order than a fresh install does. Every
timestamp scheme has this property. It is safe only because migrations are
idempotent and mutually independent, which is exactly what the statement
allowlist buys. Never write a migration that assumes an earlier timestamp
already ran.

`buildMigrator()` registers the frozen Swift block first, then the `.sql`
files and inline Swift escape-hatch migrations merged into one
identifier-sorted list. An escape-hatch migration therefore lands in authoring
order among the files rather than at the end.

## Migration history is frozen

A migration file that has landed on `origin/main` may not be modified or
deleted, and the same goes for the frozen block's `vN` bodies. Those migrations
have already run on user machines; editing one is either a no-op, because GRDB skips
an identifier it has recorded, or a fresh divergence between one developer's
schema and everyone else's. Fix a mistake with a new migration.

**For the `.sql` files, this is mechanical.** `scripts/lint-migrations.py`
enforces it in the `lint` CI job and the pre-push hook, on two legs that cover
different things. Every entry in the migrations
directory must be an addition relative to the merge base with `origin/main` —
that leg is what sees deletions and renames. And every migration `origin/main`
already holds must be byte-identical here — that leg never consults the merge
base, so it holds even where the base ref is stale, which on a developer's
machine it usually is.

**For the frozen Swift block, it is not.** Both legs are scoped to the
migrations directory and never open `Database.swift`, so nothing reads a `vN`
body and compares it to what `origin/main` holds. What covers the block instead
is `SchemaBaselineDriftTests`, which asserts the block still produces exactly
the committed baseline fixture — a check on the *resulting schema*, not on the
bodies. It catches any edit that changes a column, an index, or a table, which
is the overwhelming majority of ways a `vN` body gets edited. It cannot catch
an edit that leaves the schema identical while changing what the migration
does: altering the literal values a data-only `UPDATE` writes, for one. Treat
the block's freeze as a rule a reviewer enforces, backed by a check that
catches the schema half of it.

## The Swift escape hatch

Register procedural migrations in `SQLMigrationLoader.inlineTimestampMigrations`
under a 14-digit identifier. They still conflict textually with a concurrent
one, which is why a `.sql` file is the default.

Any Swift migration body goes through the idempotent helpers in
`MigrationHelpers.swift` rather than raw DDL:

- `addColumnIfMissing(table:column:type:defaults:)`
- `createTableIfNotExists(_:body:)`
- `addIndexIfMissing(_:on:columns:unique:where:)`

The `migration_use_helpers` SwiftLint rule catches `create(table:)`,
`.add(column:)`, and raw `CREATE TABLE` / `CREATE INDEX`. It names two files —
`Database.swift` and `SQLMigrationLoader.swift` — at `severity: error`, so raw
DDL in an escape-hatch body fails `swiftlint --strict` in the `lint` CI job and
the pre-push hook rather than resting on discipline. `.sql` files need no
helpers at all — the loader gives them the equivalent ADD COLUMN guard, and the
`IF NOT EXISTS` forms cover the rest.

For a feature-flag column, omit the SQL `DEFAULT` clause so "unset" stays a
third state distinct from `0` and `1`. The root `CLAUDE.md` explains why under
"Large or risky new behavior ships behind a default-off flag".

## The resource bundle

`Package.swift` declares `resources: [.copy("Database/Migrations")]` on
`TBDDaemonLib`. `.copy` preserves the directory verbatim, dotfiles included, so
the `.gitkeep` that lets git track it while empty ships too — the loader filters
to `.sql` rather than trusting what it finds. SwiftPM treats an undeclared
non-source file inside a target path as an error, so the declaration is not
optional.

`SQLMigrationLoader` deliberately does **not** use `Bundle.module`. SwiftPM
generates that accessor with a hardcoded absolute path into the building
worktree's `.build`, so a daemon binary copied anywhere on the same machine
still resolves it and silently reads migrations out of the tree it was built in
instead of failing. The loader instead searches an ordered candidate list — the
executable's own directory, the directory of the bundle owning a marker type,
and that directory's parent, which is where the resource bundle sits under the
test harness — and throws an error naming every path it searched when the list
is exhausted.

Refusal has two gates, and only the first of them refuses.

**Gate one is the locator.** A locator that exhausts every candidate throws, so
a daemon that cannot find its resource bundle at all fails at startup whatever
the database holds — a fresh install included.

**Gate two reports.** `init(path:)` calls `verifyResourceIntegrity` before
migrating, using the database as its own manifest: if `grdb_migrations` holds
timestamp-shaped identifiers while the bundle yielded zero `.sql` files, it logs
that at error level, naming the directory and the applied identifiers, and
carries on. It does not refuse, and the distinction matters because the
stricter-looking choice is the wrong one here. A bundle that is present but
hollowed out is not a failure `.copy` produces — SwiftPM either ships the
directory or does not, and "does not" is gate one. Meanwhile "directory
present, zero files" is the ordinary state of any worktree branched before the
first migration landed, and since `scripts/restart.sh` from any worktree
replaces the daemon machine-wide, refusing there would brick the fleet on a
routine branch switch.

A *partial* mismatch is fine and deliberately does not fire — downgrading to an
older build legitimately leaves applied identifiers with no corresponding file,
and GRDB's `hasBeenSuperseded` already covers that.

## The frozen baseline fixture

`Tests/TBDDaemonTests/Fixtures/schema-baseline-frozen-block.sql` is the schema
the frozen Swift block produces against an empty database. The lint's
chain-apply check replays the `.sql` migrations against it without needing a
Swift build, and `SchemaBaselineDriftTests` asserts the block still produces
exactly that fixture. The filename names no version, so extending the block's
tail never renames a file.

`scripts/gen-migration-baseline.sh` regenerates it, and should essentially never
run: the block it snapshots is frozen. A diff against the committed fixture
means the frozen block changed, which is the bug to chase — not a chore to
resolve by committing the regenerated file.

The one exception is a rebase that carries new `vN` migrations from `main` onto
a branch, extending the block's tail. There the diff is legitimate, and it must
consist of exactly the columns those migrations add — with
`SchemaBaselineDriftTests.frozenBlockLastIdentifier` moved to the new tail.
Anything else in the diff is the bug the warning is about.

## Splitter parity

The loader and the lint split statements with two bindings to one C function —
`sqlite3_complete()` from Swift, `sqlite3.complete_statement()` from Python.
`Tests/TBDDaemonTests/Fixtures/MigrationSplitter/` holds adversarial SQL both
sides must agree on, and its README states the contract they pin. A
disagreement means one side's framing code drifted, not that SQLite changed.

## Pre-migration snapshot

`init(path:)` writes `~/tbd/state.db` to
`~/tbd/state.db.pre-migration.<UTC-timestamp>` (e.g.
`state.db.pre-migration.20260513T143055Z`) via `VACUUM INTO` whenever migration
work is pending AND the database file already existed. Failures log at error
level but do not block the migration — best effort only. Safe to delete the
snapshot once the upgrade looks clean.
