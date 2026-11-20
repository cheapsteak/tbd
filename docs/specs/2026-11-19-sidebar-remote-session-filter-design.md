# Sidebar filter for registry-provider sessions

**Date:** 2026-11-19
**Status:** Approved and built.
**Builds on:** [`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md) (remote rows in the tree),
[`2026-08-27-remote-create-menu-entries-design.md`](2026-08-27-remote-create-menu-entries-design.md) (the cloud provider versus registry providers),
[`2026-10-06-sidebar-groups-toggle-design.md`](2026-10-06-sidebar-groups-toggle-design.md) (the optional Remote group).

## Summary

A repo whose sidebar list carries sessions from a registry provider gets a
filter button on its header row. Turned on, the button hides that repo's
registry-provider rows and sessions and keeps its local and cloud rows. The
choice is saved per repo in the app's settings. Repos with no
registry-provider sessions never show the button.

## Problem

A registry provider can fill a repo's list faster than a person can read it.
On one install, a single repo carried 28 active registry-provider rows beside
63 local rows and one cloud row. Many such sessions are run by an external
orchestrator that manages them and reports on them in chat. For the person at
the sidebar they are noise: the list exists to reach their own local work, and
the remote lanes are already watched elsewhere.

Cloud sessions are different. They are few, the person started them by hand,
and they want to see them.

The existing grouping setting ("Group hibernated, remote and exited
worktrees") does not fit. It applies to every repo at once, it also moves
hibernated and exited rows, and its Remote group holds cloud rows beside
registry rows, so folding it hides the cloud rows too.

TBD cannot tell which registry sessions an orchestrator made: the provider
contract carries no "created by" field. The filter therefore acts on the
provider, not on the creator.

## Terms

- **Registry provider** – any provider listed in `~/tbd/agent-providers.json`,
  which is every provider except the compiled `claude-cloud` one. This is the
  set `CloudCreateEntryPresentation.registryProviders` returns.
- **Registry row** – a worktree row whose location is
  `.remote(provider:sessionID:)` with a registry provider.
- **Loose registry session** – a registry-provider session that matches the
  repo but has no worktree row.

## What the filter hides and keeps

The filter is per repo. Turning it on changes that repo's list and nothing
else.

- **Hidden:**
  - Every registry row, at any depth: at the top of the repo, under a local
    lane, or under another remote row.
  - Every loose registry session.
  - Exited registry rows and sessions, including those that sit in the Ended
    or Exited groups.
  - The descendants of a hidden row.
- **Kept:**
  - The main row and every local row. A lane that began on a provider and
    landed on this machine is local: its files are on this disk, so it stays,
    whatever its origin.
  - Every cloud row and cloud session.
  - The ancestors of a kept row. When a local or cloud row sits under a
    registry row, the registry rows above it stay in view, so the kept row is
    never cut off from the tree.
- **Unchanged:**
  - Every other repo.
  - The provider sections at the foot of the sidebar, which list sessions that
    match no repo.
  - TBD's notifications. The filter changes the list, never what TBD alerts on.
  - The toolbar's repo filter.
  - The pinned dock. A pinned registry row stays in it: pinning is a choice
    made row by row, and the filter does not overrule it.
  - The Hibernated group. With grouping on, a local lane files under
    Hibernated by looking at all of its descendants, hidden ones included, so
    a lane with a live hidden registry child stays in the working list.

**The count** is the number of hidden rows plus hidden loose sessions. A
session counts once, so a session and its row are one.

## The button

### Placement

The button sits on the repo header row, directly after the repo name and the
disclosure chevron, on whichever side of the name the chevron is set to draw:

- Chevron after the name: `name ▸ [filter] … [+]`
- Chevron before the name: `▸ name [filter] … [+]`

The missing badge and Locate…, when shown, follow the filter. The `+` stays
at the trailing edge.

The button is kept away from the `+` on purpose. A near miss on the `+` starts
a new worktree; a near miss between the filter and the chevron only folds the
repo or flips the filter, and one more click undoes either.

When a repo has the button, the header keeps its 20 pt square in the layout
whether or not the button is drawn. Hovering therefore never shifts the name
or cuts it shorter. A long name truncates by that square. While the filter is
on, the space also holds the count, sized for the largest count the button can
show – what the filter would hide with nothing selected – so a selection that
lowers the count never moves the name's cut point either.

### When it exists

The button exists while the filter would hide at least one row or session in
the repo, judged without the selection exception below. A repo with only
local rows, or only local and cloud rows, never shows it, and neither does a
repo whose only registry rows stay in view as ancestors of kept rows.
Selecting a hidden row never makes the button vanish under the pointer; the
count simply drops by the rows the selection brings back.

"Registry provider" here means any provider name other than `claude-cloud`,
not membership in the currently loaded provider list. That list is empty
until the app's first fetch and is cleared while remote backends are
unavailable, so judging by it would bring hidden rows back at every launch.

When the filter is on and nothing is left to hide, the button goes away and
the setting stays on. A registry session that arrives later is hidden at once,
and the button returns, tinted and counted, so the filter never acts unseen.

### States

- **Off:**
  - Drawn only while the pointer is over the repo's section – its header or
    any of its rows – which is when the `+` is drawn.
  - An outlined filter symbol.
  - Tooltip: "Hide <provider> sessions", naming the provider by its
    `RemoteProviderIdentityPresentation.headline`. When the repo has sessions
    from two or more registry providers: "Hide remote sessions except cloud".
- **On:**
  - Always drawn, in the accent colour, as a filled filter symbol with the
    count beside it.
  - Tooltip: "<count> <provider> sessions hidden. Click to show them.", with
    the same two-provider wording as above.

A click flips the state, and the list updates at once.

### Menu item

The repo header's context menu carries a "Hide <provider> Sessions" item,
checked while the filter is on, under the same existence rule as the button.
A control drawn only on hover is hard to reach by keyboard or VoiceOver; the
menu item is the path that does not depend on hover.

## Behaviour around the edges

- **The selected row stays in view.** Opening a hidden row on purpose – from a
  notification, a deep link, Back or Forward, or by creating a new registry
  session – shows that row and its ancestors while it is selected. Selecting
  anything else hides it again. A hidden session that needs input does not
  return on its own: only selection brings a row back.
- **Grouping on.** A Remote group holds only the rows the filter keeps, and its
  summary counts only those. A Remote group left empty does not render.
- **Grouping off.** Hidden rows leave the flat list, and the rest keep their
  stored order.
- **Drag to reorder.** A drag moves among the visible rows. The dropped row
  lands directly after the visible row above the drop point in the full
  sibling list. Hidden rows keep their order among themselves and never move
  as a side effect. A drop that leaves the visible order as it was moves
  nothing at all, so dropping a row back into its own gap cannot slip it past
  a hidden neighbour.
- **Folded or hidden repo.** No change: the filter acts only on rows the repo
  would otherwise show.
- **Repo removed.** Removing a repo from TBD removes its ID from the saved set,
  and so does every successful refresh of the repo list, which catches a repo
  removed from the CLI. A failed refresh prunes nothing.

## Design

### Storage

One `UserDefaults` key, `sidebarRegistryRemoteHiddenRepoIDs`, holds an array
of repo UUID strings. Absent and empty both mean no repo is filtered, which is
the shipped behaviour.

`AppState` owns the value as an observed property, loaded from and written to
`AppState.userDefaults`. Views read it through `AppState`, never through
`@AppStorage`, because views under the detail pagers read `@AppStorage` from
`.standard` rather than from the store `AppState` uses.

The setting is presentation only. The daemon never reads it, no RPC carries
it, and the CLI cannot see it. A database column on `repo` was considered and
rejected: it would cost a migration, a model change and an RPC for state that
no process outside the app consults.

### The rule in one place

A pure value type, `SidebarRegistryRemoteFilter`, decides everything the
filter does. Its inputs are a repo's worktree rows, its matched remote
sessions, the set of registry-provider names, and the selected row or session.
Its output is:

- the worktree IDs to hide
- the remote session IDs to hide
- the count
- the registry provider names present, for the tooltip and menu wording

Every surface – the tree builder, the per-parent remote groups, the header
model, the menu item and the drop policy – consumes that output. None of them
repeats the rule.

### Integration points

- **`AppState+SidebarGroups.swift`** – `sidebarRepositoryLayout`,
  `sidebarMatchedRemoteSessions(repoID:)` and
  `sidebarRemoteGroups(parentID:)` drop what the filter hides. Each cache those
  functions keep is cleared when the saved set or the selection changes.
- **`SidebarTreeBuilder`** – the repo header model gains the button's state:
  absent, off with a label, or on with a label and count.
- **`SectionHeaderCell`** – a third control laid out after the chevron, with its
  reserved square, and a new `SidebarHoverPart` case for its hover wash.
- **`SidebarMenus`** – the repo header item.
- **`SidebarDropPolicy`** – maps a drop between visible rows to an index in the
  full sibling list.

### Rollout

No feature flag. The default shows every row, nothing is hidden until the
person clicks, and the button appears only where there is something to hide.
That makes the change additive UI rather than a change to where existing rows
appear by default, which is the case the flag rule in `CLAUDE.md` covers.

No daemon change, no migration, and no new durable external resource. The
only state is the app setting, which the app prunes against the repo list.

## Testing

- **The filter**, as a pure function:
  - a registry row at the top level, under a local lane, and under another
    registry row is hidden
  - a loose registry session is hidden
  - exited registry rows and sessions are hidden
  - the main row, local rows, a landed lane with a registry origin, cloud rows
    and cloud sessions are kept
  - a local or cloud row under a registry row keeps that registry row and its
    ancestors in view
  - the selected row and its ancestors are kept
  - a session with a row counts once
- **The button's existence:** absent with no registry sessions, absent with only
  cloud sessions, present with one registry row, present with one loose
  registry session, and absent once the filter has nothing left to hide.
- **Wording:** one registry provider names it; two or more fall back to the
  generic text.
- **Storage:** a round trip through a `TestDefaultsSuite`, and removal of a
  repo's ID when the repo is removed.
- **Layouts:** the filter applied with grouping on (an emptied Remote group
  does not render; its summary counts kept rows only) and with grouping off.
- **Drop mapping:** a drop between two visible rows with hidden rows between
  them lands directly after the upper visible row, and the hidden rows keep
  their relative order.
- **Header layout:** the reserved square is present while the button is not
  drawn, and the title frame does not change when the button appears.
