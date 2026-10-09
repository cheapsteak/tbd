# Sidebar: collapse ended remote sessions

## Problem

With workflow groups off, the shipped default, the sidebar renders every
unadopted remote session that is neither dismissed nor archived as an inline
row: in its project's section when the session resolves to a registered
repository, under its provider otherwise. A session keeps that row after it
ends, whether it exited or its provider stopped reporting it, until someone
dismisses or archives it. On a fleet that launches many short-lived remote
sessions, ended rows pile up far faster than anyone dismisses them.

Field measurement on one install:

- **Rows** – the sidebar `List` held about 320 rows. 208 were remote-session
  rows: 200 in one project and 8 under the provider. 4 of the 208 were live,
  24 had exited and 180 were no longer reported. The mirror held 851 sessions
  in all; dismissal and archiving had already taken the other 643 out of the
  sidebar.
- **Stalls** – 136 main-thread stall reports from one app session (1,450
  stack samples). A quarter of the samples sat in the remote-session sort's
  per-comparison timestamp parse, fixed separately (issue #987). 15% sat in
  SwiftUI's `List` diff (`OutlineListCoordinator.recursivelyDiffRows`, with
  `ForEach` re-applying row traits), and most of the remainder was SwiftUI
  view-graph updates beneath the sidebar's `NSHostingView`.

`List` draws only the cells on screen, so the drawing cost is not the problem.
The cost is in the row model. On every update SwiftUI walks the model to diff
it. Each `RemoteSessionRowView` body also reads `AppState` properties that are
not about that row (the selected remote session and the unread map), so a
selection change or a new notification re-evaluates every row's body. Each
sidebar update therefore costs time in proportion to the rows in the model,
including rows nobody is looking at. When the app is busy, that cost lands as
typing latency.

The rows are kept for a reason. An ended session still has a transcript, a
detail pane and actions (dismiss, delete, revive), and some users scan the
recent ones. What they do not need is all of them in the row model on every
update.

## Design

### What "ended" means

