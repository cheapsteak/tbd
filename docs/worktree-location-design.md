# Worktree Location Design

Status: **Proposal v5** — slot is the sanitized display name, no disambiguator. Collisions are refused at `repo add`. Auto-migrate moves everything.
Author: Claude (design pass, 2026-04-07)

## Decisions locked in (round 1)

1. Default location: **`~/.tbd/worktrees/...`** (not Application Support).
2. **No UUIDs in paths.** See §4a for the new naming scheme.
3. **Ship `tbd repo relocate`** in the same change, plus startup validation that surfaces missing repos instead of silently breaking.
4. Tests get routed through a `WorktreeLayout` helper.
5. Auto-migrate on upgrade is the goal — see §5a for the failure-case analysis that shapes how we do it safely.

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
5. **`~/.tbd/worktrees/` is shallow enough** that `git worktree repair` and manual recovery work fine. Each `<slot>/` subdirectory is self-contained.

### Resulting layout

```
~/.tbd/
  state.db
  sock
  tbdd.pid
  port
  conductors/
  worktrees/
    tbd/
      20260407-negative-crane/
      20260321-fuzzy-penguin/
    longeye-app/
      20260315-tame-otter/
```

See §4a for exactly how the per-repo directory name is chosen.

## 4a. Per-repo directory naming

`Sources/TBDShared/NameGenerator.swift:7-16` already gives us pleasant worktree names like `20260407-negative-crane`. The per-repo directory should be equally readable.

**Scheme:** the per-repo directory is the **sanitized repo display name**, frozen at `tbd repo add` time. Collisions are refused.

```
slot = sanitize(repo.displayName)                  # e.g. "tbd", "longeye-app"
if any existing repo has worktree_slot == slot:
    refuse `tbd repo add` with: "slot 'X' is already used by repo Y; rename one before adding"
else:
    repo.worktree_slot = slot
```

Properties:

- **Readable.** `cd ~/.tbd/worktrees/tbd/20260407-negative-crane` — no hashes anywhere.
- **User-controlled.** TBD already exposes display names in the UI and `tbd worktree rename` (which also renames repos). The directory name is whatever the user chose. No magic.
- **Frozen at add time.** The slot is persisted to `repo.worktree_slot` and **does not change when the user later renames the repo's display name.** Slot and display name diverge after the first rename, and that's fine — the slot is an on-disk detail, surfaced only when the user `cd`s into `~/.tbd/worktrees/`. If they care enough to rename the on-disk slot, that's a separate `tbd repo rename-slot` operation (not in this design's scope; add later if anyone asks).
- **Stable across repo moves.** Moving the repo on disk doesn't touch the slot. Same property the v3/v4 design had.
- **Collision policy.** At `tbd repo add`, if the sanitized display name is already taken, refuse the add and tell the user to pick a different display name (`--name <new-name>` flag, or rename the existing repo first). This is cheap to implement, can never silently overwrite anyone's data, and matches how the user already thinks about repos (display names are the human identifier).
- **Sanitization.** Lowercase, replace anything outside `[a-z0-9._-]` with `-`, collapse runs of `-`, trim leading/trailing `-`. Reject (force user to rename) if the result is empty, `.`, `..`, or starts with `.`. The UNIQUE constraint on `worktree_slot` enforces collisions at the DB level as a backstop.

### Full schema delta (one GRDB migration `vN`)

The `repo` table (singular — `Database.swift:53`) gains five columns in one migration:

```sql
ALTER TABLE repo ADD COLUMN worktree_slot TEXT UNIQUE;                -- sanitized display name, frozen at add
ALTER TABLE repo ADD COLUMN worktree_root TEXT;                       -- NULL = default; absolute override
ALTER TABLE repo ADD COLUMN status        TEXT NOT NULL DEFAULT 'ok'; -- 'ok' | 'missing'
```

Field roles:

