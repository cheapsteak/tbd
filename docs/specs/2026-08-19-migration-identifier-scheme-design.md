# One file per migration, named by timestamp

Database migrations move out of the single `buildMigrator()` function in
`Sources/TBDDaemon/Database/Database.swift` and become one `.sql` file each,
named by authoring timestamp, discovered from a SwiftPM resource bundle at
startup. Two branches can no longer pick the same identifier, and no longer
edit the same file.

The existing `v1`–`v84` migrations stay exactly where they are.

## Why this exists

Every migration today appends to the tail of one Swift function and claims the
next integer in a hand-picked sequence. Both halves of that collide.

The **identifier** collides because the number is chosen by a human reading
what `main` had at the time. Parallel branches read the same number and both
take it. `origin/main` already ships two migrations numbered `v35`
(`v35_worktree_nullable_repo` and `v35_forgotten_worktree`, the latter
registered after `v37`), and the fix is repeatedly a renumbering commit:
`a408af6b` renumbered the cloud migrations after main claimed v80, `0411d6fa`
renumbered the pin migration to v63, `4974beed` renamed stale v56 test names to
v59. The number leaks into test filenames, so a renumber is a rename too.

The **file** collides because every branch appends to the same tail. That
conflict is structural and no naming scheme fixes it.

The consequence has been worse than churn. `Sources/TBDDaemon/Database/CLAUDE.md`
records that renumbering an additive migration bricked the daemon twice: GRDB
keys applied migrations by identifier string, so a renamed-but-equivalent
migration is unapplied by its new name while its column already exists, and
SQLite throws `duplicate column name`. The idempotent helpers in
`MigrationHelpers.swift` exist to absorb exactly that.

The number was never load-bearing. `DatabaseMigrator.unappliedExecutions`
(GRDB `Migration/DatabaseMigrator.swift`) walks the registered migrations and
runs any whose identifier is absent from `grdb_migrations`, in registration
order. There is no watermark and no ordering check; the only fatal error fires
when `migrate(upTo:)` targets a migration earlier than the last applied, which
TBD never does. Identifier uniqueness is the entire contract, and a hand-picked
counter is a poor way to obtain it.

## The decision

New migrations are `.sql` files under
`Sources/TBDDaemon/Database/Migrations/`, named
`YYYYMMDDHHMMSS_lower_snake_description.sql`. The filename stem is the GRDB
migration identifier. Adding a migration means adding one file that no other
branch has touched.

The 14-digit shape is dbmate's, adopted rather than invented. Seconds matter
here beyond convention: two agents on a parallel fleet can plausibly author
migrations in the same minute, and much less plausibly in the same second.

The directory is declared on `TBDDaemonLib` as
`resources: [.copy("Database/Migrations")]`. `.copy` rather than `.process`,
so the directory is preserved verbatim in `TBD_TBDDaemonLib.bundle`. The
declaration is not optional: SwiftPM treats an undeclared non-source file
inside a target path as an error. The `TBDDaemon` executable target shares the
same `path: "Sources/TBDDaemon"` but already excludes `Database`, so it needs
no change.

`buildMigrator()` registers, in order:

1. The frozen `v1`–`v84` block, verbatim and unchanged.
2. A merged list of the discovered `.sql` files and any post-cutover Swift
   escape-hatch migrations, sorted by identifier.

### Executing a file

The loader splits each file into statements using `sqlite3_complete()`, reached
through `import SQLite3` (GRDB imports it the same way at `GRDB/Core/Database.swift:5`;
the prototype is in the macOS SDK at `sqlite3.h:2949`). This is SQLite's own
lexer — the call the `sqlite3` CLI uses to decide whether you have finished
typing a statement. It handles the cases a hand-rolled splitter gets wrong:
`UPDATE t SET s='a;b'` is reported incomplete, and a
`CREATE TRIGGER x BEGIN UPDATE t SET a=1;` body is incomplete until its `END;`.

Splitting must happen before SQLite prepares anything, because
`duplicate column name` is raised at **prepare** time, not step time. A loader
that handed the whole file to `db.execute(sql:)` and caught the error could not
recover: earlier statements in the file would already have run, and the
migration's transaction would roll back.

For each statement:

- A statement matching a strict `ALTER TABLE <table> ADD [COLUMN] <column>`
  shape is checked against `PRAGMA table_info(<table>)` and skipped with a log
  line if the column is already present.
- Everything else executes as written.

