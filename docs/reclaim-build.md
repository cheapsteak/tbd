# Disk reclaim tooling (dev tooling)

Keeps each TBD worktree's SwiftPM `.build` small, reclaims idle dependency-install directories (`node_modules`, `.venv`, `.terraform`), and cleans up orphaned Claude Code per-worktree scratchpads. **Not part of the shipped product** — it is developer machine tooling, like `scripts/restart.sh`. Two sibling scripts share conventions: `scripts/reclaim-build.sh` (SwiftPM + installs), `scripts/sweep-scratchpads.sh` (orphaned scratchpads).

## Product GC vs dev-script territory

TBD also ships a **product** garbage collector — the daemon-owned orphan GC
(`Sources/TBDDaemon/GC/`, [`docs/orphan-gc.md`](orphan-gc.md)) — which is a different
thing from everything else in this file. The split is by construction, not overlap:

| | Product GC (daemon) | This file's scripts |
|---|---|---|
| Owns | Orphaned Claude Code agent worktrees (`.claude/worktrees/agent-*`, `wf_*`) whose run has ended, + scratchpads TBD can attribute to a known worktree path | SwiftPM `.build` tiers, install dirs (`node_modules`/`.venv`/`.terraform`) in **living** TBD worktrees, and scratchpad residue TBD can't attribute |
| Trigger | Orphan-only: the owning entity is provably gone (unlocked, no live process, linkage-proven) | Idle-only: the owner (a living worktree) still exists, reaped purely by elapsed time |
| Surfacing | History "Reclaimed" section, `tbd gc` CLI, snapshot-first + restorable | Log file only, not restorable |
| Runs via | Daemon sweep loop (boot + hourly) | `launchd` (hourly) + `scripts/restart.sh` background launch |

They're non-overlapping populations: a living TBD worktree's `.build`/installs are
never orphaned (only idle), so the daemon never touches them; an agent worktree that's
been fully reaped by the daemon no longer exists for this file's scripts to consider.
One overlap is now moot rather than active: the **"Claude agent worktrees" install-dir
tier described below is redundant** wherever the daemon reaps the whole agent worktree
first (whole-directory removal takes the installs with it) — but that tier's script
behavior is intentionally left in place in this PR as a backstop for agent worktrees
the daemon hasn't gotten to yet (still locked, within grace, or `gcEnabled` off), and
for any repo the daemon doesn't manage.

## Triggers

Both scripts write to the same log (`~/Library/Logs/tbd-reclaim-build.log`) and run from `scripts/restart.sh`; `reclaim-build.sh` additionally runs hourly via launchd:

- **Hourly via launchd** — `reclaim-build.sh` only, if installed (see Install / uninstall below). `sweep-scratchpads.sh` has no launchd agent.
- **Automatically in the background on every `scripts/restart.sh`** — both `reclaim-build.sh` and `sweep-scratchpads.sh` launched with `nohup ... &` before the build starts so they overlap with it, fully silent (no terminal output). This makes it zero-setup for contributors who never installed the launchd agent. Opt out of both with `TBD_SKIP_RECLAIM=1`. restart.sh excludes its own worktree from the `reclaim-build.sh` sweep (`RECLAIM_EXCLUDE_PATH`) so the reclaim can never race the build it overlaps — without that, restarting a dormant worktree whose `.build` is ≥48h stale would make it Tier-2 eligible at plan time, before the fresh build has touched it.

## What it does (hourly, via launchd)

### SwiftPM builds (`scripts/reclaim-build.sh`)

Only acts on worktrees containing a `Package.swift` (SwiftPM packages) for `.build` tiers — `tbd worktree list` spans every repo TBD manages, including non-Swift ones (e.g. longeye-app, longeye-docs, agent-channels), which are skipped for Swift-only tiers.

