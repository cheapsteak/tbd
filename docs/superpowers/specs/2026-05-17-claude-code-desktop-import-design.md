# Claude Code Desktop Import — Design

**Date:** 2026-05-17
**Status:** Approved (brainstorming complete, ready for implementation)

## Goal

Let users migrate their existing [Claude Code Desktop](https://claude.com/claude-code) worktrees into TBD with a single script. Migration is non-destructive and dual-use: Claude Code Desktop keeps working alongside TBD, and the same worktree directory is managed by both apps.

## What's inherited for free

In-place adoption gives the same two wins as the Conductor migration ([2026-05-16-conductor-import-design.md](2026-05-16-conductor-import-design.md)) with zero migration code:

- **Claude session transcripts.** TBD's `ClaudeSessionScanner` looks at `~/.claude/projects/<encoded-cwd>/` keyed by the worktree's directory path. The worktree doesn't move, so transcripts surface automatically.
- **`.worktree-hooks/`.** TBD's `HookResolver` reads `.worktree-hooks/` from the worktree (with repo-level fallback). Whatever the user has set up keeps working.

## Why this is simpler than the Conductor import

Claude Code Desktop's worktrees are already registered in the parent repo's `git worktree list` (verified: in a real-world repo, 17 of 59 worktrees were Claude Code Desktop ones, identifiable by the `/.claude/worktrees/` path segment). No external SQLite DB, no WAL contention, no SQL. The data source is `git worktree list --porcelain` filtered by path prefix.

## Non-goals

- Walking the filesystem for repos. The user names the repo explicitly via `--repo <path>`.
- Migrating any Claude Code Desktop UI state, agent slot config, or shell-snapshot data — TBD has no analogues.
- Moving files. Worktrees stay at `<repo>/.claude/worktrees/<name>/`.

## Why this works without a filesystem move

Same property the Conductor design relied on: TBD's reconcile loop only filters by canonical/legacy path prefixes when **auto-discovering** unknown worktrees from `git worktree list`. Once a row exists in TBD's database, reconcile leaves it alone regardless of where the path lives. Adopting a `.claude/worktrees/...` path inserts a row that reconcile won't touch.

## Architecture

One artifact: **`scripts/import-claude-code-desktop.sh`**, a bash script that reads `git worktree list --porcelain` for each user-specified repo, generates a migration plan, and drives `tbd repo add` + `tbd worktree adopt` to execute it. No Swift changes — `tbd worktree adopt`, `tbd repo add`, and `tbd repo list --json` already exist (shipped in PR #161).

## Invocation

```
scripts/import-claude-code-desktop.sh --repo <path> [--repo <path>...] [--include-agents] [--dry-run]
```

- `--repo <path>` — required, repeatable. Accepts *any* path inside a repo: the main checkout, a Claude Code Desktop worktree, a TBD worktree, or any subdirectory. The script normalizes each to the main repo root before scanning.
- `--include-agents` — also adopt directories named `agent-*` (skipped by default; see below).
- `--dry-run` — print the plan, don't call any `tbd` write commands.

### Skipping agent worktrees

Claude Code Desktop creates two kinds of worktrees under `.claude/worktrees/`: user-managed ones (typically named `<adjective>-<surname>[-<hash>]` with a `cw/` branch) and scratch worktrees from individual agent runs (named `agent-<hash>` with arbitrary branch names). Users typically want only the first set in TBD. The importer skips directories matching `agent-*` by default; `--include-agents` opts back in.

## Flow

**1. Preconditions.** `tbd` and `git` on `$PATH`; at least one `--repo` provided.

**2. Resolve repo roots.** For each `--repo <path>`:
- `realpath` the input.
- `git -C <path> rev-parse --path-format=absolute --git-common-dir` → walk one level up → main repo root.
- If the path isn't inside a git repo → `skip: not inside a git repo`.
- De-dupe roots that two `--repo` args resolved to the same place.

**3. Build the repo plan.** Call `tbd repo list --json` once; for each resolved root mark `reuse` (already registered) or `add`.

**4. Enumerate Claude Code Desktop worktrees.** For each root:
- `git -C <root> worktree list --porcelain`, parse into (path, branch) tuples.
- Filter to entries whose path starts with `<root>/.claude/worktrees/`.
- Per-worktree skip checks: `[[ ! -d <path> ]]` → `skip: path missing`; basename matches `agent-*` and `--include-agents` not set → `skip: agent worktree`.
- Otherwise → queue `adopt`.

**5. Print the plan.**

```
Claude Code Desktop → TBD migration plan
────────────────────────────────────────
Repos:
  + acme-app    /Users/me/projects/acme-app    (will add)
  ~ acme-prod   /Users/me/projects/acme-prod   (already in TBD, reusing)

Worktrees:
  + focused-zhukovsky-f41df4    cw/focused-zhukovsky-f41df4    →  acme-app
  + agent-a06139d7743d36520     cw/some-branch                 →  acme-app
  - stale-dir                   (skip: path missing)

Summary: 1 repo to add, 1 to reuse · 2 worktrees to adopt, 1 to skip
```

Under `--dry-run`, exit here.

**6. Execute.** Two phases, mirroring `import-conductor.sh`:
- Phase A: `tbd repo add <root>` for each `add`. On failure, mark child worktrees `skip: parent repo unavailable` and continue.
- Phase B: `tbd worktree adopt <path>` for each `adopt`. Idempotency lives in `adopt`: existing-active is a no-op, archived is a revive.
- Stream per-item progress: `[i/N] adopting <name>… ok / FAILED`.

**7. Summary line.**

```
Done: 1 repo added · 2 worktrees adopted · 1 skipped · 0 failed
```

### Exit codes

- `0` — success, even if some items were skipped.
- `1` — at least one `tbd` invocation returned an error.
- `2` — script-level usage error (no `--repo`, bad flag, missing dependency).

### Implementation notes

- Pure bash. No Python, no SQLite.
- `set -euo pipefail` at the top, locally relaxed inside execute loops.
- Porcelain parsing via the standard `worktree`/`HEAD`/`branch` triple. Detached worktrees emit `HEAD <sha>` + `detached` and drop the `branch` line — handled by the same parser; `adopt` stores empty string as the branch in that case (matches `GitManager.parseWorktreeList` behavior).

## Edge cases & error handling

| Case | Handled by | Behavior |
|---|---|---|
| `--repo <path>` not inside a git repo | script | skip, log `not inside a git repo` |
| Two `--repo` args resolve to the same root | script | de-dupe with a note |
| Repo root not registered in TBD | script | queue `tbd repo add <root>` |
| No `.claude/worktrees/` entries for a repo | script | log `no Claude Code Desktop worktrees in <repo>` |
| Worktree path in git list but missing on disk | script | skip, log `path missing` |
| Directory named `agent-*` (and `--include-agents` not set) | script | skip with `agent worktree (--include-agents to adopt)` |
| Path already in TBD (active) | `adopt` | exit 0, log `already adopted` |
| Path already in TBD (archived) | `adopt` | revive |
| `tbd repo add` fails | script | log, skip child worktrees, continue |
| `tbd worktree adopt` fails | script | log, continue, count failures |
| Detached HEAD | `adopt` | empty branch column (matches existing behavior) |

## Testing

No Swift code is added, so all tests are bash-script level:

- **Plan generation** (against real `git worktree add` in a tempdir): worktrees under `.claude/worktrees/` are queued; worktrees elsewhere are filtered out; missing directories show as `skip: path missing`.
- **Argument handling**: `--repo` is required; repeated `--repo` paths that resolve to the same root are de-duped; a `--repo` pointing inside a worktree resolves to the main repo root.
- **Dry-run**: no `tbd` write commands are invoked.

Fixtures use `acme-app` / `acme-prod` placeholders — never `longeye`.

## README

New sibling section after `## Migrating from Conductor`:

````markdown
## Migrating from Claude Code Desktop

Adopt your existing Claude Code Desktop worktrees into TBD in place — no files moved, branches untouched. Pass any path inside the repo (main checkout or any worktree); the script resolves to the main repo root and adopts every worktree under `.claude/worktrees/`. Repos not yet in TBD are auto-registered.

```sh
./scripts/import-claude-code-desktop.sh --repo ~/projects/acme-app --dry-run
./scripts/import-claude-code-desktop.sh --repo ~/projects/acme-app
```

Flags:
- `--repo <path>` — required, repeatable. Any path inside the repo.
- `--dry-run` — print the plan, don't write anything.

Idempotent — safe to re-run as you create new Claude Code Desktop worktrees.

Existing Claude session transcripts and `.worktree-hooks/` configs are picked up automatically — nothing extra to migrate.
````

## Future work (out of scope)

- Importers for other worktree managers (Phantom, Worktrees.nvim) — the `tbd worktree adopt` primitive supports them already; only the source-specific scanning layer would be new.
