# Panel Agent Surface — Approach C: Daemon-Owned Primary-Anchor Layout

**Date:** 2026-07-22

**Status:** Adopted — Phase 1 shipped in PR #478 (2026-07-22)

**Supersedes:**
`2026-07-20-panel-agent-surface-a-mirror-design.md` and
`2026-07-20-panel-agent-surface-b-daemon-owned-design.md`

## 1. Summary

TBD will expose side-panel layout to agents through a daemon-owned surface model.
Each workspace tab has exactly one non-removable **primary anchor** and zero or
more viewer panels arranged around it in a recursive split tree.

Terminals are never side-panel content. A terminal is primary content in its own
workspace tab. Creating a terminal creates a workspace tab; closing that tab
kills the terminal session. The panel API can neither create nor embed a
terminal, so layout navigation never has to decide whether replacing a view
should hide, orphan, or destroy a live session.

Viewer panels can show files (source or rendered), web pages, transcripts, and
notes. A viewer panel is a stable slot with back/forward history. Command-click
and agent `panel.open` operations reuse a suitable viewer panel when possible or
create a new panel beside the primary anchor. There are no pane-local tabs; the
history controls and their right-click jump menu provide lightweight switching
among recently viewed references.

The daemon is the sole durable authority. Agent operations work while the app is
closed and appear when the app next connects. The app may render user gestures
optimistically, but it never persists or resolves conflicts independently of the
daemon.

## 2. Goals and non-goals

### Goals

1. **See:** agents can inspect workspace tabs, viewer panels, split structure,
   ratios, and content references without reading rendered contents.
2. **Arrange:** agents can open, close, split, move, resize, and navigate viewer
   panels, and can select a workspace tab.
3. **Single durable authority:** tab surfaces remain correct whether or not the
   app is running.
4. **Safe resource semantics:** panel navigation cannot create, orphan, or kill
   terminal sessions.
5. **Stable rendering identity:** authoritative tree updates preserve unaffected
   SwiftUI/AppKit view state.
6. **Viewer history:** each viewer panel retains its last 10 references across
   app and daemon restarts.
7. **Future extensibility:** new renderable reference types and later view-state
   or annotation features can be added without changing ownership again.

### Non-goals for v1

- Arbitrary inline content supplied over RPC, such as raw HTML or Markdown
  strings. v1 opens durable references: files, URLs, notes, and transcripts.
- Reading rendered panel contents back through the panel API.
- Pane-local tabs.
- Terminal splits or terminal content in side panels.
- Agent control of the pinned-terminal dock or multi-worktree grid.
- Persisting ephemeral view details such as scroll position, selection, find
  state, or web navigation internals.
- Treating the local RPC boundary as a security sandbox. TBD already trusts
  processes running as the same macOS user; the agent-control flag establishes
  product consent, not hostile-process isolation.

## 3. Fixed product decisions

1. The daemon owns the durable surface; the app is a subscribed renderer.
2. Agent mutations are accepted while the app is closed.
3. Every workspace tab has exactly one primary anchor.
4. Terminals may only be workspace-tab primary content.
5. `tbd terminal create` creates a workspace tab, never a side panel.
6. Closing a terminal workspace tab kills that terminal session.
7. Closing a viewer panel removes only the view. Closing a note panel does not
   delete the note; `note.delete` remains explicit. Because deletion currently
   happens only via pane close, the same change must add an explicit
   delete-note affordance in the app, or notes become unremovable.
8. Transcript panels reference but do not own terminal sessions.
9. Viewer navigation uses back/forward history and the existing right-click jump
   menu design, not pane-local tabs.
10. Cross-worktree control uses the same API with an explicit `worktreeID` (CLI
    `--worktree`). It is uncommon but not artificially restricted.
11. Agent mutations ship behind a default-off daemon config flag. Read-only
    inspection is ungated.
12. The multi-worktree grid is presentation-only app state and is not part of
    the persisted or agent-visible panel surface.

## 4. Current state and why it must change

