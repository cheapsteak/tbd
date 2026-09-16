# Workflow groups in the sidebar

## Purpose

Keep a small working list useful when a repository has many remote workers
and parked local sessions. Local and remote work retain the same repository,
parent, name, selection, and pin semantics. Disclosures control how much of
that work occupies the sidebar.

The design uses three groups:

- **Remote** – a collapsed group at each parent's child list, with a
  repository-level group for remote roots. Its header summarizes process
  state and attention without opening a terminal connection.
- **Exited** – a collapsed group inside its Remote group for confirmed exited
  sessions whose subtrees contain no continuing work.
- **Hibernated** – a collapsed group inside each repository for fully parked
  local subtrees. The pinned dock stays available.

These are presentation choices. Moving a row between groups does not archive,
dismiss, stop, wake, reparent, delete, or create a session.

## What the sidebar represents

A remote session can have an adopted `Worktree` row or only a
`RemoteSessionInfo` mirror row. Adopted rows already participate in the normal
tree. Grouping must include them, not just the session rows appended by
`RepoSectionView.matchedRemoteSessions`.

Join those representations on `(provider, sessionID)`. Preserve existing
deduplication, archive, dismissal, hidden-repository, and repository-filter
rules. The Provider Desk remains the inventory and health surface for each
provider; unmatched sessions keep their provider context.

Worktree filing, process liveness, agent attention, and provider freshness are
independent facts. An active worktree may represent an exited process.
`Terminal.isParked` describes a local terminal; it does not make a remote
session hibernated.

## Remote groups

For each sibling list, keep local rows in their existing order and place its
remote roots in a Remote disclosure after them. A remote child stays under
its owning parent. Rendering a grouped root renders its existing subtree;
no stored parent or sort order changes. Local descendants of remote parents
remain attached to those parents.

The repository-level Remote group also includes eligible mirror rows that
have no adopted worktree row. Unmatched sessions use the same presentation
under their provider. Empty groups render nothing. A single remote row still
gets a group, so the hierarchy does not change when another worker starts.

A header can read `Remote · 3 running · 2 exited`. Count each provider/session
identity once within that group's subtree. Running means a fresh provider
process state of `.running`, not an agent state of `.working`. Show starting,
unknown, or no-longer-reported counts when present; do not force them into
running or exited. A missing mirror entry is unknown. Stale provider data
must not claim current liveness.

Keep the existing attention vocabulary. A collapsed group retains its
highest-priority unread or waiting-input indication, and it indicates unknown
or stale state. Reading or expanding a group does not clear a child's unread
state. Ordinary row selection retains the existing acknowledgment behavior.

## Exited groups and available actions

Place a remote root in Exited only when its process is positively reported
exited by a fresh provider snapshot and every visible descendant is also a
confirmed exited remote. A local, starting, running, unknown, stale, or gone
descendant keeps that subtree in the outer Remote group. An exited parent
must never conceal continuing or uncertain work behind an Exited label.

Exited rows remain selectable. Preserve their capability-aware actions:
View log when supported, Archive where the existing lifecycle allows it,
and Dismiss where the existing session-row menu offers it. Grouping does not
invent a resume capability or broaden destructive actions. Unarchive changes
filing and does not promise to restart a process. Structured transcript
viewing requires its own working provider and UI path; a log is not a
transcript.

Rows that are gone remain distinct from exited rows. The Provider Desk
continues to expose the complete nondismissed inventory, including archived
sessions, according to its existing rules.

## Fully parked local work

The Hibernated shelf moves whole top-level local subtrees, preserving their
indentation and ownership. A row qualifies only when all of these are true:

- It is an ordinary active local worktree, not a main, creating, archived,
  remote, or special supervision row.
- Its terminal inventory has loaded successfully and contains at least one
  terminal.
- Every terminal satisfies `Terminal.isParked`. One awake terminal, including
  a shell, keeps the row in the working list.
- Every visible descendant satisfies the same conditions.

Missing or uncertain terminal data keeps the subtree in place. An empty
terminal array is not evidence of hibernation. A cycle, missing parent-chain
data, or traversal-limit violation also keeps affected work in place rather
than guessing that it is safe to hide.

A parked child of an awake parent stays under that parent. The initial shelf
does not extract nested children into a flat repository list. A parked parent
with an awake, remote, creating, or unknown descendant stays in the working
list with its children. Cross-repository children retain the existing owner's
section and repository suffix.

`Hibernated (N)` counts the parked worktree rows represented by the shelf,
including descendants, not terminals. Pinning does not change membership:
the existing dock keeps its shortcut even when the row is shelved. Selecting
a shelved row reveals its shelf, using the same navigation rule as remote
groups. Shelf classification and reveal do not themselves wake a terminal;
selecting a row retains the existing focus-wake rules, including the exception
for manually parked sessions.

