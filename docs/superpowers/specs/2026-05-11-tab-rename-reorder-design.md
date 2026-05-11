# Tab Rename & Reorder

Date: 2026-05-11

## Summary

Let users rename tabs in the main content panel's tab strip (double-click or right-click → Rename) and reorder them by drag. Both changes persist across app restart via the daemon's SQLite DB.

## Background

Today the tab strip in `Sources/TBDApp/TabBar.swift` shows auto-derived labels:

- Claude terminals: `"<ProfileName> <N>"` based on position among same-profile terminals
- Codex / shell terminals: `"Terminal <N>"`
- Notes: the note's `title`
- Webviews: URL host
- Code-viewers: file basename
- Live transcripts: `"Transcript"`

`Tab.label: String?` already exists in `Sources/TBDApp/Terminal/PaneContent.swift` and falls through to the auto-derived label when nil. Tab labels and ordering are kept only in `AppState.tabs: [UUID: [Tab]]` — entirely in-memory, lost on app restart. Note tabs additionally have their `label` overwritten from the note's `title` (`AppState+Notes.swift` line 33).

## Goals

- Users can rename any tab except code-viewer tabs.
- Users can drag tabs left/right within a worktree's tab strip to reorder.
- Both rename and reorder survive app restart.
- New tabs (created from a fresh terminal, note, etc.) still appear at the end of the strip; user-set order is preserved for everything else.
- Note tab labels decouple from note titles (the tab gets its own label; the note keeps its own title).

## Non-goals

- Renaming code-viewer tabs (they always show the file basename).
- Dragging tabs between worktrees, or detaching a tab into a new window.
- Reordering the `+` (new-tab) and history buttons in the tab strip.
- Live-syncing tab metadata between multiple TBDApp instances.

## Active-tab focus persistence (scoped in)

Today `AppState.activeTabIndices: [UUID: Int]` stores which tab is focused in each worktree, but it's in-memory only and resets on app launch. With reorder support landing, we also persist the active tab so a user's exact workspace state survives restart.

**Schema:** add `activeTabID: TEXT` (nullable) on the `worktree` table — same migration is fine, but since v19 is already shipped, this uses a new migration `v20_worktree_active_tab`. We store the `Tab.id` UUID (not a positional index) so the value stays correct across reorders.

**RPC:** new method `worktree.setActiveTab` with params `{ worktreeID: UUID, tabID: UUID? }`. nil clears the stored value (e.g., on close of the last tab).

**App-side wiring:** `tab.list` response gains an `activeTabID: UUID?` field. On worktree first appearance, after `loadTabStates` hydrates `worktreeTabOrders`, also resolve `activeTabID` → set `activeTabIndices[worktreeID]` to the matching position. When the user clicks a different tab, write through to the daemon (fire-and-forget). Persisted active tab gracefully degrades: if the stored `activeTabID` no longer exists in the worktree's reconciled tabs, fall back to index 0.

## Reference: iTerm2

iTerm2 has a `titleOverride: NSString?` on `PTYTab` (saved in arrangements, reverts to auto-derived when nil) — that's the same pattern as our `Tab.label: String?`. iTerm2 has no inline rename UI; titles come from escape sequences or scripts/API. Tab order in iTerm2 is encoded as the natural NSArray order in `TERMINAL_ARRANGEMENT_TABS` (no separate sort-order field). Drag is implemented in `PSMTabBarControl`, a custom `NSView` that hooks `-[NSTabView moveTabViewItem:toIndex:]`. Layout (splits) is a recursive plist dict on the tab — they don't normalize splits into a separate store. Persistence is lazy: arrangements only write on explicit save events, not per-change.

We borrow: `titleOverride` semantics, array-order persistence, lazy writes. We diverge: SwiftUI `.draggable` instead of `PSMTabBarControl`; SQLite-backed daemon instead of `NSUserDefaults` arrangements.

## Architecture

### Storage

A new sparse `tabs` table — a row exists only when a tab has user-set metadata (a custom label). Tab *order* is stored as a single JSON array on the existing `worktrees` row.

Migration (next sequential `vN+1.swift` in `Sources/TBDDaemon/Database/`):

```sql
CREATE TABLE tabs (
    id          TEXT PRIMARY KEY,        -- == Tab.id (UUID)
    worktree_id TEXT NOT NULL,
    label       TEXT,                    -- NULL = use auto-derived
    created_at  REAL NOT NULL
);
ALTER TABLE worktrees ADD COLUMN tab_order TEXT NOT NULL DEFAULT '[]';
```

