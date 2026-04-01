# Manual Suspend/Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add manual suspend/resume controls for Claude terminals via sidebar context menu and terminal tab header buttons.

**Architecture:** Four new RPC methods (`terminal.suspend`, `terminal.resume`, `worktree.suspend`, `worktree.resume`) backed by new public methods on `SuspendResumeCoordinator`. Terminal-level RPCs are the primitive; worktree-level RPCs loop over them. UI adds a suspend/resume button to Claude terminal tab headers and new context menu items in the sidebar.

**Tech Stack:** Swift, SwiftUI, GRDB, tmux, Swift Testing

---

### Task 1: Add RPC Method Constants and Param Structs

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift:78-102` (RPCMethod enum)
- Modify: `Sources/TBDShared/RPCProtocol.swift:131-236` (param structs section)

- [ ] **Step 1: Add method constants to RPCMethod**

In `Sources/TBDShared/RPCProtocol.swift`, add after `worktreeSelectionChanged` (line 101):

```swift
public static let terminalSuspend = "terminal.suspend"
public static let terminalResume = "terminal.resume"
public static let worktreeSuspend = "worktree.suspend"
public static let worktreeResume = "worktree.resume"
```

- [ ] **Step 2: Add param structs**

In `Sources/TBDShared/RPCProtocol.swift`, add after `WorktreeSelectionChangedParams` (after line 236):

```swift
public struct TerminalSuspendParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct TerminalResumeParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct WorktreeSuspendParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct WorktreeResumeParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift
git commit -m "feat: add RPC method constants and param structs for manual suspend/resume"
```

---

### Task 2: Add `manualSuspend` and `manualResume` to SuspendResumeCoordinator

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift`
- Test: `Tests/TBDDaemonTests/SuspendResumeCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests for manualSuspend**

In `Tests/TBDDaemonTests/SuspendResumeCoordinatorTests.swift`, add two new tests:

```swift
@Test func manualSuspendSkipsAlreadySuspended() async throws {
    let (db, _, terminalID) = try await setupSuspendedTerminal()
    let tmux = TmuxManager(dryRun: true)
    let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

    // manualSuspend on already-suspended terminal should be a no-op
    let result = await coordinator.manualSuspend(terminalID: terminalID)
    #expect(result == .alreadySuspended)
}

@Test func manualSuspendRejectsNonClaudeTerminal() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "test-wt",
        branch: "main", path: "/tmp/test-repo",
        tmuxServer: "tbd-test"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
        label: "zsh"
    )
    let tmux = TmuxManager(dryRun: true)
    let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

    let result = await coordinator.manualSuspend(terminalID: terminal.id)
    #expect(result == .notClaudeTerminal)
}

@Test func manualResumeSkipsNonSuspended() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "test-wt",
        branch: "main", path: "/tmp/test-repo",
        tmuxServer: "tbd-test"
    )
    let terminal = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
        label: "claude-1", claudeSessionID: "session-abc"
    )
    let tmux = TmuxManager(dryRun: true)
    let coordinator = SuspendResumeCoordinator(db: db, tmux: tmux)

    let result = await coordinator.manualResume(terminalID: terminal.id)
    #expect(result == .notSuspended)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SuspendResumeCoordinator 2>&1 | tail -20`
Expected: FAIL — `manualSuspend` and `manualResume` don't exist yet

- [ ] **Step 3: Add ManualSuspendResult enum and public methods**

In `Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift`, add the result enum before the actor definition (before line 34):

```swift
public enum ManualSuspendResult: Equatable, Sendable {
    case ok
    case alreadySuspended
    case notClaudeTerminal
    case notFound
    case busy  // Claude didn't go idle within timeout
}

public enum ManualResumeResult: Equatable, Sendable {
    case ok
    case notSuspended
    case notFound
    case noSessionID
}
```

Inside the `SuspendResumeCoordinator` actor, add after the `responseCompleted` method (after line 57):