The app currently stores `layouts: [UUID: LayoutNode]` and persists it as a
UserDefaults JSON blob (`AppState.swift:401-403,878-887`). Tab labels, ordering,
and active selection are already daemon-persisted, but the `tab` table is sparse:
only tabs with label overrides have rows (`TabStore.swift:44-45`). Actual tab
existence is reconstructed app-side from terminals and notes.

`PaneContent` currently combines visual identity and resource identity. A
terminal's pane ID is its terminal ID; a note's pane ID is its note ID; viewer
cases carry separate generated IDs (`PaneContent.swift:5-20`). That prevents a
panel slot from retaining its identity independently of the content it displays.

`LayoutNode.split` has no split-node ID (`LayoutNode.swift:12-14`), and divider
commit finds a target split by comparing its complete child arrays
(`SplitLayoutView.swift:131-153`). The view also iterates children by array
offset (`SplitLayoutView.swift:82-108`). Those identities are not stable enough
for concurrent semantic operations or authoritative tree replacement.

The existing model also permits terminal leaves anywhere in the tree. Closing a
note pane deletes the underlying note, while removing a terminal pane leaves its
terminal alive and reconciliation can later recreate a tab for it
(`PanePlaceholder.swift:488-503`, `AppState.swift:1685-1748`). Exposing those
semantics to agents would make `panel.close` content-dependent and surprising.

Finally, the same `layouts` dictionary is keyed by tab ID in single-worktree mode
and worktree ID in the multi-worktree grid (`TerminalContainerView.swift:267-270,
570-577`). The latter path is not a real persisted tab layout and must be split
out before migration.

## 5. Domain model

The durable surface types and pure mutation logic live in `TBDShared`, with no
SwiftUI or daemon dependencies.

### 5.1 Stable identity types

Use distinct nominal wrappers (or documented UUID typealiases during the first
implementation) for:

- `WorkspaceTabID`
- `PanelID`
- `SplitID`
- `PanelOperationID`

Resource identifiers such as `TerminalID` and `NoteID` are never used as panel
or split identity.

### 5.2 Workspace tab and primary content

```swift
public struct WorkspaceTabSurface: Codable, Sendable, Equatable {
    public let id: UUID
    public let worktreeID: UUID
    public var label: String?
    public var primary: PrimaryContent
    public var layout: PanelLayoutNode
    public var revision: UInt64
}

public enum PrimaryContent: Codable, Sendable, Equatable {
    case terminal(terminalID: UUID)
    case note(noteID: UUID)
    case file(FileReference)
    case web(URL)
    case transcript(terminalID: UUID)
}
```

`PrimaryContent` includes all legacy top-level content so migration never has to
discard a viewer-only tab. The invariant is one-way: terminals are allowed only
as primary content; viewer content may be primary or auxiliary. Note that
`.transcript` as primary content is new surface — today transcripts exist only
as split panes; it is included so migration and future layouts never need a
special case, not as a committed UI feature.

The primary anchor in the tree does not duplicate `PrimaryContent`. It refers to
the workspace tab's primary rendering slot:

```swift
public indirect enum PanelLayoutNode: Codable, Sendable, Equatable {
    case primary
    case panel(PanelSlot)
    case split(SplitNode)
}
```

Every valid tree contains exactly one `.primary` node.

### 5.3 Viewer panels

```swift
public struct PanelSlot: Codable, Sendable, Equatable {
    public let id: UUID
    public var content: PanelContent
}

public enum PanelContent: Codable, Sendable, Equatable {
    case file(FileReference)
    case web(URL)
    case transcript(terminalID: UUID)
    case note(noteID: UUID)
}

public struct FileReference: Codable, Sendable, Equatable {
    public var path: String
    public var presentation: FilePresentation
}

public enum FilePresentation: String, Codable, Sendable {
    case automatic
    case source
    case rendered
}
```

