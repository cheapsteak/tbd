# Worktree Location Design

Status: **Proposal v11** — bot review round 4: `retry_count` write-before-attempt protocol, recovery bound covers step 3 *and* step 4, backfill collision uses an explicit in-memory set, `--force` flag removed.
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
| **A. App-support, slot-namespaced** | `~/.tbd/worktrees/<slot>/<wt-name>/` (slot = sanitized display name, see §4a) | No | Yes | No (UNIQUE slot) | Medium (hidden dir) | Medium |
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

**Option F: default to `~/.tbd/worktrees/<slot>/<wt-name>/` where `<slot>` is the sanitized repo display name (§4a), with an optional per-repo `worktree_root` override persisted in `state.db`.**

Rationale:

1. **Reuses existing infrastructure.** TBD already owns `~/.tbd/`. No new directory convention to teach users. `~/Library/Application Support/TBD/` would be more "Mac-correct" but inconsistent with where `state.db` already lives, and migrating *that* is out of scope.
2. **Readable, and stable across repo moves.** The display name is what the user already thinks of the repo as. The slot is frozen at add time, so the repo's filesystem path can change freely without touching the worktree directory. (The slot also doesn't change when the user later renames the display name — slot and display name diverge after a rename, and that's an accepted trade-off; see §4a.) This also nudges us toward fixing the latent "moved repo breaks lookup" bug — once worktrees no longer derive from `repo.path`, the only thing tying a repo to its filesystem location is the `repo.path` column, which can be repaired with `tbd repo relocate` (§4b).
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
    refuse `tbd repo add` with:
        "display name '<new.displayName>' sanitizes to slot '<slot>',
         which is frozen to repo '<existing.displayName>' (at <existing.path>).
         (Slot is set at add time and does not change when a repo is renamed,
          so '<existing.displayName>' may hold a slot that no longer matches its
          current display name.)
         Pass --name <different-name>, or run
         `tbd repo rename-slot <existing.displayName> <new-slot>` first."
else:
    repo.worktree_slot = slot
