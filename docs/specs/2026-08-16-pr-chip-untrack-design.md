# Untracking and identifying a PR from the status-bar chips

## Problem

The status bar renders one chip per PR bound to the selected worktree — a
status dot plus `#21156` — capped at four, with the rest collapsed into `+N`.
Three things are missing from that strip.

**A chip cannot be removed.** A worktree that has been alive for a week
accumulates PRs that merged, got closed, or belonged to work nobody is thinking
about any more. `tbd pr detach` removes one, but the gesture lives in a terminal
while the thing being removed is on screen; nobody runs it. So the cluster only
ever grows, and the chips that matter get pushed behind `+N` by chips that do
not.

**A chip says only its number.** `#21156` identifies a PR to GitHub and to
nobody else. Deciding whether a chip is worth keeping — or worth clicking —
means opening it in a browser, which is the action the strip exists to make
unnecessary.

**Four is too few** for a worktree whose agent has opened a handful of PRs, so
the overflow menu carries PRs that would have fit on screen.

## Design

### Cap

Seven chips before `+N`, up from four. The cap is a judgement about how many
numbers are worth scanning at a glance, not a width calculation: nothing
consults the available width, and the overflow count is a pure function of how
many bindings there are.

What the cluster does give up under pressure is width, not chips. It carries
`layoutPriority(-1)` just as the path label beside it does, so a narrow window
compresses the strip rather than squeezing the path — and compressing it
truncates chip labels (`#41…`) rather than folding chips into the overflow
menu. Seven chips reach that point at a wider window than four did. Width-aware
collapsing would be the real answer and is deliberately not built here; it is a
layout change to make on its own, with the window in front of you.

### Untracking from the chip

Hovering a chip turns its **status dot into an `xmark`**, in place. Clicking the
xmark detaches that PR from the worktree; clicking anywhere else on the chip
keeps its present meaning and opens the PR in the default browser.

The dot is the right host for this, and not merely the convenient one. It is the
only part of the chip with no click behaviour of its own, so nothing is
displaced; it is already the chip's leading affordance, so the cursor is
travelling past it anyway; and swapping in place means the chip does not grow a
control that has to be laid out somewhere.

Two constraints govern the implementation:

- **The layout must not move between the two states.** The icon slot is a fixed
  size that fits the larger of the two glyphs, and both are centred in it. A
  chip that changed width on hover would shove every chip to its right, and the
  xmark would slide out from under the cursor that summoned it.
- **The hit area is at least 12×12pt**, larger than the 6pt dot and larger than
  the drawn xmark. It is contributed by a transparent overlay rather than by
  padding, so it costs no layout width: an overlay is sized by its parent and
  cannot push its siblings. At 12pt centred on a 6pt dot the region extends 3pt
  past the dot on each side, which stays inside the 6pt gap between chips, so no
  chip can steal a click from its neighbour.
- **The slot's action is derived from the same flag as its glyph.** Hover state
  is not a fact the view can rely on having received: chips are inserted and
  reflowed under a stationary cursor every time the selection changes or a poll
  adds one, and `onHover` need not have fired. An untrack target that stayed
  live under a *drawn status dot* would turn "open this PR" into "stop tracking
  it" on a click the user read correctly. So while the slot draws a dot it
  behaves as a dot did before this gesture existed — it opens the PR — and it
  untracks only while it is drawing the xmark. Accessibility does not hover, so
  that element keeps the untrack identity unconditionally and carries its own
  action; the gesture must not be reachable by pointer only.

Detaching is **tombstoning**, which is what `pr.detach` already does — a delete
would be undone by the next poll or hook fire. The status bar therefore inherits
the whole of the existing durability story rather than inventing one.

#### Detach must be able to tombstone a PR that was never bound

A worktree with no bindings but a cached `Worktree.prStatus` renders a
**synthetic** binding — a display-only value lifted from that status, which by
design never reaches the database. It is not an edge case worth ignoring: it is
what keeps the PR surfaces alive when `gh` is unauthenticated or offline, and
what every worktree shows before its first successful poll after upgrade.

Against today's `pr.detach` the xmark on such a chip would do nothing at all.
The detach matches no row, updates nothing, and reports `detached: false`; the
cached status is untouched, so the chip returns on the next render. A control
that silently declines is worse than an absent one.