For paths inside a worktree, the daemon stores a normalized worktree-relative
path. Absolute paths are retained when explicitly supplied and supported by the
existing viewer. `automatic` renders known renderable formats such as Markdown
and otherwise shows source. Switching source/rendered presentation is navigation
within the same panel; it does not create a new panel.

### 5.4 Split nodes

```swift
public struct SplitNode: Codable, Sendable, Equatable {
    public let id: UUID
    public var direction: SplitDirection
    public var children: [PanelLayoutNode]
    public var ratios: [Double]
}
```

The model remains n-ary for compatibility with the current layout. Ratios must
match child count, each child must meet the minimum share, and normalized ratios
must sum to approximately 1.0. Resize operations target `SplitID`; they never
identify a split through tree position or child equality.

### 5.5 Invariants

The shared validator and reducer enforce:

- exactly one primary anchor per workspace tab;
- globally unique panel IDs within a tab;
- globally unique split IDs within a tab;
- no empty or one-child split nodes after normalization;
- valid, normalized ratios;
- no terminal case in `PanelContent` or any panel-creation specification;
- referenced notes and transcripts belong to an allowed worktree/resource;
- close and move operations cannot target the primary anchor;
- a mutation either returns a fully valid tree or a typed error without change.

## 6. Viewer navigation and history

A viewer panel is a stable navigation slot. Navigating it changes
`PanelSlot.content` but preserves `PanelSlot.id`, so pane-owned view identity and
history remain stable.

```swift
public struct PanelHistory: Codable, Sendable, Equatable {
    public var entries: [PanelContent]
    public var cursor: Int
}
```

History rules (matching the MRU semantics shipped in PR #472 — a tab-like
most-recently-viewed list, not a browser stack; there is no forward-branch
truncation):

- retain at most 10 entries per panel; `entries[0]` is the most recently
  committed reference and `cursor` indexes the currently displayed entry;
- back moves the cursor toward older entries (cursor + 1), forward toward
  newer (cursor − 1), and jump sets it directly; none of these reorder the
  list, so the jump menu holds its order while the user flips through it;
- a normal navigation commits: the current entry moves to the front if not
  already there, any existing occurrence of the destination is removed (an
  entry moves rather than duplicates), the destination is inserted at the
  front, and the cursor resets to zero; navigating to the current entry is
  a no-op;
- the cap evicts the oldest (tail) entry, which is never the current entry
  because a commit moves the current entry to the front first;
- closing a panel deletes its history;
- a deleted note or terminal removes invalid note/transcript history entries;
- if current content becomes invalid, navigate to the nearest valid history
  entry or close the panel when none remains (this generalizes the transcript
  toggle-off restore behavior shipped in PR #472: dismissing a transcript from
  a reused slot restores the nearest non-transcript entry rather than
  destroying the panel);
- history stores reconstructable references, never rendered content or live
  view/controller state.

`entries[cursor]` is always equal to `PanelSlot.content`; a new panel starts with
one entry and cursor zero. The duplication lets layout queries summarize current
content without loading history, while the store transaction and validator keep
the two representations consistent.

The app presents the established back/forward controls at the leading edge of
the viewer header (fixed slots, per PR #472). Primary click steps through
history; right-click opens the jump menu — both buttons show the same full
list, newest first, with a checkmark on the current entry. This menu is
deliberately tab-like, but entries are navigation history, not independently
mounted tabs.

### 6.1 Default file-routing policy

Command-click in a terminal or viewer issues the same semantic `open` intent as
the CLI:

1. In the active workspace tab, prefer the most recently navigated viewer panel
   (the daemon can derive this durably from `panel_history.updated_at`), falling
   back to deterministic pre-order traversal.
2. If one exists, navigate that panel to the new reference and push history.
3. Otherwise split a new viewer panel to the right of the primary anchor at a
   default 35% share.
4. Never replace, embed, hide, or kill the primary terminal.

The most-recently-navigated preference supersedes the interim reuse order
shipped in PR #472 (prefer an existing code viewer, then any viewer-class
pane); it is a deliberate behavior change, not drift.