```

The error surfaces *both* display names and the sanitized slot so the user understands why `TBD` and `tbd`, or `my-app` and `my_app`, collide. It also explicitly names the slot-frozen-at-add-time invariant, because this is the *only* user-facing surface where slot/displayName divergence is visible — without this explanation, a user whose existing repo was renamed sees "slot `foo` is used by repo `bar`" and has no mental model for why.

Properties:

- **Readable.** `cd ~/.tbd/worktrees/tbd/20260407-negative-crane` — no hashes anywhere.
- **User-controlled.** TBD already exposes display names in the UI and `tbd worktree rename` (which also renames repos). The directory name is whatever the user chose. No magic.
- **Frozen at add time.** The slot is persisted to `repo.worktree_slot` and **does not change when the user later renames the repo's display name.** Slot and display name diverge after the first rename, and that's fine — the slot is an on-disk detail, surfaced only when the user `cd`s into `~/.tbd/worktrees/`. If they care enough to rename the on-disk slot, that's a separate `tbd repo rename-slot` operation (not in this design's scope; add later if anyone asks).
- **Stable across repo moves.** Moving the repo on disk doesn't touch the slot. Same property the v3/v4 design had.
- **Collision policy.** At `tbd repo add`, if the sanitized display name is already taken, refuse the add and tell the user to pick a different display name (`--name <new-name>` flag, or rename the existing repo first). This is cheap to implement, can never silently overwrite anyone's data, and matches how the user already thinks about repos (display names are the human identifier).
- **Sanitization.** Lowercase, replace anything outside `[a-z0-9._-]` with `-`, collapse runs of `-`, trim leading/trailing `-`. Reject (force user to rename) if the result is empty, `.`, `..`, or starts with `.`. The UNIQUE constraint on `worktree_slot` enforces collisions at the DB level as a backstop.

### Full schema delta (one GRDB migration `vN`)

The `repo` table (singular — `Database.swift:53`) gains three columns in one migration:

```sql
ALTER TABLE repo ADD COLUMN worktree_slot TEXT UNIQUE;                -- sanitized display name, frozen at add
ALTER TABLE repo ADD COLUMN worktree_root TEXT;                       -- NULL = default; absolute override
ALTER TABLE repo ADD COLUMN status        TEXT NOT NULL DEFAULT 'ok'; -- 'ok' | 'missing'
```

Plus a **new `WorktreeStatus` case** in `Sources/TBDShared/Models.swift:27-29`:

```swift
public enum WorktreeStatus: String, Codable, Sendable {
    case active, archived, main, creating, conductor, failed   // 'failed' is new
}
```

`worktree.status` is already a TEXT column (`Database.swift:69`), so no schema migration is needed for the new enum case — only the Swift enum and any switch statements that exhaustively match it. Per `CLAUDE.md` (TBDShared section), the daemon must be restarted after this change.

Field roles:

- **`worktree_slot`** — source of truth for the per-repo directory name. Sanitized display name at add-time. UNIQUE-constrained. Never auto-changes.
- **`worktree_root`** — power-user override. When non-NULL, bypasses the slot mechanism entirely.
- **`status`** — `ok` or `missing` (§4b). Validated on startup and reconcile.

The `Repo` Codable model in `Sources/TBDShared/Models.swift` gains matching optional fields (`worktreeSlot`, `worktreeRoot`, `status`) so old rows decode.

### Backfill: assigning slots to existing repos at migration time

The GRDB migration must populate `worktree_slot` for every pre-existing row in `repo`. The `tbd repo add` interactive collision-rejection path doesn't apply here — the migration runs unattended and **must not fail**. Algorithm:

```
assigned_slots: Set<String> = SELECT worktree_slot FROM repo WHERE worktree_slot IS NOT NULL
for each existing repo, ordered by createdAt ASC (stable):
    if repo.worktree_slot IS NOT NULL:
        continue   # already assigned (resumed run); don't re-suffix
    base = sanitize(repo.displayName)
    if base is empty, ".", "..", or starts with ".":
        base = "repo-\(repo.id.uuidString.prefix(6))"   # always-valid fallback
    slot = base
    n = 2
    while assigned_slots contains slot:
        slot = "\(base)-\(n)"
        n += 1
    repo.worktree_slot = slot
    assigned_slots.insert(slot)   # in-memory; UNIQUE constraint backstops the DB write