```swift
// MARK: - Manual Suspend/Resume

public func manualSuspend(terminalID: UUID) async -> ManualSuspendResult {
    guard let terminal = try? await db.terminals.get(id: terminalID) else {
        return .notFound
    }
    guard terminal.label?.hasPrefix("claude") == true else {
        return .notClaudeTerminal
    }
    guard terminal.suspendedAt == nil else {
        return .alreadySuspended
    }
    guard terminal.claudeSessionID != nil else {
        return .notClaudeTerminal
    }
    guard let server = await worktreeServer(for: terminal.worktreeID) else {
        return .notFound
    }

    // Cancel any in-flight operation for this terminal
    inFlight[terminal.id]?.cancel()

    // Wait for idle up to 10s (capture-pane only, skip hook requirement)
    var idle = false
    for _ in 0..<50 {
        if await detector.isIdle(server: server, paneID: terminal.tmuxPaneID) {
            idle = true
            break
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
    guard idle else {
        suspendLog("MANUAL SUSPEND ABORT \(terminal.id.uuidString.prefix(8)): still busy after 10s")
        return .busy
    }

    // Re-fetch terminal to verify it still exists and isn't suspended
    guard let freshTerminal = try? await db.terminals.get(id: terminalID),
          freshTerminal.suspendedAt == nil else {
        return .alreadySuspended
    }

    // Capture snapshot
    let snapshot: String?
    do {
        let captured = try await tmux.capturePaneWithAnsi(server: server, paneID: freshTerminal.tmuxPaneID)
        snapshot = captured.isEmpty ? nil : captured
    } catch {
        snapshot = nil
    }

    // Send /exit
    suspendLog("MANUAL SUSPENDING \(terminal.id.uuidString.prefix(8)): sending /exit")
    do {
        try await tmux.sendCommand(server: server, paneID: freshTerminal.tmuxPaneID, command: "/exit")
    } catch {
        return .notFound
    }

    // Verify exit: poll for up to 3s
    for _ in 0..<15 {
        try? await Task.sleep(for: .milliseconds(200))
        if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: freshTerminal.tmuxPaneID),
           !ClaudeStateDetector.isClaudeProcess(cmd) {
            break
        }
    }

    // Mark suspended
    do {
        try await db.terminals.setSuspended(id: terminal.id, sessionID: freshTerminal.claudeSessionID!, snapshot: snapshot)
        worktreeIdleFromHook.remove(freshTerminal.worktreeID)
    } catch {
        return .notFound
    }

    inFlight[terminal.id] = nil
    return .ok
}

public func manualResume(terminalID: UUID) async -> ManualResumeResult {
    guard let terminal = try? await db.terminals.get(id: terminalID) else {
        return .notFound
    }
    guard terminal.suspendedAt != nil else {
        return .notSuspended
    }
    guard let sessionID = terminal.claudeSessionID else {
        return .noSessionID
    }
    guard let server = await worktreeServer(for: terminal.worktreeID) else {
        return .notFound
    }

    // Cancel any in-flight operation for this terminal
    inFlight[terminal.id]?.cancel()

    // Reuse existing resume logic
    await resumeTerminal(terminal)
    return .ok
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SuspendResumeCoordinator 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift Tests/TBDDaemonTests/SuspendResumeCoordinatorTests.swift
git commit -m "feat: add manualSuspend and manualResume to SuspendResumeCoordinator"
```

---

### Task 3: Add RPC Handlers for Terminal and Worktree Suspend/Resume

**Files:**
- Create: `Sources/TBDDaemon/Server/RPCRouter+ManualSuspendHandlers.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift:50-103` (switch statement)

- [ ] **Step 1: Create the handler file**

Create `Sources/TBDDaemon/Server/RPCRouter+ManualSuspendHandlers.swift`:

```swift
import Foundation
import TBDShared

extension RPCRouter {

    func handleTerminalSuspend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalSuspendParams.self, from: paramsData)
        let result = await suspendResumeCoordinator.manualSuspend(terminalID: params.terminalID)
        switch result {
        case .ok, .alreadySuspended:
            return .ok()
        case .notClaudeTerminal:
            return RPCResponse(error: "Not a Claude terminal")
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        case .busy:
            return RPCResponse(error: "Claude is busy, try again later")
        }
    }

    func handleTerminalResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalResumeParams.self, from: paramsData)
        let result = await suspendResumeCoordinator.manualResume(terminalID: params.terminalID)
        switch result {
        case .ok, .notSuspended:
            return .ok()
        case .notFound:
            return RPCResponse(error: "Terminal not found")
        case .noSessionID:
            return RPCResponse(error: "No session ID to resume")
        }
    }

    func handleWorktreeSuspend(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSuspendParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

        let claudeTerminals = terminals.filter {
            $0.label?.hasPrefix("claude") == true && $0.suspendedAt == nil
        }

        await withTaskGroup(of: Void.self) { group in
            for terminal in claudeTerminals {
                group.addTask {
                    _ = await self.suspendResumeCoordinator.manualSuspend(terminalID: terminal.id)
                }
            }
        }

        return .ok()
    }

    func handleWorktreeResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeResumeParams.self, from: paramsData)
        guard let terminals = try? await db.terminals.list(worktreeID: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }

        let suspendedTerminals = terminals.filter { $0.suspendedAt != nil }

        await withTaskGroup(of: Void.self) { group in
            for terminal in suspendedTerminals {
                group.addTask {
                    _ = await self.suspendResumeCoordinator.manualResume(terminalID: terminal.id)
                }
            }
        }

        return .ok()
    }
}
```

- [ ] **Step 2: Wire handlers into RPCRouter switch**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add four cases before the `default:` case (before line 97):

```swift
case RPCMethod.terminalSuspend:
    return try await handleTerminalSuspend(request.paramsData)
case RPCMethod.terminalResume:
    return try await handleTerminalResume(request.paramsData)
case RPCMethod.worktreeSuspend:
    return try await handleWorktreeSuspend(request.paramsData)
case RPCMethod.worktreeResume:
    return try await handleWorktreeResume(request.paramsData)
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+ManualSuspendHandlers.swift Sources/TBDDaemon/Server/RPCRouter.swift
git commit -m "feat: add RPC handlers for manual terminal/worktree suspend/resume"
```

---

### Task 4: Add DaemonClient Methods for App

**Files:**
- Modify: `Sources/TBDApp/DaemonClient.swift:429-435` (after `worktreeSelectionChanged`)

- [ ] **Step 1: Add client methods**

In `Sources/TBDApp/DaemonClient.swift`, add after the `worktreeSelectionChanged` method (after line 435):

```swift
/// Manually suspend a single Claude terminal.
func terminalSuspend(terminalID: UUID) throws {
    try callVoid(
        method: RPCMethod.terminalSuspend,
        params: TerminalSuspendParams(terminalID: terminalID)
    )
}

/// Manually resume a single suspended terminal.
func terminalResume(terminalID: UUID) throws {
    try callVoid(
        method: RPCMethod.terminalResume,
        params: TerminalResumeParams(terminalID: terminalID)
    )
}

/// Suspend all Claude terminals in a worktree.
func worktreeSuspend(worktreeID: UUID) throws {
    try callVoid(
        method: RPCMethod.worktreeSuspend,
        params: WorktreeSuspendParams(worktreeID: worktreeID)
    )
}

/// Resume all suspended terminals in a worktree.
func worktreeResume(worktreeID: UUID) throws {
    try callVoid(
        method: RPCMethod.worktreeResume,
        params: WorktreeResumeParams(worktreeID: worktreeID)
    )
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/DaemonClient.swift
git commit -m "feat: add DaemonClient methods for manual suspend/resume"
```

---

### Task 5: Add Sidebar Context Menu Items

**Files:**
- Modify: `Sources/TBDApp/Sidebar/SidebarContextMenu.swift`

- [ ] **Step 1: Add suspend/resume menu items**

Replace the entire body of the `else` branch in `SidebarContextMenu.swift` (lines 25-45) with:

```swift
Button("Rename...") {
    onRename()
}

let terminals = appState.terminals[worktree.id] ?? []
let hasUnsuspendedClaude = terminals.contains {
    $0.label?.hasPrefix("claude") == true && $0.suspendedAt == nil
}
let hasSuspendedClaude = terminals.contains {
    $0.label?.hasPrefix("claude") == true && $0.suspendedAt != nil
}

if hasUnsuspendedClaude {
    Button("Suspend Claude") {
        let wtID = worktree.id
        Task {
            try? await appState.daemonClient.worktreeSuspend(worktreeID: wtID)
            await appState.refreshTerminals(worktreeID: wtID)
        }
    }
}

if hasSuspendedClaude {
    Button("Resume Claude") {
        let wtID = worktree.id
        Task {
            try? await appState.daemonClient.worktreeResume(worktreeID: wtID)
            await appState.refreshTerminals(worktreeID: wtID)
        }
    }
}

Button("Archive", role: .destructive) {
    let wtID = worktree.id
    Task {
        await appState.archiveWorktree(id: wtID)
    }
}

Divider()

Button("Open in Finder") {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
}

Button("Copy Path") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(worktree.path, forType: .string)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Sidebar/SidebarContextMenu.swift
git commit -m "feat: add Suspend/Resume Claude items to sidebar context menu"
```

---

### Task 6: Add Suspend/Resume Button to Terminal Tab Header

**Files:**
- Modify: `Sources/TBDApp/TabBar.swift:21-29` (Tab struct in TabBarItem)

The `TabBarItem` currently has no access to terminal state (it only knows `Tab`). We need to pass terminal suspend state through.

- [ ] **Step 1: Add suspend state and callbacks to TabBar**

In `Sources/TBDApp/TabBar.swift`, update the `TabBar` struct to accept suspend state:

```swift
struct TabBar: View {
    let tabs: [Tab]
    @Binding var activeTabIndex: Int
    var onAddTab: () -> Void
    var onCloseTab: (Int) -> Void
    /// Map from tab ID to Terminal for Claude terminals (nil for non-terminal tabs)
    var terminalForTab: (UUID) -> Terminal?
    var onSuspendTab: (UUID) -> Void
    var onResumeTab: (UUID) -> Void
```

Update the `TabBarItem` instantiation inside `TabBar.body` (around line 23) to pass the new properties:

```swift
TabBarItem(
    tab: tab,
    index: index,
    isSelected: index == activeTabIndex,
    terminal: terminalForTab(tab.id),
    onSelect: { activeTabIndex = index },
    onClose: { onCloseTab(index) },
    onSuspend: { onSuspendTab(tab.id) },
    onResume: { onResumeTab(tab.id) }
)
```

- [ ] **Step 2: Add suspend button to TabBarItem**

Update the `TabBarItem` struct to accept terminal state:

```swift
private struct TabBarItem: View {
    let tab: Tab
    let index: Int
    let isSelected: Bool
    let terminal: Terminal?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onSuspend: () -> Void
    let onResume: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @State private var isHoveringSuspend = false
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false
```

Add the `isClaudeTerminal` and `isSuspended` computed properties:

```swift
private var isClaudeTerminal: Bool {
    guard let terminal else { return false }
    return terminal.label?.hasPrefix("claude") == true
}

private var isSuspended: Bool {
    terminal?.suspendedAt != nil
}
```

In the `TabBarItem.body` HStack, add the suspend button after the sidebar toggle block and before the type icon (before line 115 `// Type icon`):

```swift
// Suspend/resume button for Claude terminals
if isClaudeTerminal {
    Button(action: isSuspended ? onResume : onSuspend) {
        Image(systemName: isSuspended ? "play.circle" : "pause.circle")
            .font(.system(size: 10))
            .foregroundStyle(isHoveringSuspend ? .primary : .secondary)
            .frame(width: 16, height: 16)
            .background(
                Circle()
                    .fill(Color.primary.opacity(isHoveringSuspend ? 0.12 : 0))
            )
            .onHover { hovering in
                isHoveringSuspend = hovering
            }
    }
    .buttonStyle(.plain)
    .opacity(showClose ? 1 : 0)
    .animation(.easeInOut(duration: 0.12), value: showClose)
    .help(isSuspended ? "Resume Claude" : "Suspend Claude")
    .padding(.trailing, 2)
}
```