An explicit “Open to Side” placement always creates a new panel. An explicit
“Replace Panel” placement targets a particular `PanelID` and pushes its history.

## 7. Ownership and runtime architecture

### 7.1 Authority

The daemon is the only committed-state writer:

```text
 app gesture ── semantic operation ──┐
                                     ▼
 agent CLI ── semantic operation ──► PanelCoordinator actor
                                     │
                            shared pure reducer
                                     │
                              SQLite transaction
                                     │
                         snapshot/result + StateDelta
                              │                    │
                              ▼                    ▼
                           caller            subscribed app
```

The daemon owns:

- workspace-tab existence and ordering;
- primary-content association;
- active workspace tab;
- panel layout and revisions;
- viewer history;
- semantic validation and conflict resolution;
- cleanup when referenced notes or terminals disappear.

The app owns only presentation state such as hover, divider drag preview,
keyboard focus, scroll position, and temporary optimistic projections.

### 7.2 PanelCoordinator

A daemon `PanelCoordinator` actor serializes operations per worktree, applies the
shared reducer, persists the resulting surface and history in one database
transaction, and broadcasts only after commit. GRDB write serialization is not
a replacement for this domain boundary: the coordinator also orders validation,
resource reconciliation, result construction, and broadcasts.

Operations carry:

```swift
public struct PanelOperationEnvelope: Codable, Sendable {
    public let operationID: UUID
    public let worktreeID: UUID
    public let tabID: UUID
    public let baseRevision: UInt64?
    public let origin: PanelOperationOrigin
    public let operation: PanelOperation
}
```

`origin` supports feature gating and diagnostics (`appUser`, `agentCLI`,
`daemonReconcile`); it is not a security credential.

### 7.3 Semantic operations

```swift
public enum PanelOperation: Codable, Sendable {
    case open(content: PanelContentSpec, placement: PanelPlacement)
    case close(panelID: UUID)
    case move(panelID: UUID, placement: PanelPlacement)
    case resize(splitID: UUID, ratios: [Double])
    case navigate(panelID: UUID, destination: PanelContentSpec)
    case history(panelID: UUID, action: PanelHistoryAction)
    case selectTab(tabID: UUID)
}
```

`PanelPlacement` supports automatic reuse, replacement of a specific panel, and
insertion before/after/above/below the primary anchor or a specific panel. The
wire vocabulary uses user-facing edges; split direction is derived internally.

There is deliberately no terminal content specification and no generic
whole-tree `set` method exposed to clients.

### 7.4 Versions, idempotency, and conflicts

- Every successful mutation increments that tab's monotonic revision.
- `operationID` is unique and idempotent. The daemon persists a bounded recent
  operation record so reconnect/retry after a response loss cannot apply twice.
- `baseRevision` is advisory for semantic rebase, not an unconditional compare-
  and-swap gate.
- If the base is stale but all targets still exist, apply the operation to the
  current authoritative tree.
- If a target was removed or changed incompatibly, return a typed stale-target
  error and leave state unchanged.
- Duplicate operation IDs return the original committed result.
- State deltas and RPC results include revision and `operationID`, allowing the
  app to deduplicate the response/subscription race.

### 7.5 App optimistic projection

The app keeps:

```text
confirmed daemon snapshot + ordered pending user operations = rendered snapshot
```

For a user gesture, the app runs the shared reducer locally and renders the
projection immediately, then sends the operation. On an authoritative result or
delta it adopts the newer confirmed snapshot, removes the matching pending
operation, and reapplies any remaining pending operations. If a pending target
became invalid, the app drops that projection and presents a non-blocking error.

The app does not maintain an offline write queue. If the daemon is unavailable,
committed layout controls are temporarily disabled and the app shows its normal
connection failure UI. This preserves one authority and avoids a recovery-time
whole-tree overwrite.

### 7.6 Stable SwiftUI identity

Before switching authority, rendering must use stable IDs:

