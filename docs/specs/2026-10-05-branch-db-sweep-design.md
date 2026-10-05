# Branch database sweep

A user-land script, `scripts/sweep-branch-dbs.sh`, that finds and drops the
per-worktree databases a project keeps on a local Postgres once their
worktrees are gone. It is developer tooling in the family of
`scripts/sweep-scratchpads.sh` and `scripts/reclaim-build.sh`, not daemon code:
no Swift, no migration, no config column, no flag.

## The problem

Some projects give each worktree its own "branch database": a database on the
developer's local Postgres, copied from a template when the worktree is set up,
so that agents working in parallel never share mutable schema or data. The
project names each database from the worktree, as `<prefix><label>`, where the
label is derived from the worktree directory's basename.

Nothing drops that database when the worktree goes away. TBD archives the
worktree and reclaims its directory, but it never created the database and has
no idea it exists. Each one is a full copy of the template, so on a busy machine
they pile up into one of the largest real-byte leaks on the disk. Unlike the
`node_modules` and `.venv` trees in the same worktrees, which are APFS clones
whose apparent size `du` overstates, these bytes are real.

Field measurement on one fleet machine: the local cluster held 268 branch
databases totalling 19 GB. 118 of them, 8.9 GB, matched no worktree in any
worktree root. Dropping those 118 by hand returned about 8.9 GB of free space,
as `df` measured it.

## What the script does

`scripts/sweep-branch-dbs.sh --prefix <p>` lists every database whose name
starts with `<p>`, derives a label from every live worktree it can find, and
reports each database as `KEEP` or `ORPHAN` with its size, followed by a total.
That report is the default. With `--apply` it drops the orphans and prints the
change in free disk space, as its sibling scripts do.

- **Prefix** – `--prefix` is required and must match `[A-Za-z0-9_]+`. The
  naming contract belongs to the project, so the script hardcodes no prefix.
  Examples here use `app_db_`.
- **Label rule** – the worktree directory's basename, lowercased, every `-`
  turned into `_`, every character outside `[a-z0-9_]` dropped, and the result
  cut to 54 characters. The database name is the prefix followed by the label.
  A worktree at `.../acme/Fix-Login.v2` has label `fix_loginv2` and database
  `app_db_fix_loginv2`. The rule is pinned by its own test cases, including the
  54-character cut.
- **Roots** – each `--root <glob>` expands to candidate worktree directories,
  for example `--root "$HOME/tbd/worktrees/*/*"`; the option repeats, so
  worktrees made by other tools are covered by adding their roots. Every
  non-archived worktree that `tbd worktree list --json` reports is added
  automatically. When that listing is unavailable (the daemon is down, or the
  `tbd` CLI or `jq` is missing) a dry run still reports, marked incomplete, and
  `--apply` refuses (see Safety rules). `--no-tbd` skips the listing on purpose,
  making the `--root` globs the whole scan.
- **Connection** – psql and dropdb run with the standard Postgres environment
  (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and the rest), plus `--host` and
  `--port` passed straight through. They connect to the `postgres` maintenance
  database.
- **Single-target mode** – `--worktree <path>` computes that one path's label
  and considers exactly that database. It is meant for a repo's archive hook
  (below). It still requires `--prefix`, still applies every safety rule, and
  still reports without dropping unless `--apply` is given.

## Safety rules

The script exists to delete data, and the cost of its two possible mistakes is
lopsided: keeping an orphan costs some disk until the next run, dropping a live
worktree's database destroys someone's working state. Every ambiguity is
therefore resolved toward KEEP.

- **Matching is by prefix in both directions.** A database `<prefix><x>` is kept
  when any live label `L` equals `x`, starts with `x`, or is a prefix of `x`.
  The first direction protects a database whose name was cut shorter than the
  live label, for example by Postgres's 63-byte identifier limit. The second
  protects a database named under a longer cut than the script's 54 characters.
  The cost is that an orphan whose name happens to extend a live label, such as
  `app_db_feature_old` while `feature` is live, survives until that worktree
  goes too. That cost is accepted.