Update the tab icon to show suspended state — replace the `tabIcon` computed property:

```swift
private var tabIcon: String {
    switch tab.content {
    case .terminal:
        return isSuspended ? "moon.zzz" : "terminal"
    case .webview: return "globe"
    case .codeViewer: return "doc.text"
    }
}
```

Update the tab label foreground style to dim when suspended — in the `Text(tabLabel)` modifier, change `.foregroundStyle(isSelected ? .primary : .secondary)` to:

```swift
.foregroundStyle(isSuspended ? .tertiary : (isSelected ? .primary : .secondary))
```

- [ ] **Step 3: Update TerminalContainerView to pass new TabBar props**

In `Sources/TBDApp/Terminal/TerminalContainerView.swift`, find the `TabBar(` call (around line 95) and add the new parameters:

```swift
TabBar(
    tabs: tabs,
    activeTabIndex: $activeTabIndex,
    onAddTab: {
        Task {
            await appState.createTerminal(worktreeID: worktreeID)
            let newCount = appState.tabs[worktreeID]?.count ?? 0
            if newCount > 0 {
                activeTabIndex = newCount - 1
            }
        }
    },
    onCloseTab: { index in
        closeTab(at: index)
    },
    terminalForTab: { tabID in
        if case .terminal(let terminalID) = appState.tabs[worktreeID]?.first(where: { $0.id == tabID })?.content {
            return appState.terminals[worktreeID]?.first { $0.id == terminalID }
        }
        return nil
    },
    onSuspendTab: { tabID in
        if case .terminal(let terminalID) = appState.tabs[worktreeID]?.first(where: { $0.id == tabID })?.content {
            Task {
                try? await appState.daemonClient.terminalSuspend(terminalID: terminalID)
                await appState.refreshTerminals(worktreeID: worktreeID)
            }
        }
    },
    onResumeTab: { tabID in
        if case .terminal(let terminalID) = appState.tabs[worktreeID]?.first(where: { $0.id == tabID })?.content {
            Task {
                try? await appState.daemonClient.terminalResume(terminalID: terminalID)
                await appState.refreshTerminals(worktreeID: worktreeID)
            }
        }
    }
)
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/TabBar.swift Sources/TBDApp/Terminal/TerminalContainerView.swift
git commit -m "feat: add suspend/resume button to Claude terminal tab headers"
```

---

### Task 7: Add "Suspended" Badge Overlay to Terminal Content

**Files:**
- Modify: `Sources/TBDApp/Terminal/TerminalPanelView.swift` (the view that shows terminal content / snapshot)

- [ ] **Step 1: Explore current snapshot display**

Read `Sources/TBDApp/Terminal/TerminalPanelView.swift` to understand how the frozen snapshot is currently rendered when `suspendedAt != nil`. The view identity already includes `tmuxWindowID` (per PR #48), so the snapshot is shown automatically. We just need to add a badge.

- [ ] **Step 2: Add "Suspended" badge overlay**

Find the view that renders the suspended snapshot in `TerminalPanelView.swift`. Add an overlay with a "Suspended" label:

```swift
.overlay(alignment: .topTrailing) {
    if terminal.suspendedAt != nil {
        Text("Suspended")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(8)
    }
}
```

The exact placement depends on what `TerminalPanelView` looks like — adapt to the existing structure. The overlay should sit on top of the snapshot content, top-trailing corner.

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Terminal/TerminalPanelView.swift
git commit -m "feat: add Suspended badge overlay on frozen terminal snapshot"
```

---

### Task 8: Run Full Test Suite and Verify

**Files:** None (verification only)

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 2: Build the app target specifically**

Run: `swift build --target TBDApp 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Final commit if any fixups needed**

If any fixes were required, commit them with an appropriate message.
