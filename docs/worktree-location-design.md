# Worktree Location Design

Status: **Proposal v3** — review round 2 folded in (table names, slot collision policy, dual-prefix reconcile, journal lock ordering, residual editor risk).
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
    tbd/                          # repo basename, when unique
      20260407-negative-crane/
      20260321-fuzzy-penguin/
    longeye-app/
      20260315-tame-otter/
    app-7c3f/                     # basename + 4-char disambiguator
    app-91ae/                     #   when two repos share a basename
```

See §4a for exactly how the per-repo directory name is chosen.

## 4a. Per-repo directory naming (no UUIDs)

`Sources/TBDShared/NameGenerator.swift:7-16` already gives us pleasant worktree names like `20260407-negative-crane`. Burying those under `1f3a...c2/` would defeat the readability win.

**Scheme:** the per-repo directory is named after the **repo's filesystem basename**, with a short disambiguator suffix only when needed.

```
slot = sanitize(basename(repo.path))               # e.g. "tbd", "longeye-app"
if no other repo claims `slot`:
    dir = slot
else:
    dir = "\(slot)-\(shortHash(repo.id))"          # 4 hex chars of repo UUID
```

Properties:

- **Readable.** `cd ~/.tbd/worktrees/tbd/20260407-negative-crane` is the common case.
- **Stable across renames and moves.** The slot is chosen at repo-add time and persisted in a new `repos.worktree_slot` column. Renaming or moving the repo on disk does **not** change the slot — that's the whole point of persisting it.
- **Collision-proof, without touching the existing repo.** When a second repo would claim a slot already in use, **only the newcomer gets the suffix**. The existing repo keeps its bare slot.
  1. At `tbd repo add`, look up any existing repo with `worktree_slot = <slot>`.
  2. If found, the new repo's slot is `<slot>-<hash>` (4 hex chars of its UUID).
  3. If not found, the new repo gets the bare `<slot>`.

  **Why not rewrite both** (the v2 proposal): repo-add is a foreground user action, and the existing repo may have an open editor, a running build, or live TBD terminals. Rewriting it would require either (a) blocking `repo add` on §5a's safety pre-flight — bad UX — or (b) forcing the move and risking the corruption cases §5a exists to prevent. Asymmetry is a small consistency cost (the user sees `app` and `app-7c3f` instead of `app-1a2b` and `app-7c3f`); never moving a working repo on an unrelated `repo add` is worth it.
  - Cosmetic asymmetry can be cleaned up later by a manual `tbd repo rename-slot` command if anyone cares.
- **Sanitization.** Lowercase, replace anything outside `[a-z0-9._-]` with `-`, collapse runs, trim leading/trailing `-`, fall back to `repo` if the result is empty. Reserved names (`.`, `..`, names that begin with `.`) get the suffix treatment unconditionally.
- **Hash source.** First 4 hex chars of the repo UUID (already a primary key, never changes). 4 chars = 65 k slots, fine for disambiguating a handful of same-named repos. We don't need cryptographic strength.

### Full schema delta (one GRDB migration `vN`)

The `repo` table (singular — `Database.swift:53`) gains five columns in one migration:

```sql
ALTER TABLE repo ADD COLUMN worktree_slot   TEXT;                       -- e.g. "tbd" or "app-7c3f"
ALTER TABLE repo ADD COLUMN worktree_root   TEXT;                       -- NULL = default; absolute override
ALTER TABLE repo ADD COLUMN status          TEXT NOT NULL DEFAULT 'ok'; -- 'ok' | 'missing'
ALTER TABLE repo ADD COLUMN origin_url      TEXT;                       -- cached at add-time, used by relocate
ALTER TABLE repo ADD COLUMN first_commit_sha TEXT;                      -- cached at add-time, used by relocate
```

Field roles:

- **`worktree_slot`** — source of truth for the per-repo directory name. Set at repo-add time, never changes (except via slot-collision rewrite, see below).
- **`worktree_root`** — power-user override. When non-NULL, bypasses the slot mechanism entirely.
- **`status`** — `ok` or `missing` (§4b). Validated on startup and reconcile.
- **`origin_url`, `first_commit_sha`** — cached at add-time so `tbd repo relocate` can sanity-check that the user pointed it at the same repo. **Both are NULL for repos that existed before this migration**; relocate must tolerate NULL and degrade to "warn, no cross-check" for those rows.

The `Repo` Codable model in `Sources/TBDShared/Models.swift` gains matching optional fields (`worktreeSlot`, `worktreeRoot`, `status`, `originURL`, `firstCommitSHA`) so old rows decode.

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

Auto-migrate is desirable, but **only when we can prove it's safe**. The right shape is "auto-migrate at startup, conservatively, with eager skipping and a hands-off fallback":

- **Auto-migrate runs once on daemon startup after an upgrade**, gated by a `layout_version` row in a TBD-owned table (orthogonal to GRDB's `grdb_migrations` — don't conflate the two). It does not run on every launch.
- **It only migrates worktrees that pass a strict pre-flight**:
  - Status is `.ready`.
  - No TBD terminal (`terminal` table) has this worktree as its CWD.
  - No conductor process is running against it (check `conductors/` PID files).
  - `git status --porcelain` is clean.
  - `lsof +D <worktree-path>` returns no foreign processes (best-effort; skip if `lsof` is slow).
  - The destination is on the same volume as `~/.tbd/` (skip cross-volume; force it via the manual command).
  - The repo's main path still exists and is a git repo (otherwise this whole repo is in `.missing` state — see §4b below — and can't migrate until `tbd repo relocate` runs).
- **Worktrees that fail pre-flight are skipped, not failed.** They stay in their old location and continue working. The daemon logs a one-line reason per skip and surfaces a notification: *"3 worktrees couldn't be auto-migrated (open editor / dirty / running build). Run `tbd repo migrate-worktrees` after closing them."*
- **Residual risk that pre-flight cannot fully eliminate.** `lsof +D` reliably catches processes that hold file descriptors *under* the worktree, but modern editors often don't:
  - VS Code uses FSEvents-based file watching; it may hold no descriptors on the worktree directory at all, only on individually opened files (and not always those).
  - Xcode primarily holds descriptors on `.xcodeproj` package internals, not the worktree root.
  - JetBrains IDEs hold a `.idea/` lock but the path can vary.

  This means a worktree with **unsaved buffers in an editor can pass pre-flight and still get moved**, with the editor potentially flushing the buffer back to a stale cached path. We mitigate but cannot fully prevent this:
  1. Add cheap heuristic skips on top of `lsof`: presence of `.idea/`, `.vscode/.lock`, `*.swp`, or any file modified within the last 5 minutes → skip.
  2. **Surface a one-time notification before auto-migrate runs**: *"TBD will reorganize worktrees on disk. Close any editors with unsaved changes in TBD worktrees first. Migration begins in 30 seconds — click to defer."*
  3. Document in user-visible release notes that the safe move is to quit editors before the first post-upgrade launch.

  This is honest residual risk, not a hole the design can fully close. The alternative — "never auto-migrate, always manual" — pushes the same risk onto every user instead of just the few with live editor sessions.
- **A two-phase journal** (see §5b) makes every individual move recoverable.
- **A startup mutex** via `tbdd.pid` + a `migration.lock` file prevents two daemons from racing.
- **Never block daemon startup on migration.** The daemon starts, serves requests, and runs migration in the background. Worst case: a worktree appears at its old path until the user closes their editor, then it auto-moves on the next launch.

The manual `tbd repo migrate-worktrees [--force] [--dry-run] [<repo>]` command remains for:
- Migrating worktrees the auto-pass skipped (after the user closes their editor).
- Cross-volume moves.
- Forcing through a dirty worktree (with `--force`).
- Inspecting what *would* happen (`--dry-run`).

This gives you the "ideal" auto-migrate experience for the 90% case without the risk of corrupting an open editor's state.

## 4b. Fixing `repos.path` silent breakage

You said this needs fixing, not just flagging. Concretely:

1. **Add a `repo.status` column** with values `.ok`, `.missing`. Default `.ok`.
2. **On daemon startup and on every reconcile**, validate each repo: does `repo.path` exist, is it a git repo, does its `HEAD` resolve? If any check fails → `.missing`.
3. **Every RPC handler that takes a repo ID** checks status first. `.missing` repos return a structured error (`.repoMissing(repoId, lastKnownPath)`) that the app surfaces with a "Locate…" button instead of a generic failure.
4. **`tbd repo relocate <id-or-name> <new-path>`** (CLI + RPC):
   - Validates `<new-path>` exists and is a git repo.
   - Optionally validates it's the *same* repo (compare `git config --get remote.origin.url`, or the first commit hash, against the old value if we have it cached). Mismatch → require `--force`.
   - Updates `repo.path`.
   - Updates every `worktree.path` row whose old absolute path was inside the old repo path **only for legacy worktrees still living under the old `<repo>/.tbd/worktrees/`**. New-layout worktrees in `~/.tbd/worktrees/<slot>/` are unaffected — that's another argument for the new layout.
   - Runs `git worktree repair` for each worktree from the new repo path so git's metadata picks up the new location.
   - Sets `repo.status = .ok`.
5. **Cache the origin URL and first-commit hash in `repos`** at add-time, so future `relocate` calls can sanity-check.
6. **App UI:** missing repos are dimmed in the sidebar with a "Locate…" affordance that opens an `NSOpenPanel`. No silent failures.

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

1. **Pre-flight checks** (skip this worktree if any fail; do not abort the whole batch — see §5a for the auto-migrate skip philosophy):
   - Worktree status is `.ready` (not `.creating`, not `.error`).
   - No uncommitted changes (`git status --porcelain` empty) — *or* `--force` was passed.
   - No TBD terminal/conductor has this worktree as its CWD (check `state.db`).
   - `lsof +D <path>` returns no foreign processes (with timeout; see §5a for the residual-risk caveat about editors).
   - Destination is on the same volume as the source (if not, skip auto, require `--force` for manual).
   - Destination path does not already exist.
2. **Move the directory** with `FileManager.moveItem(at:to:)`. On the same volume this resolves to `rename(2)`, whose final inode flip is atomic — but the *operation as a whole* is only safe because there's no copy step. Cross-volume falls back to copy-then-delete and is **not atomic**; the journal in step 1 is what makes it recoverable, and `--force` is required to opt in.
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

Round 2 locked in the slot-collision policy (only newcomer gets suffixed), the schema delta, the dual-prefix reconcile helper, and the lock/journal ordering. Still open:

1. **`lsof +D` timeout.** It can take seconds on large worktrees. Recommendation: 2 s timeout, skip-on-timeout during background auto-migrate; no timeout for the manual command.
2. **Disambiguator length.** 4 hex chars (65 k) or 6 (16 M)? Both are essentially free. Recommendation: 4, bump to 6 only if we ever see a real collision.
3. **Editor heuristic strictness.** §5a proposes skipping if `.idea/`, `.vscode/.lock`, `*.swp`, or any file modified in the last 5 min is present. Too strict (most active worktrees get skipped) or about right? The 5-min mtime check in particular will skip a worktree the user is actively editing even without an open IDE.
4. **`repo.status = .missing` UX.** Should missing repos appear in `tbd worktree list` (dimmed) or be hidden until relocated? App-side definitely dimmed; CLI preference?
5. **Origin URL mismatch on relocate.** Warn + `--force`, or hard-refuse? Recommendation: warn + `--force`, since users legitimately re-fork and re-clone.
6. **Pre-upgrade notification timing.** §5a proposes a 30-second countdown notification before auto-migrate runs. Too short? Should we also block migration until the notification is acknowledged (opt-in rather than opt-out)?
