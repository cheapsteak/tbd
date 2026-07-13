# Orphan GC (product feature)

Daemon-owned garbage collection for Claude Code agent worktrees and their scratchpads.
**Shipped product**, unlike `scripts/reclaim-build.sh`/`sweep-scratchpads.sh` (see
[`docs/reclaim-build.md`](reclaim-build.md) for the dev-script sibling and the boundary
between the two). Design background:
[`docs/superpowers/specs/2026-07-10-orphan-gc-design.md`](superpowers/specs/2026-07-10-orphan-gc-design.md),
[`docs/research/2026-07-10-agent-worktree-gc/agent-deck-worktree-lifecycle.md`](research/2026-07-10-agent-worktree-gc/agent-deck-worktree-lifecycle.md),
[`docs/research/2026-07-10-agent-worktree-gc/ecosystem-prior-art.md`](research/2026-07-10-agent-worktree-gc/ecosystem-prior-art.md).

## What it reaps

`isolation: "worktree"` subagents and Workflow runs make Claude Code create git
worktrees under `<repo-root>/.claude/worktrees/{agent-*,wf_*}`. Claude Code only
auto-removes one if it ended unchanged — the moment an agent commits, the worktree
(and its gitignored `.build`/`node_modules`/`.venv`) persists forever, and Claude
Code's own 30-day sweep permanently exempts anything with unpushed commits. Nothing
else ever cleans these up.

Two things get reaped:
- **Agent worktrees** — `<repo>/.claude/worktrees/agent-*` and `wf_*` whose run has
  ended (see gates below).
- **Attributable scratchpads** — `/private/tmp/claude-<uid>/<slug>` directories TBD can
  tie to a worktree path it knows about (its own, or an agent worktree it just reaped).

## Philosophy: orphaned, not idle

*Orphaned* = the owning entity is gone and nothing will programmatically return to it.
*Idle* = the owner still exists and might come back — that needs a time-judgment
policy, which stays out of the product and lives in the dev-script reaper instead. The
branch and its commits always live in the repo's shared `.git`, not the checkout —
removing the worktree directory never loses committed work. Only uncommitted/untracked
state is at risk, and the snapshot step (below) covers exactly that.

## Agent-worktree reap gates

For each directory under `<repo>/.claude/worktrees/`, gates run in this order. **Every
gate fails toward keeping** — a `nil`/error/timeout anywhere means "don't touch it":

1. **Linkage proof** — the candidate's `.git` file must resolve (via `realpath`
   canonicalization on both sides) into `<repo>/.git/worktrees/<id>`. Path shape alone
   never qualifies a directory; a decoy `mkdir`, a symlink to the repo root, or
   anything not backed by a real linked worktree is silently skipped.
2. **Not locked** — `git worktree list --porcelain` reports no `locked` for the path.
   Claude Code holds the lock for the whole live run, so this alone excludes in-flight
   agents. A leaked stale lock means the worktree is kept forever (fail-safe, logged as
   `kept: locked`).
3. **No live process** — no `lsof -d cwd` entry at or below the canonicalized path.
   **A non-zero `lsof` exit skips the entire sweep, not just this gate** — a failed or
   partial process listing is never treated as "no live processes"; same treatment as
   an `lsof` timeout. This is stricter than a per-candidate keep: one bad `lsof` run
   means nothing in the whole sweep gets reaped that pass.
4. **Grace window** — HEAD/index mtime older than `gcGraceSeconds` (default 3600s /
   1h). A settling buffer for the gap between unlock and sweep, and for a human still
   poking around right after a run — not an idle policy.
5. **Reap** — snapshot first if needed (see below), `du -sk` for the disk-usage
   estimate, `rm -rf`, verify the removal actually took, then `git worktree prune`.
   **The branch is never deleted** — branch cleanup stays a human / `clean_gone`
   concern.

## Snapshot & restore

