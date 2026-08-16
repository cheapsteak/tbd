# Orphan GC (product feature)

Daemon-owned garbage collection for Claude Code agent worktrees, their scratchpads, and
orphaned per-profile Claude config directories.
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

Four things get reaped:
- **Agent worktrees** — `<repo>/.claude/worktrees/agent-*` and `wf_*` whose run has
  ended (see gates below).
- **Attributable scratchpads** — `/private/tmp/claude-<uid>/<slug>` directories TBD can
  tie to a worktree path it knows about (its own, or an agent worktree it just reaped).
- **Orphaned profile config directories** — `~/tbd/profiles/<uuid>/` directories whose
  `model_profiles` row is gone; `ProfileDirCollector` is the named reconciler for that
  resource class, alongside the agent-worktree and scratchpad collectors, and it
  quarantines rather than deletes (see below).
- **Orphaned supervision desks** — the scratch space and `desks.json` entry of a hosted
  supervisor whose session is gone; `SupervisionDeskCollector` is the named reconciler
  for that resource class (see below).

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
5. **Reap** — a pre-rm re-check first (see below), then snapshot if needed (see
   below), `du -sk` for the disk-usage estimate, `rm -rf`, verify the removal actually
   took, then `git worktree prune`. **The branch is never deleted** — branch cleanup
   stays a human / `clean_gone` concern.

**TOCTOU: pre-rm re-check.** Gates 2–4 run once, against lock/`lsof` data captured at
sweep start; on a large sweep a given candidate's turn to actually reap can come up
minutes later, so that data can be stale by the time it matters. Immediately before
anything destructive happens — before even the snapshot step, since snapshotting
writes into the doomed worktree's git index — the reap step re-fetches both the lock
state and a fresh `lsof` pass and re-applies the same lock/live-cwd checks. A `nil`
from the fresh `lsof` pass fails toward keeping, same sentinel semantics as the
sweep-level pass. This closes the staleness window down to the instant between the
re-check and the `rm -rf`/`removeItem` call — a race an external process would have to
land in to defeat it, not the minutes-wide window gates 2–4 alone left open.

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

## Profile config directories

Every non-Bedrock model profile gets an isolated Claude config directory at
`~/tbd/profiles/<uuid>/`, created lazily — on session spawn, when the profile's
`CLAUDE_CONFIG_DIR` is resolved, and on OAuth login prep
(`modelProfile.prepareConfigDir`, called before `tbd profile login`). Exactly one
`model_profiles` row points at it, and it is the *only* pointer: nothing on disk records
which profile a directory belongs to beyond the UUID in its name.

That makes deletion the risk. `modelProfile.delete` cleans the Keychain items and the
directory before deleting the row — deliberately, so a daemon killed partway leaves "row
present, directory gone or present", both benign — but each cleanup step is log-only and
non-fatal. A `removeItem` that fails still deletes the row, and the row is what would
have named the leftover directory. Without a sweep, a single failed removal orphans that
directory permanently. `ProfileDirCollector` is the backstop.

**Orphan definition.** An immediate child of `~/tbd/profiles/` whose name parses as a
UUID, is a directory, and matches no `model_profiles` row. Non-UUID entries, plain files
and the `.reaped/` quarantine are never candidates. Directories are enumerated *before*
the rows are read, so a profile created mid-sweep is always in the row set and can never
be classified as an orphan.

**Flag: `gc_profile_dirs_enabled`, default off.** The flag gates *classification*: a
directory is enumerated, gated and quarantined only when `gcEnabled` **and** this flag
are both on. It does **not** gate quarantine expiry, which runs under `gcEnabled` alone —
purging `.reaped/` is cleanup of GC's own artifacts, of data the sweep already moved
aside, not a judgement about a user's resource. That split is what makes quarantining
safer than deleting: an operator who ends a soak by turning the flag off (or backs out
after a suspected misclassification) must not thereby strand credentials on disk forever,
well past the retention window. A dry run bypasses both switches, exactly as it does for
the rest of the sweep: `tbd gc sweep --dry-run` prints the `REAP profile-dir` and
`PURGE quarantine` lines this phase *would* act on with the flag off, so the decision to
enable a default-off switch can be made against real candidates rather than blind.
Planning touches neither disk nor the database. Enable it for a soak with
`tbd gc profile-dirs on` (RPC
`config.setGCProfileDirsEnabled`); there is no Settings toggle. The column carries no SQL
default, so an install nobody has touched reads NULL and resolves through
`Config.gcProfileDirsEnabledDefault` — graduation is a one-line change to that constant,
reaching everyone who never flipped the switch while preserving every explicit opt-out.