That is `addColumnIfMissing` recovered, relocated from the call site to the
loader. `CREATE TABLE ... IF NOT EXISTS` and `CREATE INDEX ... IF NOT EXISTS`
are idempotent in SQL already and need no help; the lint requires those forms.

### The Swift escape hatch

Three of the 84 existing migrations do procedural Swift rather than DDL — `v10`,
`v14_worktree_location`, and `v35_worktree_nullable_repo`, all of them old. A
post-cutover migration that genuinely needs Swift is registered inline in
`Database.swift` under a timestamp identifier and joins the same sorted merge,
so it lands in authoring order rather than at the end. Such a migration still
conflicts textually with a concurrent one. At the historical rate that is about
one migration in twenty-five.

### Application order is machine-dependent, deliberately

A developer who has applied `20260901…` and then pulls a branch adding
`20260819…` runs them in a different order than a fresh install does. This is
inherent to every timestamp scheme — Rails and dbmate both have it — and it is
safe only because migrations are idempotent and mutually independent. The lint
below is what holds that property.

## The lint

`scripts/lint-migrations.py`, wired into the existing `lint` CI job and the
pre-push hook. That job builds nothing — it runs on `macos-26`, installs
swiftlint from Homebrew, and already carries a non-SwiftLint guard in the Rust
archive staleness check — so the migration lint costs seconds, not a compile.

Checks, all whitelist-shaped: they assert what is permitted rather than
enumerating what is banned.

- **Filename shape** — `^\d{14}_[a-z0-9_]+\.sql$`, and nothing else may
  live in the directory.
- **Identifier uniqueness** — across `.sql` files, post-cutover inline Swift
  migrations, and the frozen `v1`–`v84` names.
- **Statement allowlist** — every statement must lead with one of
  `CREATE TABLE IF NOT EXISTS`, `CREATE [UNIQUE] INDEX IF NOT EXISTS`,
  `ALTER TABLE … ADD [COLUMN]`, `ALTER TABLE … RENAME`, `DROP TABLE IF EXISTS`,
  `DROP INDEX IF EXISTS`, `INSERT OR IGNORE`, `INSERT OR REPLACE`, `UPDATE`,
  `DELETE FROM`, or `PRAGMA`. Anything outside the list fails, and the author
  either rewrites or takes the Swift escape hatch. Widening the list is a
  deliberate edit with a reviewer, which is the point: each addition is a claim
  that the new form is idempotent and order-independent.
- **Idempotent DDL** — `CREATE TABLE` and `CREATE INDEX` must carry
  `IF NOT EXISTS`; `DROP` must carry `IF EXISTS`.
- **History is frozen** — a migration file present on `origin/main` may not be
  modified or deleted. `git diff --name-status $(git merge-base origin/main HEAD) HEAD`
  over the migrations directory must report `A` for every entry. The three-dot
  merge-base form is load-bearing; a two-dot diff flags files that merely
  landed on main after the branch was cut.
- **The chain applies** — load the frozen baseline schema fixture, apply every
  `.sql` migration in identifier order against an in-memory database, assert
  success.

The lint splits statements with Python's `sqlite3.complete_statement()`, which
is a binding to the same `sqlite3_complete()` the Swift loader calls. Lint and
runtime are not two implementations of one lexer; they are two bindings to one
implementation.

`migration_use_helpers` in `.swiftlint.yml` stays, narrowed in meaning: it now
governs only the Swift escape hatch, and its message says so.

### The frozen baseline fixture

The chain-apply check needs a schema to apply against, so the schema produced
by `v1`–`v84` is generated once and committed as a fixture.

This is not the live schema snapshot rejected below. Rails' `schema.rb` is
rewritten by every migration, which is why it conflicts constantly. This
baseline is a snapshot of the legacy block, which is already forbidden from
changing and, as of the history-is-frozen check, mechanically prevented from
changing. It is generated once and never again. A Swift test asserts it still
equals what `v1`–`v84` actually produce, so drift is caught rather than
assumed.

The cost is that the linter reimplements the ADD COLUMN skip in about five
lines, which is drift surface against the Swift loader. The splitter-parity
fixture is what keeps the two honest.

### The lint's own harness

`scripts/lint-migrations.test.sh`, mirroring `scripts/test.test.sh`: one
fixture per guard that must fail, plus a mutation pass that disables each guard
and proves its fixture then passes. A guard nobody has watched fail is a guard
that does not work.

## What the lint deliberately does not check

