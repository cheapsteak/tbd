# Design: Orphan GC — agent worktrees & scratchpads as a product feature

*2026-07-10. Grounded in the PR #423 review discussion (issue #420), the 2026-07-08
reclaim design (`2026-07-08-reclaim-worktree-build-disk-design.md`), and two research
reports: [`docs/research/2026-07-10-agent-worktree-gc/agent-deck-worktree-lifecycle.md`](../../research/2026-07-10-agent-worktree-gc/agent-deck-worktree-lifecycle.md)
and [`docs/research/2026-07-10-agent-worktree-gc/ecosystem-prior-art.md`](../../research/2026-07-10-agent-worktree-gc/ecosystem-prior-art.md).*

## Problem

Claude Code's `isolation: worktree` subagents and Workflow runs create git worktrees
under `<repo-root>/.claude/worktrees/{agent-*,wf_*}` — at the **main repo root**, not
under the TBD worktree whose session spawned them. Claude Code auto-removes one only if
it ended unchanged; once an agent commits, the worktree persists so the branch survives,
and Claude Code's own 30-day cleanup sweep permanently exempts anything with **unpushed
commits** — which is exactly the persisted population. Nothing records which session
spawned which worktree, and nothing ever GCs them. Incidents: 17 SwiftPM agent worktrees
(~36 GiB), and one repo with 81 agent worktrees dominated by per-worktree
`node_modules`/`.venv`.

Separately, Claude Code assigns each worktree a scratch directory under
`/private/tmp/claude-<uid>/<slug>` (slug = worktree path with `/`→`-`). When TBD
archives or deletes a worktree, its scratchpad is orphaned and never cleaned (one dead
session left 14 GB).