- **Only names the label rule could have made are candidates.** A suffix that
  is empty or contains a character outside `[a-z0-9_]` is reported
  `KEEP foreign` and never dropped. A worktree whose basename yields an empty
  label matches every database, so its presence keeps them all, with a warning.
- **An empty or partial scan refuses.** The run exits non-zero and drops
  nothing when it has no roots, when any `--root` glob matches no directory, or
  when the scan found zero worktree paths in total. An empty scan must never
  read as "everything is an orphan", and a mistyped root must never make that
  root's databases look orphaned. In single-target mode the database is named
  explicitly, so having no roots is only a warning, but a `--root` that matches
  nothing still refuses.
- **A missing TBD listing blocks `--apply`.** If `tbd worktree list --json`
  cannot be read, every TBD worktree outside the `--root` globs would read as an
  orphan, and the likeliest cause, a stopped daemon, says nothing about whether
  those worktrees are alive. So a sweep with `--apply` then exits non-zero
  before querying Postgres and drops nothing. A dry run still prints its report,
  with an `INCOMPLETE` line saying the ORPHAN rows may belong to live TBD
  worktrees and that `--apply` would refuse. An operator whose roots genuinely
  cover everything passes `--no-tbd`, which skips the listing and says so in
  the output. Single-target mode is unaffected, because its target is named
  explicitly; the listing only feeds its shared-database check.
- **A server that is not ready is skipped.** Before listing anything the script
  asks `SELECT pg_is_in_recovery()`. If the answer is anything other than
  false, or if the connection fails for any reason, it reports `SKIP` and exits
  0 without dropping. A server starting up or in crash recovery refuses
  connections with a "the database system is in recovery mode" or "is
  starting up" error; that is a connection failure, and the server's message is
  printed.
- **Connections are re-checked immediately before each drop.** For every
  database it is about to drop, the script re-queries the `pg_stat_activity`
  count for that database and drops only at zero; otherwise it reports
  `KEEP busy`. A failed or unparseable count also keeps. The drop is a plain
  `dropdb`, never `--force`, so Postgres itself refuses a database that someone
  connected to between the check and the drop.
- **Out-of-scope names are never touched.** A database not starting with the
  prefix is never listed. `postgres`, `template0`, `template1` and the
  maintenance database are excluded even when a careless prefix matches them,
  and template databases are excluded by the listing query.
- **Identifiers are safe by construction.** The prefix allows only
  `[A-Za-z0-9_]`, candidate suffixes allow only `[a-z0-9_]`, the one SQL literal
  the script builds also has its quotes doubled, and dropdb receives the name as
  an argument, not as SQL. The prefix is matched with a shell string comparison,
  not `LIKE`, because `_` is a `LIKE` wildcard.

## Where this lives, and why

The naming contract is a per-project theory, in the sense of
[`docs/theory-placement.md`](../theory-placement.md): whether a project keeps
branch databases at all, which server holds them, what prefix it uses, how it
derives and truncates a label, and which worktree roots count are all answers
two reasonable projects give differently. Compiling them into TBD would encode
one project's convention where changing it takes a rebuild and a release. The
root `CLAUDE.md` rule "compile only what user-land cannot do well" applies
directly: a script run by hand, by a scheduler, or from a hook does this job
well. Nothing here is per-event across a fleet, needs liveness attestation, or
protects the integrity of TBD's own record.

Capability moves inward only on field evidence, one piece at a time. If the
script proves itself and projects converge on a contract, a later change can
promote a fact or an actuation into TBD. Until then the script carries the
whole behavior.

## Who reclaims the orphans