- split children are keyed by their `PanelID`/`SplitID` identity, never array
  offset;
- panel-owned state objects are keyed by `PanelID`;
- the primary renderer is keyed by workspace-tab identity and primary resource;
- an authoritative tree replacement with unchanged IDs must preserve unaffected
  terminal, file-watcher, webview, and transcript view identity.

This makes normal SwiftUI reconciliation the diff engine. There is no separate
hand-written view-tree “diff apply” protocol.

## 8. Persistence

The daemon needs first-class rows for every workspace tab; the existing sparse
`tab` metadata table cannot represent the authoritative aggregate.

Illustrative schema (exact migration number chosen at implementation time):

```sql
CREATE TABLE workspace_tab_surface (
    id              TEXT PRIMARY KEY,
    worktree_id     TEXT NOT NULL,
    primary_content TEXT NOT NULL,  -- PrimaryContent JSON
    label           TEXT,
    position        INTEGER NOT NULL,
    layout          TEXT NOT NULL,  -- PanelLayoutNode JSON
    revision        INTEGER NOT NULL DEFAULT 0,
    updated_at      DATETIME NOT NULL
);
CREATE INDEX idx_workspace_tab_surface_worktree
    ON workspace_tab_surface(worktree_id, position);

CREATE TABLE panel_history (
    panel_id   TEXT PRIMARY KEY,
    tab_id     TEXT NOT NULL,
    history    TEXT NOT NULL,       -- PanelHistory JSON
    updated_at DATETIME NOT NULL
);
CREATE INDEX idx_panel_history_tab ON panel_history(tab_id);

CREATE TABLE panel_operation_receipt (
    operation_id TEXT PRIMARY KEY,
    worktree_id  TEXT NOT NULL,
    tab_id       TEXT NOT NULL,
    revision     INTEGER NOT NULL,
    result       TEXT NOT NULL,
    applied_at   DATETIME NOT NULL
);
```

The store writes layout, affected history, ordering, active-tab changes, and
operation receipt atomically. Old receipts are pruned by count/age; they are not
an event-sourcing log. The current snapshot remains the authority.

Per the repository migration rule, the schema migration, GRDB record/store
types, and backward-compatible `TBDShared` Codable models land together. Existing
migrations are never modified.

## 9. Resource lifecycle reconciliation

Panel operations have no terminal-creation or terminal-destruction side effects.
Terminal lifecycle remains a workspace-tab concern:

- terminal creation creates a terminal record and its primary workspace tab as
  one coordinated daemon workflow;
- closing a terminal workspace tab kills its tmux session, deletes the terminal
  record, deletes the complete tab surface/history, updates ordering/selection,
  and broadcasts the committed result;
- external terminal death performs the same durable surface cleanup;
- closing a file, web, transcript, or note panel only removes that panel;
- deleting a note explicitly removes primary tabs and panel/history references
  to that note;
- deleting a terminal prunes transcript panels and transcript history entries
  that reference it across the worktree;
- the pinned-terminal dock is a separate presentation of the terminal resource;
  deleting the terminal removes it from the dock through existing terminal
  lifecycle state, not through panel layout.

Terminal-tab close is a recoverable daemon workflow, not one database
transaction pretending it can atomically include tmux:

1. Validate the tab and durably mark its terminal as closing.
2. In the same database transaction, remove the tab surface and dependent
   transcript panels/history, update order/selection, and record the operation.
3. Broadcast the committed surface, then kill the tmux resource.
4. Delete/finalize the closing terminal record after the kill attempt.
5. On daemon startup, finish any terminal records left in the closing state.

Thus the UI and surface stop referencing the session immediately, and a daemon
crash between layout commit and tmux cleanup cannot leave a permanent orphan.

Closing a non-terminal primary tab removes that tab presentation but does not
delete its note or other referenced resource. Reopening such a resource is an
explicit note/file action; reconciliation never recreates a closed tab merely
because its resource still exists.