So `pr.detach` gains one rule: **when no row matches, insert a tombstone
instead of reporting failure.** The detach becomes an assertion about the PR's
future — "this does not belong to this worktree" — rather than an edit to a row
that happens to exist. Three consequences follow, all wanted:

- the xmark works uniformly, on every chip, whatever backs it;
- `detachedCount` becomes non-zero, which is precisely the signal that
  suppresses the legacy-status fallback, so the chip clears and stays cleared;
- `tbd pr detach` becomes idempotent and order-independent — detaching a PR
  before anything discovers it pre-empts the binding rather than losing to it.

The inserted row is `source = manual`, because a tombstone with no prior row
records nothing but a user's decision. `pr.attach` clears it exactly as it
clears any other tombstone, so the gesture stays reversible.

**Both arms are one write transaction**, not a tombstone-the-row call followed
by an insert-on-miss call. `PRBindingCoordinator` is a reentrant actor, so every
`await` in a detach is a point at which a concurrent bind — the poll's branch
matcher, or a hook's `pr attach` — can run. Split in two, that bind lands a live
row in the gap; the insert then finds an identity already on record, declines,
and the click becomes the silent no-op this whole section exists to remove. The
store therefore exposes a single `tombstone` that detaches an existing row or
inserts one, and reports whether the record changed.

The app names the PR by **URL with its number as a fallback**, sending both, and
`pr.detach` falls through to the number when the URL does not parse. Both halves
are needed and the second is the load-bearing one: `PRBindingExtractor`'s
pattern is host-locked to `https://github.com/`, so on a worktree hosted
anywhere else no binding can ever form, *every* chip is synthetic, and every one
of them carries a URL the daemon will reject. Url-only, the xmark would fail on
precisely the worktrees that have nothing but synthetic chips. A reference with
a bad URL and no number is still an error; the fallthrough is a second chance,
not a default.

**The insert arm carries `bind`'s wrong-repo guard.** Tombstoning an existing
row is always allowed — it is this worktree's own record of the PR, and a repo
rename must not strand it. Creating one is not: `pr.attach` rejects a wrong-repo
reference before it ever reaches a row, so a tombstone for a foreign PR could
never be cleared, and the non-zero `detachedCount` it leaves would suppress that
worktree's legacy-status fallback permanently. One mistyped
`tbd pr detach <other-repo-url>` would retire a worktree's real PR indicator
with no way back. Declining reports "changed nothing", which is the honest
answer: this worktree was not tracking that PR.

#### Removal reflows the strip, and no suppression window is added

The chip leaves the bar within an RPC round trip, and its neighbour slides into
the pixels the cursor is sitting on. A second click there — an impatient double
click on the xmark — lands on the neighbour, and if `onHover` has reached it by
then it untracks that PR too.

The obvious cure is the wrong one. A suppression window after a detach would
also block untracking two chips in a row, which is exactly the workflow a cap of
seven invites: a worktree carrying a week of merged PRs is cleared by clicking
several xmarks in sequence, and a control that ignores the second click is worse
than one that occasionally acts on it. The gesture is reversible —
`tbd pr attach` puts the binding back — and the neighbour's identity is on
screen the whole time. The real fix is for the strip not to reflow under the
cursor at all: hold a removed chip's slot until the pointer leaves the cluster.
That is a layout change, and it belongs with the width-aware collapsing above
rather than bolted onto this gesture.

#### What insert-on-miss costs, and why the cost is accepted here

`detachedCount` is a per-worktree scalar, and the legacy fallback reads any
non-zero count as "this worktree's PR evidence was deliberately removed". Before
insert-on-miss that implication held, because a tombstone could only come from a
row the worktree really had. It no longer does: on a worktree whose only PR
evidence is a cached `Worktree.prStatus` for one PR, `tbd pr detach <some other
number>` now records a tombstone for a PR nobody was tracking, and the count it
raises suppresses the *cached* PR's chip along with it.

