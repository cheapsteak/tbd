# Worktree Pinning & Ordered Split View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add worktree pinning so pinned worktrees auto-select on launch, and split view renders panes in pin/click order instead of arbitrary Set order.

**Architecture:** Database stores `pinnedAt` timestamp per worktree. AppState keeps a `selectionOrder: [UUID]` array alongside the existing `selectedWorktreeIDs: Set<UUID>` (Set required by SwiftUI's `List(selection:)`). Split view uses the ordered array. Pin icon on row left + context menu toggle pin state via RPC.

**Tech Stack:** Swift, SwiftUI, GRDB, Unix socket RPC

---

### Task 1: Database Migration + Shared Model

**Files:**
- Modify: `Sources/TBDDaemon/Database/Database.swift:104` (add migration v4)
- Modify: `Sources/TBDDaemon/Database/WorktreeStore.swift:6-50` (add pinnedAt to record + conversions)
- Modify: `Sources/TBDShared/Models.swift:26-69` (add pinnedAt to Worktree)

- [ ] **Step 1: Add `pinnedAt` to the Worktree model**

In `Sources/TBDShared/Models.swift`, add `pinnedAt: Date?` to the `Worktree` struct:

```swift
// After line 36 (archivedAt):
public var pinnedAt: Date?
```

Update the `init` (line 39-54) to accept `pinnedAt`:
```swift
public init(id: UUID = UUID(), repoID: UUID, name: String, displayName: String,
            branch: String, path: String, status: WorktreeStatus = .active,
            hasConflicts: Bool = false,
            createdAt: Date = Date(), archivedAt: Date? = nil,
            pinnedAt: Date? = nil,
            tmuxServer: String) {
    // ... existing assignments ...
    self.pinnedAt = pinnedAt
}
```

Update the custom `init(from decoder:)` (line 56-69):
```swift
pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
```

- [ ] **Step 2: Add `pinnedAt` to WorktreeRecord**

In `Sources/TBDDaemon/Database/WorktreeStore.swift`, add to the record struct (after line 18):
```swift
var pinnedAt: Date?
```

Update `init(from wt: Worktree)` (after line 31):
```swift
self.pinnedAt = wt.pinnedAt
```

Update `toModel()` to pass `pinnedAt: pinnedAt` in the Worktree init call.

- [ ] **Step 3: Add database migration v4**

In `Sources/TBDDaemon/Database/Database.swift`, before `try migrator.migrate(writer)` (line 105):
```swift
migrator.registerMigration("v4") { db in
    try db.alter(table: "worktree") { t in
        t.add(column: "pinnedAt", .datetime)
    }
}
```

- [ ] **Step 4: Add `setPin` method to WorktreeStore**

In `Sources/TBDDaemon/Database/WorktreeStore.swift`, add after `updateBranch` method:
```swift
/// Set or clear the pinned timestamp for a worktree.
public func setPin(id: UUID, pinned: Bool) async throws {
    try await writer.write { db in
        guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
            throw DatabaseError(message: "Worktree not found")
        }
        record.pinnedAt = pinned ? Date() : nil
        try record.update(db)
    }
}
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDShared/Models.swift Sources/TBDDaemon/Database/Database.swift Sources/TBDDaemon/Database/WorktreeStore.swift
git commit -m "feat: add pinnedAt column to worktree table (migration v4)"
```

---

### Task 2: RPC Protocol + Daemon Handler

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift:78-100` (add method + params)
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift:48-97` (add switch case)
- Modify: `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift:76-86` (add handler)
- Modify: `Sources/TBDDaemon/Server/StateSubscription.swift:7-17` (add delta case)

- [ ] **Step 1: Add RPC method and params**

In `Sources/TBDShared/RPCProtocol.swift`, add to `RPCMethod` enum (after line 99):
```swift
public static let worktreeSetPin = "worktree.setPin"
```

Add params struct (after `WorktreeRenameParams`, around line 175):
```swift
public struct WorktreeSetPinParams: Codable, Sendable {
    public let worktreeID: UUID
    public let pinned: Bool
    public init(worktreeID: UUID, pinned: Bool) {
        self.worktreeID = worktreeID; self.pinned = pinned
    }
}
```

- [ ] **Step 2: Add state delta for pin change**

In `Sources/TBDDaemon/Server/StateSubscription.swift`, add to the `StateDelta` enum (after `worktreeConflictsChanged`):
```swift
case worktreePinChanged(WorktreePinDelta)
```

Add the delta struct (after `WorktreeConflictDelta`):
```swift
/// Delta payload for worktree pin state change.
public struct WorktreePinDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let pinnedAt: Date?
    public init(worktreeID: UUID, pinnedAt: Date?) {
        self.worktreeID = worktreeID; self.pinnedAt = pinnedAt
    }
}
```

- [ ] **Step 3: Add handler in RPCRouter**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add case in the switch (after `worktreeRename` case, line 66):
```swift
case RPCMethod.worktreeSetPin:
    return try await handleWorktreeSetPin(request.paramsData)
```

In `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift`, add handler (after `handleWorktreeRename`):
```swift
func handleWorktreeSetPin(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(WorktreeSetPinParams.self, from: paramsData)
    try await db.worktrees.setPin(id: params.worktreeID, pinned: params.pinned)

    // Fetch the updated worktree to get the actual pinnedAt value
    let wt = try await db.worktrees.get(id: params.worktreeID)
    subscriptions.broadcast(delta: .worktreePinChanged(WorktreePinDelta(
        worktreeID: params.worktreeID, pinnedAt: wt?.pinnedAt
    )))

    return .ok()
}
```

- [ ] **Step 4: Add client method in DaemonClient**

In `Sources/TBDApp/DaemonClient.swift`, add after `renameWorktree` method:
```swift
/// Set or clear the pin on a worktree.
func setWorktreePin(id: UUID, pinned: Bool) throws {
    try callVoid(
        method: RPCMethod.worktreeSetPin,
        params: WorktreeSetPinParams(worktreeID: id, pinned: pinned)
    )
}
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift Sources/TBDDaemon/Server/RPCRouter.swift Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift Sources/TBDDaemon/Server/StateSubscription.swift Sources/TBDApp/DaemonClient.swift
git commit -m "feat: add worktree.setPin RPC method and handler"
```

---

### Task 3: AppState Selection Order + Pin Integration

**Files:**
- Modify: `Sources/TBDApp/AppState.swift:14,40-46` (add selectionOrder, init pin restore)
- Modify: `Sources/TBDApp/AppState+Worktrees.swift:50-64,78-100` (sync selectionOrder on mutations)
- Modify: `Sources/TBDApp/Terminal/TerminalContainerView.swift:19-20` (use selectionOrder)

- [ ] **Step 1: Add selectionOrder and pin methods to AppState**

In `Sources/TBDApp/AppState.swift`, add after `selectedWorktreeIDs` (line 14):
```swift
/// Tracks the order of selected worktrees for split view rendering.
/// Pinned worktrees come first (sorted by pinnedAt), then cmd+clicked ones in click order.
@Published var selectionOrder: [UUID] = []
```

- [ ] **Step 2: Add pin action method to AppState+Worktrees**

In `Sources/TBDApp/AppState+Worktrees.swift`, add after `renameWorktree`:
```swift
/// Toggle pin state for a worktree.
func setWorktreePin(id: UUID, pinned: Bool) async {
    // Optimistic local update
    for repoID in worktrees.keys {
        if let idx = worktrees[repoID]?.firstIndex(where: { $0.id == id }) {
            worktrees[repoID]?[idx].pinnedAt = pinned ? Date() : nil
        }
    }

    if pinned {
        // Add to selection if not already there
        if !selectedWorktreeIDs.contains(id) {
            selectedWorktreeIDs.insert(id)
        }
        // Rebuild order: pinned first (by pinnedAt), then unpinned in existing order
        rebuildSelectionOrder()
    } else {
        // Just rebuild order — item stays selected but loses pin priority
        rebuildSelectionOrder()
    }

    do {
        try await daemonClient.setWorktreePin(id: id, pinned: pinned)
    } catch {
        logger.error("Failed to set pin: \(error)")
        handleConnectionError(error)
    }
}

/// Rebuild selectionOrder from selectedWorktreeIDs, putting pinned items first (by pinnedAt).
func rebuildSelectionOrder() {
    let allWts = worktrees.values.flatMap { $0 }
    let wtMap = Dictionary(uniqueKeysWithValues: allWts.map { ($0.id, $0) })

    let selected = selectedWorktreeIDs
    var pinned: [(UUID, Date)] = []
    var unpinned: [UUID] = []

    for id in selectionOrder where selected.contains(id) {
        if let wt = wtMap[id], let pinnedAt = wt.pinnedAt {
            pinned.append((id, pinnedAt))
        } else {
            unpinned.append(id)
        }
    }
    // Add any selected IDs not yet in selectionOrder
    for id in selected where !selectionOrder.contains(id) {
        if let wt = wtMap[id], let pinnedAt = wt.pinnedAt {
            pinned.append((id, pinnedAt))
        } else {
            unpinned.append(id)
        }
    }

    pinned.sort { $0.1 < $1.1 }
    selectionOrder = pinned.map(\.0) + unpinned
}
```

- [ ] **Step 3: Sync selectionOrder on selection changes**

In `Sources/TBDApp/AppState.swift`, add a `didSet` observer to `selectedWorktreeIDs` to keep `selectionOrder` in sync. Change line 14 from:
```swift
@Published var selectedWorktreeIDs: Set<UUID> = []
```
to:
```swift
@Published var selectedWorktreeIDs: Set<UUID> = [] {
    didSet {
        // Remove deselected items from order
        selectionOrder.removeAll { !selectedWorktreeIDs.contains($0) }
        // Append newly selected items (maintains insertion order for cmd+click)
        for id in selectedWorktreeIDs where !selectionOrder.contains(id) {
            selectionOrder.append(id)
        }
    }
}
```

- [ ] **Step 4: Restore pinned selection on launch**

In `Sources/TBDApp/AppState.swift`, update `connectAndLoadInitialState` (line 94-103). After `await refreshAll()` and before `await refreshPRStatuses()`:
```swift
// Auto-select pinned worktrees on launch
let pinnedWts = worktrees.values.flatMap { $0 }
    .filter { $0.pinnedAt != nil }
    .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
if !pinnedWts.isEmpty {
    selectedWorktreeIDs = Set(pinnedWts.map(\.id))
    selectionOrder = pinnedWts.map(\.id)
}
```

- [ ] **Step 5: Update MultiWorktreeView to use selectionOrder**

In `Sources/TBDApp/Terminal/TerminalContainerView.swift`, change line 19-20 from:
```swift
} else if appState.selectedWorktreeIDs.count > 1 {
    MultiWorktreeView(worktreeIDs: Array(appState.selectedWorktreeIDs))
```
to:
```swift
} else if appState.selectedWorktreeIDs.count > 1 {
    MultiWorktreeView(worktreeIDs: appState.selectionOrder)
```

- [ ] **Step 6: Update cmd+click to protect pinned items**

In `Sources/TBDApp/Sidebar/WorktreeRowView.swift`, update the cmd+click handler (lines 174-179). Replace:
```swift
if NSEvent.modifierFlags.contains(.command) {
    if appState.selectedWorktreeIDs.contains(worktree.id) {
        appState.selectedWorktreeIDs.remove(worktree.id)
    } else {
        appState.selectedWorktreeIDs.insert(worktree.id)
    }
```
with:
```swift
if NSEvent.modifierFlags.contains(.command) {
    if appState.selectedWorktreeIDs.contains(worktree.id) {
        // Don't allow cmd+click removal of pinned worktrees
        if worktree.pinnedAt == nil {
            appState.selectedWorktreeIDs.remove(worktree.id)
        }
    } else {
        appState.selectedWorktreeIDs.insert(worktree.id)
    }
```

- [ ] **Step 7: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`
Expected: Build succeeds

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDApp/AppState.swift Sources/TBDApp/AppState+Worktrees.swift Sources/TBDApp/Terminal/TerminalContainerView.swift Sources/TBDApp/Sidebar/WorktreeRowView.swift
git commit -m "feat: add selectionOrder for ordered split view and pin-aware selection"
```

---

### Task 4: Pin Icon in Sidebar Row

**Files:**
- Modify: `Sources/TBDApp/Sidebar/WorktreeRowView.swift:82-230` (add pin icon to both HStacks)

- [ ] **Step 1: Add hover state and pin icon to the main HStack**

In `Sources/TBDApp/Sidebar/WorktreeRowView.swift`, add a hover state variable (after line 15):
```swift
@State private var isHovering = false
```

In the main `body` HStack (line 83), add the pin icon as the FIRST element (before the `if isMain` check at line 84):
```swift
// Pin icon: always visible when pinned, hover-only when unpinned
if worktree.pinnedAt != nil {
    Image(systemName: "pin.fill")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 10)
        .onTapGesture {
            Task { await appState.setWorktreePin(id: worktree.id, pinned: false) }
        }
} else if isHovering {
    Image(systemName: "pin")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(width: 10)
        .onTapGesture {
            Task { await appState.setWorktreePin(id: worktree.id, pinned: true) }
        }
} else {
    Color.clear.frame(width: 10)
}
```

Add `.onHover` modifier. Place it right after `.contentShape(Rectangle())` (line 172), before `.onTapGesture`:
```swift
.onHover { hovering in
    isHovering = hovering
}
```

- [ ] **Step 2: Add pin icon to the expanding row overlay HStack**

In the expanding row overlay HStack (line 196), add the same pin icon as the first element (before the `if isMain` check at line 197):
```swift
if worktree.pinnedAt != nil {
    Image(systemName: "pin.fill")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 10)
} else if isHovering {
    Image(systemName: "pin")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(width: 10)
} else {
    Color.clear.frame(width: 10)
}
```

Note: The overlay HStack does NOT need tap gesture handlers because the overlay panel has `ignoresMouseEvents = true` — clicks pass through to the underlying SwiftUI view. The click monitor in `ExpandingRowPanel` only fires the `onClick` callback (which triggers rename), then lets the click pass through. So the pin icon tap handler on the main HStack will receive the click.

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Sidebar/WorktreeRowView.swift
git commit -m "feat: add pin icon to worktree sidebar rows (hover + persistent)"
```

---

### Task 5: Context Menu Pin/Unpin

**Files:**
- Modify: `Sources/TBDApp/Sidebar/SidebarContextMenu.swift:24-46` (add Pin/Unpin button)

- [ ] **Step 1: Add Pin/Unpin to context menu**

In `Sources/TBDApp/Sidebar/SidebarContextMenu.swift`, in the `else` branch (active/archived worktrees, line 24), add after "Rename..." button (line 27):

```swift
Button(worktree.pinnedAt != nil ? "Unpin" : "Pin") {
    let wtID = worktree.id
    let shouldPin = worktree.pinnedAt == nil
    Task {
        await appState.setWorktreePin(id: wtID, pinned: shouldPin)
    }
}
```

Also add a Pin/Unpin option for main worktrees too — in the `if` branch (line 12-23), add before "Open in Finder":

```swift
Button(worktree.pinnedAt != nil ? "Unpin" : "Pin") {
    let wtID = worktree.id
    let shouldPin = worktree.pinnedAt == nil
    Task {
        await appState.setWorktreePin(id: wtID, pinned: shouldPin)
    }
}

Divider()
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Sidebar/SidebarContextMenu.swift
git commit -m "feat: add Pin/Unpin to worktree context menu"
```

---

### Task 6: Tests

**Files:**
- Modify: `Tests/TBDDaemonTests/DatabaseTests.swift` (add pin tests)

- [ ] **Step 1: Write database pin tests**

Add test cases to the existing database test file. Use `@Test` and `#expect` (Swift Testing framework):

```swift
@Test func worktreeSetPinAndUnpin() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "Test")
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
        path: "/tmp/test-repo/.tbd/worktrees/test-wt", tmuxServer: "test"
    )

    // Initially not pinned
    let initial = try await db.worktrees.get(id: wt.id)
    #expect(initial?.pinnedAt == nil)

    // Pin it
    try await db.worktrees.setPin(id: wt.id, pinned: true)
    let pinned = try await db.worktrees.get(id: wt.id)
    #expect(pinned?.pinnedAt != nil)

    // Unpin it
    try await db.worktrees.setPin(id: wt.id, pinned: false)
    let unpinned = try await db.worktrees.get(id: wt.id)
    #expect(unpinned?.pinnedAt == nil)
}

@Test func pinnedWorktreesOrderByPinnedAt() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(path: "/tmp/test-repo2", displayName: "Test2")

    let wt1 = try await db.worktrees.create(
        repoID: repo.id, name: "wt-1", branch: "tbd/wt-1",
        path: "/tmp/test-repo2/.tbd/worktrees/wt-1", tmuxServer: "test"
    )
    let wt2 = try await db.worktrees.create(
        repoID: repo.id, name: "wt-2", branch: "tbd/wt-2",
        path: "/tmp/test-repo2/.tbd/worktrees/wt-2", tmuxServer: "test"
    )

    // Pin wt2 first, then wt1
    try await db.worktrees.setPin(id: wt2.id, pinned: true)
    try await Task.sleep(for: .milliseconds(10))
    try await db.worktrees.setPin(id: wt1.id, pinned: true)

    let all = try await db.worktrees.list(repoID: repo.id)
    let pinned = all.filter { $0.pinnedAt != nil }
        .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }

    #expect(pinned.count == 2)
    #expect(pinned[0].id == wt2.id) // pinned first
    #expect(pinned[1].id == wt1.id) // pinned second
}
```

- [ ] **Step 2: Run tests**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift test 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/
git commit -m "test: add worktree pin/unpin database tests"
```

---

### Task 7: Archive Cleanup — Unpin on Archive

**Files:**
- Modify: `Sources/TBDApp/AppState+Worktrees.swift:50-64` (remove from selectionOrder on archive)

- [ ] **Step 1: Clean up selection order when archiving**

In `Sources/TBDApp/AppState+Worktrees.swift`, in `archiveWorktree` method (line 50-64), after `selectedWorktreeIDs.remove(id)` (line 57), add:
```swift
selectionOrder.removeAll { $0 == id }
```

This is needed because the `didSet` on `selectedWorktreeIDs` handles this, but it's good to be explicit. Actually — the `didSet` already removes items not in the Set, so this line is redundant. Skip this step.

Actually, let's verify: the `didSet` on `selectedWorktreeIDs` does `selectionOrder.removeAll { !selectedWorktreeIDs.contains($0) }` — this already handles it. No changes needed.

- [ ] **Step 1 (revised): Verify archive behavior is already correct**

No code changes needed. The `didSet` on `selectedWorktreeIDs` automatically removes archived worktrees from `selectionOrder` when they're removed from the Set.

- [ ] **Step 2: Commit** (skip — no changes)