This replaces the current app-side rule that infers a new tab for every terminal
not found in a layout. Placement is explicit daemon state, so there are no
“unrepresented” live terminals to rediscover.

## 10. RPC, deltas, and CLI

### 10.1 RPC

Add a small surface rather than one method per layout verb:

- `panel.get` — authoritative surface for one worktree or tab.
- `panel.apply` — one `PanelOperationEnvelope`; returns the committed affected
  tab/worktree snapshot.

`StateDelta.panelSurfaceChanged` carries `worktreeID`, affected tab snapshots,
removed tab IDs, active tab ID, revision metadata, and originating operation ID.
The full affected tab snapshot is preferred over structural wire diffs: trees
are small, IDs are stable, and full payloads are self-healing.

Read results are authoritative even when the app is closed. They do not need
`appConnected` or `stalenessSeconds`. App presence may later be exposed for
attention/focus features, but it is not part of layout correctness.

### 10.2 Agent feature gate

`config.agent_panel_control_enabled` is added default-off. `panel.apply` rejects
`origin: agentCLI` while off and names the setting in its typed error. App-user
operations and daemon reconciliation are unaffected. `panel.get` is ungated.

The origin field and local socket are not treated as an adversarial security
boundary. This is consistent with the rest of TBD's same-user CLI surface and
avoids capability/token complexity that does not match the product threat model.

### 10.3 CLI

```text
tbd panel list [--worktree <id|name>] [--tab <id>] [--json]

tbd panel open <file|url|note|transcript>
    [--worktree <id|name>] [--tab <id>]
    [--automatic|--source|--rendered]
    [--replace <panel-id>]
    [--target primary|<panel-id>] [--left|--right|--above|--below]

tbd panel close <panel-id> [--worktree <id|name>]
tbd panel move <panel-id> --target primary|<panel-id>
    --left|--right|--above|--below [--worktree <id|name>]
tbd panel resize <split-id> --ratios <r1,r2,...> [--worktree <id|name>]
tbd panel select-tab <tab-id> [--worktree <id|name>]
```

When `--worktree` is absent, the CLI uses `TBD_WORKTREE_ID`, then cwd resolution.
An explicit override is accepted normally. IDs accept full UUIDs or an
unambiguous prefix emitted by `panel list`.

`panel open` defaults to the automatic routing policy in §6.1. Its file argument
is resolved relative to the selected worktree root, not the CLI process cwd,
unless an explicit absolute path is supplied. Mutating commands print the
committed post-operation tree so an agent gets read-after-write confirmation
without a second call.

The CLI intentionally has no terminal panel syntax. Attempts such as
`--content terminal` fail during argument parsing rather than becoming daemon
operations.

### 10.4 Agent skill guidance

The bundled skill should teach intent before syntax:

- inspect before rearranging;
- use `panel open` and automatic reuse for ordinary file presentation;
- create a new side only when simultaneous comparison is useful;
- do not exceed a small number of panels without user direction;
- viewer panels never contain or control terminal sessions;
- use `tbd terminal create` for another terminal workspace tab;
- `--worktree` may target another worktree when the task calls for it;
- panel changes persist even if the app is currently closed.

Exact examples are generated from the implemented CLI help during the plan so
the skill does not document flags that do not exist.

## 11. Migration from current layouts

Migration must preserve every live terminal and as much viewer arrangement as
possible.

### 11.1 Prerequisite cleanup

1. Move the layout model and reducer to `TBDShared`.
2. Separate the multi-worktree grid's `layouts[worktreeID]` storage from real
   tab layouts; grid state remains app-local and is not imported.
3. Introduce stable panel IDs separate from content/resource IDs.
4. Introduce stable split IDs during decode when absent.
5. Render split children by stable identity.
6. Route all current app mutations through semantic reducer functions before
   changing persistence ownership.

### 11.2 One-time UserDefaults import

Only the app can reliably read its UserDefaults domain. With daemon-surface mode
enabled, it fetches the daemon surface first. For worktrees/tabs with no imported
surface, it decodes the legacy blob and submits a dedicated internal import RPC.
The import is create-if-absent and cannot overwrite an existing daemon surface.