**The reaper never targets a repo root itself** — though not because the root is absent from its input. `tbd worktree list --json` does return the repo root, as a `status: "main"` row (`WorktreeStore.createMain` inserts it; `list()` excludes only `archived`). What keeps it out of the tier logic is `list_worktrees_tsv`'s `select(.status == "active")` filter, which drops `main` rows. The other enumeration source, the `<root>/.claude/worktrees/*/` glob, sits beneath the root rather than at it. So a repo root's own `.build` is outside the reaper's reach no matter how stale. Worth stating because the opposite is a natural guess: issue #677 attributed a partially-deleted `.build/checkouts` entry in a repo root to a disk-reclaim sweep, when the reaper had never once targeted that path (zero occurrences across the full `~/Library/Logs/tbd-reclaim-build.log`) and the real cause was SwiftPM's own non-atomic checkout removal.

SourceKit-LSP background-indexing suppression is a **committed** `.sourcekit-lsp/config.json` (`"backgroundIndexing": false`) at the repo root, present in every worktree the moment it's checked out — the script no longer seeds it. Trade-off: cross-file LSP (workspace symbols, global find-references, cross-module go-to-definition) is disabled on TBD worktrees; live single-file diagnostics still work.

The script reclaims disk from **active, idle** worktrees:
- **Tier 1** — `index-build/` idle > 6h → deleted (regenerates on demand). SwiftPM-only (`Package.swift`-gated).
- **Tier 2** — whole `.build` idle > 48h AND no live Claude session → deleted (one cold rebuild next time). SwiftPM-only.
- **Installs** — `node_modules`, `.terraform` idle > 48h AND no live Claude session → deleted (regenerate with npm/terraform). **Agent worktrees only** (Claude-managed one-shot sessions; TBD-managed worktrees are never orphaned, only idle). Reaps ONLY when the worktree carries a regenerating lockfile/manifest (`node_modules` needs `package.json`; `.terraform` needs `*.tf`). Idleness measured by the worktree's newest non-pruned file mtime, which tracks REAL USE (source edits, test output, logs), not the install dir's own mtime (which only moves on install). NOT gated on `Package.swift`, covering non-Swift worktrees where these directories dominate disk usage (typically ~4.3 GB vs ~2.5 GB `.build`).

Safety rails applied before anything is reaped:
- Never reap a git-worktree-locked worktree (a `git worktree lock` held by Claude Code during an active run: `SKIP locked`).
- Never reap a worktree that is the cwd of a live process (one `lsof -d cwd` pass per run: `SKIP live-cwd`).
- Never reap a worktree with uncommitted changes (`git status --porcelain`: `SKIP dirty`).
- Never reap a target touched within `RECLAIM_ACTIVE_GRACE` (10m default; defense-in-depth recency guard).
- Never reap a worktree with a running `swift-*` build process.

Archived worktrees are already reclaimed by `git worktree remove`.

### Claude agent worktrees

`isolation: "worktree"` subagents and Workflow runs make Claude Code create their own git worktrees under `<repo-root>/.claude/worktrees/agent-*` and `<repo-root>/.claude/worktrees/wf_*`. These are real git worktrees — visible in `git worktree list` — but they are **not** TBD-managed, so `tbd worktree list` never sees them and the reaper finds them separately.

They accumulate because Claude Code only auto-removes an agent worktree if it ends up unchanged; the moment an agent commits, the worktree persists (by design, so the commit/branch survives), and its gitignored `.build`, `node_modules`, and `.venv` persist with it. Nothing else ever cleans these up. Two incidents: an early one of 17 SwiftPM agent worktrees (~36 GiB of `.build`), and later a single repo's `.claude/worktrees` holding **81 agent worktrees, reported by `du` as ~194 GB** — dominated by per-worktree `node_modules` + `.venv`, not `.build` (median idle 8 days, only one hosting a live session). However, `du` on macOS/APFS significantly overcounts: APFS `cp -c` (reflink/clonefile) copies report shared blocks as per-copy in `du` output, even though both files report `st_nlink == 1`. A delete-and-`df`-delta measurement shows the honest reclaimable size was **~35 GiB** (free space rose from 5.7 GiB to ~40 GiB), approximately **5–6× smaller than the `du` figure**. (Empirically, a 200 MiB file cloned with `cp -c` makes `du` report 400 MiB while only 200 MiB of blocks are physically unique; both files show `nlink=1`.) This is why install-dir reaping is *not* `Package.swift`-gated — the ~35 GiB of demonstrable space savings on agent worktrees justifies it.