```

Properties:

- **Never fails.** Empty/reserved sanitization falls through to a UUID-derived name; collisions get a numeric suffix. The DB-level `UNIQUE` constraint is a backstop, not a failure surface.
- **Stable.** Ordering by `createdAt ASC` means the *older* repo keeps the bare slot and newer repos get suffixed — same asymmetry rule as the live `tbd repo add` path (newer thing moves), and a re-run of the migration on the same DB produces the same slots.
- **Visible.** After migration, the daemon emits an `os.Logger` warning per repo whose slot doesn't match its sanitized display name (collision suffix or fallback). The user can `tbd repo rename-slot` later if they care; nothing is broken in the meantime.
- **Backfill happens *before* the worktree-move phase.** Slot assignment is a pure DB operation and must complete (and commit) before §5b's per-worktree journal-and-move loop starts touching the filesystem. This keeps the DB always-consistent and means a crash mid-move never leaves an unslotted repo behind.

### Code change surface (for the implementation pass, not this doc)

- New helper `WorktreeLayout` in `TBDDaemon` (or `TBDShared`) with two methods:
  - `basePath(for: Repo) -> String` — the *canonical* (new) base path for fresh worktree creation. Returns `repo.worktreeRoot` if non-NULL, otherwise `~/.tbd/worktrees/<repo.worktreeSlot>/`. This is the single point that knows about the override.
  - `legacyAndCanonicalPrefixes(for: Repo) -> [String]` — returns `[basePath(for: repo), legacyPath(for: repo)]`, where `legacyPath` is `<repo.path>/.tbd/worktrees/`. Reconcile uses this to adopt worktrees from either layout. **Critical: the canonical entry must come from `basePath(for:)`, not be hardcoded as `~/.tbd/worktrees/<slot>/`.** Otherwise repos with a `worktree_root` override get their canonical prefix wrong, and worktrees at `<worktree_root>/…` become invisible to reconcile and get reaped. This is critical because §5a's pre-flight legitimately *skips* unsafe worktrees, leaving them in the legacy location indefinitely. If reconcile only knows about the new prefix, those skipped worktrees become invisible and get reaped on the next reconcile pass. The dual-prefix view stays in place until the user confirms full migration via `tbd repo migrate-worktrees --dry-run` reporting zero legacy paths across all repos; at that point a future TBD release can drop the legacy branch from `WorktreeLayout` and the `WorktreeLifecycle+Reconcile.swift` filter. There's no flag day — the dual-prefix path is cheap and can stay indefinitely if needed.
- Replace the two hardcoded sites in `WorktreeLifecycle+Create.swift` (use `basePath(for:)`) and the filter in `WorktreeLifecycle+Reconcile.swift:108-112` (use `legacyAndCanonicalPrefixes(for:)` and match against either).
- Update tests that currently grep for `.tbd/worktrees/` — they should call the same helper, or a test-only override sets `worktree_root` to a tmpdir.
- Add `tbd repo set-worktree-root <repo> <path>` CLI command (and matching RPC) for the override.
- Ensure the per-repo dir is created lazily on first worktree creation, not on repo add (so users who never create worktrees don't get empty dirs).

## 4b. Fixing `repo.path` silent breakage

The latent bug (§2 / §3): TBD identifies repos by absolute filesystem path, with no detection or recovery if the user moves the directory. The new layout doesn't make this worse, but it surfaces it during auto-migrate (§5a) and we said we'd fix it. Concretely:

1. **Add a `repo.status` column** with values `.ok`, `.missing`. Default `.ok`. (Already in §4a's schema delta.)
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

- **Auto-migrate runs once on daemon startup after an upgrade**, gated by a `layout_version` value. Concrete shape:

  ```sql
  CREATE TABLE IF NOT EXISTS tbd_meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
  );
  -- After successful migration: INSERT OR REPLACE INTO tbd_meta VALUES ('layout_version', '1');
  ```

  - **Table:** a new `tbd_meta` key/value table created in the same GRDB migration (`vN`) that adds the `repo` columns. This is just for daemon-managed sentinels that aren't GRDB schema versions.
  - **Current version constant:** `WorktreeLayout.currentVersion: Int = 1`, hardcoded in Swift. Bumped manually if a future TBD release introduces a new layout migration.
  - **Initial value for existing installs:** absent. The startup code reads `tbd_meta.layout_version`; if missing or `< currentVersion`, runs migration. After successful migration completes (every repo's worktrees processed, success or skip), writes `currentVersion` to the row.
  - **Why this is deliberately not a GRDB migration:** GRDB migrations are single-pass and non-retryable — they run inside one transaction and either succeed or roll back. The filesystem migration must survive crashes mid-batch and resume on the next boot, exactly what the journal in §5b provides. A GRDB migration that called out to `FileManager.moveItem` would lose crash-resumability and could leave the schema marked "migrated" with the filesystem half-done. The `tbd_meta.layout_version` row records "the last layout version that finished migrating end-to-end," and only flips after the resume loop terminates with no journal entries left.

  It does not run on every launch. No countdown, no user prompt — the user knows it's coming.
- **Minimal pre-flight per worktree** (not for safety, but to avoid moving things that are demonstrably broken or in-flight):
  - Status is `.active` (skip `.creating`/`.archived`/`.main`/`.conductor`/`.failed`).
  - The migrator **actively closes** any TBD-owned terminal whose CWD is this worktree before the move. TBD-owned terminals are TBD's problem; the user reopens them post-migration. (No pre-flight check here — it's an action, not a gate.)
  - The repo's main path still exists and is a git repo. **If not, the repo is marked `.missing` (§4b) and its worktrees are *skipped*, not failed.** The legacy worktrees stay where they are and remain reachable via the dual-prefix reconcile view (§4a code-change surface). When the user later runs `tbd repo relocate`, the next startup sweep (or manual `tbd repo migrate-worktrees`) picks them up.
  - **Crucially: a missing repo must never block daemon startup.** Migration iterates repos in isolation — one missing repo skips that repo only, the daemon continues, and the user can invoke `tbd repo relocate` via RPC the moment startup finishes. Without this, the daemon would be unbootable any time a repo directory has moved, with no recovery path (relocate is an RPC that requires a running daemon).
- **Cross-volume moves are allowed**, since `~/.tbd/` and the repos are realistically all on the boot volume for the current user. The journal (§5b) covers the not-atomic case if the daemon crashes mid-copy.
- **`worktree_root` override is honored.** If a repo has a non-NULL `worktree_root`, migration moves its worktrees to `<worktree_root>/<wt-name>/` instead of `~/.tbd/worktrees/<slot>/<wt-name>/`. On first post-upgrade migration this is a no-op (all existing rows are NULL), but future manual re-runs of `tbd repo migrate-worktrees` after a user sets an override need the behavior to be defined.
- **Progress is logged per worktree** via `os.Logger` (category: `migration`). A single cross-volume copy can take minutes for a large worktree, and the daemon will appear unresponsive to app/CLI clients during that window. Document the expectation in release notes; stream with `log stream --level debug --predicate 'category == "migration"'` to watch progress live. This is not a correctness fix — it's preventing future-you from debugging "frozen app on first boot after upgrade" as a bug.
- **A two-phase journal** (see §5b) makes every individual move recoverable.
- **A `migration.lock` file** prevents two daemon processes from racing.
- **Block daemon startup on migration.** With one user and a small number of worktrees, there's no benefit to background migration — and a foreground migration is simpler to reason about (no "is the daemon ready yet?" race for RPC clients).

The manual `tbd repo migrate-worktrees [--dry-run] [<repo>]` command stays around for the rare follow-up case (e.g., a worktree that was `.creating` during the auto-pass and finished afterward) and for inspection (`--dry-run`).

## 5b. Migration mechanics

### Strategy

Auto-migrate at startup for the safe cases (§5a), with a manual `tbd repo migrate-worktrees` for everything else. Both paths share the same per-worktree machinery and the same journal.

```
tbd repo migrate-worktrees [<repo>]   # default: all repos
                          [--dry-run]
