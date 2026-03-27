# Terminal Pane Pinning & Dock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add terminal pane pinning with a persistent right-side dock, so pinned terminals remain visible when navigating between worktrees.

**Architecture:** Database stores `pinnedAt` timestamp per terminal (migration v5). A new `PinnedTerminalDock` view renders pinned terminals from non-visible worktrees in a resizable right-side column. The pane header's terminal ID label is replaced with a pin icon. Dock ratio persists in UserDefaults.

**Tech Stack:** Swift, SwiftUI, GRDB, Unix socket RPC

---

### Task 1: Database Migration + Terminal Model

**Files:**
- Modify: `Sources/TBDShared/Models.swift:75-91` (add pinnedAt to Terminal)
- Modify: `Sources/TBDDaemon/Database/Database.swift:105` (add migration v5)
- Modify: `Sources/TBDDaemon/Database/TerminalStore.swift:6-35` (add pinnedAt to record + conversions)

- [ ] **Step 1: Add `pinnedAt` to the Terminal model**

In `Sources/TBDShared/Models.swift`, add `pinnedAt: Date?` to the `Terminal` struct after `createdAt`:

```swift
public struct Terminal: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var tmuxWindowID: String
    public var tmuxPaneID: String
    public var label: String?
    public var createdAt: Date
    public var pinnedAt: Date?

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date(),
                pinnedAt: Date? = nil) {
        self.id = id
        self.worktreeID = worktreeID
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.label = label
        self.createdAt = createdAt
        self.pinnedAt = pinnedAt
    }
}
```

Note: `Terminal` uses synthesized Codable. Since `pinnedAt` is optional, existing JSON without the field decodes as `nil` automatically. No custom decoder needed.

- [ ] **Step 2: Add `pinnedAt` to TerminalRecord**

In `Sources/TBDDaemon/Database/TerminalStore.swift`, add to the record struct after `createdAt`:

```swift
var pinnedAt: Date?
```

Update `init(from terminal: Terminal)`:
```swift
self.pinnedAt = terminal.pinnedAt
```

Update `toModel()` to pass `pinnedAt: pinnedAt`.

- [ ] **Step 3: Add database migration v5**

In `Sources/TBDDaemon/Database/Database.swift`, add before `try migrator.migrate(writer)`:

```swift
migrator.registerMigration("v5") { db in
    try db.alter(table: "terminal") { t in
        t.add(column: "pinnedAt", .datetime)
    }
}
```

- [ ] **Step 4: Add `setPin` method to TerminalStore**

In `Sources/TBDDaemon/Database/TerminalStore.swift`, add after `deleteForWorktree`:

```swift
/// Set or clear the pinned timestamp for a terminal.
public func setPin(id: UUID, pinned: Bool) async throws {
    try await writer.write { db in
        guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
            throw DatabaseError(message: "Terminal not found")
        }
        record.pinnedAt = pinned ? Date() : nil
        try record.update(db)
    }
}
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDShared/Models.swift Sources/TBDDaemon/Database/Database.swift Sources/TBDDaemon/Database/TerminalStore.swift
git commit -m "feat: add pinnedAt column to terminal table (migration v5)"
```

---

### Task 2: RPC Protocol + Daemon Handler

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift` (add method + params)
- Modify: `Sources/TBDDaemon/Server/StateSubscription.swift` (add delta case)
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift` (add switch case)
- Modify: `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` (add handler)
- Modify: `Sources/TBDApp/DaemonClient.swift` (add client method)

- [ ] **Step 1: Add RPC method and params**

In `Sources/TBDShared/RPCProtocol.swift`, add to `RPCMethod` enum after `terminalDelete`:

```swift
public static let terminalSetPin = "terminal.setPin"
```

Add params struct after `TerminalDeleteParams`:

```swift
public struct TerminalSetPinParams: Codable, Sendable {
    public let terminalID: UUID
    public let pinned: Bool
    public init(terminalID: UUID, pinned: Bool) {
        self.terminalID = terminalID; self.pinned = pinned
    }
}
```

- [ ] **Step 2: Add state delta**

In `Sources/TBDDaemon/Server/StateSubscription.swift`, add to `StateDelta` enum after `worktreePinChanged`:

```swift
case terminalPinChanged(TerminalPinDelta)
```