`tab_order` holds a JSON array of UUID strings, e.g. `["e3a1...","9c44...",...]`. Unknown IDs are tolerated (sorted to the end on reconcile).

Layouts (splits within a tab) stay in `UserDefaults` under `com.tbd.app.layouts`. This change does not touch layout persistence.

### Shared model

`Sources/TBDShared/Models.swift` gains:

```swift
public struct TabState: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var worktreeID: UUID
    public var label: String?
    public var createdAt: Date

    public init(id: UUID, worktreeID: UUID, label: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.label = label
        self.createdAt = createdAt
    }
}

public struct TabDragPayload: Codable, Sendable, Transferable {
    public let tabID: UUID
    // Transferable conformance with UTType "com.tbd.app.tab-drag"
}
```

All fields have defaults or are optional so older JSON decodes cleanly (per project DB rule in `CLAUDE.md`).

### RPC surface

New methods in `Sources/TBDShared/RPCProtocol.swift`:

```swift
public static let tabSetLabel = "tab.setLabel"
public static let tabSetOrder = "tab.setOrder"
public static let tabList     = "tab.list"
```

Request shapes:

```swift
public struct TabSetLabelRequest: Codable, Sendable {
    public let tabID: UUID
    public let worktreeID: UUID
    public let label: String?  // nil = clear override (delete row)
}

public struct TabSetOrderRequest: Codable, Sendable {
    public let worktreeID: UUID
    public let tabIDs: [UUID]
}

public struct TabListRequest: Codable, Sendable {
    public let worktreeID: UUID
}

public struct TabListResponse: Codable, Sendable {
    public let tabs: [TabState]   // only tabs with overrides; empty when none
    public let order: [UUID]      // contents of worktrees.tab_order; [] if never reordered
}
```

`tab.list` is called once per worktree on first appearance in `AppState.tabs[worktreeID]` and seeds the in-memory caches.

### Daemon

In `Sources/TBDDaemon/Database/`:

- `TabRow` GRDB record matching the `tabs` table.
- `WorktreeRow` gains `tabOrder: String` (default `"[]"`).
- `Database.setTabLabel(tabID:worktreeID:label:)`:
  - If `label == nil` → `DELETE FROM tabs WHERE id = ?`.
  - Else → `INSERT OR REPLACE INTO tabs(id, worktree_id, label, created_at) VALUES (?,?,?,?)`.
- `Database.getTabsByWorktree(worktreeID:)` → `[TabRow]`.
- `Database.setTabOrder(worktreeID:tabIDs:)` → JSON-encode and update `worktrees.tab_order`.
- `Database.getTabOrder(worktreeID:)` → JSON-decode `worktrees.tab_order` into `[UUID]`.

In the RPC handler:

- Decode requests, call the DB methods, return success/response.
- Validation for `tab.setOrder`: reject if `tabIDs` contains duplicates. We do **not** require the list to exactly match the current set of tabs (tabs come and go; tolerated drift is preferable to spurious rejections).

Cleanup hooks (in the existing terminal- and note-delete code paths):

- On `terminal.delete` (or whichever path removes a terminal): `DELETE FROM tabs WHERE id = ?` with the terminal's UUID.
- On `note.delete`: same with the note's UUID.

No subscription/push for tab metadata — only one TBDApp instance writes, and reads happen on launch or worktree selection.

### App-side: AppState

New file `Sources/TBDApp/AppState+Tabs.swift`:

```swift
@Published var worktreeTabOrders: [UUID: [UUID]] = [:]
@Published var draggingTabID: UUID? = nil

func loadTabStates(worktreeID: UUID) async
func renameTab(tabID: UUID, worktreeID: UUID, newLabel: String) async
func reorderTab(draggedID: UUID, in worktreeID: UUID,
                relativeTo targetID: UUID, edge: DropEdge)
```

`renameTab`:

1. Trim whitespace from `newLabel`.
2. Resolve the currently displayed label (custom if set, else auto-derived from `tabLabel` logic).
3. If trimmed text equals the currently displayed label → no-op (no RPC).
4. If trimmed is empty → set `tab.label = nil` in `tabs[worktreeID]` and call `daemonClient.setTabLabel(..., label: nil)`.
5. Else → set `tab.label = trimmed` and call `daemonClient.setTabLabel(..., label: trimmed)`.

`reorderTab` (body sketched in §3 of the design discussion):

1. Locate `from` and `target` indices in `tabs[worktreeID]`.
2. Remove `from`, insert at the target index (`+1` for `.trailing` edge).
3. Mutate `tabs[worktreeID]` and update `activeTabIndices[worktreeID]` so the currently-active tab.id stays selected.
4. Fire-and-forget `daemonClient.setTabOrder(worktreeID, arr.map(\.id))`.