- **`worktree_slot`** — source of truth for the per-repo directory name. Sanitized display name at add-time. UNIQUE-constrained. Never auto-changes.
- **`worktree_root`** — power-user override. When non-NULL, bypasses the slot mechanism entirely.
- **`status`** — `ok` or `missing` (§4b). Validated on startup and reconcile.

The `Repo` Codable model in `Sources/TBDShared/Models.swift` gains matching optional fields (`worktreeSlot`, `worktreeRoot`, `status`) so old rows decode.

### Schema change

See §4a for the full schema delta. The short version: a new GRDB migration adds `worktree_slot`, `worktree_root`, `status`, `origin_url`, and `first_commit_sha` columns to the **`repo`** table (singular — that's the actual table name per `Database.swift:53`). Per `CLAUDE.md`, the migration, the GRDB Record type, and the `Repo` Codable model in `Sources/TBDShared/Models.swift` ship in one commit; new fields are optional/defaulted so existing rows decode.

### Code change surface (for the implementation pass, not this doc)

- New helper `WorktreeLayout` in `TBDDaemon` (or `TBDShared`) with two methods:
  - `basePath(for: Repo) -> String` — the *canonical* (new) base path for fresh worktree creation.
  - `legacyAndCanonicalPrefixes(for: Repo) -> [String]` — returns both `~/.tbd/worktrees/<slot>/` **and** `<repo.path>/.tbd/worktrees/` so that reconciliation can adopt worktrees from either layout. This is critical: §5a's pre-flight legitimately *skips* unsafe worktrees, leaving them in the legacy location indefinitely. If reconcile only knows about the new prefix, those skipped worktrees become invisible and get reaped on the next reconcile pass. The dual-prefix view stays in place permanently — there's no flag day, only a long tail.
- Replace the two hardcoded sites in `WorktreeLifecycle+Create.swift` (use `basePath(for:)`) and the filter in `WorktreeLifecycle+Reconcile.swift:108-112` (use `legacyAndCanonicalPrefixes(for:)` and match against either).
- Update tests that currently grep for `.tbd/worktrees/` — they should call the same helper, or a test-only override sets `worktree_root` to a tmpdir.
- Add `tbd repo set-worktree-root <repo> <path>` CLI command (and matching RPC) for the override.
- Ensure the per-repo dir is created lazily on first worktree creation, not on repo add (so users who never create worktrees don't get empty dirs).

## 5. Migration plan

Existing installs have worktrees at `<repo>/.tbd/worktrees/<name>/` with absolute paths persisted in `state.db`. We need to move the directories *and* update the DB without leaving git's `.git/worktrees/<name>/gitdir` files pointing into space.

## 5a. Auto-migrate failure cases (the question that decides the strategy)

You asked what could go wrong with auto-migrate-on-upgrade. Here's the honest list, grouped by how dangerous each is:

### Dangerous — can destroy work or corrupt state

1. **A TBD terminal/Claude session is currently attached to the worktree.** Its shell has CWD inside the directory we're about to move. On macOS, `mv` succeeds (the inode is unchanged), but the shell's `$PWD` becomes a stale string. New commands using relative paths still work (kernel tracks the inode), but anything that re-resolves `$PWD` (prompts, `pwd -P`, build tools that re-canonicalize) breaks. If the user `cd .`s, they're in limbo.
2. **An editor (VS Code, Xcode, Cursor) has the worktree open with unsaved buffers.** macOS file watchers (FSEvents) re-resolve paths after a move; behavior varies wildly. Xcode in particular will sometimes write the unsaved buffer back to the *old* path it cached at open time, creating a ghost file outside the new worktree. Lost work.
3. **A build is running** (`swift build`, `xcodebuild`, `npm run`, conductor-launched script). Build systems with absolute-path artifact databases (DerivedData, `.build/`, `node_modules/.cache`) get poisoned. At minimum the build fails halfway; at worst the next build appears to succeed but links against stale objects.
4. **Cross-volume move.** `~/.tbd/` is on the boot volume; the repo might be on an external SSD. `FileManager.moveItem` falls back to copy-then-delete, which is **not atomic** — interrupt it (daemon crash, machine sleep, power loss) and you have two half-copies and no journal to tell you which is canonical.
5. **The repo itself has been moved/deleted on disk** (`repos.path` is stale). We can't run `git worktree repair` because there's no main `.git/worktrees/<name>/` to fix up. The worktree's `.git` file becomes a dangling pointer. Today this is a latent bug; auto-migrate would surface it as a hard failure on upgrade.
6. **Daemon crash mid-batch.** With `--all`, we're migrating N repos × M worktrees each. If we crash on item 17 of 200, we need to know exactly where we were.
7. **Two daemons racing.** If a stale `tbdd` is still running from a previous install while the new one starts up, they both try to migrate the same DB rows. The PID file in `~/.tbd/tbdd.pid` should prevent this, but only if we check it.

### Annoying — won't lose data but will surprise the user

8. **Symlinks pointing into the old path** from elsewhere on disk (a `~/work/current → .../old-worktree` shortcut, an IDE workspace file, a CI runner config). Silently break.
9. **External hooks/scripts hardcoded to the old path** — a user's `~/.zshrc` alias, a launchd job, a tmux popup script.
10. **`.gitignore` rules in the main repo that mention `.tbd/`** — harmless but now dead.
11. **Disk full** in `~/.tbd/`. Cross-volume copy fails partway through. Same recovery story as case 4.
12. **Permission denied** writing to `~/.tbd/worktrees/<slot>/` (unusual but possible if the user has chowned `~/.tbd/`).
13. **`git worktree repair` itself fails** — happens if the main repo's `.git/worktrees/` was manually edited or pruned.
14. **Slot collision migration cascading.** If we're also rewriting an existing repo's directory because a same-basename repo was added, that's two move operations in one transaction.

### Strategy that the failure list implies

Given that the only current user has explicitly accepted editor-state loss as a non-issue ("editors are easy to reopen"), we **move everything** on first post-upgrade startup. The failure list above remains valid as a record of what we're consciously accepting, not a list of cases we defend against.

- **Auto-migrate runs once on daemon startup after an upgrade**, gated by a `layout_version` row in a TBD-owned table (orthogonal to GRDB's `grdb_migrations`). It does not run on every launch. No countdown, no user prompt — the user knows it's coming.
- **Minimal pre-flight per worktree** (not for safety, but to avoid moving things that are demonstrably broken or in-flight):
  - Status is `.ready` (skip `.creating`/`.error`/`.archived`).
  - No TBD terminal in the `terminal` table has this worktree as its CWD. If one does, the daemon detaches/closes it before the move and the user reopens it post-migration. (TBD-owned terminals are TBD's problem.)
  - The repo's main path still exists and is a git repo. If not, the repo is in `.missing` state (§4b) and `tbd repo relocate` is required before migration can proceed for that repo's worktrees.
- **Cross-volume moves are allowed**, since `~/.tbd/` and the repos are realistically all on the boot volume for the current user. The journal (§5b) covers the not-atomic case if the daemon crashes mid-copy.
- **A two-phase journal** (see §5b) makes every individual move recoverable.
- **A `migration.lock` file** prevents two daemon processes from racing.
- **Block daemon startup on migration.** With one user and a small number of worktrees, there's no benefit to background migration — and a foreground migration is simpler to reason about (no "is the daemon ready yet?" race for RPC clients).

The manual `tbd repo migrate-worktrees [--dry-run] [<repo>]` command stays around for the rare follow-up case (e.g., a worktree that was `.creating` during the auto-pass and finished afterward) and for inspection (`--dry-run`).

## 4b. Fixing `repos.path` silent breakage

You said this needs fixing, not just flagging. Concretely:

1. **Add a `repo.status` column** with values `.ok`, `.missing`. Default `.ok`.
2. **On daemon startup and on every reconcile**, validate each repo: does `repo.path` exist, is it a git repo, does its `HEAD` resolve? If any check fails → `.missing`.
3. **Every RPC handler that takes a repo ID** checks status first. `.missing` repos return a structured error (`.repoMissing(repoId, lastKnownPath)`) that the app surfaces with a "Locate…" button instead of a generic failure.
4. **`tbd repo relocate <id-or-name> <new-path>`** (CLI + RPC):
   - Validates `<new-path>` exists and is a git repo. That's it — no origin URL check (§6 explains why).
   - Updates `repo.path`.
   - Updates every `worktree.path` row whose old absolute path was inside the old repo path **only for legacy worktrees still living under the old `<repo>/.tbd/worktrees/`**. New-layout worktrees in `~/.tbd/worktrees/<slot>/` are unaffected — that's another argument for the new layout.
   - Runs `git worktree repair` for each worktree from the new repo path so git's metadata picks up the new location.
   - Sets `repo.status = .ok`.
5. **App UI:** missing repos are dimmed in the sidebar with a "Locate…" affordance that opens an `NSOpenPanel`. CLI (`tbd repo list`, `tbd worktree list`) shows them with a `[missing]` tag. No silent failures, no hiding.

### Why this matters for *this* design

The new layout makes the relocate problem dramatically simpler: once a worktree lives at `~/.tbd/worktrees/<slot>/<wt-name>/`, it doesn't care where the main repo is on disk. Relocating the repo only needs to update `repo.path` and run `git worktree repair`. Today (legacy layout), relocating a repo would require moving every worktree directory too, which is exactly the pain we're getting rid of.

## 5b. Migration mechanics

### Strategy

Auto-migrate at startup for the safe cases (§5a), with a manual `tbd repo migrate-worktrees` for everything else. Both paths share the same per-worktree machinery and the same journal.

```
tbd repo migrate-worktrees [<repo>]   # default: all repos
                          [--dry-run]
                          [--force]    # bypass dirty/lsof checks
```

### Locking and journal scope

Migrations are **serialized one worktree at a time**, even with `--all`. The journal file at `~/.tbd/migration-journal.json` holds **exactly one entry** at a time, not the whole batch. This makes recovery trivial: at startup, either the journal is absent (nothing in flight) or it describes exactly one half-done move.

A separate **`~/.tbd/migration.lock`** file (flock-style) prevents two daemon processes from racing. The strict ordering for every move is:

```
acquire migration.lock
  write journal entry          (step 1)
  move directory               (step 2)
  git worktree repair          (step 3)
  update state.db row          (step 4)
  delete journal entry         (step 5)
release migration.lock
```

The lock is held only for the duration of one move, then released so other RPCs aren't starved. On daemon startup, recovery (§5b "Failure recovery") runs *before* releasing the lock for normal operation.

### Per-worktree migration steps

For each worktree owned by the repo (one at a time, under the lock):

1. **Pre-flight** (skip this worktree if any fail; do not abort the batch):
   - Worktree status is `.ready`.
   - Any TBD terminal with this worktree as its CWD has been closed/detached.
   - Destination path does not already exist.
2. **Move the directory** with `FileManager.moveItem(at:to:)`. On the same volume this resolves to `rename(2)`, whose final inode flip is atomic. Cross-volume falls back to copy-then-delete and is **not atomic**; the journal in step 1 is what makes it recoverable.
3. **Repair git's bookkeeping.** A worktree has two pointers to fix:
   - `<main-repo>/.git/worktrees/<wt-name>/gitdir` contains the absolute path to the worktree's `.git` file.
   - `<worktree-path>/.git` contains `gitdir: <main-repo>/.git/worktrees/<wt-name>`.
   The cleanest fix is `git -C <new-worktree-path> worktree repair`, which rewrites both. Verify with `git worktree list` from the main repo.
4. **Update `state.db`** in a transaction: `UPDATE worktree SET path = ? WHERE id = ?`. If the transaction fails, `git worktree repair` again with the *old* path (it's idempotent) and fail loudly.
5. **Sweep the old `<repo>/.tbd/worktrees/` directory.** If it's now empty, remove it. Leave `<repo>/.tbd/` alone in case the user has other files in it (we shouldn't, but be polite).

### Failure recovery

The dangerous moment is between step 2 (directory moved) and step 4 (DB updated). The journal makes it recoverable:

- The journal is written *before* step 2 and deleted *after* step 4, so a daemon crash anywhere in the danger window leaves exactly one journal entry on disk.
- **On daemon startup**, before doing anything else, check `migration.lock` and `migration-journal.json`. If a journal entry exists, run recovery:
  - Both `old_path` and `new_path` exist → step 2 ran, step 4 didn't, but something *also* recreated the old path. Refuse to start; a human needs to look.
  - Only `new_path` exists → step 2 succeeded; finish steps 3–5.
  - Only `old_path` exists → step 2 failed or was rolled back; delete the journal entry and treat as "never started."
  - Neither exists → catastrophic. Mark the worktree `.error` in the DB and surface in the UI.
- Because the lock is held across the entire sequence and the journal is single-entry, "lost journal" is not a possible state under normal operation. (If the user manually deletes `~/.tbd/migration-journal.json` mid-flight, that's on them.)

### What if the repo itself can't be located anymore?

The migration refuses. The repo is in `.missing` state (§4b) and the user must run `tbd repo relocate <repo> <new-path>` first. After relocate, migration can proceed normally because `git worktree repair` now has a valid main `.git/worktrees/` to talk to.

## 6. Remaining open questions

Round 4 (slot = sanitized display name, no disambiguator) and round 5 (decisions below) closed all the prior open questions. None remain.

### Decisions locked in (round 5)

- **Missing repo UX.** Both app and CLI show missing repos but **dimmed/marked**. App: dimmed sidebar entry with "Locate…" button. CLI (`tbd repo list`, `tbd worktree list`): show with a `[missing]` tag, exit code unchanged. Hiding them would make the user think they were silently dropped, which is exactly the bug we're fixing.
- **Origin URL mismatch on relocate: drop the check entirely.** See note below — it doesn't earn its complexity.

### Why the origin-URL check is gone

Earlier drafts proposed caching `remote.origin.url` and `first_commit_sha` at `tbd repo add` so that `tbd repo relocate <new-path>` could verify the new path is "the same repo." Walking through the actual cases:

- **Repos with no remote at all** (local-only experiments, scratch repos, this very TBD worktree if it weren't pushed). `origin_url` is empty. Check is a no-op.
- **Repos whose remote has changed legitimately** (renamed GitHub repo, migrated from GitHub to a self-hosted gitea, switched from HTTPS to SSH URL — `https://github.com/x/y` → `git@github.com:x/y.git`). The URL string differs but it's the same repo. The check would false-positive constantly and we'd end up requiring `--force` every time, which means the check teaches the user to ignore it.
- **The case it would actually catch** — user runs `tbd repo relocate /path/to/totally-unrelated-repo` by accident — is also caught, more directly, by the user noticing the worktree branches and history are wrong the moment they open it.
- **`first_commit_sha`** is more stable but has the same problem with shallow clones, force-pushed root commits (rare but real), and repos that have been rewritten via `git filter-repo`.

The cost of the check: two extra columns, add-time work to populate them, NULL-tolerance code in relocate, and a `--force` flag the user will reflexively pass. The benefit: catches a rare user error that the user will notice within seconds anyway.

**Drop both `origin_url` and `first_commit_sha` from the schema delta.** Relocate becomes: validate the new path is a git repo, update `repo.path`, run `git worktree repair`, set status to `.ok`. Done.