For each legacy tab:

1. Use `Tab.content` as `PrimaryContent` and create one `.primary` anchor.
2. Find the legacy leaf corresponding to that primary resource and replace it
   with the primary anchor.
3. Convert non-terminal legacy leaves to viewer panels with new stable panel
   IDs while preserving paths, URLs, notes, transcripts, split direction, and
   ratios where valid.
4. For every additional terminal leaf, create a separate primary terminal
   workspace tab. Never kill or discard it.
5. Remove now-empty branches and normalize ratios.
6. Generate stable IDs for every surviving split.
7. Preserve existing label/order/active-tab metadata; promoted terminal tabs are
   inserted immediately after their source tab in traversal order.
8. Validate the result before committing anything for that worktree.

Per-panel histories persisted by PR #472 (the `com.tbd.app.paneHistories`
UserDefaults blob) are imported in the same pass: entries are re-keyed to the
new stable panel ID of each surviving converted panel, entries referencing
discarded panes are dropped, and imported histories are validated by the same
well-formedness rules as live ones.

The legacy UserDefaults keys (layouts and histories) remain untouched for one
rollback release. Import status is recorded daemon-side; an empty legitimate
layout is distinguishable from “not imported.”

### 11.3 Shadow comparison, not Approach A command routing

Before authority flips, the app may dual-write imported semantic results to an
inert daemon store and compare normalized snapshots for diagnostics. It must not
implement Approach A's broadcast-command/parked-ACK protocol. Shadow writes are
a migration validation tool only; agent mutation remains disabled until the
daemon path becomes authoritative.

## 12. Rollout

Two default-off daemon flags separate ownership risk from autonomous agent use:

1. `daemon_panel_surface_enabled` — controls import and daemon ownership.
2. `agent_panel_control_enabled` — controls agent-originated mutations and
   requires daemon surface ownership.

Suggested sequence:

1. Land shared IDs, model, validator, reducer, and property tests.
2. Land renderer identity fixes and remove terminal-split creation from UI.
3. Land schema/store/coordinator and import code inert behind flag 1.
4. Run shadow import/compare against real layouts; fix every divergence.
5. Enable daemon ownership for developer dogfood; keep agent mutation off.
6. Migrate terminal creation/deletion and tab reconciliation to explicit surface
   ownership.
7. Land read-only `panel list` and viewer history UI.
8. Land CLI mutation commands behind flag 2 and update the bundled skill.
9. Soak app-user operations before actively dogfooding agent arrangement.
10. Graduate flags independently using new migrations for defaults/forced
    updates as required by repository policy; remove the legacy UserDefaults
    import only after a rollback release.

Divider unification may land independently before or after these phases. It uses
the same deferred-commit behavior for layout dividers but is not a prerequisite
for ownership.

## 13. Testing

### Shared model and reducer

- decode legacy terminal/pane/split JSON;
- generate stable IDs during migration;
- exactly-one-primary validation;
- reject terminal panel specifications;
- split/close/move/resize/navigate/history semantics;
- stale-target errors;
- ratio normalization and minimums;
- history cap with tail eviction (never the current entry), MRU commit
  reordering, dedupe-by-move, cursor traversal without reordering, and
  invalid-reference cleanup;
- property tests over arbitrary valid operation sequences: the output remains
  valid, contains one primary, and never contains a terminal panel.

### Daemon/store

- migration and import create-if-absent behavior;
- atomic snapshot/history/order/receipt writes;
- monotonic revision and duplicate-operation replay;
- stale-base semantic application versus stale-target rejection;
- agent flag on/off branches;
- mutations while no app subscriber exists;
- terminal/note deletion reconciliation across primary tabs, panels, and
  history;
- terminal creation always produces a primary workspace tab;
- worktree archive/delete cleans all new rows.

### App