`reconcileTabs` and `reconcileNoteTabs` in `AppState.swift` apply stored order as a final step:

```swift
let storedOrder = worktreeTabOrders[worktreeID] ?? []
let storedIndex = Dictionary(uniqueKeysWithValues: storedOrder.enumerated().map { ($1, $0) })
currentTabs.sort { (a, b) in
    let ai = storedIndex[a.id] ?? Int.max
    let bi = storedIndex[b.id] ?? Int.max
    return ai < bi
}
```

`AppState+Notes.swift` drops the line that mirrors `note.title` into `tab.label` (line 33 today). New note tabs are created with `label: nil`. The tab label fallback for `.note` content is added in `TabBar.swift`'s `tabLabel` property: when `tab.label` is nil, look up the note in `appState.notes[worktreeID]` and use its `title`.

### App-side: TabBar UI

In `Sources/TBDApp/TabBar.swift` (`TabBarItem`):

Rename:

- `@State private var isEditing: Bool = false` on `TabBarItem`.
- Replace the static `Text(tabLabel)` with a `RenameableLabel` (from `Sources/TBDApp/Sidebar/RenameableLabel.swift`) when `isEditing == true`. Static `Text` otherwise.
- Triggers:
  - `.onTapGesture(count: 2)` on the tab text area enters edit mode, except when `tab.content == .codeViewer(...)`.
  - "Rename Tab" `Button` added to `contextMenuContent`, gated on the same content-type check.
- `RenameableLabel` is initialized with `text:` = currently displayed label so the user types over the visible text. On commit, call `appState.renameTab(...)`.
- During edit: the close button (`xmark`) is hidden; the tab becomes active if it wasn't already; tab is `.fixedSize()` so it auto-grows.

Reorder:

- `.draggable(TabDragPayload(tabID: tab.id), preview: { /* ghosted tab content */ })` on the tab.
- On drag start, set `appState.draggingTabID = tab.id`; clear on drop / cancel.
- The dragged tab renders at 40% opacity when `appState.draggingTabID == tab.id`.
- Each tab is `.dropDestination(for: TabDragPayload.self)`:
  - Compute `DropEdge` (`enum DropEdge { case leading, trailing }`, defined in `TabBar.swift`) from the local drop `CGPoint.x` vs tab width midpoint.
  - On valid drop: call `appState.reorderTab(...)`.
  - On `isTargeted` change: update `@State private var dropEdge: DropEdge?` so only one tab shows the indicator at a time.
- Insertion indicator: a 2pt-wide `RoundedRectangle` in `Color.accentColor`, full tab height, overlaid on the targeted tab's leading or trailing edge. Animated `easeInOut(duration: 0.1)`.
- The `+` button and history button are **not** drop destinations.

Drop UTType (`com.tbd.app.tab-drag`) is registered in `Info.plist`-equivalent location for the bundled `.app`. (Worktree CLAUDE.md note: the app runs from `.build/debug/TBD.app` assembled by `scripts/restart.sh` — drop registration goes in the same plist the bundle script generates.)

## Data flow

### Rename

1. User double-clicks a tab (or right-clicks → Rename).
2. `TabBarItem.isEditing = true`, `RenameableLabel` takes focus with the current displayed label preselected.
3. User types, presses Enter (or blurs).
4. `RenameableLabel.onCommit(trimmed)` → `appState.renameTab(tabID:, worktreeID:, newLabel:)`.
5. AppState applies the rules above, updates `tabs[worktreeID]` in-memory, fires `daemonClient.setTabLabel(...)`.
6. Daemon writes (or deletes) the row in `tabs`.

### Reorder

1. User starts a drag on a tab → `draggingTabID` set, dragged tab dimmed.
2. User moves cursor over another tab → that tab's `dropEdge` flips to `.leading` or `.trailing` based on the cursor's x; insertion indicator renders.
3. User releases → `dropDestination` closure runs `appState.reorderTab(...)`.
4. AppState mutates `tabs[worktreeID]`, fires `daemonClient.setTabOrder(...)`.
5. Daemon JSON-encodes the array and writes `worktrees.tab_order`.

### App launch / worktree first visit

1. AppState already loads worktrees/terminals/notes.
2. When a worktree first appears in `AppState.tabs`, AppState calls `daemonClient.listTabs(worktreeID:)`.
3. Response seeds `worktreeTabOrders[worktreeID]` and per-tab `label` overrides.
4. Subsequent `reconcileTabs` / `reconcileNoteTabs` calls apply the stored order at the end and use the seeded labels.

