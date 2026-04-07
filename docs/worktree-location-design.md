# Worktree Location Design

Status: **Proposal v2** — answers folded in from review round 1.
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
- **Collision-proof.** When a second repo would claim the same slot, *both* repos get rewritten to the suffixed form. This is a one-time mutation triggered at repo-add time:
  1. Look up any existing repo with `worktree_slot = <slot>`.
  2. If found and it doesn't already have a suffix, migrate it to `<slot>-<hash>` (move directory, update DB, in the same journaled flow as §5).
  3. Insert the new repo with its own `<slot>-<hash>`.
  This is rare (most users don't have two repos with the same basename) and uses the same migration machinery as §5, so there's no extra failure surface.
- **Sanitization.** Lowercase, replace anything outside `[a-z0-9._-]` with `-`, collapse runs, trim leading/trailing `-`, fall back to `repo` if the result is empty. Reserved names (`.`, `..`, names that begin with `.`) get the suffix treatment unconditionally.
- **Hash source.** First 4 hex chars of the repo UUID (already a primary key, never changes). 4 chars = 65 k slots, fine for disambiguating a handful of same-named repos. We don't need cryptographic strength.

### Schema delta vs §4

Replace the proposed `worktree_root` column with **two** columns:

```sql
ALTER TABLE repo ADD COLUMN worktree_slot TEXT;   -- e.g. "tbd" or "app-7c3f"
ALTER TABLE repo ADD COLUMN worktree_root TEXT;   -- NULL = default; absolute override
```

`worktree_slot` is set at repo-add time and is the source of truth for the per-repo directory name. `worktree_root` remains the power-user override and, when non-NULL, bypasses the slot mechanism entirely.

The `Repo` Codable model gains `worktreeSlot: String?` and `worktreeRoot: String?` (both optional so existing rows decode).

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

- **Auto-migrate runs once on daemon startup after an upgrade**, gated by a `schema_version` / `layout_version` row in `state.db`. It does not run on every launch.
- **It only migrates worktrees that pass a strict pre-flight**:
  - Status is `.ready`.
  - No TBD terminal (`terminal` table) has this worktree as its CWD.
  - No conductor process is running against it (check `conductors/` PID files).
  - `git status --porcelain` is clean.
  - `lsof +D <worktree-path>` returns no foreign processes (best-effort; skip if `lsof` is slow).
  - The destination is on the same volume as `~/.tbd/` (skip cross-volume; force it via the manual command).
  - The repo's main path still exists and is a git repo (otherwise this whole repo is in `.missing` state — see §4b below — and can't migrate until `tbd repo relocate` runs).
- **Worktrees that fail pre-flight are skipped, not failed.** They stay in their old location and continue working. The daemon logs a one-line reason per skip and surfaces a notification: *"3 worktrees couldn't be auto-migrated (open editor / dirty / running build). Run `tbd repo migrate-worktrees` after closing them."*
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

The migration refuses. The repo is in `.missing` state (§4b) and the user must run `tbd repo relocate <repo> <new-path>` first. After relocate, migration can proceed normally because `git worktree repair` now has a valid main `.git/worktrees/` to talk to.

## 6. Remaining open questions

Round 1 resolved the big questions. These are the small ones left:

1. **`lsof +D` in pre-flight.** It's the most reliable way to detect "something has this directory open", but it can take seconds on large worktrees. Acceptable to run during background auto-migrate, or should we skip it and rely only on the TBD-internal checks (terminals, conductors)? Recommendation: run it with a 2 s timeout, skip-on-timeout.
2. **Disambiguator length.** 4 hex chars (65 k slots) feels right for "two repos named `app`"; bumping to 6 (16 M) is essentially free. Preference?
3. **Slot rewrite for collisions.** When repo B claims a slot that repo A already has unsuffixed, we rewrite *A* too so both are suffixed. Alternative: leave A alone and only suffix B (`app` and `app-7c3f` coexist). The first is more consistent; the second avoids touching a working repo. Recommendation: rewrite both, since the migration machinery exists anyway and consistency aids debugging.
4. **`repo.status = .missing` UX.** Should missing repos still appear in `tbd worktree list` output (dimmed) or be hidden until relocated? App-side this is clearer (dimmed sidebar entry); CLI-side either works.
5. **Origin URL sanity check on relocate.** If the cached `remote.origin.url` doesn't match the new path's origin, do we hard-refuse or just warn? Recommendation: warn + require `--force`, since users legitimately re-fork and re-clone.
