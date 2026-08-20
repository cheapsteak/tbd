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
two handlers move into `archiveScratchSpace(worktreeID:actor:)` and
`reviveScratchSpace(worktreeID:)`, called from both entry points, so there stays
one implementation of "archive a scratch space" in the tree.

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

**Actuation kind.** A routed call records `.scratchArchive`, not
`.worktreeArchive`. The record names what was actually done, which is the
property the actuation log exists to hold. `scratch.revive` records no actuation
today and the routed revive matches it, so `worktree.revive` on a scratch row
writes no actuation row where the repo path writes one. Both are consistent with
"the record reflects the path taken"; giving scratch revive an actuation record
is a change to the scratch path, not to the routing.

**`force` is inert.** `worktree.archive`'s `force` flag skips the archive hook
and the archivable-children assertion. A scratch space has neither a hook
(hooks resolve per repo) nor children (nothing creates a scratch row with a
parent), so the flag is accepted and ignored on the routed path rather than
rejected. Rejecting it would break `tbd worktree archive --force <scratch>` for
no gain.

### What this does not touch

The shared scratch tmux server is not killed. `TmuxManager.serverName(forRepoPath:)`
hashes the path, so every scratch space under `~/tbd/scratch` resolves to the
same server (`tbd-7ec3bd20`); killing it on a single-row archive would take out
every other scratch space. Both the repo path and the scratch path only ever
kill individual windows, and the routing changes nothing here.

Reconcile cannot resurrect the archived row. Scratch paths are absent from
`WorktreeLayout.legacyAndCanonicalPrefixes`, so the re-adopt sweep does not scan
`TBDConstants.scratchDir`.

The `?? worktreeID` shape appears once more, in `completeCreateWorktree`. That
path is unreachable for a scratch space (scratch rows are minted by
`handleScratchCreate`, never by the create lifecycle), but it is the same
defect, so it moves to the new error case too rather than being left as a
second copy of a message the reader has just learned not to trust.

## Risks

**A non-scratch row misclassified as scratch.** The branch keys on
`Worktree.isScratch`, that is `repoID == nil`. A repo worktree whose `repoID`
were nil would be routed to a path that leaves its directory and git
registration in place, an under-cleanup rather than a data-loss failure, and
would then be reported as archived. `repoID` is non-null for every row the
create lifecycle writes, and `handleScratchCreate` is the only writer of a null
one, so this requires the DB to already be inconsistent.

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
- A repo worktree whose `repoID` names no repo row still fails, and with a
  message naming the repo id rather than the worktree id, so the guard split
  did not turn a real inconsistency into a silent success.