```

### Locking and journal scope

Migrations are **serialized one worktree at a time**, even with `--all`. The journal file at `~/.tbd/migration-journal.json` holds **exactly one entry** at a time, not the whole batch. This makes recovery trivial: at startup, either the journal is absent (nothing in flight) or it describes exactly one half-done move.

A separate **`~/.tbd/migration.lock`** file prevents two daemon processes from racing. **The locking primitive is OS-level `fcntl(F_SETLK)` (`flock(2)` on macOS via `Foundation`'s `FileHandle.lock`/`unlock` or a direct `fcntl` call).** This is intentional — kernel-managed advisory locks are released automatically when the holding process dies, so a daemon crash cannot leave a permanent stale lock. The lock file itself may persist on disk, but the *lock state* does not.

**Stale-lock recovery edge case:** if the daemon crashes after `acquire migration.lock` but *before* writing the journal in step 1, the kernel releases the lock on process death and the lock file remains as an empty marker. On next boot the recovery routine sees `migration.lock` exists but no journal entry — this means a crash made no filesystem changes. Treat the lock file as informational, attempt to acquire the kernel lock fresh (it will succeed since the dead process is gone), and proceed normally. If a stale lock file is encountered on a filesystem where `fcntl` is unavailable (network mounts), fall back to deleting the lock file after confirming via `tbd_meta` that no migration is in progress.

The strict ordering for every move is:

```
acquire migration.lock
  write journal entry          (step 1)
  move directory               (step 2)
  git worktree repair          (step 3)
  update state.db row          (step 4)
  delete journal entry         (step 5)