The reaper now finds them too: for each repo root derived from the TBD worktree list (via `git -C <wt> rev-parse --path-format=absolute --git-common-dir`, deduped), it globs `<root>/.claude/worktrees/*/`, and feeds them through the same tier logic (no `Package.swift` gate for installs — they're non-Swift most of the time). They have no TBD session concept, so they're always treated as "no live session" — Tier 2 eligible on idleness alone. The live-cwd and dirty gates now protect a busy agent worktree (not just `has_active_build`), so an active-session agent worktree is skipped. Non-Swift agent worktrees now get their install dirs reaped when idle, but only when the worktree has a regenerating manifest (e.g. `package.json` for `node_modules`).

### Re-enabling background indexing
A project-local `.sourcekit-lsp/config.json` takes precedence over user-global SourceKit-LSP config. To get cross-file LSP back on your machine without affecting the committed default: set `"backgroundIndexing": true` in the file locally, then run `git update-index --skip-worktree .sourcekit-lsp/config.json` so the flip is never committed. Alternatively, just delete the file locally.

### Migration note
Worktrees created before this change may have an untracked `.sourcekit-lsp/config.json` left over from the old per-worktree seeding, which git will flag as colliding with the newly-tracked file on pull. Remove it (`rm .sourcekit-lsp/config.json`) and re-checkout, or leave it — its contents are identical to the committed version.

## Install / uninstall
```sh
# run from a STABLE checkout (e.g. ~/projects/tbd), not a throwaway worktree
scripts/install-reclaim-agent.sh install
scripts/install-reclaim-agent.sh uninstall
```

## Manual use
```sh
scripts/reclaim-build.sh --dry-run   # preview; deletes/seeds nothing
scripts/reclaim-build.sh             # reclaim now
```

## Tuning
`RECLAIM_T1_SECONDS` (default 21600) and `RECLAIM_T2_SECONDS` (default 172800) override the thresholds.

## Env vars

### `scripts/reclaim-build.sh`
| Var | Default | Purpose |
|---|---|---|
| `RECLAIM_WT_JSON` | run `tbd worktree list --json` | Fixture file for the TBD worktree list (tests) |
| `RECLAIM_PS_CMD` | `ps -axo pid,args` | Fixture command for the active-build-process scan (tests) |
| `RECLAIM_LSOF_CMD` | `lsof -d cwd -Fn` | Fixture command for the live-cwd scan — outputs `lsof -d cwd -Fn` format (tests) |
| `RECLAIM_WORKTREE_LIST_CMD` | `git -C <wt> worktree list --porcelain` | Fixture command for the git-worktree-locked check — outputs `git worktree list --porcelain` format (tests) |
| `RECLAIM_T1_SECONDS` | `21600` (6h) | Tier-1 (`index-build/`) idle threshold |
| `RECLAIM_T2_SECONDS` | `172800` (48h) | Tier-2 (whole `.build` + installs) idle threshold |
| `RECLAIM_ACTIVE_GRACE` | `600` (10m) | Skip a target whose newest mtime is more recent than this, even if a `PLAN` was made |
| `RECLAIM_NOW` | `date +%s` | Epoch seconds treated as "now" (tests) |
| `RECLAIM_REPO_ROOTS` | derived from the TBD worktree list's git-common-dir | Newline-separated repo roots to scan for `.claude/worktrees/*` — overrides derivation entirely (tests, or to point at a repo TBD doesn't manage) |
| `RECLAIM_EXCLUDE_PATH` | unset | Single worktree path to skip unconditionally (all tiers, both enumeration sources); canonicalized before comparing, so symlink/trailing-slash variants still match. `scripts/restart.sh` passes its own worktree here |
| `RECLAIM_OPTOUT_FILE` | `.tbd-reclaim-optout` | Marker file name for per-worktree / per-repo opt-out (presence at worktree or its repo root skips on EVERY path: launchd, restart.sh, manual) |
| `TBD_SKIP_RECLAIM` | unset | Set to `1` to skip the background launch that `scripts/restart.sh` fires on every run (affects both scripts) |

