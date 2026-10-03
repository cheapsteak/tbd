# Status bar: group finished PRs into one "done" chip

## Problem

The status bar shows one chip per PR bound to the selected worktree, in bind
order, up to `StatusBarView.prChipLimit` (7), with a `+N` menu for the rest.
Merged and closed PRs get no special treatment. A long-running worktree
accumulates finished PRs, and their chips crowd out the open PRs the user
actually needs to watch.

## Design

**Finished PR** – a binding whose last observed `status.state` is `.merged` or
`.closed`. A binding with no observed status counts as open: nothing says it is
done.

**When grouping applies** – only when the worktree has two or more finished
PRs. With zero or one, the status bar renders exactly as before. A single
merged PR stays a normal chip because it carries useful news on its own: the
worktree's work shipped.

**Layout** – when grouping applies, the PR cluster renders, left to right:

- one done chip, `✓ N done`
- the open PRs as chips, in bind order, up to `prChipLimit`
- the existing `+N` menu for open PRs past the limit

The done chip leads because bind order puts the oldest PRs on the left, and
those usually finish first. A finishing PR folds into the chip beside it rather
than vanishing from one end of the row while a count changes at the other, and
the row reads oldest to newest: done, open, then the newest PRs at the right
edge.

The chip limit and the `+N` count apply to open PRs only, and so does the `+N`
menu: it lists every open PR, and its tooltip and accessibility label say so
("Show all 4 open pull requests (2 not shown here)"). Without grouping the `+N`
wording is unchanged. When every PR is finished, the cluster is the done chip
alone.

**The done chip** – a borderless menu styled like the `+N` chip: secondary text,
hover underline, and pointing-hand cursor through `StatusBarHoverAffordance`.
Its accessibility label names the count ("Show 5 merged or closed pull
requests"), in the aggregate "pull request" noun the `+N` chip uses because the
set can span both forges.

Hovering it raises a compact, read-only hover card in the same style as a PR
chip's (`StatusBarView.doneChipHoverCard`). The card's title is the count ("5
merged or closed pull requests"), and it lists the finished PRs in bind order,
one row each: the PR's title as the value, falling back to its head branch,
with the reference and state beneath it (`PR #930 · Merged`, `MR !930 · Merged`
on GitLab). A PR with neither title nor branch shows the reference and state as
its value, with nothing beneath. The reference and state come from
`PRBindingPresentation.doneReference`, which the menu rows below end with too,
so the card and the menu describe each PR in the same words, each in its own
forge's syntax. A title's internal whitespace collapses to single spaces, and
the card cuts a title past 120 characters short with an ellipsis, so ten long
titles cannot grow it past the window. The card lists at most ten PRs; past
that, a muted final row says "and N more". The chip carries no tooltip, since the card already says
what one would. Clicking the chip, or opening any menu, before the card has
appeared keeps it down until the pointer leaves the chip and returns.

Titles lead because a finished PR has no chip of its own: once folded, its
title is shown nowhere else on the status bar, and a merged branch name is a
poorer reminder of what shipped than its title.

Clicking the chip opens a menu of the same PRs in bind order, built by
`PRBindingPresentation.doneMenuRows`: each row leads with the title (or the head
branch when there is none, cut short with an ellipsis past 80 characters, since
AppKit widens a menu to its longest item), then the reference and state (`Fix
the login timeout  PR #930 · Merged`). The `+N` menu and the toolbar dropdown keep their
shared `menuRows` shape. Choosing a row opens the PR in the default browser, as
the `+N` menu does. It offers no untrack action, matching the `+N` menu.

That leaves a grouped PR with no untrack gesture in the app: the chip's leading
icon was the only one, and the PR no longer has a chip. `tbd pr detach` still
untracks it. This is accepted because the usual reason to untrack a finished
PR is the room its chip takes, and the group already returns that room. If
untracking finished PRs from the app turns out to matter, a menu entry in the
done chip is the place to add it.

**Placement in code** – the split is a pure function in
`PRBindingPresentation`, alongside `statusBarChips`, returning the open chips,
the open overflow count, the bindings the `+N` menu lists, and the finished
bindings to group (empty when grouping does not apply). `StatusBarView.prChips` and `PRChipCluster` consume
it. Keeping the rule in a pure function is what lets it be tested without a
view, as the existing chip selection is.

**Ordering** – bind order is preserved within each group. A PR moves from the
open chips into the done chip when it finishes, which is the point of the
feature; within either group nothing reorders under the cursor.

## Scope

Status bar only. The toolbar split button, its dropdown, and the sidebar PR dot
are unchanged; they summarize a worktree's PRs differently and are not the
surface that runs out of room.

No feature flag. The change is display-only, acts on no user gesture, and
mutates no state, so the default-off flag rule does not apply.

## Known limitation

`PRStatus` is a display-tier cache refreshed by the PR poller. A PR merged
moments ago can still read "Ready to merge" and stays an open chip until the
next poll observes the merge. The chip's hover card dates any reading older
than five minutes, so a lag longer than that is visible rather than hidden.

## Testing

Unit tests on the pure split function:

- zero or one finished PR → no done group, output identical to today's
  `statusBarChips`
- two or more finished PRs → grouped; open PRs keep bind order; finished PRs
  keep bind order in the group
- `.closed` folds alongside `.merged`; a binding with no status stays open
- the chip limit and the `+N` overflow count only open PRs
- every PR finished → no open chips, no overflow, all PRs in the group
- the `+N` wording says "open pull requests" when grouping applies and is
  unchanged otherwise

## Rejected alternatives

- **Sort finished PRs to the end of one list.** Less code, but chips would
  reorder as states change, breaking the bind-order rule
  `PRBindingPresentation` holds for every PR surface.
- **Filter finished PRs in the daemon.** The toolbar and sidebar still need
  them, and the daemon is the wrong layer for a display choice.
- **Inline expand/collapse.** Expanding pushes the path and branch cluster
  aside and needs per-worktree expansion state; a menu gives the same access
  with neither.