Add the delta struct after `WorktreePinDelta`:

```swift
/// Delta payload for terminal pin state change.
public struct TerminalPinDelta: Codable, Sendable {
    public let terminalID: UUID
    public let pinnedAt: Date?
    public init(terminalID: UUID, pinnedAt: Date?) {
        self.terminalID = terminalID; self.pinnedAt = pinnedAt
    }
}
```

- [ ] **Step 3: Add handler in RPCRouter**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add case in the switch after `terminalDelete`:

```swift
case RPCMethod.terminalSetPin:
    return try await handleTerminalSetPin(request.paramsData)
```

In `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`, add handler after `handleTerminalSend`:

```swift
func handleTerminalSetPin(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(TerminalSetPinParams.self, from: paramsData)
    try await db.terminals.setPin(id: params.terminalID, pinned: params.pinned)

    let terminal = try await db.terminals.get(id: params.terminalID)
    subscriptions.broadcast(delta: .terminalPinChanged(TerminalPinDelta(
        terminalID: params.terminalID, pinnedAt: terminal?.pinnedAt
    )))

    return .ok()
}
```

- [ ] **Step 4: Add client method**

In `Sources/TBDApp/DaemonClient.swift`, add after `setWorktreePin`:

```swift
/// Set or clear the pin on a terminal.
func setTerminalPin(id: UUID, pinned: Bool) throws {
    try callVoid(
        method: RPCMethod.terminalSetPin,
        params: TerminalSetPinParams(terminalID: id, pinned: pinned)
    )
}
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift Sources/TBDDaemon/Server/StateSubscription.swift Sources/TBDDaemon/Server/RPCRouter.swift Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift Sources/TBDApp/DaemonClient.swift
git commit -m "feat: add terminal.setPin RPC method and handler"
```

---

### Task 3: AppState Terminal Pin Support

**Files:**
- Modify: `Sources/TBDApp/AppState+Terminals.swift` (add setTerminalPin method)
- Modify: `Sources/TBDApp/AppState.swift` (add pinnedTerminals computed property, dock ratio persistence)

- [ ] **Step 1: Add setTerminalPin to AppState**

Read `Sources/TBDApp/AppState+Terminals.swift` first to understand existing patterns.

Add a new method for toggling terminal pin state:

```swift
/// Toggle pin state for a terminal.
func setTerminalPin(id: UUID, pinned: Bool) async {
    // Optimistic local update
    for worktreeID in terminals.keys {
        if let idx = terminals[worktreeID]?.firstIndex(where: { $0.id == id }) {
            terminals[worktreeID]?[idx].pinnedAt = pinned ? Date() : nil
        }
    }

    do {
        try await daemonClient.setTerminalPin(id: id, pinned: pinned)
    } catch {
        logger.error("Failed to set terminal pin: \(error)")
        handleConnectionError(error)
    }
}
```

- [ ] **Step 2: Add pinnedTerminals computed property and dock ratio to AppState**

In `Sources/TBDApp/AppState.swift`, add the computed property (after `selectionOrder`):

```swift
/// All pinned terminals across all worktrees, sorted by pinnedAt.
var pinnedTerminals: [Terminal] {
    terminals.values.flatMap { $0 }
        .filter { $0.pinnedAt != nil }
        .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
}
```

Add dock ratio persistence (near the layouts persistence):

```swift
private static let dockRatioKey = "com.tbd.app.dockRatio"

@Published var dockRatio: CGFloat = 0.3 {
    didSet { UserDefaults.standard.set(Double(dockRatio), forKey: Self.dockRatioKey) }
}
```

In `init()`, before the `Task` block, add:

```swift
if let saved = UserDefaults.standard.object(forKey: Self.dockRatioKey) as? Double {
    dockRatio = CGFloat(saved)
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/AppState.swift Sources/TBDApp/AppState+Terminals.swift
git commit -m "feat: add terminal pin support and dock ratio persistence to AppState"
```

---

### Task 4: Pane Header Pin Icon (Replace Terminal ID)

**Files:**
- Modify: `Sources/TBDApp/Panes/PanePlaceholder.swift:64-74` (replace paneLabel)

- [ ] **Step 1: Replace terminal ID with pin icon in pane header**

In `Sources/TBDApp/Panes/PanePlaceholder.swift`, add a hover state at the top of the struct (after line 12):