**Gates**, in order. Like the agent-worktree gates, every one fails toward keeping, and
each keep is reported in the sweep plan with its reason:

1. **Row exists** (`row-exists`) — a `model_profiles` row with this UUID is present.
2. **Terminal reference** (`terminal-reference`) — any `terminal` row's `profile_id`
   matches the UUID. `modelProfile.delete` deliberately leaves `profile_id` on terminals
   spawned with that profile's env, so a live (or hibernated, resumable) session may
   still be pointing `CLAUDE_CONFIG_DIR` at the directory. Terminal rows disappear when
   terminals close, so this converges. It is deliberately stricter than the interactive
   delete path: a background sweep yanking credentials out from under a running session
   is worse than a user doing it knowingly.
3. **Grace window** (`grace`) — the directory's creation date is younger than
   `gcGraceSeconds` (default 3600s / 1h). An unreadable creation date keeps too
   (`unknown-age`).
4. **Pre-reap re-read** (`row-appeared`, `row-read-failed`) — immediately before the
   rename, `model_profiles` is re-read for the UUID. The candidate list and the row
   snapshot are both taken at the top of the phase, so a profile recreated with this
   UUID in between must not have its directory pulled out from under it. A row that is
   found again keeps as `row-appeared`; a read that *throws* keeps as `row-read-failed`,
   distinct on purpose — "no answer" is not "no row", and collapsing the two would reap
   on the one piece of evidence that says nothing.

A failed `model_profiles` or `terminal` read skips the whole classification arm rather
than treating the empty result as "everything is an orphan".

**Quarantine, not delete.** A reap renames the directory into
`~/tbd/profiles/.reaped/<uuid>-<UTC timestamp>/`. The rename is the commit point: a
failure leaves the candidate exactly where it was for the next sweep to reconsider
(`quarantine-failed`). Both destructive filesystem calls are anchored first, and to the
collector's own base rather than to whatever the caller passed: a reap refuses any
candidate that is not a UUID-named *immediate* child of `~/tbd/profiles/` (so an
already-quarantined entry can never be re-quarantined a level deeper), and a purge
refuses any path not strictly under `.reaped/`. Apparent size is measured just before the rename, while it is
still readable at the original path. Immediately after, the path-keyed Claude Code
login-keychain item for the *original* config dir (`<uuid>/claude`) is deleted — the
rename invalidated the path its service name is derived from, so it is unreachable
garbage either way; `errSecItemNotFound` counts as success. A `.profileDir` reap record
is then written, carrying the original path and the quarantine path.

The other collectors can delete outright because what they remove is recoverable by
other means, or was never precious: an agent worktree replays from a verified snapshot
ref, and a scratchpad is disposable tmp. A profile directory is neither. It holds `.claude.json` (login identity, onboarding
state, per-profile settings), `.credentials.json` (fallback OAuth credentials when the
Keychain is unavailable), and `<slot>.profile-local` sidecars holding real pre-existing
user content that was moved aside when a slot became a host symlink — none of which has
another copy once the row is gone. A misclassification therefore has to stay
recoverable, so reaping parks the data instead of destroying it.

**Quarantine expiry.** The same phase deletes `.reaped/` entries older than
`gcSnapshotRetentionDays` (default 30), which keeps the quarantine from growing into the
disease it treats. It runs on every sweep `gcEnabled` allows, whatever
`gc_profile_dirs_enabled` says, so nothing this collector parked can outlive the
retention window. Age comes from the timestamp this collector stamped into the entry's
own name; an entry whose name carries no parsable stamp falls back to the newer of its
own creation and modification dates, and one with no readable date at all is kept rather
than guessed at. Expiry writes no new reap record — the entry already has one.

**No restore path, recovery by hand.** `tbd gc restore` accepts `.agentWorktree` records
only and rejects `.profileDir`. By the time the collector runs, the profile row — its
name, kind, endpoint — is already gone, so renaming the directory back would only
recreate an orphan for the next sweep to find. Recovery is manual and lasts as long as
the retention window: `tbd gc list` prints the quarantine location next to each record
(`quarantined→ <path>`), and the user copies out whatever they need, or recreates a
profile and moves the directory into the new UUID. The app's Reclaimed section does not
surface these records — it is per-repo, and a profile directory belongs to no repo — so
the CLI is where a quarantine path is read.

