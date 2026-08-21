# Archiving a scratch space through `worktree.archive`: design

Status: **implemented**.

## Problem

`tbd worktree archive <name-or-id>` fails on every scratch space, and the
failure message names the wrong object:

```
$ tbd worktree archive 20260814-zygomorphic-ant
Error: Repository not found: E3DB7381-2215-4B1A-B7A2-DEB42E4CE4A5
```

The UUID printed there is the *worktree* id. Nothing looked up a repo.

A scratch space is a repo-less TBD workspace under `~/tbd/scratch/<name>`
(`docs/superpowers/specs/2026-07-02-scratch-spaces-design.md`); `Worktree.isScratch`
is defined as `repoID == nil` (`Sources/TBDShared/Models.swift`). Archive's phase 1
resolves a repo before it does anything else:

```swift
guard let rid = worktree.repoID, let repo = try await db.repos.get(id: rid) else {
    throw WorktreeLifecycleError.repoNotFound(worktree.repoID ?? worktreeID)
}
```

For a scratch row the *first* clause fails, so `worktree.repoID` is nil and the
`?? worktreeID` fallback substitutes the worktree id into a message about
repositories. Revive carries the identical guard, so an archived scratch space
could not be brought back through `worktree.revive` either.

The daemon is perfectly capable of archiving a scratch space: `scratch.archive`
does it, and the GUI reaches it by routing client-side in
`AppState.archiveWorktree(id:force:)`, whose doc comment records the workaround
("the repo-worktree `worktree.archive` RPC rejects them with `repoNotFound`").
Only the GUI knows to route. Every other client, the CLI included, sends
`worktree.archive` and gets the misleading error. The CLI has no scratch
lifecycle commands at all: `tbd scratch` exposes `new`, `list`, and `promote`,
and the `scratchArchive`/`scratchDelete`/`scratchRevive` client methods have
exactly one caller, the GUI.

The user-visible consequence is that the only CLI verb that appears to apply
(`tbd worktree forget`) is the wrong one. `forget` hard-deletes the worktree row
and its closed-terminal history and has no inverse, so reaching for it as a
substitute for archiving loses the row and its history permanently.

## Design

`worktree.archive` and `worktree.revive` route a repo-less row to the scratch
implementation inside the daemon, before any repo resolution is attempted. The
routing sits in `handleWorktreeArchive` / `handleWorktreeRevive`, immediately
alongside the remote-lane branch those handlers already carry, and reuses the
exact code path `scratch.archive` / `scratch.revive` run. The bodies of those
two handlers move into `archiveScratchSpace(worktreeID:surface:actor:)` and
`reviveScratchSpace(worktreeID:method:)`, called from both entry points, so the
two RPC doors share one implementation.

Separately, the guard stops lying. `WorktreeLifecycleError` gains a case for the
condition that actually held:

```swift
guard let rid = worktree.repoID else {
    throw WorktreeLifecycleError.worktreeHasNoRepo(worktreeID)
}
guard let repo = try await db.repos.get(id: rid) else {
    throw WorktreeLifecycleError.repoNotFound(rid)
}
```

`repoNotFound` now only ever carries a repo id, and a repo-less row gets a
message that says so and names what to do about it. The routing above means no
supported client reaches the new error through archive or revive, but three
call paths still enter `beginArchiveWorktree` without passing the router
(the synchronous `archiveWorktree(worktreeID:force:)` wrapper, the `repo.remove`
cascade, and auto-archive on merge), and an internal invariant violation should
report itself accurately rather than as a fictional repo lookup.

### Why route in the daemon rather than add `tbd scratch archive`

`worktree.archive` is already the general verb, not the repo-worktree verb. The
same handler dispatches remote lanes to `archiveRemoteLane` because "the files
are on another machine" makes the local teardown meaningless for them. "The
worktree has no repo" is the same kind of fact about the row, discovered the
same way (one DB read before any work), and it deserves the same treatment. The
CLI's `worktree` noun already covers scratch spaces everywhere else:
`resolveWorktreeNameOrID` resolves them by name, and `tbd worktree list` prints
them. `worktree archive` refusing them was the odd one out.

Routing in the daemon also fixes every client at once, including the ones that
do not exist yet: the CLI, `tbd` skill invocations, hooks, scripts, and the
nightwatch desk. Fixing it in the CLI instead would have reproduced the GUI's
client-side check a second time and left the next client to discover the trap a
third time.

The contract question is whether silently redirecting an RPC is honest. It is,
because the redirect preserves the caller's intent exactly: the caller asked for
this worktree to be archived, and afterwards it is archived, its folder is
intact, and it appears in the archived listing. The alternative reading, that
`worktree.archive` promises specifically the git-worktree teardown, is not a
promise any client relies on: the same method already means something
structurally different for a remote lane.