- confirmed-plus-pending optimistic projection;
- response/delta deduplication by operation ID;
- authoritative rebase with pending operations;
- failed pending operation rollback and user feedback;
- stable view identity when unrelated panels move, resize, open, or close;
- command-click automatic reuse and no-viewer fallback split;
- back/forward/right-click jump behavior;
- multi-worktree grid state never enters daemon persistence;
- daemon-disconnected layout controls do not accumulate offline writes.

### Migration fixtures

- one terminal only;
- terminal plus code viewer;
- nested mixed viewer splits;
- multiple terminal leaves (all promoted, none killed);
- note primary with viewer panels;
- viewer-only legacy primary;
- transcript referencing primary and non-primary terminals;
- malformed ratios and missing legacy resources;
- active/order/label preservation;
- rollback leaves the UserDefaults blob readable.

### CLI/RPC

- default worktree from `TBD_WORKTREE_ID` and cwd fallback;
- explicit cross-worktree override;
- UUID-prefix ambiguity errors;
- file path normalization relative to target worktree;
- read-after-write result matches persisted snapshot;
- terminal content rejected before mutation;
- app-closed list/open/close/move/resize/select-tab flow.

All integration tests follow the repository's `TBD_HOME` isolation rules and
must never touch the developer's live `~/tbd` state.

## 14. Risks and mitigations

### First-class tab ownership is a broad migration

Today tabs are partially inferred app state. Making them authoritative touches
terminal creation, notes, ordering, selection, close, restore, and worktree
cleanup. Mitigate with semantic centralization first, create-if-absent import,
shadow comparison, two flags, and a rollback release.

### SwiftUI identity regressions can disrupt live viewers

Stable IDs in the data model are insufficient if the renderer still keys by
offset or reconstructs controllers under changing structural identity. Treat
identity tests and live terminal/file/web verification as an ownership-flip
gate, not polish.

### Promoting legacy split terminals changes presentation

The no-terminal-panel invariant necessarily turns old split terminals into
workspace tabs. The sessions survive, ordering is deterministic, and the import
should show a one-time explanatory toast or release note rather than silently
appearing as a random rearrangement.

### Automatic viewer reuse may surprise users

Use the most recently active compatible viewer and preserve history, so the
previous destination is one Back click away. “Open to Side” remains explicit
when simultaneous visibility matters. Dogfood the reuse policy separately from
daemon ownership.

### App-closed mutations can change the next launch

This is intentional. RPC results are authoritative, operations are idempotent,
and the next app connection loads the committed surface. The CLI and skill must
state that panel changes persist even while the app is closed.

## 15. Future work

- raw/scratch rendered content with a durable content-addressing scheme;
- view-state mirrors such as visible file range and scroll position;
- user annotations keyed by panel content reference;
- richer placement intents (“beside my terminal”, “reuse the plan panel”);
- reopen-closed-panel history, distinct from per-panel navigation history;
- saved workspace layout templates;
- agent inspection of navigation history if a concrete use case emerges;
- explicit tuck-away/archive workflows for non-terminal primary content;
- panel control for other presentation surfaces only if they acquire a durable
  product model (the pinned dock and multi-worktree grid remain out of scope).

## 16. Acceptance criteria

The design is complete when all of the following hold:

1. An agent can inspect and mutate viewer panels with the app closed.
2. Reopening the app renders exactly the daemon's committed surface.
3. No panel operation can create, embed, replace, close, or orphan a terminal
   session.
4. Creating a terminal creates a primary workspace tab; closing that tab kills
   the terminal.
5. Command-click never replaces a terminal and either reuses viewer history or
   creates a viewer panel.
6. Every tab layout always contains exactly one primary anchor.
7. Unaffected live views retain identity across authoritative updates.
8. Existing split terminal sessions survive migration as separate tabs.
9. Viewer history survives restart and its right-click menu replaces the need
   for pane-local tabs.
10. The legacy UserDefaults blob is no longer an active writer after authority
    flips, and no competing app-owned mirror protocol remains.
