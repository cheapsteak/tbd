# Conductor Import — Design

**Date:** 2026-05-16
**Status:** Approved (brainstorming complete, ready for planning)

## Goal

Let users migrate their existing [Conductor](https://conductor.build) worktrees into TBD with a single script. Migration is non-destructive and supports dual-use: Conductor keeps working alongside TBD, and the same worktree directory is now managed by both apps.

## What's inherited for free

In-place adoption gives us two big wins with zero migration code:

- **Claude session transcripts.** TBD discovers Claude Code transcripts at `~/.claude/projects/<encoded-cwd>/` keyed by the worktree's directory path (`Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift`). Because the worktree directory doesn't move, the encoded cwd is unchanged, and TBD picks up whatever transcripts already exist for that path.
- **Setup / archive / run hooks.** TBD's `HookResolver.resolve()` reads `conductor.json` from the repo root as a deprecation-warned fallback (`Sources/TBDDaemon/Hooks/HookResolver.swift:63-69`). Conductor users typically have a `conductor.json` checked into the repo describing their setup/archive/run scripts; adopted worktrees execute those identically to how Conductor did. The user gets a `consider migrating to .worktree-hooks/` warning, but everything works.

## Non-goals

- Migrating Conductor's own `session_messages` table (its custom chat UI rendering). TBD has no equivalent feature — it lives off Claude Code's transcript files, which are already in the right place.
- Migrating linked or secondary Conductor workspaces (only the primary `workspace_path`).
- Migrating Conductor-DB-only metadata like `custom_prompt_*`, `agent_personality`, `model`, `permission_mode` per workspace. TBD doesn't have direct equivalents for most of these.
- Writing to Conductor's database. The migration never modifies Conductor state; users can manually archive in Conductor's UI if they want.
- Moving files. Worktree directories stay where Conductor put them (`~/conductor/workspaces/<repo>/<name>/`).

## Why this works without a filesystem move

TBD's reconcile loop only filters by canonical/legacy path prefixes when **auto-discovering** unknown worktrees from `git worktree list`. Once a worktree row exists in TBD's database, reconcile leaves it alone regardless of where the path lives:

- The "add unknown worktrees" branch (`WorktreeLifecycle+Reconcile.swift:140-152`) skips entries already in `dbPaths`.
- The "archive missing worktrees" branch (line 109) only archives rows whose path is *missing from git's worktree list* — the adopted Conductor path is in git's list, so it stays.
- Every other path-consuming site in the codebase (archive, revive, status refresh, file viewer, terminal cwd) reads `worktree.path` from the database row.

So adoption reduces to "insert a `worktrees` row whose path field points outside the canonical prefix." No reconcile changes, no prefix filter relaxation.

## Architecture

Two artifacts:

1. **`tbd worktree adopt`** — a new Swift CLI subcommand. General-purpose primitive for registering an existing git worktree directory into TBD's database. Independent of Conductor.
2. **`scripts/import-conductor.sh`** — a bash script that reads Conductor's SQLite database, generates a migration plan, and drives `tbd repo add` + `tbd worktree adopt` to execute it.

This split keeps Conductor-specific schema knowledge out of the Swift binary. `tbd worktree adopt` is independently useful for users who created worktrees via raw `git worktree add` or other tools.

## Part 1: `tbd worktree adopt`

### Invocation

```
tbd worktree adopt <path> [--repo <id-or-path>] [--name <name>]
```

### Behavior

1. Resolve `<path>` to an absolute, symlink-canonicalized path.
2. Verify it's a valid git worktree: `git -C <path> rev-parse --is-inside-work-tree`.
3. Find the parent repo via `git -C <path> rev-parse --git-common-dir`, then walk to the repo root.
4. Resolve the TBD repo record:
   - If `--repo` is set, use it.
   - Otherwise match by `root_path` against TBD's `repos` table.
   - Error if no match — the caller (script or user) is responsible for adding the repo first.
5. Verify the path appears in `git worktree list` for the resolved repo. If not, error with a hint to run `git worktree repair`.
6. Idempotency:
   - If a TBD `worktrees` row already has this exact path and is active, exit 0 with `already adopted: <name>`.
   - If a row exists but is archived, revive it (reuse existing `WorktreeRevive` flow) rather than inserting a new row.
7. Read the branch from git (`git -C <path> branch --show-current`); if detached HEAD, store the commit SHA.
8. Insert (or revive) the worktree row via a new daemon RPC method:
   - `repoID` = resolved repo
   - `name` = `--name` flag, else last path component of the resolved path
   - `branch` = from git
   - `path` = canonicalized input path
   - `tmuxServer` = `TmuxManager.serverName(forRepoPath: repo.path)`
   - `status = .active`

### Files touched

- `Sources/TBDCLI/Commands/WorktreeCommands.swift` — add `WorktreeAdopt` subcommand to the `worktree` command group.
- `Sources/TBDShared/` (RPC types) — add `WorktreeAdoptRequest` / `WorktreeAdoptResponse`.
- `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift` — add the new handler.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Adopt.swift` — new file. Mirrors the structure of `+Create.swift` but skips the `git worktree add` step (the worktree already exists on disk).
- `Tests/TBDDaemonTests/WorktreeAdoptTests.swift` — adoption tests.

### Tests

- Adopting a valid out-of-prefix git worktree succeeds and the row appears in the database with the correct path.
- Adopting the same path twice is a no-op (second call exits 0, no duplicate row).
- Adopting a previously-archived worktree revives it.
- Adopting a non-git directory errors with a clear message.
- Adopting a path whose git common-dir doesn't match any TBD repo errors with "register the repo first."
- Adopting a path not in `git worktree list` errors with a `git worktree repair` hint.
- Adopting a detached-HEAD worktree stores the commit SHA in the branch column.

## Part 2: `scripts/import-conductor.sh`

### Invocation

```
scripts/import-conductor.sh [--all] [--repo <name>] [--dry-run]
```

### Inputs

- `~/Library/Application Support/com.conductor.app/conductor.db` (SQLite + WAL). Copied to `$(mktemp)` before reading to avoid contention with a running Conductor.
- `tbd` CLI on `$PATH`.
- `sqlite3` (ships with macOS).

### Flow

**1. Preconditions.** Check `tbd`, `sqlite3`, and the Conductor DB. Copy DB to tmp, install `trap rm` for cleanup.

**2. Query Conductor.** Two queries:

```sql
SELECT id, name, root_path, default_branch FROM repos;

SELECT w.id, w.repository_id, w.directory_name, w.branch, w.state, w.workspace_path
FROM workspaces w
WHERE w.state = 'ready'
  AND w.workspace_path IS NOT NULL
  AND (:repo_filter_id IS NULL OR w.repository_id = :repo_filter_id);
```

Under `--all`, the state filter becomes `w.state IN ('ready', 'archived')`.

Use `-separator $'\x1f'` (ASCII unit separator) to safely handle paths with spaces.

**3. Build the plan** (no writes).

For each Conductor repo referenced by selected workspaces:
- If the repo's `root_path` doesn't exist on disk → mark repo and all its workspaces as `skip: repo path missing`.
- If TBD already has a repo with the same `root_path` (matched via `tbd repo list --json` — adding the `--json` flag is part of this work if not already present) → `reuse: <repo-name>`.
- Otherwise → queue `tbd repo add <root_path> --name <name>`.

For each workspace:
- If `workspace_path` doesn't exist on disk → `skip: path missing`.
- If `git -C <workspace_path> rev-parse --is-inside-work-tree` fails → `skip: not a git worktree`.
- Otherwise → queue `tbd worktree adopt <workspace_path>`. (Idempotency lives inside `adopt`; the script doesn't pre-check.)

**4. Print the plan.**

```
Conductor → TBD migration plan
──────────────────────────────
Repos:
  + longeye-app    /Users/chang/projects/longeye-app    (default branch: main)
  ~ standup-kit    /Users/chang/projects/standup-kit    (already in TBD, reusing)

Workspaces:
  + denver-v3      cw/denver-v3    →  longeye-app
  + cambridge-v1   cw/cambridge-v1 →  longeye-app
  + atlanta        main            →  standup-kit
  - riyadh-v1      (skip: path /Users/chang/conductor/workspaces/longeye-docs/riyadh-v1 not found)

Summary: 1 repo to add, 1 to reuse · 3 workspaces to adopt, 1 to skip
```

Under `--dry-run`, exit here.

**5. Execute.** Stream per-item progress:

```
[1/4] adding repo longeye-app… ok
[2/4] adopting denver-v3… ok
[3/4] adopting cambridge-v1… ok
[4/4] adopting atlanta… ok
```

Continue on error. If a step fails, print `FAILED: <reason>` and continue.

**6. Summary line.**

```
Done: 1 repo added · 3 worktrees adopted · 1 skipped · 0 failed
```

### Exit codes

- `0` — success, even if some items were skipped (skipping is expected behavior for missing paths).
- `1` — at least one `tbd` invocation returned an error (distinct from a skip).
- `2` — script-level usage error (bad flag, missing dependency, no Conductor DB).

### Implementation notes

- Pure bash. No Python.
- `set -euo pipefail` at the top, locally relaxed inside the execute loop so continue-on-error works.
- NUL/unit-separator-delimited sqlite output for safe path handling.
- If `tbd repo list --json` doesn't yet exist, add it as part of this work (small flag, generally useful for scripting).

## Part 3: README documentation

New section in the project README, placed before "Critical Rules":

````markdown
## Migrating from Conductor

Adopt your existing Conductor worktrees into TBD in place — no files moved, branches untouched, Conductor keeps working alongside. By default, only active (`ready`) Conductor workspaces are adopted, and any repos they reference are auto-registered in TBD.

```sh
./scripts/import-conductor.sh --dry-run    # preview
./scripts/import-conductor.sh              # run
```

Flags:
- `--all` — also adopt archived Conductor workspaces.
- `--repo <name>` — limit to one Conductor repo (e.g. `--repo longeye-app`).
- `--dry-run` — print the plan, don't write anything.

Idempotent — safe to re-run as you create new Conductor worktrees.

Existing Claude session transcripts and `conductor.json` hooks are picked up automatically — nothing extra to migrate.
````

## Edge cases & error handling

**Per workspace (filesystem / git state):**

| Case | Handled by | Behavior |
|---|---|---|
| `workspace_path` doesn't exist on disk | script | skip, log `path missing` |
| Path exists but isn't a git worktree | script | skip, log `not a git worktree` |
| Git common-dir doesn't match any TBD repo | `adopt` | error: "register the repo first with `tbd repo add <root>`"; script catches and continues |
| Path is a git worktree but not in `git worktree list` (corrupt git state) | `adopt` | error: "git worktree list does not include this path; run `git worktree repair`" |
| Path already in TBD as active | `adopt` | exit 0, log `already adopted` |
| Path already in TBD as archived | `adopt` | revive the row |
| Detached HEAD | `adopt` | store commit SHA as branch |

**Per Conductor repo (registration):**

| Case | Handled by | Behavior |
|---|---|---|
| `repos.root_path` doesn't exist on disk | script | skip the repo and its workspaces, log `repo path missing` |
| TBD already has a repo at the same `root_path` | script | reuse existing repo |
| Two Conductor repos with the same `root_path` | script | use the first, warn on duplicates |
| `tbd repo add` fails | script | log error, skip workspaces for that repo, continue |

**Conductor-side:**

| Case | Behavior |
|---|---|
| Conductor is currently running | not blocked — dual-use is intentional |
| Conductor DB locked (WAL contention) | preempted by copying DB to tmp before reading |
| Conductor DB schema changed in a future version | `sqlite3` query fails loudly with the SQL error; user files an issue |
| `workspace_path` is NULL in the DB | skip with `null path` reason |

**Script-level:**

| Case | Behavior |
|---|---|
| `sqlite3` not on `$PATH` | exit 2 with install hint |
| `tbd` not on `$PATH` | exit 2 with hint |
| Conductor DB missing entirely | exit 0 with "no Conductor data found, nothing to migrate" |
| `--repo <name>` with no matching repo | exit 1 with "no Conductor repo matches '<name>'" |
| Zero workspaces match the filter | print "no workspaces to migrate" and exit 0 |

**Archived-worktree note.** Conductor's archived workspaces usually have their on-disk directory removed. Under `--all`, most archived rows will land in the "path missing" skip bucket — that's correct. The few whose directory still exists get adopted normally.

## Conductor database reference

For implementer convenience, the two tables the script reads:

```sql
-- repos
id TEXT PRIMARY KEY,
name TEXT,
root_path TEXT,
default_branch TEXT DEFAULT 'main',
-- (plus many fields we don't read: setup_script, run_script, custom_prompt_*, etc.)

-- workspaces
id TEXT PRIMARY KEY,
repository_id TEXT,
directory_name TEXT,
branch TEXT,
state TEXT DEFAULT 'active',   -- observed values: 'ready', 'archived'
workspace_path TEXT,            -- absolute path, e.g. /Users/chang/conductor/workspaces/longeye-app/denver-v3
-- (plus many fields we don't read: setup_log_path, derived_status, linked_workspace_ids, etc.)
```

## Open implementation questions

These are decisions to make during implementation, not blockers for planning:

- **`tbd repo list --json`** — does this exist today? If not, add it as a small flag during this work. Used by the script to detect already-registered repos by `root_path`.
- **`tbd worktree list --json`** — same question, for idempotency reporting (optional polish; the script doesn't strictly need it since `adopt` handles the dedup).

## Future work (out of scope)

- A `tbd worktree relocate <name> <new-path>` command for users who later want to move an adopted worktree from `~/conductor/...` into TBD's canonical `~/tbd/worktrees/...` layout. Today they can do this manually with `mv` + `git worktree repair` + `tbd worktree archive` + `tbd worktree adopt`.
- Importers for other worktree managers (Phantom, Worktrees.nvim) — the `tbd worktree adopt` primitive supports them already; only the source-DB-reading layer would be new.
