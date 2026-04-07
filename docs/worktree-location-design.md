# Worktree Location Design

Status: **Proposal** — awaiting user decision before implementation.
Author: Claude (design pass, 2026-04-07)

## 1. Current behavior

TBD creates every worktree inside the repo it belongs to:

```
<repo-root>/.tbd/worktrees/<auto-name>/
```

The path is hardcoded in `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift:34-35`:

```swift
let worktreePath = (repo.path as NSString)
    .appendingPathComponent(".tbd/worktrees/\(name)")
```

Same string appears in the retry path (`+Create.swift:136`) and in the reconciliation filter (`+Reconcile.swift:108-112`), which uses `.appendingPathComponent(".tbd/worktrees/")` to decide which on-disk worktrees belong to TBD.

Persistence:

- **Repos** are keyed by UUID (`Sources/TBDShared/Models.swift:4`) but the `path` column has a `.unique()` constraint (`Sources/TBDDaemon/Database/Database.swift:55`). The DB has no relocation logic — moving a repo on disk silently breaks lookup, which is *also* an existing problem this design touches.
- **Worktrees** store an absolute `path` with a `.unique()` constraint (`Database.swift:69`). Paths are persisted, not derived.
- **TBD config dir** is `~/.tbd/` (`Sources/TBDShared/Constants.swift:5-8`), holding `state.db`, `sock`, `tbdd.pid`, `port`, and `conductors/`. TBD does **not** use `~/Library/Application Support/`.

The canonical layout is documented in `docs/superpowers/specs/2026-03-21-tbd-design.md:171` and exercised by 40+ tests across `WorktreeLifecycleTests`, `DatabaseTests`, and `SystemPromptBuilderTests` that hard-code the `.tbd/worktrees/` substring.

## 2. Problem

Putting TBD's metadata inside the repo working tree leaks TBD into every tool that looks at the repo:

1. **`git status` noise** — `.tbd/` shows up as untracked (unless gitignored, which forces every TBD-managed repo to add a line to `.gitignore` or `.git/info/exclude`).
2. **IDE/file-tree clutter** — Xcode, VS Code, and Finder all show `.tbd/` and recursively index the worktrees, which can be many GB and contain *other* `.git` directories. This regularly confuses search, "Find in Files", and indexers.
3. **Backup/sync hazards** — Time Machine, Dropbox, iCloud Drive, and rsync-based backups will happily duplicate every worktree under the repo. A 200 MB repo with 10 worktrees becomes ~2 GB of backed-up duplicates.
4. **Conceptual mismatch** — worktrees are a TBD-managed runtime concept, not a project artifact. They have no business living next to `Package.swift`.
5. **Permission edge cases** — read-only repos, network-mounted repos, and repos under restricted directories (e.g. `/Applications/...`) cannot host worktrees today.

## 3. Options

| Option | Layout | Pollutes repo? | Survives repo move? | Collisions? | Discoverable? | Migration cost |
|---|---|---|---|---|---|---|
| **A. App-support, UUID-namespaced** | `~/.tbd/worktrees/<repo-uuid>/<wt-name>/` | No | Yes (if repo lookup is fixed) | No (UUID) | Medium (hidden dir) | Medium |
| **B. App-support, name-namespaced** | `~/.tbd/worktrees/<repo-name>/<wt-name>/` | No | Yes | **Yes** (two repos named `app`) | Medium | Medium |
| **C. Home dir, visible** | `~/tbd-worktrees/<repo-name>/<wt-name>/` | No | Yes | Yes | High | Medium |
| **D. Sibling dir** | `<repo-parent>/<repo-name>.tbd/<wt-name>/` | No (sibling) | No (breaks on move) | Possible | High | Low |
| **E. Status quo** | `<repo>/.tbd/worktrees/<wt-name>/` | **Yes** | No | No | High | None |
| **F. Per-repo override + default A** | A by default, override stored in `repos.worktree_root` | No | Yes | No | Configurable | Medium |

Notes on rejected options:

