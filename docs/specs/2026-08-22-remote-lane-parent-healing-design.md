# A remote lane's parent: one late assignment, then the user's

A remote lane is a worktree row TBD mints for an agent session running on a
machine it does not manage. Where that row sits in the tree — nested beneath the
lane that spawned it, or at the top level of its repository — comes from
`meta["tbd_parent_worktree_id"]`, a stamp the provider carries for the session,
or from the parent the user pointed at when starting the lane from a nested `+`.

Both can fail to produce a parent at the moment the row is minted, and the lane
lands at top level. This document records what may happen to that lane
afterwards: it may take a first parent from a later sighting, exactly once, and
after that its position belongs to the user.

Companion documents. The creation path — one-click creation, where each
create-param answer comes from — is
[`2026-08-20-remote-lane-creation-design.md`](2026-08-20-remote-lane-creation-design.md).
The tree model that makes a remote session a worktree row at all is
[`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md),
which specified the row as "created once at first sighting and never
re-derived" and left the nesting edge's one exception for here. The rules as a
provider sees them are stated on the wire in
[`docs/remote-provider-contract.md`](../remote-provider-contract.md) under
Worktree identity keys.

## The problem: the parent may not be knowable at first sighting

Adoption mints a row the first time a session resolves to a registered repo, and
it resolves the parent edge in that same write. The edge can come out empty for
reasons that are temporary rather than permanent:

- **The session was not stamped yet.** The stamp is written by whoever creates
  the session, and a poll can land before it does.
- **The spawning lane was not yet a row TBD had.** A stamp naming a worktree
  this TBD does not hold resolves to nothing, and the same identifier resolves
  fine once that row exists.

The edge also comes out empty for reasons that are not temporary — an
unparseable stamp, or one naming a `main` or archived worktree, neither of which
renders a subtree in the sidebar — and those simply leave the lane where the
user can see and place it.

Nothing in adoption revisits the edge on its own. Adoption's first act on a
sighting is to look for an existing binding, and finding one ends the creation
half of adoption for that session. So without a second path, a lane that missed
its parent by a few seconds stays at top level for the rest of its life, however
many times the resolvable stamp arrives afterwards. That is the defect this
mechanism exists to fix.

## The policy: a row is offered a parent exactly once

**A row that has never been given a parent may take a first one from a later
sighting. A row that has been given one is never offered another.**

The count is the whole decision, and both neighbouring numbers are worse:

- **Zero** — the reading that "a later value is always ignored". It is what
  strands the lane above: adoption finds the row already bound on every later
  sighting, so a parent that becomes resolvable one poll too late never lands.
- **Unlimited** — a guard that asks only whether the parent edge is currently
  nil. The stamp is static: a provider that stamped a session at create time
  repeats the same value on every poll, forever. So the first poll after the
  user runs `tbd worktree move <lane> --root` reads the stamp again and puts the
  lane back, broadcasting a `.worktreeMoved` nobody asked for — the lane
  visibly jumps in the sidebar, within one poll interval, every time.

One assignment satisfies both: the lane that was never placed gets filed, and
the lane the user placed stays placed.

Two properties keep the late edge from being a weaker kind of edge than a drag:

- **Same rules.** `assignParentIfUnset` runs `move()`'s own `validateParent` —
  not self, the parent exists, the parent is neither `main` nor archived, and
  the edge closes no cycle. The last two matter only for a late edge, since a
  row being minted can be neither its own parent nor an ancestor of one.
- **Refusal is not assignment.** An edge the rules refuse assigns nothing and
  therefore records nothing, so a later stamp that does validate can still file
  the lane.

Subscribers hear what a viewer would see: a row taking a late parent broadcasts
`.worktreeMoved`, not a second `.worktreeCreated` for a row they already have.

## The marker and its lifecycle

The fact that arbitrates is `worktree.remote_parent_assigned`, carried on the
model as `Worktree.remoteParentAssigned`. It answers one question: has adoption
already given this row a parent, or has the user already said where it goes?

**Three writes set it**, and they are the three ways a remote row can acquire a
parent:

- **Minting a remote row under a parent.** `WorktreeStore.create` derives the
  value from the row it is about to insert — remote location, non-nil parent —
  rather than asking the caller for it, because the marker records what that
  write did and this is where that is known. A remote row is minted by adoption
  and by nothing else, so a remote row born with a parent is an assignment.
- **Late healing.** `assignParentIfUnset` sets it in the same statement that
  writes the parent.
- **The user's own move.** `move()` sets it when the moving row is remote *and*
  the parent edge actually changes. This is the only place a user's placement
  gesture lands — the sidebar drag and `tbd worktree reparent` both arrive
  through `worktree.move` — so it is the only place that can record one.

Two qualifications on that third write carry weight:

- **Both directions.** The invariant is that a user's placement decision is
  final, which is about the gesture and not its direction. Without the to-root
  half, a lane the user nests by hand and then un-nests arrives back at a nil
  parent still unmarked, the guard passes, and the first poll able to resolve
  the stamp re-nests it — the same regression, reached through a first parent
  that came from the user rather than from adoption.
- **Only on an actual change.** A move that keeps the same parent is a
  reordering, and reordering within the top-level group says nothing about
  nesting. A lane the user merely dragged up the list is still one adoption may
  file under its spawning lane once the stamp resolves.

**Local rows never carry it.** Adoption is not in a local worktree's life, and a
marker there would only mislead a later reader.

**Nothing ever clears it.** There is no path that writes the column back to
false; clearing on un-nest would erase precisely the gesture the marker exists
to make permanent.

**One reader.** `assignParentIfUnset` refuses unless the row's parent is nil
*and* the row is unmarked, re-checking both inside its own write transaction so
two concurrent convergences cannot both read "no parent" and both assign one.
The adoption path tests the same pair first, to avoid a write it knows will be
refused.

**Across the wire** the field is optional with a default, so a daemon and an app
at different versions still decode each other's worktrees; a row that is marked
stays marked through a round trip, so the app's copy agrees with the daemon's
about a lane the user has already placed.

## Why a recorded fact rather than an inference from state

`parentWorktreeID IS NULL` has two provenances, and on the row itself they are
identical:

- nobody could name a parent when the row was minted, or
- the user took away the parent it had.

The first invites healing and the second forbids it, and no amount of reading
the row distinguishes them. The stamp cannot arbitrate either — it is static, so
its presence proves only that the session was stamped at create time, which is
equally true in both cases. The marker is the missing fact, and it is written by
the very transaction that assigns a parent, so it survives the parent's removal:
the edge goes back to nil, the record of having been offered one does not.

## Legacy rows: the backfill marks every pre-existing remote lane

The forward migration marks **every** remote row that predates it, parented or
not, so nothing written before the column is eligible for late assignment.

A parented legacy row plainly had a parent assigned — nothing but adoption mints
these rows. A top-level one is the ambiguous case, and it cannot be resolved
after the fact: a build without the column recorded nothing when `move()` took a
parent away, so the lane the user deliberately un-nested and the lane nobody
could ever place are the same row. Leaving those unmarked would re-file the
first kind on the first poll after the upgrade, from a stamp that arrives again
every poll — exactly the outcome the column exists to prevent.

**The asymmetry that makes marking safe:** the marker can only ever *withhold* a
parent adoption would have imposed, never impose one. Over-marking costs at most
a heal nobody was promised — a lane sits at top level until the user drags it,
which is where it already was. Under-marking costs the user's gesture, silently
and repeatedly.

Rows minted after the migration are unaffected: the insert path writes the
column explicitly, so their `false` is a fact the daemon recorded rather than a
schema default, and they stay healable.

The column carries an ordinary SQL default. CLAUDE.md's rule about adding a
column with no default — so that "nobody has chosen" stays a third state — is
about feature flags whose shipped default may need flipping later. This is data
about a row, there is no third state to preserve, and the backfill's whole
purpose is to give every existing row a definite value.

## Why no feature flag

Late assignment is the one behavior here that acts without a user gesture, which
is the shape CLAUDE.md asks to be gated by default. It is not gated, for reasons
that are about its bounds rather than its convenience:

- **Bounded, not standing.** At most one write per row for the row's lifetime.
  It is not a sweep, a timer, or an actor that keeps acting; once the row is
  marked, the code path is inert for that row forever.
- **No relaxed authority.** It reuses `move()`'s full `validateParent` rather
  than a copy, so it can produce no edge a user could not have produced by
  dragging.
- **Degrades to the status quo.** A refusal leaves the lane at top level —
  where it already was — rather than failing anything.
- **The user always wins afterwards.** Any placement gesture spends the
  assignment permanently.

The rule's trigger is met literally — this acts on a poll, with no gesture
behind it — so what stands in for the flag is the written justification the rule
allows in its place, which is the list above. The distinction matters: the claim
is not that the rule fails to apply, but that a soak would observe nothing. A
flag protects a behavior whose failure mode is unknown until it runs at scale,
and this one's worst outcome is bounded at "the lane stays where it is".

CLAUDE.md names two shapes of sufficient justification — gated behind an explicit
user action, or extending behavior that is already flagged — and this is neither.
It introduces those with "e.g.", so a boundedness argument stands as a third form,
and the maintainer has accepted it as one for this behavior specifically. That
acceptance is recorded here rather than left implicit, because the call is not an
agent's to make: a reader deciding whether to reach for the same exception should
see that a human took it deliberately, and scoped it to a write that happens once
per row and reuses the existing validation rather than relaxing it.

## Rejected alternatives

**A parent edge that can never change after the row is minted.** The simplest
rule to state, and the one that produced the defect. A lane whose parent became
resolvable one poll after adoption is stranded at top level permanently, with no
signal that anything was lost.

**A nil parent is invitation enough — no marker at all.** Cheapest to build, and
it silently reverts the user. Because the stamp is static, every poll re-asserts
the create-time parent, so `tbd worktree move <lane> --root` survives for less
than one poll interval and the lane jumps back in the sidebar unprompted.

**A marker written only by adoption's own paths.** It covers the lane adoption
placed but not the lane the user placed. A lane adopted top-level, nested by
hand, then un-nested arrives back at nil unmarked — and the next resolvable
stamp files it somewhere the user has already rejected. The marker has to be
about the row's placement history, not about which subsystem wrote it.

**Clearing the marker when a lane returns to top level.** Reads as symmetric
housekeeping and destroys the mechanism: moving to root is the gesture the
marker exists to make permanent.

**Marking only the legacy rows that already had a parent.** It looks more
conservative — mark only what is provably assigned — and it leaves eligible
exactly the ambiguous rows, which is where the user's un-nest gesture is
invisibly recorded. Given the asymmetry above, the conservative direction is to
mark more, not less.

**Asking the provider which lanes it placed.** The parent edge is TBD-side
presentation state: it never affects the session's git base and is never
reported back to the provider, so a provider has no record of the user's
gestures and could only replay the same static stamp under another name.

**A relaxed validation for the late edge**, on the grounds that a stamp is a
weaker claim than a drag. It would give TBD two definitions of who may parent
whom, free to drift; and the two guards a late edge uniquely needs — no self,
no descendant — argue for stricter, not looser.

## Open question

Nothing clears the marker, including the reconciler that promotes a child back
to top level when its parent goes missing or is archived
(`nullOrphanedParents`). A remote lane promoted that way keeps its marker, so it
stays at top level until the user places it, even though the position it lost
was not one the user chose to leave. Whether such a promotion should restore
eligibility is not settled here.