A dedicated `tbd scratch archive|delete|revive` CLI surface is deliberately
**not** part of this change. With the routing in place those commands would be
aliases for verbs that already work, so they add naming surface and no
capability. They remain a reasonable follow-up for discoverability, and the
argument for them is not weakened by shipping this first.

### Why delegate rather than teach the repo path to skip its repo work

The alternative was to make `beginArchiveWorktree` tolerate `repoID == nil`,
returning `(Worktree, Repo?)`, and have `completeArchiveWorktree` skip the parts
that need a repo. That was rejected on blast radius and on risk asymmetry. It
changes the signature of two public lifecycle methods and every caller and test
that touches them, and the phase-2 body it would newly become responsible for
gating is the destructive one: the archive hook, `deletionQueue.enqueue`, the
directory rename, `git worktree prune`, and the fallback `git worktree remove`.
A missed gate there deletes the user's scratch folder, which is the one outcome
archive exists to avoid. Delegating to a path that never had a phase 2 makes
that failure mode unreachable rather than merely guarded.

### Consequences of delegating, accepted

**Teardown fidelity.** The scratch path (`closeScratchTerminals`) kills each
tmux window and clears the terminal, tab, and pending-question rows. It does not
capture scrollback into Closed Terminals history, and it does not escalate to
SIGKILL for a pane that survives `kill-window`'s SIGHUP, both of which the repo
path's `captureThenKillWindow` does. That gap is pre-existing behavior of
`scratch.archive`, which the GUI has always used, and is not introduced here.
Closing it means changing `closeScratchTerminals`, which improves both callers
at once; it is a separate change with its own testable surface.

**Actuation records name the door, not the destination.** `ActuationSurface`'s
own rule is that `method` names the door a request came through and `kind` names
the act, so a request that arrived on `worktree.archive` records
`method: "worktree.archive"` even though the scratch body carries it out. The
surface is therefore a parameter of `archiveScratchSpace`, passed as
`.scratchArchive` by its own door and `.worktreeArchive` by the routed one, and
both shared bodies interpolate the caller's method into their success log lines
for the same reason. This
needs no `ActuationBranch`: both surfaces already map to `kind: .dispose`, so
the act is identical and only the door differs. Filing routed archives under a
verb only the GUI sends would have made a door-based audit under-report
`worktree.archive` and report `scratch.archive` calls nobody made.

