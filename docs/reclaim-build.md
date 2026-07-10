# `.build` reclaimer (dev tooling)

Keeps each TBD worktree's SwiftPM `.build` small. **Not part of the shipped product** — it is developer machine tooling, like `scripts/restart.sh`.

## Triggers

The reaper runs from two places, both writing to the same log:

- **Hourly via launchd**, if installed (see Install / uninstall below).
- **Automatically in the background on every `scripts/restart.sh`** — launched with `nohup ... &` before the build starts so the two overlap, fully silent (no terminal output), logging to `~/Library/Logs/tbd-reclaim-build.log`. This makes it zero-setup for contributors who never installed the launchd agent. Opt out with `TBD_SKIP_RECLAIM=1`. restart.sh excludes its own worktree from the sweep (`RECLAIM_EXCLUDE_PATH`) so the reclaim can never race the build it overlaps — without that, restarting a dormant worktree whose `.build` is ≥48h stale would make it Tier-2 eligible at plan time, before the fresh build has touched it.

## What it does (hourly, via launchd)
Only acts on worktrees containing a `Package.swift` (SwiftPM packages) — `tbd worktree list` spans every repo TBD manages, including non-Swift ones (e.g. longeye-app, longeye-docs, agent-channels), which are skipped entirely.

SourceKit-LSP background-indexing suppression is a **committed** `.sourcekit-lsp/config.json` (`"backgroundIndexing": false`) at the repo root, present in every worktree the moment it's checked out — the script no longer seeds it. Trade-off: cross-file LSP (workspace symbols, global find-references, cross-module go-to-definition) is disabled on TBD worktrees; live single-file diagnostics still work.

The script itself only reclaims disk from **active, idle** worktrees:
- **Tier 1** — `index-build/` idle > 6h → deleted (regenerates on demand).
- **Tier 2** — whole `.build` idle > 48h AND no live Claude session → deleted (one cold rebuild next time).

Worktrees with a running `swift-*` build process are never touched. Archived worktrees are already reclaimed by `git worktree remove`.

### Claude agent worktrees

`isolation: "worktree"` subagents and Workflow runs make Claude Code create their own git worktrees under `<repo-root>/.claude/worktrees/agent-*` and `<repo-root>/.claude/worktrees/wf_*`. These are real git worktrees — visible in `git worktree list` — but they are **not** TBD-managed, so `tbd worktree list` never sees them and the reaper used to skip them entirely.

They accumulate because Claude Code only auto-removes an agent worktree if it ends up unchanged; the moment an agent commits, the worktree persists (by design, so the commit/branch survives), and its gitignored `.build` persists with it. Nothing else ever cleans these up. One incident: 17 such worktrees, all idle 6+ days, had accumulated 36 GiB before being hand-deleted.

The reaper now finds them too: for each repo root derived from the TBD worktree list (via `git -C <wt> rev-parse --path-format=absolute --git-common-dir`, deduped), it globs `<root>/.claude/worktrees/*/`, applies the same `Package.swift` gate, and feeds the results through the identical tier logic. They have no TBD session concept, so they're always treated as "no live session" — Tier 2 eligible on idleness alone. All the same safety rails (`has_active_build`, `RECLAIM_ACTIVE_GRACE`) still apply.

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
| Var | Default | Purpose |
|---|---|---|
| `RECLAIM_WT_JSON` | run `tbd worktree list --json` | Fixture file for the TBD worktree list (tests) |
| `RECLAIM_PS_CMD` | `ps -axo pid,args` | Fixture command for the active-build-process scan (tests) |
| `RECLAIM_T1_SECONDS` | `21600` (6h) | Tier-1 (`index-build/`) idle threshold |
| `RECLAIM_T2_SECONDS` | `172800` (48h) | Tier-2 (whole `.build`) idle threshold |
| `RECLAIM_ACTIVE_GRACE` | `600` (10m) | Skip a `.build` whose newest mtime is more recent than this, even if a `PLAN` was made |
| `RECLAIM_NOW` | `date +%s` | Epoch seconds treated as "now" (tests) |
| `RECLAIM_REPO_ROOTS` | derived from the TBD worktree list's git-common-dir | Newline-separated repo roots to scan for `.claude/worktrees/*` — overrides derivation entirely (tests, or to point at a repo TBD doesn't manage) |
| `RECLAIM_EXCLUDE_PATH` | unset | Single worktree path to skip unconditionally (both tiers, both enumeration sources); canonicalized before comparing, so symlink/trailing-slash variants still match. `scripts/restart.sh` passes its own worktree here |
| `TBD_SKIP_RECLAIM` | unset | Set to `1` to skip the background reclaim launch that `scripts/restart.sh` fires on every run |

## Shared module cache

`scripts/restart.sh` passes every `swift build` through a **shared clang/Swift
module cache** at `$HOME/Library/Caches/tbd/swift-module-cache`:

```sh
swift build -Xswiftc -module-cache-path -Xswiftc "$SHARED" -Xcc -fmodules-cache-path="$SHARED"
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
  `.build/debug.yaml` at plan time. A plain `swift build` after a flagged one
  silently keeps using the shared cache — and conversely, the first build
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