- **B** loses the "no collisions" property the moment a user adds two repos with the same basename (e.g., a fork). Bad default.
- **C** clutters `$HOME`, which users notice and dislike.
- **D** preserves the move-fragility we already have *and* leaves crumbs in the parent directory, often a shared `~/projects/` folder. Worst of both worlds.
- **E** is what we have. Section 2 lists why it has to go.

## 4. Recommendation

**Option F: default to A (`~/.tbd/worktrees/<repo-uuid>/<wt-name>/`), with an optional per-repo `worktree_root` override persisted in `state.db`.**

Rationale:

1. **Reuses existing infrastructure.** TBD already owns `~/.tbd/`. No new directory convention to teach users. `~/Library/Application Support/TBD/` would be more "Mac-correct" but inconsistent with where `state.db` already lives, and migrating *that* is out of scope.
2. **UUID namespacing is collision-proof and rename-proof.** The repo's display name and filesystem path can change freely without touching the worktree directory. This also nudges us toward fixing the latent "moved repo breaks lookup" bug — once worktrees no longer derive from `repo.path`, the only thing tying a repo to its filesystem location is the `repos.path` column, which can be repaired with a `tbd repo relocate` command later.
3. **Per-repo override gives power users an escape hatch** without changing the default. Useful for:
   - Repos on a fast scratch SSD while the main repo lives on a slow networked drive.
   - Users who *want* sibling-dir layout for muscle memory.
   - Tests and CI that need a tmpdir.
4. **Discoverability** is acceptable: `tbd worktree list` already prints absolute paths, and we can add `tbd worktree reveal <name>` (open in Finder) if users complain. The hidden-dir cost is real but small.
5. **`~/.tbd/worktrees/` is shallow enough** that `git worktree repair` and manual recovery work fine. Each `<repo-uuid>/` subdirectory is self-contained.

### Resulting layout

```
~/.tbd/
  state.db
  sock
  tbdd.pid
  port
  conductors/
  worktrees/
    1f3a...c2/                  # repo UUID
      20260407-negative-crane/
      20260321-fuzzy-penguin/
    9b8e...44/
      20260315-tame-otter/
```

### Schema change

Add to the `repos` table:

```sql
ALTER TABLE repos ADD COLUMN worktree_root TEXT;  -- NULL = use default
```

When `NULL`, the daemon computes `Constants.configDir / "worktrees" / repo.id.uuidString`. When set, it's used verbatim. The migration is a single new GRDB migration step (`vN`) per `CLAUDE.md`'s rules; the `Repo` Codable model in `Sources/TBDShared/Models.swift` gains an optional `worktreeRoot: String?` so existing rows still decode.

### Code change surface (for the implementation pass, not this doc)