CLAUDE.md requires that a migration, its GRDB record type, and its `Models.swift`
Codable model land in one commit. Inferring that a column-adding migration
should have been accompanied by a `Models.swift` edit is heuristic and would be
noisy in both directions. That rule stays prose.

## Where tests run

Nothing goes into the Swift suite that could have been static. A post-cutover
migration PR touches no Swift files, and its author must not need a full
compile to learn whether the SQL parses.

**Fast lane** — the `lint` job and the pre-push hook, no build: filename shape,
identifier uniqueness, statement allowlist, idempotent DDL, the history-is-frozen
git check, chain-apply against the baseline, and the lint's own mutation
harness.

**Swift suite** — only what needs the runtime:

- The ADD COLUMN guard, both branches: column already present is skipped and
  logged without throwing; column absent is added.
- Ordering — out-of-order filenames register sorted, and a Swift escape-hatch
  migration interleaves by identifier rather than landing last.
- `Bundle.module` discovery finds the directory in the test context. This is
  the tripwire for the resource bundle silently vanishing in CI.
- Splitter parity, Swift half — a shared fixture table of adversarial SQL
  (semicolons inside literals, trigger bodies, comments, trailing empties)
  splits identically in the loader and the lint.
- Baseline drift — `v1`–`v84` still produce exactly the committed baseline.
- Full-chain apply — every migration, `v1` onward, against a fresh in-memory
  database throws nothing. This is not a duplicate of the lint's chain-apply:
  the lint starts from the baseline fixture and covers only the `.sql` files,
  while this one exercises the Swift block that produced the baseline.

## Risk: the resource bundle must resolve

`Bundle.module` must resolve for `TBDDaemonLib` in two contexts: the daemon run
from `.build/debug/TBDDaemon` by `scripts/restart.sh`, and `scripts/test.sh`.
`TBDCLI` never opens the database, so it is not a third.

This is not a formality. `scripts/restart.sh` hand-copies `TBD_TBDApp.bundle`
into the assembled `.app` precisely because this failure already happened here
once — without the copy, app launch fails with "could not load resource
bundle". CLAUDE.md's unbundled-executable section is a standing warning against
assuming bundle APIs work in this package.

**Proving it is the first task, and a negative result kills this design** in
favor of the rejected plugin alternative below. The daemon's case is
structurally easier than the app's, since the daemon is never relocated and the
bundle sits beside the binary, but easier is not proven.

### Failing loudly when it is absent

SwiftPM's generated `Bundle.module` accessor traps with an opaque `fatalError`.
The loader instead locates the directory itself and throws a described error.

The stronger check uses the database as its own manifest: if `grdb_migrations`
holds timestamp-shaped identifiers but the bundle yielded zero `.sql` files,
the resource bundle is missing or truncated and the daemon refuses to start.
That catches the real hazard — a daemon shipped or copied without its
resources, which would otherwise run happily against an under-migrated schema.

It deliberately does not fire on a partial mismatch. Downgrading to an older
build is a legitimate way to hold applied identifiers with no corresponding
file, and GRDB's `hasBeenSuperseded` already covers that case.

## Cutover, and why there is no feature flag

The house rule gates behavior that wholesale-replaces a load-bearing path, and
persistence qualifies. A flag is nevertheless the wrong instrument here: two
migrators cannot both run, so gating would mean shipping two code paths over
one database.

The better soak is available for free. The mechanism lands with an **empty
`Migrations/` directory**, where the merged list is empty and `buildMigrator()`
produces behavior byte-identical to today. That commit is provably inert. The
first real `.sql` migration lands separately and is the actual soak.

Cutover is a no-op for existing installs. Identifiers `v1`–`v84` are untouched,
so no user database re-runs anything, the eleven `upTo: "vNN_…"`
call sites across ten test files keep passing unchanged, and nothing about `grdb_migrations`
changes shape.

## Rejected alternatives

**Timestamp identifiers alone, everything still in `Database.swift`.** Kills the
renumbering churn and the test-file renames, and costs almost nothing. It does
not kill the git conflict, because every branch still appends to one function.
Rejected because the conflict is the stated target.

**Swift file per migration, registry generated by a SwiftPM build-tool plugin.**
A prebuild command lists the directory and emits the registry into the plugin
work directory, so nothing generated is committed and conflicts reach zero.
This preserves everything — GRDB's DDL builder, the existing helpers, the
`upTo:` tests — and changes only where migration code lives. It was the
stronger candidate on machinery alone, and it remains the fallback if the
resource-bundle spike fails.