### `scripts/sweep-scratchpads.sh`
| Var | Default | Purpose |
|---|---|---|
| `SWEEP_BASE` | `/private/tmp/claude-$(id -u)` | Scratchpad base directory to sweep (tests) |
| `SWEEP_LSOF_CMD` | `lsof -d cwd -Fn` | Fixture command for the live-cwd scan — outputs `lsof -d cwd -Fn` format (tests) |
| `SWEEP_DAYS` | `3` | Keep-if-modified-within N days (default 3) |
| `TBD_SKIP_RECLAIM` | unset | Set to `1` to skip the background launch that `scripts/restart.sh` fires on every run (affects both scripts) |

## Scratchpad sweep (`scripts/sweep-scratchpads.sh`)

Claude Code assigns each worktree a temporary scratch directory under `/private/tmp/claude-<uid>/<slug>/` (where `<slug>` is the worktree's path with `/` replaced by `-`). When a worktree is deleted or its session dies, these orphaned scratchpads are never cleaned up. A single dead session has been observed leaving 14 GB behind; this sweeper removes them.

A scratchpad is **kept** when either:
- A live process's cwd slugifies to it (an active session still owns it), or
- It contains a file modified within `SWEEP_DAYS` (default 3 days).

Everything else is removed by default. Use `--dry-run` to preview. See the Env vars section above for `SWEEP_BASE`, `SWEEP_LSOF_CMD`, and `SWEEP_DAYS`.

## Swift build admission

Local SwiftPM `build`, `test`, and `run` compilation goes through
`scripts/swift-safe`. It holds a
kernel-managed, machine-global lock at `~/tbd/runtime/swift-build.lock`, so a
fleet of TBD worktrees cannot compile simultaneously. Compile commands default
to two jobs and reject an explicit job count above that configured limit.
Non-compiling `swift package` metadata and resolution commands do not enter the
governor.

- `TBD_SWIFT_JOBS` sets the job count (default `2`), honored at face value with
  no ceiling. Because the lock already allows only one build at a time, this is
  a bound on the whole machine's compiler parallelism, and exporting it is the
  machine owner's consent — e.g. `8` on a 12-core laptop. A `-j`/`--jobs` on
  the command line may lower it but not raise it; raise this instead.
- `TBD_SWIFT_LOCK_TIMEOUT_SECONDS` sets the wait timeout (default `1800`).
- `TBD_SWIFT_SHARED_MODULE_CACHE=0` restores SwiftPM's per-worktree module
  cache, and `TBD_SWIFT_MODULE_CACHE_PATH` moves the shared one. See
  "Shared module cache" below.
- `TBD_SWIFT_LOCK_PATH` overrides the shared lock path for isolated testing.
- `TBD_SWIFT_ALLOW_ORPHAN=1` keeps a queued build waiting even after the
  process that requested it exits. A queued wrapper otherwise records its
  ancestor chain at startup and gives up as soon as any of those processes
  dies, because killing a shell or an agent session signals only that process:
  the wrapper it started is never told, and left waiting it eventually takes
  the machine-global slot to compile a tree nobody will read. The whole chain
  is watched, not just the direct parent, because the requester usually is not
  the parent — `scripts/test.sh` reaches the wrapper through `env`, which
  execs, so a killed agent shell leaves test.sh alive in between. Set this for
  a build deliberately detached from a shell that will exit later
  (`nohup scripts/swift-safe build &`); a build launched from something already
  parented to pid 1 needs no opt-out, since it records no ancestor that can die.

The repository guardrail rejects raw `swift build`, `swift test`, and `swift
run` commands issued by agents. CI and non-compiling package commands remain
unaffected.

## Shared module cache

`scripts/swift-safe` points every governed compile — `build`, `test` and `run`
alike — at one **shared clang/Swift module cache** at
`<home>/Library/Caches/tbd/swift-module-cache`, so all three entry points, and
every worktree, plan identically:

```
-Xswiftc -module-cache-path -Xswiftc <cache> -Xcc -fmodules-cache-path=<cache>
```

Without it every worktree's `.build` accumulates its own 510–818 MB
`ModuleCache` of near-identical precompiled clang modules (Foundation, AppKit,
SwiftUI, the NIO C shims, …). The `-Xcc -fmodules-cache-path=` half is what
reaches the C-language dependency shim targets (e.g. CNIOAtomics) that
`-Xswiftc -module-cache-path` alone misses.

The wrapper is the only place that decides this, and that is the point:
SwiftPM bakes the cache path into every compile command in
`.build/debug.yaml` at plan time, so **two entry points that disagree about
the path make every transition between them a full recompile**, in both
directions. Do not reintroduce the flags in `scripts/restart.sh` or anywhere
else. Design and evidence:
[`docs/specs/2026-08-30-shared-module-cache-design.md`](specs/2026-08-30-shared-module-cache-design.md).

Notes:

- **The path is resolved from the passwd database, never `$HOME`.**
  `scripts/test.sh` deliberately points `HOME` and `CFFIXED_USER_HOME` at a
  scratch fence it deletes; a `$HOME`-derived path would resolve inside that
  fence on every test run, minting an empty cache each time so every run paid
  a full rebuild — silently, looking like nothing worse than slow tests.
  `pwd.getpwuid(os.getuid()).pw_dir` answers the real home whatever the fence
  does, so the fence needs no cooperation and `scripts/test.sh` needs no
  change. Writing into `~/Library/Caches` during a test run is intended: it is
  a build artifact, not test state, and it is not one of the stores the
  fence's fingerprint detector brackets.
- **Concurrency-safe.** clang's module cache is designed for concurrent
  writers, and in practice the wrapper's exclusive lock means at most one
  build writes to it at a time.
- **Callers may still choose.** `TBD_SWIFT_MODULE_CACHE_PATH` moves the
  cache; `TBD_SWIFT_SHARED_MODULE_CACHE=0` restores SwiftPM's per-worktree
  default. A caller that passes its own `-module-cache-path` is left alone —
  a second, differently-spelled copy would itself be a third plan variant.
- **CI opts out.** When `CI` is set the wrapper adds nothing. Runners are
  ephemeral (one worktree per VM), so a shared cache saves nothing there, and
  `.github/workflows/test.yml` ends its job with a build that does not route
  through the wrapper at all — flagging only the steps that do would make CI
  alternate against its own `actions/cache`d `.build` on every run.
- **Why not `Package.swift` `swiftSettings`?** Measured dead end:
  `.unsafeFlags(["-module-cache-path", …])` on every root target still left
  a 591 MB local ModuleCache — manifest settings don't apply to dependency
  targets (SwiftNIO, GRDB, SwiftTerm…), which are the bulk of it.
- **Why not a symlink?** Cached artifacts embed the *spelled* path of the
  worktree that created them and clang validates that spelling, so a shared
  directory reached through per-worktree symlinks works for exactly one
  worktree and wedges every other with `PCH was compiled with module cache
  path '<A>/…' but the path is currently '<B>/…'`. Sharing by flag works
  precisely because every worktree spells the identical path.
- **Not swept by the reaper.** The shared cache sits outside every `.build`,
  so Tier 1/2 above never touch it. clang prunes it itself (a pass every
  seven days evicting entries unused for thirty-one), which holds it at
  roughly 1.5 GB, and it is safe to delete by hand at any time — the next
  build regenerates what it needs.

## Future
The ~4.6 GiB of compiled artifacts can only be de-duplicated across worktrees via SwiftPM compilation caching (LLVM CAS + prefix mapping) on the new Swift Build engine — currently an opt-in pitch. Track and pilot when it lands.
For the measured cold-build cost breakdown behind that conclusion — where the 327.9 s of a cold build actually goes, and why splitting the package into core and app halves was judged low return — see [`docs/research/2026-08-19-cold-build-split/findings.md`](research/2026-08-19-cold-build-split/findings.md).
