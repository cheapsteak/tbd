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
to two jobs and rejects an explicit job count above that configured limit unless
a developer opts out. Non-compiling `swift package` metadata and resolution
commands do not enter the governor.

- `TBD_SWIFT_JOBS` sets the default and maximum job count (default `2`).
- `TBD_SWIFT_LOCK_TIMEOUT_SECONDS` sets the wait timeout (default `1800`).
- `TBD_SWIFT_LOCK_PATH` overrides the shared lock path for isolated testing.
- `TBD_SWIFT_ALLOW_HIGH_JOBS=1` permits an explicit higher job count on an
  otherwise idle machine.

The repository guardrail rejects raw `swift build`, `swift test`, and `swift
run` commands issued by agents. CI and non-compiling package commands remain
unaffected.

## Shared module cache

`scripts/restart.sh` passes every governed Swift build through a **shared
clang/Swift module cache** at `$HOME/Library/Caches/tbd/swift-module-cache`:

```sh
scripts/swift-safe build -Xswiftc -module-cache-path -Xswiftc "$SHARED" -Xcc -fmodules-cache-path="$SHARED"
```

Without it, every worktree's `.build` accumulates its own ~640 MB
`ModuleCache` with near-identical contents (precompiled clang modules for
Foundation, AppKit, SwiftUI, the NIO C shims, …). With it there is **one
~610–690 MB copy total, regardless of worktree count**, and the per-worktree
`.build` carries no ModuleCache at all (measured: clean build's `.build`
drops ~2.1 GB → ~1.4 GB; local `ModuleCache` 707 MB → 0 MB). The `-Xcc
-fmodules-cache-path=` piece is what reaches the C-language dependency shim
targets (e.g. CNIOAtomics) that `-Xswiftc -module-cache-path` alone misses
(~70 MB residual otherwise).

Notes:

- **Concurrency-safe.** clang's module cache is designed for concurrent
  writers; parallel builds from multiple worktrees against the shared cache
  were tested with zero lock errors.
- **Stickiness (expected, not a bug).** SwiftPM bakes the cache path into
  `.build/debug.yaml` at plan time. A later build after a flagged one silently
  keeps using the shared cache — and conversely, the first build
  after a manifest re-plan only picks the shared cache up if it runs with the
  flags (i.e. via `restart.sh`). Flag alternation does not trigger
  recompilation; worst case is a ~14 s re-plan.
- **Why not `Package.swift` `swiftSettings`?** Measured dead end:
  `.unsafeFlags(["-module-cache-path", …])` on every root target still left
  a 591 MB local ModuleCache — manifest settings don't apply to dependency
  targets (SwiftNIO, GRDB, SwiftTerm…), which are the bulk of it.
- **Not swept by the reaper.** The shared cache sits outside every `.build`,
  so Tier 1/2 above never touch it. It stays a constant single-copy size and
  is safe to delete manually at any time — the next build regenerates it.
- **CI is unchanged.** Runners are ephemeral (one worktree per VM), so a
  shared cache buys nothing there, and the `actions/cache`d `.build` interacts
  with plan-time stickiness in non-obvious ways. Deliberately not wired up.

## Future
The ~4.6 GiB of compiled artifacts can only be de-duplicated across worktrees via SwiftPM compilation caching (LLVM CAS + prefix mapping) on the new Swift Build engine — currently an opt-in pitch. Track and pilot when it lands.