## Edge cases

- **Rename to empty / whitespace-only** → clear override (`label = nil`, DB row deleted). Tab reverts to auto-derived label.
- **Rename to same value as displayed** → no-op (no RPC, no in-memory change).
- **Drag onto self or current slot** → no-op.
- **Drag onto `+` button or history button** → drop rejected, tab snaps back.
- **Drop outside tab strip** → SwiftUI default cancel, tab snaps back.
- **Reorder while a tab is mid-edit** — guarded by SwiftUI's normal interaction routing; the dragged tab's `RenameableLabel` loses focus, which commits the in-progress edit (`RenameableLabel.onChange(of: isTextFieldFocused)` already handles this).
- **Tab whose terminal/note was deleted while app was offline** → next reconcile drops the tab; daemon's `terminal.delete` / `note.delete` already cleaned the `tabs` row.
- **Unknown UUIDs in stored `tab_order`** (e.g. tab existed at write-time, gone now) → sorted to the end via `Int.max` sentinel, no error.
- **Code-viewer tab** → double-click ignored, "Rename Tab" not shown in context menu. Still reorderable.
- **Note tab decoupling**: if a note's title was previously mirrored into `tab.label` (pre-migration), that label stays on first run; user clearing it reverts to the live note title.

## Testing

Per project rule "add a test for each branch":

| Layer | Test |
|---|---|
| Migration | Round-trip from prior version: `tabs` table present, `worktrees.tab_order` defaults to `'[]'` |
| Database | `setTabLabel` with non-empty inserts row; with nil deletes row |
| Database | `setTabOrder` round-trips JSON correctly; preserves order |
| Database | `getTabOrder` returns `[]` for a worktree with no overrides |
| RPC | `tab.setOrder` rejects request with duplicate UUIDs |
| RPC | `tab.list` returns labels + order for a worktree, empty when unset |
| Cleanup | Deleting a terminal removes its `tabs` row |
| Cleanup | Deleting a note removes its `tabs` row |
| AppState | `renameTab` with empty string sets `label = nil` and calls RPC with nil |
| AppState | `renameTab` with same-as-displayed value is a no-op (no RPC) |
| AppState | `renameTab` with new value updates `tabs[worktreeID]` and calls RPC with trimmed value |
| AppState | `reorderTab` updates order and preserves `activeTabIndices` pointing at same `tab.id` |
| Reconcile | New terminal appears at end of strip when user-ordered tabs already present |
| Reconcile | Tab whose terminal disappeared is dropped on next reconcile |
| Note decoupling | Renaming a note no longer mutates its tab's `label`; renaming the tab leaves `note.title` untouched |

Manual UI verification (after `scripts/restart.sh`):

- Double-click enters edit; Esc cancels; Enter commits; empty + Enter clears override.
- Right-click → "Rename Tab" works.
- Drag tab left/right of another tab — insertion indicator on the correct edge.
- Drag onto `+` or history button — no drop, tab returns.
- Code-viewer tabs: double-click and context menu item suppressed.
- Restart app — custom labels and tab order persist.

## Files touched

- `Sources/TBDDaemon/Database/Database.swift` — migration, queries.
- `Sources/TBDDaemon/Database/TabRow.swift` (new) — GRDB record.
- `Sources/TBDDaemon/Database/WorktreeRow.swift` (or equivalent) — add `tabOrder` field.
- `Sources/TBDDaemon/RPCHandler.swift` (or equivalent) — dispatch the three new methods.
- `Sources/TBDShared/Models.swift` — `TabState`, `TabDragPayload`.
- `Sources/TBDShared/RPCProtocol.swift` — method names, request/response structs.
- `Sources/TBDApp/DaemonClient.swift` — `listTabs`, `setTabLabel`, `setTabOrder` clients.
- `Sources/TBDApp/AppState+Tabs.swift` (new) — `renameTab`, `reorderTab`, `loadTabStates`, `draggingTabID`.
- `Sources/TBDApp/AppState.swift` — apply stored order in `reconcileTabs` / `reconcileNoteTabs`.
- `Sources/TBDApp/AppState+Notes.swift` — drop the line that mirrors `note.title` into `tab.label`.
- `Sources/TBDApp/TabBar.swift` — `isEditing` state, `RenameableLabel` swap, double-click trigger, context menu item, `.draggable` / `.dropDestination`, insertion indicator, dimmed dragged tab.
- `Sources/TBDApp/Terminal/PaneContent.swift` — no change (existing `Tab.label: String?` is reused).
- Bundle plist (assembled by `scripts/restart.sh`) — register `com.tbd.app.tab-drag` UTType.