The root `CLAUDE.md` asks every durable resource for a named reconciler. These
databases are a durable resource TBD does not create, so none of TBD's three
reconcilers (`OrphanGC`, `AgentReaper`, `WorktreeLifecycle+Reconcile`) owns
them. This script is their reconciler: it compares ground truth (the databases
on the cluster) against intent (the live worktrees across every root) and
reclaims the difference. It runs when an operator runs it, or on whatever
schedule the operator chooses; TBD seeds no scheduler for it.

## Archive-hook recipe

A project that wants a worktree's database dropped as the worktree is archived
can call single-target mode from its `archive` hook. TBD resolves that hook
through `HookResolver`, first match wins:

1. TBD's per-repo hook, `~/tbd/repos/<repo-id>/hooks/archive`, set in the
   repo's settings;
2. `.worktree-hooks/archive` in the worktree;
3. the deprecated `conductor.json` and `.dmux-hooks/` locations;
4. the global default, `~/tbd/hooks/default/archive`.

The hook runs during the slow phase of an archive, after the worktree's
terminals have been torn down and before its directory is handed to the
deletion queue. Its working directory is the worktree, it receives
`TBD_WORKTREE_PATH` among other variables, it has a 60-second timeout, and its
exit status is logged without blocking the archive. A forced archive skips it.

```bash
#!/bin/bash
# archive hook: drop this worktree's branch database
/path/to/tbd/scripts/sweep-branch-dbs.sh \
  --prefix app_db_ \
  --root "$HOME/tbd/worktrees/*/*" \
  --worktree "$TBD_WORKTREE_PATH" \
  --apply
```

Passing `--root` lets the script notice another live worktree with the same
basename under a different root, which would share the database; it then
reports `KEEP shared` and drops nothing. The terminals are gone by this point,
but anything else still connected to the database, such as a dev server started
outside TBD, keeps it via the connection re-check, and the periodic sweep
reclaims it later. Because a hook can be skipped, time out, or meet a stopped
server, the hook is a convenience; the full sweep remains the reconciler.

## Testing

`scripts/sweep-branch-dbs.test.sh` runs with no Postgres, no `tbd` and no real
worktree. Every external command sits behind an environment seam
(`BRANCHDB_PSQL_CMD`, `BRANCHDB_DROPDB_CMD`, `BRANCHDB_TBD_LIST_CMD`,
`BRANCHDB_DF_CMD`), and the harness supplies fakes driven by files in a temp
directory. It covers the label rule, both matching directions, the refusal on
an empty or partial scan, the skip on recovery and on connection failure, the
connection re-check at drop time, the refusal of `--apply` on a missing TBD
listing together with its `--no-tbd` and dry-run branches, protected names, and
single-target mode. The recovery skip, the connection re-check, the empty-scan
refusal and the missing-listing refusal were each
disabled in turn to confirm a case goes red. The harness runs in CI with the
other bash-only script harnesses.

## Rejected alternatives

- **A compiled collector in `OrphanGC`.** It would have to own the naming
  contract, the server location, and which roots count, all per-project
  theories, and it would need a flag, a config surface for the contract, and a
  Postgres client inside the daemon. A wrong default there deletes data on
  every install that enables it. The script holds the same logic where a
  project can read and change it.
- **Dropping from TBD's archive path directly.** Same objection, and it covers
  only TBD's own archives; worktrees removed by other tools, or deleted by hand,
  would still leak. The archive hook gives the same timing without compiling
  the contract.
- **One-directional prefix matching.** Treating a database as live only when
  its suffix equals a live label, or only when the label starts with it, would
  let a name truncated differently from the script's rule read as orphaned.
  Matching in both directions costs a few retained orphans and never costs a
  live database.
- **`DROP DATABASE ... WITH (FORCE)`.** Forcing terminates connections, which
  turns a race with a reconnecting process into data loss. A plain drop that
  fails is reported and retried on the next run.
- **Treating archived TBD worktrees as live.** An archived worktree's directory
  is already queued for deletion, so keeping its database for a possible revive
  would keep most of the leak this script exists to reclaim. A revived worktree
  gets a database the way any new worktree does, if the project's setup hook
  creates one.