Waking a terminal returns its subtree through the same projection. The shelf
does not itself invoke wake; existing explicit row gestures retain their
meaning. Terminal loading evidence comes from the app's existing state; this
design adds no freshness model.

## Disclosure, navigation, and attachment

Remote, Exited, and Hibernated groups begin collapsed. Store expansion in
app-owned transient state keyed by repository, owning parent, group kind,
and provider where needed. Recomputing a view or polling does not reset it.
An application restart may return groups to their collapsed defaults.

An explicit navigation to a row reveals its repository and every containing
group before the existing scroll request runs. Apply this to keyboard
navigation, history, deep links, and dock selection. A selected row that
changes process state remains visible; its new containing group opens if
needed. The user may then collapse that group deliberately without closing
the selected detail pane. Do not reopen it on every poll.

Disclosure headers are buttons with accessible expanded state and count
labels. They are not selectable worktrees, drag targets, or terminal hosts.
Expanding any group performs no attach, wake, provider mutation, or network
request beyond the app's existing inventory refreshes.

Inspection and attachment are separate intentions. Ordinary selection and
View Log must not establish a first attachment. An unattached session opens
Log when supported; otherwise it shows `Not attached` with an explicit Attach
button when the provider supports attachment. A provider without either
capability retains its existing explanatory empty state.

`showRemoteSessionSurface` changes attachment recency and clears detached
state only for an explicit `.attach` request. The attach-lifecycle projection
protects the selected session only when it already has recorded attachment
intent in the existing bounded recency set. Rendering a row, expanding a
group, selecting an unvisited worker, and requesting its log add no intent.

Preserve warm connections, explicit Reattach, and existing recovery of an
attachment already requested. A previously attached session still recorded
in the bounded recency set may reconnect when selected after eviction; that
is reuse of prior intent. This change does not require an Attach click on
every return. An explicitly detached session remains detached on ordinary
selection until the user requests attachment again.

Deliver this selection change in a separate app-only PR, with tests for
ordinary selection, View Log, history, dock navigation, explicit attachment,
detachment, warm reuse, eviction, and reconnect. Grouping never mounts hidden
remote detail views.

## Ordering and implementation boundary

Project existing state through small pure helpers in the app. Keep daemon
models, provider contracts, and lifecycle operations unchanged. This is an
additive sidebar presentation change, with no new timer, background action,
durable external resource, or feature flag.

Reuse the existing row views, tags, context menus, and pinned dock. Resolve
group membership from stable identities, not names or captured terminal text.
Build traversal indexes once per projection rather than rescanning the full
fleet for every row. Preserve the existing recursion bound.

Filtered row offsets cannot be passed to the full sibling reorder API.
Translate a displayed move through stable IDs: reorder only the displayed
subset within its existing slots in the complete sibling order, preserving
the relative order and positions of hidden siblings. Apply the same rule to
local, remote, and hibernated subsets. Do not offer cross-group dragging as an
implicit archive, wake, or reparent action. If safe translation is not yet
implemented for a subset, disable its drag gesture explicitly.

## Alternatives

- **Global Hibernated group** – shorter to scan across repositories, but loses
  the project context needed to choose which work to resume. A separate
  Hibernated view adds a navigation step for the same reason.
- **One remote group per repository** – a useful first delivery for remote
  roots, but extracting nested workers would obscure which parent owns them.
  Provider-only grouping likewise separates workers from their local peers.
- **Exited rows beside running rows** – makes completion easy to notice but
  preserves the clutter. A separate history view would make occasional
  inspection more distant. Nested Exited groups retain both access and context.

## Verification and delivery

Test pure membership, counts, ordering, and reveal decisions before wiring
views. Cover adopted/mirror deduplication, every process state, stale snapshots,
mixed-location descendants, empty and unloaded terminal inventories, all-parked
versus mixed terminals, pins, selection, cross-repository children, cycles,
and filtered reorder indices. Assert that disclosure changes do not select
rows, clear unread state, invoke lifecycle actions, or start attachments.

Exercise populated and empty repositories, narrow sidebars, keyboard
disclosures, deep-link reveal, pinning, state transitions, and menus in the
rendered app. Verify the fixed dock remains available and the selected pane
does not disconnect when its sidebar group closes.

Deliver remote roots and their Exited group first, then nested remote groups
and the conservative Hibernated shelf in small reviewable changes. Separate
inspection from first attachment in its own PR. Each PR states exactly which
level it covers. Build with `scripts/swift-safe build`,
run focused app tests through `scripts/test.sh`, and run broader checks as
required by the touched files. No merge or installation is part of this
design.

Intermittent missing terminal output is a separate rendering investigation.
This spec neither claims a reproduction nor changes terminal transport,
SwiftTerm rendering, or the installed renderer configuration.