release migration.lock
```

The lock is held only for the duration of one move, then released between worktrees. With migration currently blocking daemon startup (§5a), no RPCs can arrive between moves, so the per-move release is moot today — but the granularity is preserved so this code can move to background migration in a future release without redesigning the locking. On daemon startup, recovery (§5b "Failure recovery") runs *before* releasing the lock for normal operation.

### Per-worktree migration steps

For each worktree owned by the repo, **step 0 runs outside the lock** (so a skip is cheap), then **steps 1–5 run under the lock** and use the same numbering as the lock-sequence box above:

**Step 0 — Pre-flight and prep** (outside lock; skip this worktree if any *check* fails; do not abort the batch):
- *Check:* worktree status is `.active`.
- *Check:* destination path does not already exist.
- *Check:* the owning repo's status is `.ok` (not `.missing`).
- *Action:* close/detach any TBD terminal in the `terminal` table whose CWD is this worktree. Logged at `info`.

**Steps 1–5 — under the lock** (same numbering as the lock-sequence box):

1. **Write the journal entry** (`{worktree_id, old_path, new_path, started_at}`) to `~/.tbd/migration-journal.json`.
2. **Move the directory** with `FileManager.moveItem(at:to:)`. On the same volume this resolves to `rename(2)`, whose final inode flip is atomic. Cross-volume falls back to copy-then-delete and is **not atomic**; the journal from step 1 is what makes it recoverable across crashes. **If `moveItem` throws inline (e.g. `ENOSPC`, `EPERM`) without crashing the daemon**, the filesystem state is unchanged from before step 1: `old_path` still exists and `new_path` does not. Inline behavior: delete the journal entry (safe — no filesystem change occurred), log at `error` level, mark this worktree `.failed` (both in memory and persist to `worktree.status` in the DB), release the lock, and **continue the batch** to the next worktree. Without this explicit handling, a leftover journal entry would block every subsequent worktree in the same sweep.
3. **Repair git's bookkeeping** with `git -C <new-worktree-path> worktree repair`. This rewrites both `<main-repo>/.git/worktrees/<wt-name>/gitdir` (absolute path to the worktree's `.git` file) and `<worktree-path>/.git` (which contains `gitdir: <main-repo>/.git/worktrees/<wt-name>`). Verify with `git worktree list` from the main repo.
4. **Update `state.db`** in a transaction: `UPDATE worktree SET path = ? WHERE id = ?`. If the transaction fails, **do not attempt inline recovery** — at this point `old_path` no longer exists on disk (Step 2 moved it) and git's metadata already points to `new_path` (Step 3 repaired it), so a `git worktree repair` from the old path would fail. The journal entry from Step 1 still describes the in-flight move, and the on-disk state matches the "only `new_path` exists" case in §5b's recovery routine: on next daemon startup, recovery re-runs Steps 3–5 idempotently. Inline behavior: log at `error` level (`os.Logger`, category `migration`), mark this worktree `.failed` in memory for the rest of the current sweep so nothing else touches it, and **continue the batch** to the next worktree. Do not abort the sweep — one DB write failure shouldn't strand every other worktree.

   **Bounded-recovery edge case:** if *any* step in recovery's "only `new_path` exists" branch (step 3 `git worktree repair` *or* step 4 DB update) persistently fails across reboots, the journal would stay on disk indefinitely. To bound this, the journal entry carries a **`retry_count: Int`** field, and the recovery protocol on each boot is strict:

   1. Read the journal entry, including `retry_count` (default `0` if absent — fresh entry from a pre-recovery crash).
   2. **If `retry_count >= 3`:** delete the journal entry, mark the worktree `.failed` in the DB, log at `error` level with instructions to run `tbd worktree repair --reconcile` (or equivalent) to reconcile the DB pointer, and continue startup. The worktree is *physically intact* at `new_path` — only the DB row is stale, and reconcile (§4a code-change surface) can rebuild it from the dual-prefix scan.
   3. **Otherwise**, write `retry_count + 1` to the journal file on disk **before attempting recovery**. The increment-then-fsync-then-attempt order is load-bearing: if the daemon crashes after the in-memory increment but before the write, the count would reset on next boot and the bound would never be reached.
   4. Attempt steps 3–5 (repair → DB update → delete journal). On success, the journal is gone and the count is moot. On any failure, the next boot reads the incremented count and the loop converges.

   This applies equally to step-3 (`git worktree repair`) failures — the most common real-world case being "the main repo was moved or deleted after migration started." Without the bound, that scenario would loop forever.
5. **Delete the journal entry**, then **sweep the old `<repo>/.tbd/worktrees/` directory** if it's now empty. If `<repo>/.tbd/` is *also* empty after that removal, remove it too — leaving an empty `<repo>/.tbd/` behind would defeat the `.tbd/`-pollution fix in §2 (the directory would still show up in `git status` and IDE trees). Only remove if strictly empty; if the user has put anything else in there, leave it alone.

### Failure recovery

The dangerous moment is between step 2 (directory moved) and step 4 (DB updated). The journal makes it recoverable:

- The journal is written *before* step 2 and deleted *after* step 4, so a daemon crash anywhere in the danger window leaves exactly one journal entry on disk.
- **On daemon startup**, before running any new migrations, check `migration.lock` and `migration-journal.json`. If a journal entry exists, run recovery:
  - Only `new_path` exists → step 2 succeeded; run the bounded-retry protocol from Step 4 above (read `retry_count`, bail if ≥3, otherwise increment-and-persist then attempt steps 3–5). If step 3 (`git worktree repair`) or step 4 (DB update) throws during this retry and the count hasn't reached the bound, the journal stays on disk with the incremented count and the next boot tries again. If either step throws *and* the count has now reached the bound, the worktree is marked `.failed`, the journal is deleted, and startup continues.
  - Only `old_path` exists → step 2 failed or was rolled back; delete the journal entry and **re-queue the worktree into the current startup sweep** so it retries this boot. (Without re-queue, the iteration that started this attempt has already moved on, and the worktree would stay in legacy until the user manually runs `tbd repo migrate-worktrees`.)
  - Both `old_path` and `new_path` exist → ambiguous (something recreated the old path). Mark the worktree `.failed`, leave both directories in place, log loudly (`os.Logger` at `error` level, category `migration`), and **continue startup**. The user investigates manually — `tbd worktree forget` + re-reconcile is the normal recovery. Refusing to start would strand the user with no RPCs available.
  - Neither exists → catastrophic. Mark the worktree `.failed` in the DB, delete the journal entry, continue startup.

  In every case the daemon comes up. Migration never blocks startup on an unrecoverable state — startup is a prerequisite for the user to do anything about it.
- Because the lock is held across the entire sequence and the journal is single-entry, "lost journal" is not a possible state under normal operation. (If the user manually deletes `~/.tbd/migration-journal.json` mid-flight, that's on them.)

### What if the repo itself can't be located anymore?

**This section applies to the manual `tbd repo migrate-worktrees` command only.** The auto-migrate startup sweep (§5a) *skips* missing repos silently so that a moved repo never blocks the daemon from coming up — that's a load-bearing invariant and must not be broken.

For the manual command: migration refuses. The repo is in `.missing` state (§4b) and the user must run `tbd repo relocate <repo> <new-path>` first. After relocate, migration can proceed normally because `git worktree repair` now has a valid main `.git/worktrees/` to talk to.

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