```swift
@State private var isHeaderHovering = false
```

Replace the `paneLabel` computed property (lines 64-74):

```swift
@ViewBuilder
private var paneLabel: some View {
    switch content {
    case .terminal(let terminalID):
        let terminal = terminal(for: terminalID)
        let isPinned = terminal?.pinnedAt != nil
        HStack(spacing: 4) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .onTapGesture {
                        Task { await appState.setTerminalPin(id: terminalID, pinned: false) }
                    }
            } else if isHeaderHovering {
                Image(systemName: "pin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .onTapGesture {
                        Task { await appState.setTerminalPin(id: terminalID, pinned: true) }
                    }
            }
        }
    case .webview(_, let url):
        Text(url.host ?? url.absoluteString)
    case .codeViewer(_, let path):
        Text(URL(fileURLWithPath: path).lastPathComponent)
    }
}
```

Add `.onHover` to the toolbar view. In the `toolbar` computed property, add after `.background(Color(nsColor: .controlBackgroundColor))`:

```swift
.onHover { hovering in
    isHeaderHovering = hovering
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Panes/PanePlaceholder.swift
git commit -m "feat: replace terminal ID in pane header with pin icon"
```

---

### Task 5: Pinned Terminal Dock View

**Files:**
- Create: `Sources/TBDApp/Terminal/PinnedTerminalDock.swift`

- [ ] **Step 1: Create the dock view**

Create `Sources/TBDApp/Terminal/PinnedTerminalDock.swift`:

```swift
import SwiftUI
import TBDShared

/// A vertical dock showing pinned terminals from worktrees not currently visible.
/// Each pinned terminal gets a cell with a header (pin icon + worktree name) and the terminal view.
struct PinnedTerminalDock: View {
    let terminals: [Terminal]
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 1) {
            ForEach(terminals) { terminal in
                PinnedTerminalCell(terminal: terminal)
            }
        }
        .background(Color(nsColor: .separatorColor))
    }
}

/// A single cell in the pinned terminal dock.
private struct PinnedTerminalCell: View {
    let terminal: Terminal
    @EnvironmentObject var appState: AppState

    private var worktree: Worktree? {
        for wts in appState.worktrees.values {
            if let wt = wts.first(where: { $0.id == terminal.worktreeID }) {
                return wt
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: pin icon + worktree name
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .onTapGesture {
                        Task { await appState.setTerminalPin(id: terminal.id, pinned: false) }
                    }
                if let worktree {
                    Text(worktree.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Terminal content
            if let worktree {
                TerminalPanelView(
                    terminalID: terminal.id,
                    tmuxServer: worktree.tmuxServer,
                    tmuxWindowID: terminal.tmuxWindowID,
                    tmuxBridge: appState.tmuxBridge,
                    worktreePath: worktree.path
                )
                .id(terminal.id)
            } else {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Terminal/PinnedTerminalDock.swift
git commit -m "feat: add PinnedTerminalDock view for pinned terminal cells"
```

---

### Task 6: Integrate Dock into TerminalContainerView

**Files:**
- Modify: `Sources/TBDApp/Terminal/TerminalContainerView.swift:12-26` (wrap content with dock)

- [ ] **Step 1: Add dock wrapper to TerminalContainerView**

In `Sources/TBDApp/Terminal/TerminalContainerView.swift`, replace the `body` of `TerminalContainerView` (lines 15-25):

```swift
var body: some View {
    let visibleWorktreeIDs = appState.selectedWorktreeIDs
    let dockTerminals = appState.pinnedTerminals.filter { terminal in
        !visibleWorktreeIDs.contains(terminal.worktreeID)
    }

    let mainContent = Group {
        if appState.selectedWorktreeIDs.count == 1,
           let worktreeID = appState.selectedWorktreeIDs.first {
            SingleWorktreeView(worktreeID: worktreeID)
        } else if appState.selectedWorktreeIDs.count > 1 {
            MultiWorktreeView(worktreeIDs: appState.selectionOrder)
        } else {
            Text("Select a worktree or click + to create one")
                .foregroundStyle(.secondary)
        }
    }

    if dockTerminals.isEmpty {
        mainContent
    } else {
        DockSplitView(
            dockRatio: $appState.dockRatio,
            mainContent: { mainContent },
            dockContent: { PinnedTerminalDock(terminals: dockTerminals) }
        )
    }
}
```