A session is **ended** when the mirror records `gone` (absent from the
provider's inventory) or its reported state is `exited`. Running, starting and
unknown sessions are **live**.

The test reads the session's recorded facts, never provider freshness. The
grouped sidebar's Exited group does the opposite on purpose: it files a session
as exited only while its provider's snapshot is fresh, and otherwise counts it
as unknown. That rule suits a summary that claims something about the present.
This rule decides what occupies the row model, and two things favor recorded
facts here:

- A provider going stale must not pour hundreds of ended rows back into the
  `List`. Freshness drops exactly when the machine or the network is already
  struggling, which is when an extra diff of hundreds of rows hurts most.
- A session last seen exited, or gone from the provider's own inventory, does
  not become live because the provider is temporarily unreachable. When it
  does come back, the next successful sighting moves it back inline.

### Where ended sessions go

Each owner, a project section or a provider section, renders its live
sessions inline exactly where all of its sessions render today. If it has any
ended sessions, one disclosure header follows them, titled **Ended**, with the
same summary line and attention badge the workflow groups use: for example,
"24 exited · 180 no longer reported". It starts collapsed. Expanded, the ended
sessions render beneath it one indent level in, in the order they have today
(creation order).

A collapsed group's rows are absent from the `List`. There is no hidden
`ForEach`, so its sessions cost the diff nothing. Expanding the group brings
them back. Because that happens only when the user asks, so does the cost.

The ordering is unchanged: the per-repository memo of the filtered, sorted
sessions (`AppState.sidebarMatchedRemoteSessions(repoID:)`) still produces the
section's sessions. The live/ended split runs over that result on current
values, because `gone` and the process state are deliberately not memo inputs.
It is a single linear pass with no parsing.

### Group identity and remembered expansion

The disclosure is a new workflow-group kind, `ended`, persisted as
`ended|repository|<uuid>` or `ended|provider|<name>` in the same store as the
workflow groups (`com.tbd.app.sidebarExpandedGroups`). The same pruning covers
it: an entry goes when its repository or provider goes, and only on an
authoritative fetch. Scratch never owns one, because Scratch has no remote
sessions.

It is a separate kind from `exited` because the two hold different sets in
different places. The grouped Exited group excludes no-longer-reported
sessions and sits under the Remote group. The Ended group includes them and
sits at the end of the owner's inline rows. Sharing one expansion state between
them would open one whenever the user opened the other.

### Selection reveal

Selecting an ended session from outside the sidebar opens its owner's Ended
group, so the selected row exists in the `List`. Those selections come from the
Provider Desk's ledger, the pinned dock, back/forward navigation or a
notification. The owner is where the row would render: the project when the
session resolves to a registered repository and no worktree row in that
project has adopted it, the provider otherwise. An adopted session renders as
its worktree row and reveals nothing.

Reveal only ever opens a group. Collapsing is the user's gesture alone. It
never expands a collapsed project section, which the ungrouped sidebar has
never done on selection either. A re-selection of the same session reveals
again, keyed on the same selection generation the workflow groups use, so a
group the user collapsed reopens when they explicitly navigate back into it.

### What does not change

- **Workflow groups on** – the flag has no effect. The grouped sidebar already
  keeps exited work behind its own disclosures.
- **Worktree rows** – adopted remote lanes are worktree rows, and they stay
  where they are whether or not their session ended.
- **Dismiss, archive and delete** – unchanged. Collapsing is presentation
  only; nothing is dismissed, deleted or mutated in the daemon.

## The flag

This changes where existing items appear by default, which `CLAUDE.md` puts
behind a default-off flag. The behavior is pure sidebar presentation, so the
flag lives in the app's `UserDefaults`, the placement `sidebarWorkflowGroupsKey`
and `enableTranscriptKey` already use. No daemon `config` column is added.

- **Key** – `sidebarCollapseEndedSessionsEnabled`, three-state. Absent follows
  the one shipped constant, `AppState.sidebarCollapseEndedSessionsDefault`,
  which is `false`. An explicit `true` or `false` is a user's choice and
  survives any later change to the constant. Readers resolve it through
  `AppState.sidebarCollapseEndedSessionsEnabled(defaults:)` or an
  `@AppStorage` whose default is that constant, never `bool(forKey:)`.
- **Setting** – Settings → General, "Collapse ended remote sessions", directly
  beneath "Group hibernated, remote and exited worktrees".
- **Soak** – turn it on from that toggle, or with
  `defaults write TBDApp sidebarCollapseEndedSessionsEnabled -bool true`.
- **Graduation** – a one-line change to the constant, which moves everyone who
  never chose and leaves every explicit choice alone.

## Rejected alternatives

- **A "show N more" cap** – the threshold is arbitrary, and it ignores the
  property that actually makes a row uninteresting. Sessions sort oldest
  first, so a cap would keep the oldest ended rows and hide newer live ones;
  re-sorting to avoid that changes an ordering users rely on. A cap also hides
  live sessions on a fleet that genuinely has many of them, and that is the
  one case where those rows matter.
- **Turn on workflow groups** – it already exists, but it also moves live
  remote work and hibernated local work behind disclosures, a much larger
  change than most users want. And it files no-longer-reported sessions under
  the Remote group rather than its Exited group, so on the measured install it
  would leave 180 of the 204 ended rows in an expanded Remote group.
- **Replace `List` with a lazy stack** – this wholesale-replaces a load-bearing
  path. It would mean reimplementing selection, keyboard navigation and drag
  reorder, and a lazy stack still diffs its whole `ForEach` identity list.
- **Auto-dismiss ended sessions** – it acts without a gesture and mutates
  state. Dismissal also does more than hide a row (it removes the cached
  transcript eagerly), and the right retention policy for that is a separate
  question.
- **Report fewer gone sessions from the provider** – many no-longer-reported
  sessions are simply older than a provider's listing window, and that is
  worth fixing at the provider. It does nothing for exited sessions, though,
  and depends on every provider, so the sidebar still needs a bound of its own.

## Verification

- **Tests** – the three-state resolver, including an explicit `false` held
  against a shipped default of `true`. The live/ended partition: exited,
  gone and gone-while-running sessions are ended; running, starting and
  unknown ones are live; both halves keep their order; the summary counts gone
  and exited separately and takes attention only from ended sessions. Both
  branches of the flag for repository and provider sections. The grouped
  layout, which is identical with the flag on and off. The persistence-key
  round trip, with Scratch rejected. Reveal for a matched, unmatched, live,
  adopted, dismissed and archived selection.
- **Benchmark** – `SidebarListUpdateBench`, gated on `TBD_PERF_BENCH=1` and
  inert otherwise, mounts the real `SidebarView` offscreen with N remote
  sessions in the measured live/exited/gone mix. It times the main-thread CPU
  of a refresh-shaped update with the flag off and on, at the measured 208 and
  at 800. The PR reports its numbers.

## Decisions

A human answered these when the design was proposed. The design above
follows them.

1. **No-longer-reported sessions count as ended.** They were 180 of the 204
   ended rows measured. Excluding them would leave the bound waiting on every
   provider's listing window.
2. **A collapsed Ended disclosure, not a "show N more" cap**, for the reasons
   under rejected alternatives.
3. **An ended session with an unread error or attention notification files
   under Ended** like any other, and the header carries the attention badge.
   That is how the grouped sidebar's Exited group behaves, and keeping the row
   inline until read would make it jump twice.
4. **Selecting an ended session from elsewhere opens its group**, as specified
   under selection reveal.
5. **The soak ends** when one heavy user has run with the flag on for a week
   with no lost-session reports and the benchmark shows the update cost no
   longer tracks the ended-session count. Then the shipped default flips.
