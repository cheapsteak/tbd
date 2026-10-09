# Unmanaged worktree ownership

TBD stops adopting git worktrees on location alone. A git worktree under one of
TBD's worktree directories that has no row is reported, and becomes TBD's only
when the user runs `tbd worktree adopt <path>`. TBD's own checkouts stay tracked
by the paths that create them, not by a sweep that guesses ownership from where
a directory sits.

## Problem

Reconcile used to insert a row for every git worktree that sat under one of
TBD's own directories (`~/tbd/worktrees/<repo>/…`, or the legacy
`<repo>/.tbd/worktrees/`) and had no row. The only evidence for ownership was
the location.

That makes ownership something anyone can grant by accident. A person, or
another tool, that runs a plain `git worktree add` inside TBD's directory gets
the tree adopted at the next reconcile (daemon start, `tbd cleanup`, repo add),
with no terminals and no notice. A row hands the tree to TBD's lifecycle:
archive deletes the directory, and sweeps over rows can reap it. A session that
is still working in such a tree, with uncommitted changes, loses them when an
archive pass decides the worktree is idle.

Field evidence: an archive sweep that treated "no tabs" as "idle" deleted two
helper trees that another session was still using, one of them holding
uncommitted work. Both had been adopted by reconcile on location alone.

## Decision

Reconcile reports and does not adopt. For each git worktree that is listed by
`git worktree list`, lives under a TBD worktree directory, has no row in the
set reconcile is comparing against, and is not a forgotten path, it writes one
log line naming the path and pointing at `tbd worktree adopt`. If an archived
row still holds the path, the line says so and notes that `adopt` revives that
row. The main worktree, paths outside TBD's directories and forgotten paths
(`tbd worktree forget` tombstones) are skipped as before; a forgotten path is
skipped without a log line, because the user has already decided about it.

Adoption is opt-in. `tbd worktree adopt <path>` (`WorktreeLifecycle+Adopt.swift`)
already exists, is idempotent, verifies git lists the path, and clears a forget
tombstone. The Conductor and Claude Code Desktop import scripts already call it
explicitly. Nothing else in TBD depended on reconcile adopting, with one
exception covered next: TBD's own checkouts.

Reconcile is not on a timer. It runs at daemon start, on `tbd cleanup` and when
a repo is added, so the report is one line per unmanaged tree per such event,
and carries no once-per-path state.

## How TBD keeps its own checkouts tracked

The old behavior was also a safety net: any checkout TBD made and then lost
track of was re-adopted by the next reconcile. With adoption gone, each way TBD
can lose track of its own checkout needs its own answer. A tree TBD creates
always has a row first (`beginCreateWorktree` inserts it as `.creating` before
any git work), so the cases are the ones where that row is lost or points at the
wrong place.

**A create that fails after `git worktree add` succeeded.** The create is still
reported failed and its row is still deleted, with any parked first message
saved. But the create has recorded the checkout it made in an in-memory ledger
(`CreatedCheckoutLedger`, on the lifecycle, shared across its copies), on every
leg (fresh branch, existing branch, PR head) as soon as the checkout exists, and
drops the entry when the create finishes. The rollback reads that entry, not the
row's path: after a name collision the checkout is at a different path than the
row's, and a foreign tree may sit at the row's own path, so ownership is carried
from the create rather than inferred. If the entry exists, the deleted row had a
repo and the directory exists, the rollback gives the checkout a fresh `.active`
row through `adoptWorktree` with the old display name, and broadcasts the usual
created event. A failure to adopt is logged and leaves the checkout on disk,
reported by reconcile.

The re-adopted row is adopt-shaped (no parent, no PR number, no terminals) with
one exception: the foreign-head stamp. A checkout fetched from a fork's PR head
must never have folder trust pre-answered. The stamp is taken from the deleted
row and from the ledger entry (the row's own stamp is written after the
checkout, by a write that can itself be the failing step). If stamping the new
row fails, the new row is deleted again when this adopt inserted it, and the
checkout stays on disk, so an active unstamped row never stands for foreign
contents.

**A name-collision retry.** The retry creates the checkout at a new folder and
branch. The row's path and branch are persisted before the retry's
`git worktree add`, not after it, so a daemon death between the add and the
create's own bookkeeping leaves a row that names the checkout. If the retry add
then fails, the create fails and the rollback deletes the row as usual. The
row's `name` is left as it was: it is the identity the caller was handed, and its
folder and branch are what reconcile and later git calls read. A row whose path
is not in `git worktree list` is archived by the next reconcile, killing its
terminals, which is what persisting the path early prevents.

**A daemon restart mid-create.** Startup recovery resolves `.creating` rows
under its own rules. A row with no terminals whose path git lists as a worktree
of its repo is activated (`.active`, no terminals), not deleted for reconcile to
re-adopt: TBD made that checkout and reconcile no longer would. Listing is the
gate. A plain directory at the path, a repo that cannot be found and a listing
that fails all take the old delete of the row and its records, and the directory
is never touched, because a directory git does not vouch for is not one TBD can
claim. A parked first message in an activated row is saved to `unsent-prompts/`
as a failed create saves it and cleared in the same write that flips the status,
so it is never delivered into a later terminal. A row still carrying archived
Claude sessions (a revive interrupted by the restart) keeps them, since there is
no terminal to restore them into.

## Named reconciler

The doctrine in the root `CLAUDE.md` asks who reclaims the orphans of a
resource. This change creates no new durable resource and one new class of
unmanaged one: git worktrees under TBD's directories that TBD no longer
adopts. Their reconciler is `scripts/sweep-foreign-worktrees.sh`
([foreign worktree sweep](2026-10-05-foreign-worktree-sweep-design.md)): it
walks every repo TBD knows, treats a worktree as a candidate when git lists it
and TBD does not manage it, reports by default, and removes only trees that are
provably finished. It is the right owner because its test for "finished" is
explicit and conservative, where location-based adoption had no test at all.
Directories held by archived rows remain covered by OrphanGC's interrupted-archive
collector, unchanged.

## Rejected alternative: keep adopting, rely on the archive and GC gates

Keep reconcile's insert and make archive and GC careful enough not to delete a
tree that is in use. Rejected because a row is a standing grant, not a single
decision. Every current and future sweep over rows (archive on merge, idle
archive, GC, deletion queue) acts on the tree the moment the row exists, and each
would need its own correct test for "this tree was never TBD's", which none can
have: the only fact available to them is the row. Adoption on location alone
puts the whole burden on every later consumer. Opt-in adoption puts it on the one
place that can ask the user.

## Assumptions and edge cases

- **The ledger is memory only.** A crash between the checkout and the rollback
  empties it; the interrupted create is then resolved by startup recovery under
  the rules above, which do not need the ledger. The only thing the ledger
  alone carries is the foreign-head stamp, and a crash between a fork checkout
  and its stamp leaves a row recovery activates without the stamp. This window
  is the width of two adjacent database writes in the same function, and it is
  not closed here. Closing it would mean stamping the row before the checkout,
  which is a different change to the create.
- **Re-adding a repo.** A repo that is removed and added again no longer picks up
  trees that remain in TBD's directory; each is reported and adopted
  deliberately.
- **A recovered checkout git does not list** is not activated, so nothing is
  ever re-added on a directory's presence alone.
- **The main worktree and paths outside TBD's directories** are not considered
  at all, as before.