That is worth stating rather than hiding, and it is still the right trade. The
gesture the chips need cannot work without insert-on-miss; the mismatch is
unreachable from the chips themselves, since a chip always names its own PR; it
requires a hand-typed number on a worktree that has never successfully polled;
and it suppresses a display-tier cache rather than unbinding anything, so the
first successful poll restores the chip. Making it impossible means reporting
which PRs are tombstoned instead of how many — a change to the `pr.bindings`
payload, and a decision for its own spec rather than a detail of this one.

### Identifying a chip: the hover overlay

Resting on a chip shows an overlay carrying the PR **number, title, state, and
the age of that observation**. The title is the whole point: it is what turns
`#21156` into something a person can decide about.

**No description.** GitHub's GraphQL cannot return a truncated body — `body` and
`bodyText` come whole — so any excerpt would be trimmed only after the bytes had
crossed the wire, on every PR, on every poll, on a fleet that polls
continuously. PR bodies routinely run to kilobytes and are template-heavy. A
title is one short string riding a query that already runs, and it answers the
question the strip actually poses. The description belongs to the PR page, which
is one click away.

Titles are fetched by adding `title` to `prNodeFieldSelection`, the by-number
selection the binding refresh already issues. The viewer-authored batch query
alongside it fetches `title` already, so this closes a gap rather than opening a
cost.

The title is persisted on the binding row, in a new nullable `title` column
(the migration follows the shared-model rule: column, GRDB record, and Codable
model in one commit). It is folded in through `withObservation`, on the same
terms as `headBranch` and `baseRef`: **nil means "not observed", never
"cleared"**, so a transient fetch failure cannot blank a title that is already
on screen.

A synthetic binding has no title, and the overlay renders without one rather
than fabricating a placeholder — number, state and age are still worth showing,
and the missing line is honest about a status that was hydrated rather than
polled.

The overlay states the observation's age because the cached `PRStatus` is
display-tier and has been measured reading "Ready to merge" for PRs merged days
earlier. Every surface that renders it must render its age with it.

## Testing

- Chip cap — seven bindings produce seven chips and no overflow; eight produce
  seven and `+1`; the overflow chip's tooltip still names the total.
- Detach on a live binding tombstones it, and the chip does not return after a
  poll.
- Detach with no matching row inserts a `manual` tombstone; a second detach of
  the same PR is a no-op rather than a duplicate row; `pr.attach` afterwards
  clears it.
- The same store call that would insert a tombstone detaches an existing live
  row in place instead, keeping that row's id and `source` — the arm that makes
  a concurrent bind harmless.
- Detaching an unbound PR from another repo writes nothing and reports no
  change, while detaching a row that already exists still works after the
  worktree's repo has changed under it.
- A reference whose URL does not parse resolves through its number, against the
  worktree's own repo; one with neither is still an error.
- The icon slot means untrack while hovered and open while not, so a click can
  never destroy an association the slot is not offering to remove.
- Detaching the last chip of a worktree whose bindings were synthetic leaves the
  cluster empty, because `detachedCount` suppresses the legacy fallback.
- Title parse — a by-number GraphQL response carrying `title` populates it; one
  omitting `title` leaves the stored value untouched rather than clearing it.
- Title round-trips through the row, the RPC, and back.
- Overlay content for a binding with a title, without one, and with no observed
  status.

## Rejected alternatives

**A separate xmark button beside the number.** Every chip grows a permanent
control, the cluster gets wider at exactly the moment the cap went up, and the
dot — which carries the state — competes with it for the eye.

**A right-click context menu.** Discoverable by nobody, and a second interaction
grammar for a strip whose entire vocabulary is "click the thing".

**Fetching bodies in the poll and truncating server-side.** The bandwidth is
spent before the truncation happens, which is the cost being avoided.

**Fetching the body lazily on hover.** Bounded by what the user looks at, so the
bandwidth objection mostly dissolves — but it buys a new RPC, a cache, and a
loading state in the overlay for content that the PR page presents better. Left
available if titles prove insufficient.

**Hiding the xmark on synthetic chips** rather than making detach tombstone
unconditionally. Zero daemon change, but one chip in a row would silently lack
the affordance its neighbours have, with no way to explain why.

## Why no feature flag

The convention gates behavior that acts without a user gesture or that destroys
state. This is the opposite of both: every removal here is a deliberate click,
and it removes an association TBD inferred, not any repository or session state.
The PR itself is untouched, and `pr.attach` reverses the gesture.