Rejected on two grounds. First, the incremental-build tax is documented rather
than hypothetical: `swiftlang/swift-build#305` ("SwiftPM Build Tool Plugin
excessively runs causing recompilation", open since February 2025) reports a
build-tool plugin re-running on every incremental build and invalidating
already-compiled targets, pushing incremental compiles past 100 seconds. This
package has no plugins today, and its build caching is already delicate.
Second, a plugin cannot express the history-is-frozen check: with 84 bodies
inside one Swift function, no diff shape means "you edited history."

If the resource-bundle spike fails, this becomes the design, and the mitigation
is to make the generated output strictly stamped — write only when content
changes — so the plugin does not invalidate the world on every build.

**Committed generated registry with a CI check.** A script writes the array and
CI asserts it matches the directory. No plugin. But two branches adding
same-day adjacent entries still conflict; resolution becomes mechanical rather
than absent. Rejected because zero was the goal.

**A custom git merge driver on `Database.swift`.** Auto-resolves by
concatenating both sides. Rejected: it needs per-clone `git config` that fresh
clones and CI will not have, and a silently wrong merge of schema code is the
worst available failure mode.

**A committed live schema snapshot, Rails' `schema.rb`.** Rejected because it
restores a single file that every migration rewrites, which is the conflict
this design exists to remove. The frozen baseline fixture above is a different
object: it snapshots only the legacy block, and that block cannot change.

**Dropping the ADD COLUMN guard entirely.** Renumbering was the sole documented
cause of both bricking incidents, and unique-by-construction identifiers
eliminate it, so the guard could be argued unnecessary. Rejected because a
different path to the same collision survives: two agents independently
implementing the same feature produce two distinct migrations that add the same
column. On a fleet of parallel agents that is TBD's normal workload, not an
edge case.

**Adopting an existing migration engine.** None can run in-process here.
Flyway is JVM-only; dbmate, goose, golang-migrate and Atlas are Go libraries or
CLI binaries with no maintained C ABI to bridge from Swift; Alembic is Python.
Migrations must run at daemon startup against the user's database, so a
developer-run CLI cannot be the runtime path. `SQLiteMigrationManager.swift` is
the one Swift-native file-based migrator with the right shape — `<version>_<name>.sql`
discovered from a bundle — but it is built on SQLite.swift, so adopting it
means running a second SQLite abstraction beside GRDB, and it shows no Swift 6
or strict-concurrency support.

**Atlas as the linter.** `atlas migrate lint` is the one survivor of that
survey: it supports SQLite via `sqlite://dev?mode=memory`, it is git-aware via
`--git-base`, and it would cover two of our six checks — replaying the chain,
and detecting edits to existing migration files.

Rejected because its versioned workflow is built on `atlas.sum`, a committed
integrity file listing a checksum per migration. Atlas's own documentation
states that adding a migration changes that file and "will raise merge
conflicts in most version control systems", and presents this as the point:
it "forces developers to address conflicts before merging". That is a coherent
position and the exact opposite of this design's. Adopting Atlas would
reintroduce, by intent, the single always-touched file we are paying to remove
— alongside a Go binary dependency in CI and in every contributor's pre-push
hook, for two checks that are a few dozen lines of Python here.

## Consequences

Three shapes coexist permanently — the frozen Swift block, `.sql` files, and
the Swift escape hatch — where today there is one. That is the main cost of
this design, and `Sources/TBDDaemon/Database/CLAUDE.md` has to carry it.

We also give up a forcing function, and it is worth naming because Atlas
charges for it deliberately. Today a merge conflict makes two people notice
that they both added a migration and look at the pair together. After this
change, two concurrent migrations merge silently. What stands in for that
review moment is mechanical rather than human: statements are idempotent and
order-independent by lint, the ADD COLUMN guard absorbs the common collision,
and history cannot be edited. If a class of defect starts slipping through that
a conflict would have caught, that is evidence against this design.

In exchange, schema archaeology becomes a grep over one file per change rather
than a scroll through a 1500-line function, each migration diffs in isolation
for review, the schema history is legible to someone who does not read GRDB's
DDL builder, and the freeze on migration history stops being a convention
people remember and becomes a check that fails.

## What would show this is wrong

- The `Bundle.module` spike fails in the daemon or under `scripts/test.sh`.
- The statement allowlist proves too narrow in practice and migrations start
  routinely taking the Swift escape hatch, which would mean the conflict rate
  never fell.
- The linter's ADD COLUMN skip drifts from the loader's despite the parity
  fixture, producing a migration that lints clean and fails at runtime.