## Hosted supervision desks

Turning a project on under fleet supervision spawns a **hosted desk**: a scratch
worktree with one agent session in it, recorded in `~/tbd/supervision/desks.json`
(`docs/specs/2026-07-26-fleet-supervision-design.md` §9). Neither half is covered by the
legs above — the agent-worktree leg walks `db.repos.list()` and so sees only repo-backed
worktrees, and the archived legs only touch rows already `.archived` — so
`SupervisionDeskCollector` is that resource class's reconciler.

**Its subject is a desk that got recorded and then died.** It enumerates the record, so
a spawn that failed before writing an entry is not visible to it at all; that half is
the spawn path's own, which archives its scratch row on every failing exit and thereby
hands the directory to the deletion-queue leg.

**Flag: `gc_supervision_desks_enabled`, default off.** Enable it for a soak with
`tbd gc supervision-desks on` (RPC `config.setGCSupervisionDesksEnabled`); there is no
Settings toggle. Like the profile-dir flag it carries no SQL default, so an untouched
install reads NULL and resolves through `Config.gcSupervisionDesksEnabledDefault` —
graduation is a one-line change to that constant. `tbd gc sweep --dry-run` bypasses the
flag and prints the `REAP supervision-desk` lines it would act on.

**Gates**, every one failing toward keeping:

1. **Grace** (`desk-within-grace`) — a desk spawned inside `gcGraceSeconds` may not have
   reached the `lsof` pass yet.
2. **Terminal read** (`desk-row-read-failed`) — a read that did not answer says nothing
   about the desk.
3. **Worktree read** (`desk-worktree-read-failed`) — likewise, and kept distinct from a
   row that is genuinely absent (`desk-worktree-row-gone`, which reaps the record only,
   there being nothing on disk this sweep can attribute).
4. **Shape** (`desk-not-a-scratch-space`) — a recorded worktree that is repo-backed, or
   outside the scratch base, is not this leg's to touch.
5. **Already archived** (`desk-already-archived`) — the row is where a reap would put it.
6. **Live** (`desk-live`) — a process sitting in the desk's directory *or anywhere below
   it* is the desk running, matched on the same prefix boundary the agent-worktree leg
   uses. **A live desk is never reclaimed**, whatever its rows or its project say.

Reaping drops the record and moves the worktree row to `.archived`, from where the
deletion-queue and scratchpad legs reclaim the directory and `WorktreeLifecycle+Reconcile`
settles its tmux state — this leg kills no window itself. The record write is guarded on
the entry the sweep judged (`desk-record-changed`): a spawn for the same project landing
mid-sweep leaves a live desk nobody judged, and dropping its key would unrecord it.

**Liveness is the whole decision.** A desk whose project stopped resolving is not
reaped on that ground: design §9 is explicit that a topology gesture ending a project
takes its mark, its mode selection and its supervisor binding, and that no coverage
gesture disposes a desk. Once the desk is not live it is reclaimed regardless of whether
the project still resolves, so a project check would gate nothing and would need a
second reader of `supervision.json`.

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
`gcEnabled` or `gc_profile_dirs_enabled`. One under-report to know about: a companion
scratchpad reap for an agent worktree that's only *planned* (not actually reaped) in a
dry run isn't planned either, since it's only computed once the agent worktree itself
has actually been removed — a real (non-dry) sweep will report more scratchpad reaps
than the preceding dry run predicted.

## Config knobs

| Key | Default | Where |
|---|---|---|
| `gcEnabled` | `true` | Settings toggle + `config.setGCEnabled` RPC |
| `gcProfileDirsEnabled` | `false` | `tbd gc profile-dirs on\|off` + `config.setGCProfileDirsEnabled` RPC, no UI |
| `gcSupervisionDesksEnabled` | `false` | `tbd gc supervision-desks on\|off` + `config.setGCSupervisionDesksEnabled` RPC, no UI |
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
tbd gc list [--repo <path>] [--json]   # list reap records (id, kind, path, size, snapshot state, restored, quarantine path)
tbd gc restore <uuid>                  # restore a reaped agent worktree
tbd gc sweep [--dry-run]               # run a sweep now; --dry-run prints the plan, mutates nothing
tbd gc profile-dirs on|off             # gate the profile-config-dir collector (ships off)
tbd gc supervision-desks on|off        # gate the supervision-desk collector (ships off)
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
