# Design: Reclaim worktree SwiftPM `.build` disk

*2026-07-08. Grounded in `~/projects/longeye-docs/disk-cleanup/tbd-swiftpm-build-lessons.md`
(the disk-full incident investigation) plus live measurement on this machine.*

## Problem

Every TBD worktree that builds the tbd Swift package produces a SwiftPM `.build/`
directory of **~5.5 GiB**, with **zero sharing** across worktrees (fully real,
`du`-honest bytes). Worktrees routinely outlive their sessions, so `.build` dirs
accumulate until hand-deleted. On this 460 GB machine that pool has hit 55 GiB
across 14 worktrees and driven the disk to near-0 free three times in ~5 weeks,
killing unrelated processes mid-write.

Cleanup today is manual (`du` + `rm`) and loses to normal usage within days.

**Goal:** keep the steady-state `.build` footprint low automatically, so the
developer never runs `du`/`rm` by hand. Crash prevention is a welcome side
effect, not the design target — steady-state reclamation is.

## Measured composition (identical across all live worktrees, 2026-07-08)

| Chunk | Size | % | What it is | Reclaim safety |
|---|---|---|---|---|
| `index-build/` | 2.6 GiB | 47% | SourceKit-LSP's **separate** background-index build | Disposable — nothing runtime reads it; regenerates on demand |
| `arm64-apple-macosx/` | 2.0 GiB | 37% | The real debug build (`debug/` symlinks into it; the running/testable app lives here) | Needed while active; one cold rebuild if deleted |
| `repositories/` | 0.68 GiB | 12% | Bare git mirrors of pinned deps | Identical across worktrees |
| `checkouts/` | 0.23 GiB | 4% | Dep working copies | Needed, small |

Key facts established by measurement:

- **The running app is NOT in `index-build/`.** `scripts/restart.sh` builds and
  runs `.build/debug/TBD.app`, i.e. `arm64-apple-macosx/debug/` — the 2.0 GiB
  chunk we keep. `index-build/` is a parallel build that only SourceKit-LSP
  reads for indexing; deleting it cannot break a running or testable app.
- **`index-build/` regenerates on demand.** 8 worktrees had `sourcekit-lsp`
  attached but only 3 had an `index-build/` — the others had their `.build`
  hand-deleted and LSP simply hadn't re-indexed yet.
- **Agent (Read/Grep/Bash) work generates no `.build` at all.** The worktree
  this design was authored in had an actively-working agent and zero `.build`.
  `index-build/` appears only when a build runs or an editor/LSP indexes.

## Approach chosen (and rejected alternatives)

**Chosen: a standalone reclaimer script, driven by launchd, that reads worktree
activity from the `tbd` CLI (read-only) and deletes stale build artifacts in two
tiers.**

Rejected:

- **Reaper logic inside the TBD daemon.** TBD is an OSS product other people
  install; a SwiftPM `.build` reaper is dev tooling for *this repo* (product
  users' worktrees may be Node/Rust/Go with entirely different bloat). It should
  not ship into every user's daemon runtime. It belongs beside `restart.sh` /
  `test.sh` as repo dev tooling.
- **Disabling SourceKit-LSP background indexing at the source.** A permanent
  behavior change with uncertain impact on agents that may use cross-file LSP.
  Since `index-build/` regenerates on demand, we reclaim it instead of
  preventing it — no bet required. (Left as a possible future optimization only
  if measurement later shows agents never use cross-file LSP.)
- **Shared SwiftPM dependency cache** (`--cache-path` / shared repositories).
  Saves only ~0.9 GiB/worktree, concurrency-safety across simultaneous builds is
  unverified. YAGNI for now.
- **A crash guardrail** (disk-pressure watcher blocking new builds). Explicitly
  descoped: the priority is steady-state footprint, and a low baseline gives
  bursts enough headroom.

## Design

### Component: `scripts/reclaim-build.sh`

Repo dev tooling, sibling to `restart.sh`. Not compiled, not in the daemon, not
shipped to product users. Runnable by hand (with `--dry-run` to preview) and by
a launchd agent hourly.

Responsibilities, in order:

1. **Enumerate worktrees from the source of truth.** Parse
   `tbd worktree list --json` for each worktree's `path`, `status`, and
   `liveClaudeSessionCount`. This is authoritative — it avoids globbing a
   hardcoded directory (the CLI reports real paths, which are not always under
   `~/tbd/worktrees/tbd`) and it yields the activity signal without any daemon
   code change. Only `status == "active"` worktrees are considered; archived
   ones are already reclaimed by TBD's `git worktree remove`.

2. **Per worktree that has a `.build`, apply the safety gate then the tiers:**

   - **Hard skip (active build).** If any `swift-build` / `swift-frontend` /
     `swiftc` / `swift-driver` process has this worktree's path in its args,
     leave the whole worktree untouched. Deleting `.build` under a live build
     corrupts it.

   - **Tier 1 — `index-build/` only, aggressive (T1 = 6h).** If the newest file
     mtime under `.build/index-build/` is older than **6 hours**, delete just
     `index-build/`. Reclaims ~2.6 GiB (47%) with no runtime impact: `swift
     build`, running apps, and live single-file LSP diagnostics are unaffected;
     LSP re-indexes in the background if the worktree is reopened in an editor.
     This is the primary lever — half the footprint, no rebuild cost — so it
     runs on a short timer.

   - **Tier 2 — whole `.build`, relaxed (T2 = 48h).** If the newest file mtime
     under `.build/arm64-apple-macosx/` (the real debug build) is older than
     **48 hours** AND `liveClaudeSessionCount == 0`, delete the entire `.build`.
     Reclaims the full ~5.5 GiB; cost is one cold rebuild next time that worktree
     builds, so this catches only genuinely-abandoned worktrees.

   **Staleness is measured on the newest *file* mtime within each tier's own
   subtree — never the `.build` directory's own mtime.** This is deliberate:
   Tier 1's `rm index-build/` bumps `.build`'s directory mtime, so a `.build`-dir
   clock for Tier 2 would be perpetually reset by our own Tier-1 deletions and
   never fire. Measuring Tier 2 on `arm64-apple-macosx/` (which Tier 1 never
   touches) and Tier 1 on `index-build/` keeps the two clocks independent and
   each reflective of genuine build activity.

3. **Report.** Log per-worktree what was reclaimed and total bytes (measured via
   `df` delta on `/System/Volumes/Data`, never `du`, per the incident doc).
   `--dry-run` prints the plan and skips all deletion.

Thresholds `T1` and `T2` are constants near the top of the script (env-var
overridable for tuning), defaulting to 6h and 48h.

### Component: launchd agent

A `LaunchAgents` plist (installed by a small `scripts/install-reclaim-agent.sh`,
or folded into the existing `scripts/install-hooks.sh` setup step) that runs
`reclaim-build.sh` **hourly**. Uninstall is documented. The agent is the
developer's own machine-level tooling — it is not part of the shipped product.

### Data flow

```
launchd (hourly)
  └─> scripts/reclaim-build.sh
        ├─ tbd worktree list --json        (authoritative paths + status + live session count)
        ├─ ps -axo …                       (active-build guard)
        ├─ newest file mtime under index-build/ and arm64-apple-macosx/  (independent tier clocks)
        └─ rm -rf index-build/ | .build/    (guarded, tiered)
```

### Error handling

- CLI/`ps` failures → the script skips that worktree (fail-safe: never delete on
  incomplete information) and logs a warning; it does not abort the whole run.
- `rm` is only ever invoked after the gate + tier checks pass; a mid-run build
  starting is bounded by the per-worktree re-check immediately before delete.
- The script is idempotent — a second run finds nothing new to do.

## Testing

- **Unit-ish (shell, no live daemon):** feed the script a fixture
  `tbd worktree list --json` and a fake worktree tree with planted mtimes; assert
  in `--dry-run` mode that it selects exactly the expected Tier-1 / Tier-2 /
  skipped sets. Cover each branch: fresh `.build` (skip both tiers), stale
  `index-build` only (Tier 1), stale whole `.build` with no session (Tier 2),
  stale `.build` WITH a live session (Tier 1 eligible, Tier 2 skipped), and an
  active-build process match (hard skip).
- **Integration (manual, documented):** run `--dry-run` against the live machine
  and eyeball the plan against `du -sh */.build`; then a real run with a `df`
  before/after to confirm reclaimed bytes.

## Success criteria

- `~/tbd/worktrees/tbd/*/.build` steady-state footprint stays roughly at
  (actively-building worktrees) × (2.0–2.9 GiB), instead of N × 5.5 GiB.
- No manual `du`/`rm` needed to keep the disk healthy.
- No active build, running app, or live agent session is ever disrupted.