- New helper `WorktreeLayout.basePath(for: Repo) -> String` in `TBDDaemon` (or `TBDShared`).
- Replace the two hardcoded sites in `WorktreeLifecycle+Create.swift` and the filter in `WorktreeLifecycle+Reconcile.swift`.
- Update tests that currently grep for `.tbd/worktrees/` — they should call the same helper, or a test-only override sets `worktree_root` to a tmpdir.
- Add `tbd repo set-worktree-root <repo> <path>` CLI command (and matching RPC) for the override.
- Ensure the per-repo dir is created lazily on first worktree creation, not on repo add (so users who never create worktrees don't get empty dirs).

## 5. Migration plan

Existing installs have worktrees at `<repo>/.tbd/worktrees/<name>/` with absolute paths persisted in `state.db`. We need to move the directories *and* update the DB without leaving git's `.git/worktrees/<name>/gitdir` files pointing into space.

### Strategy: opt-in migration command, grandfather by default

On daemon upgrade we do **not** auto-move anything. New worktrees go to the new location; old worktrees stay where they are and continue to work because their absolute path is in the DB. Both layouts coexist indefinitely.

A new CLI command performs the migration explicitly:

```
tbd repo migrate-worktrees <repo>          # one repo
tbd repo migrate-worktrees --all           # everything
tbd repo migrate-worktrees --dry-run ...   # show what would happen
```

### Per-worktree migration steps

For each worktree owned by the repo:

1. **Pre-flight checks** (abort the whole repo if any fail; report which):
   - Worktree status is `.ready` (not `.creating`, not `.error`). Skip in-flight worktrees.
   - No uncommitted changes (`git status --porcelain` empty) — *or* `--force` was passed.
   - No running processes have CWD inside the worktree. Use `lsof +D <path>` or just check TBD's own terminal/conductor records in `state.db`. Refuse to migrate if a TBD terminal is attached.
   - Destination path does not already exist.
2. **Move the directory** with `FileManager.moveItem(at:to:)`. This is atomic on the same volume; if the new path is on a different volume (unlikely for `~/.tbd/`), fall back to copy-then-delete and only delete after the DB update succeeds.
3. **Repair git's bookkeeping.** A worktree has two pointers to fix:
   - `<main-repo>/.git/worktrees/<wt-name>/gitdir` contains the absolute path to the worktree's `.git` file.
   - `<worktree-path>/.git` contains `gitdir: <main-repo>/.git/worktrees/<wt-name>`.
   The cleanest fix is `git -C <new-worktree-path> worktree repair`, which rewrites both. Verify with `git worktree list` from the main repo.
4. **Update `state.db`** in a transaction: `UPDATE worktrees SET path = ? WHERE id = ?`. If the transaction fails, `git worktree repair` again with the *old* path (it's idempotent) and fail loudly.
5. **Sweep the old `<repo>/.tbd/worktrees/` directory.** If it's now empty, remove it. Leave `<repo>/.tbd/` alone in case the user has other files in it (we shouldn't, but be polite).

### Failure recovery

The dangerous moment is between step 2 (directory moved) and step 4 (DB updated). Make it recoverable:

- **Write a journal file** at `~/.tbd/migration-journal.json` *before* step 2, containing `{worktree_id, old_path, new_path, started_at}`. Delete it after step 4 succeeds.
- **On daemon startup**, if the journal exists, run a recovery routine: check whether `old_path` or `new_path` exists on disk, and reconcile the DB row to match reality. If both exist, refuse to start and surface an error (a human needs to look).
- **Worst case** (directory moved, DB not updated, journal lost): the worktree appears as `.error` in TBD's reconciler because its persisted path doesn't exist. The user can manually run `tbd worktree forget <name>` and re-discover the moved directory, or move the directory back.

### What if the repo itself can't be located anymore?

If the repo's `repos.path` is stale (user moved the repo), migration cannot run because step 3 needs the main repo's `.git/worktrees/` directory. The migration command should detect this, refuse, and tell the user to run `tbd repo relocate <repo> <new-path>` (a new command that updates `repos.path`). That command is a prerequisite, not part of this design — note it as a follow-up.

## 6. Open questions for the user

1. **Default location.** Confirm `~/.tbd/worktrees/<repo-uuid>/<wt-name>/`, or do you prefer `~/Library/Application Support/TBD/worktrees/...` (more Mac-correct, inconsistent with current `~/.tbd/`)?
2. **Auto-migration vs opt-in.** This proposal grandfathers existing worktrees and requires `tbd repo migrate-worktrees` to move them. Would you rather auto-migrate on daemon upgrade (riskier, but no manual step)?
3. **Should the per-repo override (`worktree_root`) ship in the same change**, or land as a follow-up once the default works? Shipping it together costs little and makes tests easier (they can set a tmpdir override instead of relying on path-substring asserts).
4. **Display name vs UUID in the path.** UUIDs are ugly when a user `cd`s into the dir. Alternative: `~/.tbd/worktrees/<sanitized-display-name>-<uuid-prefix>/<wt-name>/` — readable *and* collision-proof. Slightly more code. Worth it?
5. **`tbd repo relocate`** for the moved-repo case — in scope here, or a separate ticket? It's a real bug today and this design surfaces it but doesn't fix it.
6. **Tests.** ~40 tests assert the literal `.tbd/worktrees/` substring. Are you OK with a one-time sweep to route them through `WorktreeLayout.basePath(for:)`, or would you rather keep the substring as a backwards-compat assertion against the *old* layout while the new layout is tested separately?