The routed **revive**, by contrast, records nothing, and the asymmetry with the
repo branch is the correct one. `ActuationSurface`'s boundary rule puts DB-only
mutations out of the record ("nothing there reaches a process, so nothing there
is an actuation"), and this branch is exactly that: a status flip, a re-read and
a delta. The repo branch records because it really does spawn the worktree's
primary terminals, which is what `.worktreeRevive`'s `spawn` kind names, and a
row claiming a spawn against a worktree with zero terminals is a phantom a fleet
reader querying "spawned but no session appeared" would flag forever. Archive is
the opposite case and does record: killing panes disposes of sessions, which is
squarely inside the boundary.

The same reasoning is why `cols`, `rows` and `preferredSessionID` are accepted
and unused on the routed revive: there is no terminal to size and no session to
resume, because archive deleted every terminal row and revive spawns none.

**`force` is not forwarded, and that is parity rather than a shortfall.**
`worktree.archive`'s `force` flag has two jobs in the lifecycle: skipping the
archive hook and skipping the archivable-children assertion. But
`handleWorktreeArchive` does not pass it to `beginArchiveWorktree` at all, so on
this door it reaches only phase 2's hook skip, and the children assertion always
runs for a repo worktree too. `force` bypasses that assertion only for the
in-process cascade flows that call the lifecycle directly (`repo.remove`), and no
cascade reaches a repo-less row.

So the scratch body asserts unconditionally. Forwarding `force` would have made
one flag bypass the children refusal for a scratch row while leaving it in force
for a repo worktree through the same door: a flag whose meaning depends on the
row shape is worse than one that is simply inert here.

The hook half is a real gap, not an absence. Hook resolution is only *partly*
repo-scoped: the highest-priority leg is the app's per-repo hook path, which a
repo-less row can never have, but the remaining legs are repo-independent,
including `<worktreePath>/.worktree-hooks/<event>` and a global
`~/tbd/hooks/default/<event>` that applies to every worktree regardless of repo.
A scratch space is routinely a git repo (promotion requires `git init` plus
commits), so `.worktree-hooks/archive` inside one is an ordinary shape. Neither
that hook nor the global default runs when a scratch space is archived, through
either door, and the user gets no diagnostic. This is pre-existing
`scratch.archive` behavior that the routing now exposes to every client; closing
it means giving the scratch body a hook call, and deciding first what the
per-repo leg means for a row with no repo.

### The refusals the routed path keeps

Routing must not turn `worktree.archive` into a quieter verb than it was, so the
scratch body enforces the guards that matter for a repo-less row. Three were
missing from `scratch.archive` and are added here, because the routing is what
makes them reachable without a user gesture:

- **Active children.** `assertArchivable` asks whether the row *is* a parent
  (`SELECT ... WHERE parentWorktreeID = ?`), and a scratch space can be one:
  `ParentResolver`'s `caller` arm returns the caller id after rejecting only
  `.main` and `.archived`, so `tbd worktree new` run from inside a scratch space
  mints a repo worktree parented to it, and `worktree.move` permits the same by
  hand. Archiving the parent out from under a live child leaves the child
  rendering nowhere until reconcile nulls the pointer. Refused unconditionally,
  which is what a repo worktree arriving through this same door gets. The GUI's
  row menu pre-disables its scratch Archive item on active children, with the
  same copy the repo-worktree Archive already uses, so the refusal is not first
  met as an alert from an enabled control.
- **Already archived.** `WorktreeStore.archive` re-stamps `archivedAt`
  unconditionally, and that timestamp is the grace clock
  `OrphanProcessCollector` reaps orphaned agents from. A retried call would push
  the reap of a wedged agent out by another `gcGraceSeconds` every time, and
  re-broadcast an archive delta for a row every client has already filed away.
  So an already-archived row is an idempotent no-op that re-stamps nothing,
  rather than either a re-archive or a new user-visible refusal. This guard is a
  read in its own transaction, so it closes sequential retries and not two calls
  overlapping in flight; the durable fix is a status check inside
  `WorktreeStore.archive`'s write block beside the `.main`/`.creating` refusals,
  which would cover the repo path and the direct callers at once.
- **Promoted.** Promotion retires the row as archived with `promotedToRepoID`
  set and leaves `repoID` NULL, so `isScratch` and revive's status check both
  still pass. Only the stale path, whose folder promotion moved away,
  incidentally blocked revive; anything that recreates a directory there would
  resurrect a retired row as active. Both sibling verbs guard on the pointer
  explicitly, so revive does too.

**The Watch Desk is refused.** `isNightwatchDesk` is `isScratch` plus the desk's
display name, so the routing reaches the Nightwatch desk row. Its teardown is
`DeskSessionManager.closeDeskSession`, which also clears the in-memory desk
pointer and is paired with `releaseJudgeLease` to drop the lease row and unlink
the lease credential file. Neither resource has a named reconciler, so retiring
the desk through the generic body would leak both with nothing to reclaim them.
Both doors refuse it and say so, which is the honest answer to the reconciler
question this new destruction path would otherwise have to answer.

Revive refuses it as well, and needs its own guard rather than inheriting
archive's. `closeDeskSession` archives the desk row through
`db.worktrees.archive` directly and changes neither `repoID` nor the display
name, so the archived row still reads as the desk and satisfies every other
revive guard. Bringing it back by hand would flip the row `.active` and
broadcast a revive while the desk actor's pointer, lease row, lease credential
file and terminals stay gone. Nothing legitimately revives a desk row:
`ensureDeskSession`'s recovery path excludes archived worktrees deliberately, so
the desk opens a fresh session instead.

The app keeps its own listings honest on daemon-originated transitions: the
`.worktreeRevived` handler drops the row from `archivedScratchWorktrees`, and the
archived handler refreshes that listing for a scratch row. Without the first
half, a revive from the CLI left the row in the Scratch section's open Archived
tab while it was live again, and that stale row's Delete button trashes the
folder: `scratch.delete` has no status guard, deliberately, because the sidebar
deletes active scratch spaces through it. Without the second half, an archived
scratch space looked deleted: gone from the sidebar and absent from the only view
that lists it.

Revive also re-reads the row **before** broadcasting `.worktreeRevived`. The
re-read exists because the caller that answers with a row must answer with the
stored post-revive `status`; ordering it ahead of the broadcast means the one
failure that can occur after the write commits (a concurrent delete removing the
row) does not tell every subscriber the revive happened and the caller that it
did not.

### What this does not touch

The shared scratch tmux server is not killed. `TmuxManager.serverName(forRepoPath:)`
is a djb2 hash of the directory's absolute path, so every scratch space under
`~/tbd/scratch` resolves to one server name; killing it on a single-row archive
would take out every other scratch space. Both the repo path and the scratch
path only ever kill individual windows, and the routing changes nothing here.

Reconcile cannot resurrect the archived row. Scratch paths are absent from
`WorktreeLayout.legacyAndCanonicalPrefixes`, so the re-adopt sweep does not scan
`TBDConstants.scratchDir`.

`DeskSessionManager.closeDeskSession` carries a third, hand-rolled copy of this
teardown against a row of the same kind, and it has already drifted: it omits
the `pendingQuestions.clear` and per-session overlay removal that
`closeScratchTerminals` performs, so overlay files accumulate until the next
daemon restart. Folding it onto the shared body is deferred, so the extraction
here unifies the two RPC doors rather than every caller.

Four further properties of the scratch body are pre-existing, unchanged by the
routing, and deliberately left for separate changes. Each is a change to that
body, testable on its own, and none is a refusal the routing removes:

- **Teardown ordering.** The scratch body kills panes and deletes terminal and
  tab rows *before* the status flip, and stamps its actuation `.dispatched`
  before a write that can throw. The repo path documents the opposite ordering
  as load bearing ("a crash mid-archive can't leave the row half-updated").
- **No terminals after revive.** Archive deletes every terminal row and revive
  spawns none, so a revived scratch space comes back active with nothing to
  attach to. `scratch.create` auto-spawns a primary agent; revive does not. The
  GUI's Archived tab has always behaved this way, and the CLI now does too.
- **Claude session ids.** The repo path captures resumable session ids before
  deleting terminals and preserves them across a revive that spawns no agent.
  The scratch body does neither; the two halves currently mask each other, so
  fixing either alone would clear ids that nothing had recorded.
- **Deep links.** A `tbd://` deep link to an archived scratch space returns
  without navigating and without a diagnostic. Previously near-unreachable,
  since only the GUI could archive one.

The `?? worktreeID` shape appears once more, in `completeCreateWorktree`. That
path is unreachable for a scratch space (repo-less rows are minted through
`WorktreeStore.createScratch`, never by the create lifecycle), but it is the same
defect, so it moves to the new error case too rather than being left as a
second copy of a message the reader has just learned not to trust.

## Risks

**A non-scratch row misclassified as scratch.** The branch keys on
`Worktree.isScratch`, that is `repoID == nil`. A repo worktree whose `repoID`
were nil would be routed to a path that leaves its directory and git
registration in place, an under-cleanup rather than a data-loss failure, and
would then be reported as archived. `repoID` is non-null for every row the
create lifecycle writes, and the only two writers of a null one both go through
`WorktreeStore.createScratch`: `handleScratchCreate`, whose rows are the
intended target of this routing, and the Watch Desk's session creation, whose
row is refused explicitly by the `isNightwatchDesk` guard in both shared bodies.
So a row reaching the scratch teardown by way of a nil `repoID` it should not
have had requires the DB to already be inconsistent. That premise is worth
re-checking rather than inheriting: a third `createScratch` caller would widen
this routing silently, and its rows would need their own answer here.

**A scratch row misclassified as a repo worktree.** The inverse is the dangerous
direction, since it reaches the phase-2 deletion path, and it is exactly what
the routing prevents. It is unreachable through the router after this change,
and the `worktreeHasNoRepo` guard is what stops it in the three non-router
entry points.

**Ordering against the remote-lane branch.** Both branches read the same row.
The remote check runs first and is unchanged; a remote lane is never scratch
(remote rows carry a repo), so the two conditions cannot both hold, and the
order is not load bearing. It stays first to keep the existing branch's diff
empty.

## Testing

`Tests/TBDDaemonTests/ScratchArchiveReviveRPCTests.swift` covers the
`scratch.*` methods already. The new coverage exercises the routed `worktree.*`
methods against a scratch row created through `scratch.create`, asserting the
properties that distinguish archive from both the old failure and from delete:

- `worktree.archive` on a scratch row succeeds, flips `status` to `.archived`,
  sets `archivedAt`, and broadcasts one `.worktreeArchived` delta.
- The folder is still on disk afterwards, and the row is still present (not
  deleted), so it appears in the archived listing.
- `worktree.revive` on that archived row succeeds, returns the decodable
  `Worktree` result its clients expect, and flips the row back to `.active`.
- Terminals and tabs are torn down, matching what `scratch.archive` does.
- The false arm of each `isScratch` gate: a `.main` repo worktree is refused by
  `beginArchiveWorktree`'s first guard, and an `.active` repo worktree by
  revive's status guard. Both prove the repo path ran, since the scratch body
  refuses with "Not a scratch space", and both stop before any tmux, git, or
  disk work, in particular before archive's detached phase 2, whose
  deletion-queue rename would outlive the test's `TBD_HOME` isolation.
- The three kept refusals: a scratch space with an active child is refused and
  `--force` does not bypass it, through either door; a second archive re-stamps no `archivedAt` and
  broadcasts no second delta; a promoted row is refused even with a directory
  recreated at its stale path, so the guard and not the filesystem is what
  refuses it.
- `worktreeHasNoRepo` renders through the `LocalizedError` bridge, alongside
  the other daemon errors, so the worktree id survives into log lines.

A dangling `repoID` is not constructible through the store (the column is
`REFERENCES repo(id) ON DELETE CASCADE`), so `repoNotFound(rid)`'s new argument
is covered by the error-rendering test rather than by a router-level fixture.