- [ ] **Step 2: Add DockSplitView**

Add at the bottom of `TerminalContainerView.swift` (or in a new section):

```swift
// MARK: - DockSplitView

/// A horizontal split between main content (left) and pinned terminal dock (right).
/// The divider is draggable to resize the dock.
private struct DockSplitView<Main: View, Dock: View>: View {
    @Binding var dockRatio: CGFloat
    @ViewBuilder let mainContent: () -> Main
    @ViewBuilder let dockContent: () -> Dock

    @State private var dragStartRatio: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let dividerWidth: CGFloat = 4
            let available = totalWidth - dividerWidth
            let dockWidth = available * dockRatio
            let mainWidth = available - dockWidth

            HStack(spacing: 0) {
                mainContent()
                    .frame(width: mainWidth)

                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: dividerWidth)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragStartRatio == nil {
                                    dragStartRatio = dockRatio
                                }
                                guard let startRatio = dragStartRatio, available > 0 else { return }
                                let delta = -value.translation.width / available
                                let newRatio = max(0.1, min(0.6, startRatio + delta))
                                dockRatio = newRatio
                            }
                            .onEnded { _ in
                                dragStartRatio = nil
                            }
                    )

                dockContent()
                    .frame(width: dockWidth)
            }
        }
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift build 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Terminal/TerminalContainerView.swift
git commit -m "feat: integrate pinned terminal dock into TerminalContainerView"
```

---

### Task 7: Tests

**Files:**
- Modify: `Tests/TBDDaemonTests/DatabaseTests.swift` (add terminal pin tests)

- [ ] **Step 1: Add terminal pin tests**

Read `Tests/TBDDaemonTests/DatabaseTests.swift` to check the existing pattern for creating test terminals and repos (look for `createAndListTerminals` or similar).

Add test functions following the existing patterns. The `repos.create` method requires `(path:displayName:defaultBranch:)` and `worktrees.create` requires `(repoID:name:branch:path:tmuxServer:)`. Terminals require `(worktreeID:tmuxWindowID:tmuxPaneID:)`.

```swift
@Test func terminalSetPinAndUnpin() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(path: "/tmp/test-term-pin", displayName: "Test", defaultBranch: "main")
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
        path: "/tmp/test-term-pin/.tbd/worktrees/test-wt", tmuxServer: "test"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1"
    )

    // Initially not pinned
    let initial = try await db.terminals.get(id: terminal.id)
    #expect(initial?.pinnedAt == nil)

    // Pin it
    try await db.terminals.setPin(id: terminal.id, pinned: true)
    let pinned = try await db.terminals.get(id: terminal.id)
    #expect(pinned?.pinnedAt != nil)

    // Unpin it
    try await db.terminals.setPin(id: terminal.id, pinned: false)
    let unpinned = try await db.terminals.get(id: terminal.id)
    #expect(unpinned?.pinnedAt == nil)
}

@Test func pinnedTerminalsOrderByPinnedAt() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(path: "/tmp/test-term-pin-order", displayName: "Test2", defaultBranch: "main")
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt-1", branch: "tbd/wt-1",
        path: "/tmp/test-term-pin-order/.tbd/worktrees/wt-1", tmuxServer: "test"
    )
    let t1 = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1"
    )
    let t2 = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2"
    )

    // Pin t2 first, then t1
    try await db.terminals.setPin(id: t2.id, pinned: true)
    try await Task.sleep(for: .milliseconds(10))
    try await db.terminals.setPin(id: t1.id, pinned: true)

    let all = try await db.terminals.list(worktreeID: wt.id)
    let pinned = all.filter { $0.pinnedAt != nil }
    let sorted = pinned.sorted { ($0.pinnedAt ?? Date.distantPast) < ($1.pinnedAt ?? Date.distantPast) }

    #expect(sorted.count == 2)
    #expect(sorted[0].id == t2.id) // pinned first
    #expect(sorted[1].id == t1.id) // pinned second
}
```

- [ ] **Step 2: Run tests**

Run: `cd /Users/chang/projects/tbd/.tbd/worktrees/20260326-comprehensive-bee && swift test 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/
git commit -m "test: add terminal pin/unpin database tests"
```