Community asks for built-in cleanup were closed not-planned (anthropics/claude-code
#55435, #57767). Third-party GC is legitimately TBD's gap to fill, and TBD has the one
thing no other tool has for this population: live session/worktree state in its DB.

## Design decisions (from brainstorm)

| Decision | Choice |
|---|---|
| Ambition | First-class product feature (daemon-owned), not dev-machine scripts |
| Autonomy | Auto-reap, always snapshot-first (Codex model) — reversible, silent-by-default |
| Philosophy | **Orphan-only, never idle-based.** Reap things whose owner is gone; time-based "idle" policies stay in dev scripts |
| Scope | Agent worktrees (run ended = orphaned) + scratchpads TBD can attribute (worktree path gone = orphaned) |
| Out of scope | `node_modules`/`.venv`/`.terraform` and SwiftPM `.build` inside living TBD worktrees (never orphaned, only idle → dev-script territory); branch deletion; non-attributable scratchpads |
| Surfacing | History tab entries + `tbd gc` CLI; restore via both |
| PR #423 | Lands descoped as dev tooling (scratchpad sweep + safety rails + canonicalization fix; install reaping scoped per review); this feature supersedes nothing it keeps |

### Why "orphaned", not "idle"

*Idle* = the owner still exists and might come back; reaping needs a time-judgment
policy (the contested part of PR #423). *Orphaned* = the owning entity is gone and
nothing will programmatically return. For agent worktrees, "run ended" is detectable
without a clock: Claude Code holds `git worktree lock` for the duration of the run and
releases it on finish, and a live run has a process cwd inside the worktree. Once
unlocked with no live process, nothing ever re-enters that checkout — Claude has no
resume-into-agent-worktree mechanism. Crucially, **the branch and its commits live in
the shared repo's `.git`, not in the checkout** — removing the worktree directory loses
nothing committed. Only uncommitted/untracked state is at risk, and the snapshot covers
exactly that.

## Architecture

New daemon subsystem `Sources/TBDDaemon/GC/`:

- **`OrphanGC`** (actor) — owns the sweep loop and both collectors. Runs on daemon
  start, then hourly, plus event-triggered (archive/delete/reap completion → immediate
  scratchpad cleanup for that exact path). A sweep is cheap: enumerate repos from the
  `repos` table (not the worktree list — covers repos whose agent worktrees outlived
  every TBD worktree), glob `.claude/worktrees/*/`, one `lsof -d cwd -Fn` pass per
  sweep, one `git worktree list --porcelain` per repo for lock state.
- **`AgentWorktreeCollector`** — orphan detection + reap for `agent-*` / `wf_*`
  worktrees.
- **`ScratchpadCollector`** — attributable-orphan cleanup under
  `/private/tmp/claude-<uid>/`.
- **`ReapSnapshot`** — git-plumbing helper for snapshot commit/ref creation and restore.
- **DB** — new `reap_records` table (next sequential migration).
- **RPC** — `gc.list`, `gc.restore`, `gc.sweepNow`.
- **CLI** — `tbd gc list | restore <id> | sweep [--dry-run]`.
- **App** — reap records rendered in the existing History tab with a Restore action.

## Agent-worktree orphan detection & reap

For each candidate directory under `<repo>/.claude/worktrees/`, gates run in order;
**every gate fails toward keeping**:

1. **Linkage proof** (never path-shape alone): the candidate's `.git` must be a *file*
   whose `gitdir:` resolves into `<repo>/.git/worktrees/<id>`, both sides canonicalized
   with `realpath` semantics (the `/tmp` → `/private/tmp` class; see agent-deck's
   `IsLinkedWorktree` and its data-loss incident #1200, and claude-code #41010 where a
   prefix-collision cleanup deleted a parent working dir). The repo root, submodules,
   and non-worktree debris are untouchable.
2. **Not locked**: `git worktree list --porcelain` reports no `locked` for the path.
   Claude Code locks for the whole live run, so this alone excludes in-flight agents.
   A stale leaked lock means we never reap — fail-safe; the sweep logs `kept: locked`
   so chronic leaks are visible.
3. **No live process**: no lsof cwd at or below the canonicalized path.
4. **Grace window**: HEAD/index mtime older than `gcGraceSeconds` (default 3600). A
   settling buffer — covers the gap between unlock and sweep, and a human poking around
   right after a run — not an idle policy.
5. **Orphaned → reap**:
   - If dirty or untracked files exist → snapshot commit + ref (see below). If HEAD is
     not reachable from any branch (detached-HEAD agent), create an anchor ref at HEAD
     regardless, so the commits can't be lost to git's own gc.
   - `du -sk` for the History record (recorded as *apparent* bytes — APFS clones make
     `du` an upper bound), then `rm -rf` (fast path for huge trees) + `git worktree
     prune`, then insert the `reap_record`.
   - **The branch is never deleted.** Branch GC stays a human / `clean_gone` concern.

## Scratchpad cleanup — attributable orphans only

A scratchpad is TBD's to clean only when TBD can attribute it to a concrete worktree
path it knows. No slug *decoding* exists anywhere in the design — only exact slug
*computation* (`path.replacingOccurrences(of: "/", with: "-")`) from known paths:

- **Event-driven (primary)**: on archive/delete of a TBD worktree, and on every
  agent-worktree reap above, the daemon computes the exact slug for the removed path
  and deletes `/private/tmp/claude-<uid>/<slug>` immediately. TBD creates these orphans;
  it cleans them the moment it does.
- **Reconciliation sweep (catch-up)**: for paths retained in TBD's own DB (archived
  worktree rows keep `path`), compute exact slugs and remove scratchpads whose worktree
  directory no longer exists on disk. Covers events missed while the daemon was down.

Scratchpad reaps are recorded in `reap_records` (kind `scratchpad`, no snapshot —
scratch content is disposable by definition).

**Explicit non-goals**: scratchpads of non-TBD projects, and scratchpads of agent
worktrees Claude Code auto-removed before TBD ever swept. Those are Claude Code's
litter (and `/private/tmp` clears on reboot); PR #423's shell sweeper remains available
as dev tooling for that residue.

## Snapshot & restore

**Snapshot** (agent worktrees only, only when dirty): in the orphaned worktree, with a
temp `GIT_INDEX_FILE` seeded from HEAD, `git add -A` (captures modified + untracked,
excludes `.gitignore`d content — so `node_modules`/`.venv` never enter the snapshot),
`git write-tree`, `git commit-tree <tree> -p HEAD -m "TBD reap snapshot: <path> @
<iso-date>"`, `git update-ref refs/tbd/snapshots/<worktree-name>-<yyyymmdd-hhmmss>`.
Nothing is stored outside the repo; content dedupes into the object store; power users
can inspect with plain git. (Shipped implementation note: `GitManager.stageAllAndWriteTree`
stages directly against the orphaned worktree's own real index via a plain `git add -A`
rather than a temp `GIT_INDEX_FILE` as sketched above — safe because the worktree is
already orphaned and about to be deleted, so there is no live index state left to protect.)

**Restore** (`tbd gc restore <id>` or the History button): `git worktree add
<original-path> <branch>` (or `--detach <head-sha>` if the branch is gone), then if a
snapshot ref exists, materialize its tree into the working copy (tracked changes via
`git restore --source=<ref> --worktree -- .`, untracked files re-created from the
snapshot tree) — ending in the exact pre-reap state: same commits, same uncommitted
changes, uncommitted. Sets `restored_at`. Refuses with a clear error if the original
path is occupied.

**Snapshot GC**: the sweep deletes `refs/tbd/snapshots/*` older than
`gcSnapshotRetentionDays` (default 30) **only** for records never restored *and* whose
branch still exists. Anchor refs guarding otherwise-unreachable commits are kept
indefinitely — they are the only thing keeping that work alive, and refs are nearly
free.

## Config, DB, surfaces

- **Config** (daemon-side): `gcEnabled` — boolean, default **on** (snapshot-first is
  the safety story). One toggle governs both collectors. Ad-hoc dry-runs are served by
  `tbd gc sweep --dry-run`, not a config state. Advanced knobs, config-only (not in
  Settings UI): `gcGraceSeconds` (3600), `gcSnapshotRetentionDays` (30). Per the house
  rule on gated behavior, `gcEnabled` gets a test per branch: off → zero filesystem
  mutations and no records; on → reaps happen.
- **Deliberately not configurable** (safety invariants, not knobs): snapshot-before-
  delete (no mode exists where uncommitted work is deleted without a snapshot), the
  detection gates (linkage proof, lock, live-cwd), and sweep cadence (`gc.sweepNow` /
  `tbd gc sweep` cover "now").
- **DB migration** (next `vN`): `reap_records` — id, kind (`agentWorktree` |
  `scratchpad`), repo path, worktree path, branch (nullable), head sha (nullable),
  snapshot ref (nullable), apparent bytes freed (nullable), `reaped_at`, `restored_at`
  (nullable). Migration + GRDB record + `TBDShared` Codable model (new fields optional
  or defaulted) in one commit.
- **History tab**: reap records live in a **separate, collapsed-by-default disclosure
  section** at the bottom of the archived-worktrees left rail — header *"Reclaimed
  (12 · ~9.4 GB)"* — rendered only when the repo has reap records, so the main archived
  list is unchanged until the user expands it. Reap rows are a visually distinct row
  type (own GC glyph, muted styling — never dressed up as archived worktrees): agent-
  worktree rows read *"`agent-a3c04…` · branch `fix-render-path-waste` kept · 1.2 GB
  (apparent) · snapshot ✓"* with a Restore button in the detail pane (RPC `gc.restore`),
  and no session-count/revive affordances. Scratchpad reaps are rolled up into one
  aggregate row per repo (*"23 scratchpads cleaned · 31 GB"*) — they have no restore
  action, so per-row listing is noise. Restore applies to `agentWorktree` records only;
  restored entries show restored-at instead of the button.
- **CLI**: `tbd gc list` (incl. snapshot/restorable state), `tbd gc restore <id>`,
  `tbd gc sweep [--dry-run]` — dry-run prints the identical plan without mutating.

## Error handling

- Ordering is the transaction: snapshot ref written **and verified** before any `rm`.
  Snapshot failure → keep the worktree, log `kept: snapshot-failed`. Never
  delete-anyway.
- `rm` failure leaves a partial dir; the next sweep retries idempotently (linkage proof
  still passes on the remains, or the leftover is `git worktree prune`-able debris).
- Per-worktree isolation: one bad repo/worktree logs and continues; a sweep never
  aborts wholesale.
- All GC activity logs via `os.Logger` subsystem `com.tbd.daemon`, category `gc`
  (`.debug` for per-candidate gate traces, `.info` for reaps/restores), explicit
  `privacy:` on dynamic interpolations.

## Testing

- **Unit** (injection seams, no `setenv` outside sanctioned suites): collectors with
  fixture lsof/ps output and tmp git repos built with real `git worktree add`
  (locked, dirty, detached-HEAD, submodule-decoy, symlinked-path variants);
  `ReapSnapshot` round-trip — snapshot → reap → restore → byte-identical dirty state;
  exact-slug computation; `gcEnabled` off/on branch tests.
- **Integration** (suites under `TBDHomeSerialized` in `Tests/TBDDaemonTests`): full
  sweep against a `TBD_HOME` sandbox; archive event → scratchpad deleted; daemon-down
  catch-up via reconciliation sweep.
- No test touches `~/tbd` or the developer's real scratchpads.

## Rollout & relation to PR #423

1. **PR #423 lands first, descoped**, as dev tooling: keep the scratchpad shell sweep +
   universal live-cwd/dirty rails, fix the symlink-canonicalization finding, scope
   install reaping per the review (agent worktrees only, or re-measured clone-aware).
   Immediate relief, no product coupling.
2. **This feature ships behind `gcEnabled`** (default on), dogfooded on the developer
   fleet. The shell scripts keep covering what the product intentionally does not:
   SwiftPM `.build`, install dirs in living worktrees, non-attributable scratchpads.
3. **`docs/reclaim-build.md`** gains a section delineating product GC vs dev-script
   territory so the boundary stays explicit.

## Non-goals

- Idle-based reaping of anything (stays in dev scripts).
- Deleting branches (human / `clean_gone` concern).
- Reaping installs or `.build` inside living TBD worktrees.
- GC of non-attributable scratchpads or other Claude Code global state.
- Provenance capture via Claude Code hooks (`WorktreeCreate`/`SubagentStop`) — a
  possible future refinement for authoritative run-ended signals, not needed for
  orphan detection.

## Future

- Claude-hook provenance (map agent worktree → spawning TBD session) would enable
  "reap immediately on session end" and per-session attribution in History.
- Count-cap LRU (Codex keeps 15, Cursor 25) as a backstop if orphan detection ever
  under-collects in practice.
- Surfacing chronic `kept: locked` leaks as a user-visible health warning.
