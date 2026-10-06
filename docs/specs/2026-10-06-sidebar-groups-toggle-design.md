# Sidebar workflow groups toggle

## Problem

The workflow groups in
[`2026-09-16-workflow-sidebar-groups-design.md`](2026-09-16-workflow-sidebar-groups-design.md)
file remote and exited work under a collapsible Remote group and wholly
parked local work under a Hibernated group, each starting collapsed. For a
user who did not ask for that, rows they navigate by every day disappear
from the place they have always been, behind a header they have to find and
open. Nothing let them put the sidebar back, and a restart collapsed every
group they had opened.

The grouping is a reasonable choice for a large fleet, not a correction every
user wants. So it becomes an opt-in setting that ships off, and the groups a
user does open stay open.

## The setting

Settings → General carries a toggle, "Group hibernated, remote and exited
worktrees", directly beneath the sidebar's other layout toggles.

- **Off** – the sidebar renders exactly as it did before workflow groups
  existed. Within a repository: the main worktree, then every active or
  creating top-level row, local and remote, in its stored order, then the
  repository's unadopted remote sessions. Under a provider: its unmatched
  sessions, listed inline beneath its header. In Scratch: every pad. No group
  header renders, drag reorder moves the full sibling list, and selection
  reveals no group because none exists.
- **On** – the grouped sidebar the earlier spec describes, unchanged.

The flag lives entirely in the app, under the `UserDefaults` key
`sidebarWorkflowGroupsEnabled`. It changes presentation only, the daemon has
no part in it, and the same placement already serves `enableTranscript` and
the chevron-placement toggle. No `config` column is added.

### Three states, one default

The key has three states, and they must stay distinguishable:

- **Absent** – nobody has chosen. The setting resolves through one shipped
  constant, `AppState.sidebarWorkflowGroupsDefault`, which is `false`.
- **Explicit `false`** – the user turned grouping off.
- **Explicit `true`** – the user turned it on.

The toggle writes an explicit value only when flipped. Every reader resolves
the key the same way: `AppState.sidebarWorkflowGroupsEnabled(defaults:)`
reads `object(forKey:) as? Bool` and falls back to the constant, and each
`@AppStorage` that binds the key spells its default with that same constant,
never a literal. Reading through `bool(forKey:)` is forbidden because it
collapses "never chose" into `false`.

The point is graduation. A later change to the constant reaches exactly the
people who never touched the toggle and preserves every explicit choice,
including an explicit off. This is the app-side form of the rule `CLAUDE.md`
gives for `config` columns – add them with no SQL default so that unset stays
a third state. A tested resolver takes the shipped default as a parameter, so
the property is provable without editing the constant: absent follows either
default, and an explicit `false` holds against a default of `true`.

## Remembered expansion

With grouping on, the groups a user expands stay expanded across restarts.

- **Key** – each group is identified by its owner (a repository's UUID, a
  provider's name, or Scratch) and its kind (Remote, Exited, Hibernated),
  serialized as `<kind>|<owner type>|<owner value>`. The provider name comes
  last and is split off with a bounded split, so a separator inside a name
  round-trips. The expanded set is stored as a sorted string array under
  `sidebarExpandedGroups`.
- **Write** – every change to the expanded set rewrites the array. That
  includes the expansions selection reveal makes, so a group opened to show a
  selected row is still open after a restart, just as a group opened by hand
  is.
- **Read** – `AppState.init` restores the set from the store it was built
  with. An entry this build cannot parse is dropped rather than misread.
- **Bound** – entries are pruned when their owner disappears. After each
  successful repository fetch, groups owned by a repository the daemon no
  longer reports are removed; after each successful provider-roster fetch,
  groups owned by an unregistered provider are removed. Pruning runs only on
  those authoritative answers, never on a failed or refused fetch, so a
  daemon restart or a disabled remote backend forgets nothing. Every owner
  contributes at most three entries and only a gesture or a reveal adds one,
  so the set stays proportional to the repositories and providers the user
  has.

With grouping off nothing expands, so the stored set is left untouched, and
turning grouping back on restores it as the user left it.

## Rule change in CLAUDE.md

The flag rule in `CLAUDE.md` listed three kinds of change that must ship
default-off: autonomous behavior, destructive behavior, and wholesale
replacement of a load-bearing path. Workflow groups met none of them and
still disrupted daily use, because moving rows people already rely on is its
own kind of risk. The rule gains a fourth case – changing where existing
items appear by default, by moving, hiding, regrouping, or collapsing UI that
users already rely on – and its "small additive UI" exemption now states that
rearranging existing items is not additive.

## Graduation

The flag soaks off. Enable it for the soak from Settings → General, or with
`defaults write TBDApp sidebarWorkflowGroupsEnabled -bool true`. If the grouped
sidebar proves the better default, graduation is a one-line change to
`sidebarWorkflowGroupsDefault`, which moves everyone who never chose and
leaves every explicit choice alone. If it does not, the default stays off and
the toggle remains as a preference. The flag is not deleted while both
layouts have users who chose them.

## Verification

- The off branch renders every repository, provider, and Scratch row inline
  with no group headers, its reorder applies to the full sibling list, and
  selection reveal is a no-op.
- The on branch files remote, exited, and hibernated rows under their headers
  as before, and the existing reveal and shelf suites run with it on.
- The three states resolve as specified, including an explicit `false`
  against a shipped default of `true`.
- An expanded set survives constructing a fresh `AppState` over the same
  `UserDefaults` suite, unparsable entries are dropped, and pruning removes
  only groups whose owner vanished.