**Snapshot** (only when the worktree is dirty, or its HEAD isn't reachable from any
branch — e.g. a detached-HEAD agent): stage everything with a temp index, `git
write-tree`, `git commit-tree` on top of HEAD, `git update-ref
refs/tbd/snapshots/<worktree-name>-<timestamp>`, then **verify the ref is actually
readable** before anything is deleted. A verification failure keeps the worktree
untouched. `.gitignore`d content (so `node_modules`/`.venv`) never enters the snapshot
— `git add -A` respects ignore rules. Nothing is stored outside the repo; content
dedupes into the normal object store.

**Anchor refs**: if HEAD is clean but unreachable from any branch, the ref is written
straight at `headSHA` (no new commit) purely to keep the commit alive against git's own
GC. Anchor refs for otherwise-unreachable commits are **kept indefinitely** — they're
the only thing keeping that work alive, and refs are cheap.

**Restore** (`tbd gc restore <id>` or the Reclaimed section's Restore button):
recreates the worktree with `git worktree add` — on the original branch if it still
exists, detached at the recorded HEAD SHA otherwise — then, if a snapshot ref exists,
replays it into the working tree (`git restore --source=<ref> --worktree -- .` for
tracked content, snapshot-tree files re-created for untracked content). Refuses with an
error if the original path is already occupied.

**Known limitation — deletions aren't replayed.** `git restore` re-creates files from
the snapshot tree; it does not delete files. If the dirty state being snapshotted
included files the agent had *deleted* (vs. modified or added), restore does not
reproduce those deletions — the restored worktree can end up with files present that
were gone at snapshot time. Only for `.agentWorktree` records — scratchpads have no
restore path (nothing to recreate a bare tmp dir from); restoring twice, or restoring
an already-restored record, is refused.

**Snapshot retention**: the sweep deletes `refs/tbd/snapshots/*` older than
`gcSnapshotRetentionDays` (default 30) **only** when the record was never restored
*and* its branch still exists. A record whose branch is gone keeps its ref forever —
deleting it would make the snapshot unrecoverable garbage to git itself.

## Scratchpad cleanup

A scratchpad is only ever cleaned when TBD can attribute it to a concrete worktree path
it knows — there is no slug *decoding*, only exact slug *computation*
(`path.replacingOccurrences(of: "/", with: "-")`) from paths TBD already has on hand:

- **Event-driven** — the moment TBD archives/deletes one of its own worktrees, and the
  moment an agent worktree is reaped, the exact slug's scratchpad is deleted
  immediately. This path runs independent of the hourly sweep cadence, still gated by
  `gcEnabled`.
- **Reconciliation (part of the hourly sweep)** — for archived TBD worktree rows whose
  `path` no longer exists on disk, compute the slug and remove the scratchpad. Catches
  anything missed while the daemon was down.

Non-goals: scratchpads of non-TBD projects, and scratchpads left behind by agent
worktrees Claude Code itself removed before TBD ever swept them. That residue is
`scripts/sweep-scratchpads.sh`'s territory (`docs/reclaim-build.md`).

## Cadence and the `gcEnabled` gate

`gcEnabled` (config-table boolean, **default on**) is the single master switch — it
gates the hourly sweep **and** event-driven scratchpad cleanup. When off, a non-dry-run
sweep does nothing at all — not even the `lsof` pass. Toggle it in Settings
("Automatically clean up orphaned agent worktrees") or via the `config.setGCEnabled`
RPC.

### Why default-on, despite the default-off house rule

CLAUDE.md's "large or risky new behavior ships behind a default-off flag" rule names
exactly this shape (background timer, deletes persisted state), and the
`auto_hibernate_enabled` precedent (shipped on, force-disabled in v50) is the cautionary
tale. This feature is judged exempt, deliberately, per the design spec's brainstorm
decision (`docs/superpowers/specs/2026-07-10-orphan-gc-design.md` §Config):

- **Deletion here is not lossy by construction.** Nothing is deleted without a
  snapshot ref written *and verified* in the shared repo first; branches are never
  deleted; every reap is restorable from History/CLI for `gcSnapshotRetentionDays`.
  The un-gated failure mode of auto-hibernate (losing live session state) has no
  analog: the worst outcome of a wrong reap is one click to restore.
- **Orphan-only, never idle.** Every gate must *prove* the owner is gone (linkage,
  lock, live-cwd, grace) and every gate/error direction fails toward keeping — each
  direction carries a dedicated test, including the both-branch `gcEnabled` tests the
  house rule requires.
- **Default-off would un-ship the feature.** The entire point is unattended cleanup of
  worktrees nothing else GCs; the population it protects against grows silently
  (81-worktree incident). A soak already happened live during development: the first
  boot sweep reaped 11 real orphaned agent worktrees on the dev machine, all
  restorable, gates verifiably keeping every busy worktree.

The sweep itself runs:
- **Once immediately at daemon boot** (cold-start recovery), then
- **Every hour** thereafter, for as long as the daemon runs.

For an ad-hoc look without waiting for the clock, use `tbd gc sweep --dry-run` — it
computes and prints the identical plan without touching disk or the DB, regardless of
`gcEnabled`. One under-report to know about: a companion scratchpad reap for an
agent worktree that's only *planned* (not actually reaped) in a dry run isn't planned
either, since it's only computed once the agent worktree itself has actually been
removed — a real (non-dry) sweep will report more scratchpad reaps than the preceding
dry run predicted.

## Config knobs

| Key | Default | Where |
|---|---|---|
| `gcEnabled` | `true` | Settings toggle + `config.setGCEnabled` RPC |
| `gcGraceSeconds` | `3600` (1h) | config table only, no UI |
| `gcSnapshotRetentionDays` | `30` | config table only, no UI |

Deliberately **not** configurable, as safety invariants rather than knobs: whether a
dirty worktree gets snapshotted before delete (always), the detection gates
themselves, and sweep cadence.

## History (Reclaimed section)

Archived-worktrees view gets a collapsed-by-default "Reclaimed" disclosure section at
the bottom, rendered only when the repo has reap records. Header reads e.g. *"RECLAIMED
(12 · 9.4 GB)"* — the count/size covers **unrestored** records only. Rows:

- **Agent-worktree rows** — one per record, muted/distinct styling from real archived
  worktrees (no session-count or revive affordances). Shows path, branch, apparent
  size, whether a snapshot exists. Restored rows are dimmed and show "Restored
  `<date>`" instead of a Restore button.
- **Scratchpad rows** — rolled up into a single aggregate row per repo (e.g. "23
  scratchpads cleaned · 31 GB") — no restore action, so no per-row listing.

Restore is available for `agentWorktree` records only.

## CLI

```sh
tbd gc list [--repo <path>] [--json]   # list reap records (id, kind, path, size, snapshot state, restored)
tbd gc restore <uuid>                  # restore a reaped agent worktree
tbd gc sweep [--dry-run]               # run a sweep now; --dry-run prints the plan, mutates nothing
```

## Non-goals (from the design spec)

| Out of scope | Why |
|---|---|
| Idle-based reaping of anything | Stays in dev scripts (`docs/reclaim-build.md`) — needs a time-judgment policy this feature deliberately avoids |
| Deleting branches | Human / `clean_gone` concern |
| Reaping installs (`node_modules`/`.venv`/`.terraform`) or `.build` inside living TBD worktrees | Never orphaned, only idle |
| GC of non-attributable scratchpads or other Claude Code global state | No linkage to a known TBD/agent-worktree path |
| Provenance capture via Claude Code hooks (`WorktreeCreate`/`SubagentStop`) | Possible future refinement for authoritative run-ended signals; not needed for orphan detection today |

## Logging

`os.Logger` subsystem `com.tbd.daemon`, category `gc` — `.debug` for per-candidate gate
traces, `.info` for reaps/restores, with explicit `privacy:` on dynamic
interpolations. Stream live:
```sh
log stream --level debug --predicate 'subsystem == "com.tbd.daemon" AND category == "gc"'
```
