# Conductor UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Guake-style toggleable conductor terminal overlay to TBDApp with navigation suggestions and hotkey support.

**Architecture:** SwiftUI `.overlay(alignment: .top)` on the main content area renders the conductor's terminal. Conductor lifecycle (setup/start/stop) triggered from a toolbar button. Navigation suggestions flow via polling `conductor.list` (which gains an in-memory `suggestion` field). Local `NSEvent` monitor handles Opt+. hotkey.

**Tech Stack:** SwiftUI, SwiftTerm, NSEvent, TBDShared RPC protocol, GRDB

**Spec:** `docs/superpowers/specs/2026-04-04-conductor-ui-design.md`

---

### Task 1: Add suggestion field to Conductor model + RPC

**Files:**
- Modify: `Sources/TBDShared/ConductorModels.swift`
- Modify: `Sources/TBDShared/RPCProtocol.swift:119-120,364-396`
- Modify: `Sources/TBDDaemon/Conductor/ConductorManager.swift`
- Modify: `Sources/TBDDaemon/Conductor/ConductorStore.swift:34-58`
- Modify: `Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift:136`
- Test: `Tests/TBDDaemonTests/ConductorManagerTests.swift`

- [ ] **Step 1: Add `ConductorSuggestion` to shared models and optional field to `Conductor`**

In `Sources/TBDShared/ConductorModels.swift`, add the suggestion struct and an optional field:

```swift
public struct ConductorSuggestion: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let worktreeName: String
    public let label: String?

    public init(worktreeID: UUID, worktreeName: String, label: String? = nil) {
        self.worktreeID = worktreeID
        self.worktreeName = worktreeName
        self.label = label
    }
}
```

Add to `Conductor` struct (after `createdAt`):

```swift
public var suggestion: ConductorSuggestion?
```

Add the parameter to the `init` with default `nil`:

```swift
suggestion: ConductorSuggestion? = nil
```

- [ ] **Step 2: Add RPC method constants and param structs**

In `Sources/TBDShared/RPCProtocol.swift`, add after `conductorStatus` (line 118):

```swift
public static let conductorSuggest = "conductor.suggest"
public static let conductorClearSuggestion = "conductor.clearSuggestion"
```

Add param structs after the existing conductor section (~line 396):

```swift
public struct ConductorSuggestParams: Codable, Sendable {
    public let name: String
    public let worktreeID: UUID
    public let label: String?
    public init(name: String, worktreeID: UUID, label: String? = nil) {
        self.name = name; self.worktreeID = worktreeID; self.label = label
    }
}
```

`conductor.clearSuggestion` reuses existing `ConductorNameParams`.

- [ ] **Step 3: Add in-memory suggestion state to ConductorManager**

In `Sources/TBDDaemon/Conductor/ConductorManager.swift`, add a thread-safe suggestions dict. Since `ConductorManager` is `Sendable` (not an actor), use `OSAllocatedUnfairLock`:

```swift
import os

// Add as property:
private let _suggestions = OSAllocatedUnfairLock(initialState: [String: ConductorSuggestion]())

public func suggest(name: String, worktreeID: UUID, worktreeName: String, label: String?) async throws {
    guard let _ = try await db.conductors.get(name: name) else {
        throw ConductorError.notFound(name: name)
    }
    let suggestion = ConductorSuggestion(worktreeID: worktreeID, worktreeName: worktreeName, label: label)
    _suggestions.withLock { $0[name] = suggestion }
}

public func clearSuggestion(name: String) async throws {
    guard let _ = try await db.conductors.get(name: name) else {
        throw ConductorError.notFound(name: name)
    }
    _suggestions.withLock { $0.removeValue(forKey: name) }
}

public func suggestion(for name: String) -> ConductorSuggestion? {
    _suggestions.withLock { $0[name] }
}
```

- [ ] **Step 4: Update `handleConductorList` and `handleConductorStatus` to include suggestions**

In `Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift`, modify `handleConductorList`:

```swift
func handleConductorList() async throws -> RPCResponse {
    var conductors = try await db.conductors.list()
    for i in conductors.indices {
        conductors[i].suggestion = conductorManager.suggestion(for: conductors[i].name)
    }
    return try RPCResponse(result: ConductorListResult(conductors: conductors))
}
```

Similarly in `handleConductorStatus`, add before the return:

```swift
var conductor = conductor  // make mutable
conductor.suggestion = conductorManager.suggestion(for: conductor.name)
```

- [ ] **Step 5: Add suggest/clearSuggestion RPC handlers**

In `Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift`:

```swift
func handleConductorSuggest(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(ConductorSuggestParams.self, from: paramsData)
    // Look up worktree name for the suggestion
    let worktreeName: String
    if let wt = try await db.worktrees.get(id: params.worktreeID) {
        worktreeName = wt.displayName
    } else {
        return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
    }
    try await conductorManager.suggest(
        name: params.name,
        worktreeID: params.worktreeID,
        worktreeName: worktreeName,
        label: params.label
    )
    return .ok()
}

func handleConductorClearSuggestion(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
    try await conductorManager.clearSuggestion(name: params.name)
    return .ok()
}
```

- [ ] **Step 6: Route the new methods in RPCRouter**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add before the `default:` case (~line 136):

```swift
case RPCMethod.conductorSuggest:
    return try await handleConductorSuggest(request.paramsData)
case RPCMethod.conductorClearSuggestion:
    return try await handleConductorClearSuggestion(request.paramsData)
```

- [ ] **Step 7: Update ConductorStore.toModel() to handle the new optional field**

The `suggestion` field is in-memory only (not stored in DB), so `ConductorStore.toModel()` already returns `nil` for it by default (since `Conductor.init` defaults `suggestion` to `nil`). No store changes needed.

- [ ] **Step 8: Write tests**

In `Tests/TBDDaemonTests/ConductorManagerTests.swift`, add:

```swift
@Test func suggestAndClearSuggestion() async throws {
    let db = try makeDB()
    let tmux = TmuxManager(dryRun: true)
    let manager = ConductorManager(db: db, tmux: tmux)

    let conductor = try await manager.setup(name: "test-suggest", repos: ["*"])
    defer { try? FileManager.default.removeItem(at: TBDConstants.conductorsDir.appendingPathComponent("test-suggest")) }

    // Create a worktree to suggest
    let wt = try await db.worktrees.create(
        repoID: TBDConstants.conductorsRepoID,
        name: "fake-wt",
        branch: "main",
        path: "/tmp/fake",
        tmuxServer: "test",
        status: .active
    )

    // No suggestion initially
    #expect(manager.suggestion(for: "test-suggest") == nil)

    // Set suggestion
    try await manager.suggest(name: "test-suggest", worktreeID: wt.id, worktreeName: "fake-wt", label: "waiting")
    let s = manager.suggestion(for: "test-suggest")
    #expect(s?.worktreeID == wt.id)
    #expect(s?.label == "waiting")

    // Overwrite suggestion
    try await manager.suggest(name: "test-suggest", worktreeID: wt.id, worktreeName: "fake-wt", label: "new label")
    #expect(manager.suggestion(for: "test-suggest")?.label == "new label")

    // Clear
    try await manager.clearSuggestion(name: "test-suggest")
    #expect(manager.suggestion(for: "test-suggest") == nil)
}

@Test func suggestForNonexistentConductorFails() async throws {
    let db = try makeDB()
    let tmux = TmuxManager(dryRun: true)
    let manager = ConductorManager(db: db, tmux: tmux)

    do {
        try await manager.suggest(name: "nope", worktreeID: UUID(), worktreeName: "x", label: nil)
        Issue.record("Expected not found error")
    } catch {
        #expect(error.localizedDescription.contains("not found"))
    }
}
```

- [ ] **Step 9: Run tests**

Run: `swift test --filter ConductorManagerTests`
Expected: All tests pass including the new suggestion tests.

- [ ] **Step 10: Commit**

```bash
git add Sources/TBDShared/ConductorModels.swift Sources/TBDShared/RPCProtocol.swift \
  Sources/TBDDaemon/Conductor/ConductorManager.swift Sources/TBDDaemon/Server/RPCRouter.swift \
  Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift \
  Tests/TBDDaemonTests/ConductorManagerTests.swift
git commit -m "feat: add conductor.suggest/clearSuggestion RPC with in-memory state"
```

---

### Task 2: Add suggest/clear-suggestion CLI commands

**Files:**
- Modify: `Sources/TBDCLI/Commands/ConductorCommands.swift`

- [ ] **Step 1: Add ConductorSuggest subcommand**

In `Sources/TBDCLI/Commands/ConductorCommands.swift`, add to the `subcommands` array in `ConductorCommand.configuration`:

```swift
ConductorSuggestCmd.self,
ConductorClearSuggestionCmd.self,
```

Then add the command structs:

```swift
// MARK: - conductor suggest

struct ConductorSuggestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: "Set a navigation suggestion for the UI"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Option(name: .long, help: "Worktree ID to suggest navigating to")
    var worktree: String

    @Option(name: .long, help: "Optional label (e.g. 'waiting for input')")
    var label: String?

    mutating func run() async throws {
        guard let worktreeID = UUID(uuidString: worktree) else {
            print("Error: invalid worktree UUID: \(worktree)")
            throw ExitCode.failure
        }
        let client = SocketClient()
        let response = try client.call(RPCRequest(
            method: RPCMethod.conductorSuggest,
            params: ConductorSuggestParams(name: name, worktreeID: worktreeID, label: label)
        ))
        if !response.success {
            print("Error: \(response.error ?? "unknown")")
            throw ExitCode.failure
        }
        print("Suggestion set for conductor '\(name)'")
    }
}

// MARK: - conductor clear-suggestion

struct ConductorClearSuggestionCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-suggestion",
        abstract: "Clear the navigation suggestion"
    )

    @Argument(help: "Conductor name")
    var name: String

    mutating func run() async throws {
        let client = SocketClient()
        let response = try client.call(RPCRequest(
            method: RPCMethod.conductorClearSuggestion,
            params: ConductorNameParams(name: name)
        ))
        if !response.success {
            print("Error: \(response.error ?? "unknown")")
            throw ExitCode.failure
        }
        print("Suggestion cleared for conductor '\(name)'")
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDCLI/Commands/ConductorCommands.swift
git commit -m "feat: add conductor suggest/clear-suggestion CLI commands"
```

---

### Task 3: Add conductor polling to AppState + DaemonClient

**Files:**
- Modify: `Sources/TBDApp/DaemonClient.swift`
- Modify: `Sources/TBDApp/AppState.swift`

- [ ] **Step 1: Add `listConductors` to DaemonClient**

In `Sources/TBDApp/DaemonClient.swift`, add after the existing conductor-related methods (or at the end of the MARK sections):

```swift
// MARK: - Conductors

/// List all conductors.
func listConductors() throws -> [Conductor] {
    let result = try callNoParams(method: RPCMethod.conductorList, resultType: ConductorListResult.self)
    return result.conductors
}

/// Set up a new conductor with defaults.
func conductorSetup(name: String, repos: [String] = ["*"]) throws -> Conductor {
    return try call(
        method: RPCMethod.conductorSetup,
        params: ConductorSetupParams(name: name, repos: repos),
        resultType: Conductor.self
    )
}

/// Start a conductor.
func conductorStart(name: String) throws -> Terminal {
    return try call(
        method: RPCMethod.conductorStart,
        params: ConductorNameParams(name: name),
        resultType: Terminal.self
    )
}

/// Stop a conductor.
func conductorStop(name: String) throws {
    try callVoid(
        method: RPCMethod.conductorStop,
        params: ConductorNameParams(name: name)
    )
}

/// Teardown (remove) a conductor.
func conductorTeardown(name: String) throws {
    try callVoid(
        method: RPCMethod.conductorTeardown,
        params: ConductorNameParams(name: name)
    )
}
```

- [ ] **Step 2: Add conductor state properties to AppState**

In `Sources/TBDApp/AppState.swift`, add after the `prStatuses` property (~line 67):

```swift
/// Conductor for each repo (wildcard conductors expanded across all repos).
@Published var conductorsByRepo: [UUID: Conductor] = [:]
/// The conductor's terminal record, keyed by repo ID.
@Published var conductorTerminalsByRepo: [UUID: Terminal] = [:]
/// Current navigation suggestion from any conductor.
@Published var conductorSuggestion: ConductorSuggestion? = nil
/// Whether the conductor overlay is visible.
@Published var showConductor: Bool = false
/// Conductor overlay height — persisted.
@Published var conductorHeight: CGFloat = 300 {
    didSet { UserDefaults.standard.set(Double(conductorHeight), forKey: "com.tbd.app.conductorHeight") }
}
```

Add to `init()` after the dockRatio restoration (~line 91):

```swift
if let savedHeight = UserDefaults.standard.object(forKey: "com.tbd.app.conductorHeight") as? Double {
    conductorHeight = max(100, min(800, CGFloat(savedHeight)))
}
```

- [ ] **Step 3: Add `refreshConductors()` and wire into poll cycle**

In `Sources/TBDApp/AppState.swift`, add after `refreshNotifications()`:

```swift
/// Refresh conductor state from the daemon.
func refreshConductors() async {
    do {
        let conductors = try await daemonClient.listConductors()

        // Build conductorsByRepo: expand ["*"] conductors across all repo IDs
        var byRepo: [UUID: Conductor] = [:]
        var termByRepo: [UUID: Terminal] = [:]
        let repoIDs = repos.map(\.id)

        for conductor in conductors {
            let matchingRepoIDs: [UUID]
            if conductor.repos.contains("*") {
                matchingRepoIDs = repoIDs
            } else {
                matchingRepoIDs = conductor.repos.compactMap { UUID(uuidString: $0) }
            }
            for repoID in matchingRepoIDs {
                if byRepo[repoID] == nil {  // first match wins
                    byRepo[repoID] = conductor
                    // Find the conductor's terminal in the terminals dict
                    if let termID = conductor.terminalID,
                       let wtID = conductor.worktreeID,
                       let term = terminals[wtID]?.first(where: { $0.id == termID }) {
                        termByRepo[repoID] = term
                    }
                }
            }
        }

        if byRepo != conductorsByRepo { conductorsByRepo = byRepo }
        if termByRepo != conductorTerminalsByRepo { conductorTerminalsByRepo = termByRepo }

        // Update suggestion from the conductor matching the current selection
        let newSuggestion: ConductorSuggestion? = {
            guard let selectedID = selectedWorktreeIDs.first,
                  let selectedWt = worktrees.values.flatMap({ $0 }).first(where: { $0.id == selectedID }),
                  let conductor = byRepo[selectedWt.repoID] else { return nil }
            return conductor.suggestion
        }()
        if newSuggestion != conductorSuggestion { conductorSuggestion = newSuggestion }
    } catch {
        // Don't log connection errors for conductors — they're not critical
    }
}
```

Add computed properties:

```swift
/// The conductor for the repo of the currently selected worktree.
var currentConductor: Conductor? {
    guard let selectedID = selectedWorktreeIDs.first,
          let selectedWt = worktrees.values.flatMap({ $0 }).first(where: { $0.id == selectedID }) else { return nil }
    return conductorsByRepo[selectedWt.repoID]
}

/// Whether a conductor is active (exists and has a terminal) for the current repo.
var conductorActive: Bool {
    guard let conductor = currentConductor else { return false }
    return conductor.terminalID != nil
}

/// The conductor's terminal for the currently selected repo.
var currentConductorTerminal: Terminal? {
    guard let selectedID = selectedWorktreeIDs.first,
          let selectedWt = worktrees.values.flatMap({ $0 }).first(where: { $0.id == selectedID }) else { return nil }
    return conductorTerminalsByRepo[selectedWt.repoID]
}
```

Wire into `refreshAll()`:

```swift
func refreshAll() async {
    await refreshRepos()
    await refreshWorktrees()
    await refreshNotifications()
    await refreshConductors()
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/DaemonClient.swift Sources/TBDApp/AppState.swift
git commit -m "feat: add conductor polling to AppState with repo-scoped lookup"
```

---

### Task 4: Build ConductorOverlayView + ConductorSuggestionBar

**Files:**
- Create: `Sources/TBDApp/Conductor/ConductorOverlayView.swift`
- Create: `Sources/TBDApp/Conductor/ConductorSuggestionBar.swift`

- [ ] **Step 1: Create ConductorOverlayView**

Create `Sources/TBDApp/Conductor/ConductorOverlayView.swift`:

```swift
import SwiftUI
import TBDShared

struct ConductorOverlayView: View {
    @EnvironmentObject var appState: AppState
    let terminal: Terminal
    let tmuxServer: String

    @State private var dragStartHeight: CGFloat = 0
    @State private var dragIndicatorOffset: CGFloat? = nil

    private let minHeight: CGFloat = 100

    var body: some View {
        GeometryReader { geometry in
            let maxHeight = geometry.size.height * 0.8

            VStack(spacing: 0) {
                // Terminal
                TerminalPanelView(
                    terminalID: terminal.id,
                    tmuxServer: tmuxServer,
                    tmuxWindowID: terminal.tmuxWindowID,
                    tmuxBridge: appState.tmuxBridge
                )
                .frame(height: appState.conductorHeight)
                .clipped()

                // Drag handle
                ZStack {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)

                    if let offset = dragIndicatorOffset {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .offset(y: offset)
                    }
                }
                .frame(height: 4)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartHeight == 0 { dragStartHeight = appState.conductorHeight }
                            let proposed = dragStartHeight + value.translation.height
                            let clamped = max(minHeight, min(maxHeight, proposed))
                            dragIndicatorOffset = clamped - appState.conductorHeight
                        }
                        .onEnded { value in
                            let proposed = dragStartHeight + value.translation.height
                            appState.conductorHeight = max(minHeight, min(maxHeight, proposed))
                            dragStartHeight = 0
                            dragIndicatorOffset = nil
                        }
                )

                // Suggestion bar (conditional)
                if let suggestion = appState.conductorSuggestion {
                    ConductorSuggestionBar(suggestion: suggestion)
                }
            }
            .background(.ultraThinMaterial)
        }
    }
}
```

- [ ] **Step 2: Create ConductorSuggestionBar**

Create `Sources/TBDApp/Conductor/ConductorSuggestionBar.swift`:

```swift
import SwiftUI
import TBDShared

struct ConductorSuggestionBar: View {
    @EnvironmentObject var appState: AppState
    let suggestion: ConductorSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 12))

            Text(suggestion.worktreeName)
                .fontWeight(.medium)
                .font(.caption)

            if let label = suggestion.label {
                Text("— \(label)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()

            Button("Go") {
                navigateToSuggestion()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                appState.conductorSuggestion = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func navigateToSuggestion() {
        appState.selectedWorktreeIDs = [suggestion.worktreeID]
        appState.conductorSuggestion = nil
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Conductor/ConductorOverlayView.swift \
  Sources/TBDApp/Conductor/ConductorSuggestionBar.swift
git commit -m "feat: add ConductorOverlayView and ConductorSuggestionBar"
```

---

### Task 5: Add hotkey monitor

**Files:**
- Create: `Sources/TBDApp/Conductor/ConductorHotkeyMonitor.swift`

- [ ] **Step 1: Create the hotkey monitor**

Create `Sources/TBDApp/Conductor/ConductorHotkeyMonitor.swift`:

```swift
import AppKit

/// Monitors local key events for the conductor toggle hotkey (Opt+.).
/// Only fires when TBD is the active app.
final class ConductorHotkeyMonitor {
    private var monitor: Any?

    /// Install the local event monitor. Call once at app startup.
    /// The `toggle` closure is called on the main thread when the hotkey fires.
    func install(toggle: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Opt+. : modifiers = option, keyCode 47 = period
            if event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               event.keyCode == 47 {
                toggle()
                return nil  // consume the event
            }
            return event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        uninstall()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Conductor/ConductorHotkeyMonitor.swift
git commit -m "feat: add ConductorHotkeyMonitor for Opt+. toggle"
```

---

### Task 6: Integrate overlay + toggle + hotkey into ContentView

**Files:**
- Modify: `Sources/TBDApp/ContentView.swift`
- Modify: `Sources/TBDApp/AppState.swift` (minor — add conductor name derivation helper)

- [ ] **Step 1: Add conductor name derivation helper to AppState**

In `Sources/TBDApp/AppState.swift`, add a helper (e.g., after the computed properties added in Task 3):

```swift
/// Derive a conductor name from a repo's display name.
/// Lowercases, replaces non-alphanumeric chars with hyphens, trims leading/trailing hyphens.
static func conductorName(from repoName: String) -> String {
    let cleaned = repoName
        .lowercased()
        .replacing(/[^a-z0-9]+/, with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let truncated = String(cleaned.prefix(64))
    return truncated.isEmpty ? "conductor" : truncated
}
```

- [ ] **Step 2: Add one-click conductor setup/start method to AppState**

In `Sources/TBDApp/AppState.swift`:

```swift
/// One-click conductor: setup (if needed) + start + show overlay.
func ensureConductorRunning() async {
    guard let selectedID = selectedWorktreeIDs.first,
          let selectedWt = worktrees.values.flatMap({ $0 }).first(where: { $0.id == selectedID }) else { return }
    let repoID = selectedWt.repoID

    do {
        if let existing = conductorsByRepo[repoID] {
            // Conductor exists — start it if not running
            if existing.terminalID == nil {
                _ = try await daemonClient.conductorStart(name: existing.name)
            }
        } else {
            // No conductor — setup + start
            guard let repo = repos.first(where: { $0.id == repoID }) else { return }
            let name = Self.conductorName(from: repo.displayName)
            _ = try await daemonClient.conductorSetup(name: name, repos: [repoID.uuidString])
            _ = try await daemonClient.conductorStart(name: name)
        }
        await refreshConductors()
        showConductor = true
    } catch {
        showAlert("Conductor error: \(error.localizedDescription)", isError: true)
    }
}
```

- [ ] **Step 3: Modify ContentView to add overlay and toolbar button**

In `Sources/TBDApp/ContentView.swift`, add a `@StateObject` for the hotkey monitor and set it up. Then add the overlay to the content branch and the toolbar button.

Add at the top of `ContentView`:

```swift
@State private var conductorHotkeyMonitor = ConductorHotkeyMonitor()
```

Wrap the `HStack` content branch (lines 31-42) with the overlay. Replace:

```swift
HStack(spacing: 0) {
    TerminalContainerView()
    if showFilePanel, let worktree = selectedWorktree, !worktree.path.isEmpty {
        FilePanelDivider(panelWidth: Binding(
            get: { CGFloat(filePanelWidth) },
            set: { filePanelWidth = Double($0) }
        ))
        FileViewerPanel(worktree: worktree)
            .frame(width: CGFloat(filePanelWidth))
            .id(worktree.id)
    }
}
```

With:

```swift
HStack(spacing: 0) {
    TerminalContainerView()
    if showFilePanel, let worktree = selectedWorktree, !worktree.path.isEmpty {
        FilePanelDivider(panelWidth: Binding(
            get: { CGFloat(filePanelWidth) },
            set: { filePanelWidth = Double($0) }
        ))
        FileViewerPanel(worktree: worktree)
            .frame(width: CGFloat(filePanelWidth))
            .id(worktree.id)
    }
}
.overlay(alignment: .top) {
    if appState.showConductor,
       let terminal = appState.currentConductorTerminal {
        ConductorOverlayView(
            terminal: terminal,
            tmuxServer: TBDConstants.conductorsTmuxServer
        )
    }
}
```

Add the toolbar button in the `ToolbarItemGroup`, after the auto-suspend button (after line 58):

```swift
// Conductor toggle
Button {
    if appState.conductorActive {
        appState.showConductor.toggle()
    } else {
        Task { await appState.ensureConductorRunning() }
    }
} label: {
    Image(systemName: appState.conductorActive
        ? (appState.showConductor ? "wand.and.stars" : "wand.and.stars.inverse")
        : "wand.and.stars.inverse")
        .foregroundStyle(appState.showConductor ? .primary : .secondary)
}
.help(appState.conductorActive
    ? (appState.showConductor ? "Hide conductor (⌥.)" : "Show conductor (⌥.)")
    : "Start conductor (⌥.)")
.contextMenu {
    if appState.conductorActive, let conductor = appState.currentConductor {
        Button("Stop Conductor") {
            Task {
                try? await appState.daemonClient.conductorStop(name: conductor.name)
                appState.showConductor = false
                await appState.refreshConductors()
            }
        }
        Button("Remove Conductor", role: .destructive) {
            Task {
                try? await appState.daemonClient.conductorTeardown(name: conductor.name)
                appState.showConductor = false
                await appState.refreshConductors()
            }
        }
    }
}
```

Install the hotkey monitor. Add `.onAppear` to the outermost `VStack` (after `.alert`):

```swift
.onAppear {
    conductorHotkeyMonitor.install { [weak appState] in
        guard let appState else { return }
        if appState.conductorActive {
            appState.showConductor.toggle()
        } else {
            Task { await appState.ensureConductorRunning() }
        }
    }
}
```

- [ ] **Step 4: Add TBDConstants.conductorsTmuxServer to TBDShared if not accessible from app**

Check if `TBDConstants.conductorsTmuxServer` is accessible from the app target. It's in `Sources/TBDShared/Constants.swift`. Verify it's `public`. If not, make it public.

- [ ] **Step 5: Verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDApp/ContentView.swift Sources/TBDApp/AppState.swift
git commit -m "feat: integrate conductor overlay, toolbar toggle, and Opt+. hotkey"
```

---

### Task 7: Update conductor CLAUDE.md template with suggest commands

**Files:**
- Modify: `Sources/TBDDaemon/Conductor/ConductorManager.swift`

- [ ] **Step 1: Add suggest commands to the template**

In `Sources/TBDDaemon/Conductor/ConductorManager.swift`, in the `generateTemplate` method, add before the `## Terminal States` section:

```swift
## Navigation Suggestions

When discussing a specific worktree, help the user navigate to it:

| Command | Description |
|---------|-------------|
| `tbd conductor suggest \(name) --worktree <id>` | Show a "Go to" pill in the UI |
| `tbd conductor suggest \(name) --worktree <id> --label "waiting for input"` | With context label |
| `tbd conductor clear-suggestion \(name)` | Remove the pill |

Set a suggestion when surfacing info about a worktree. Clear it when moving on
to a different topic or when the user has acknowledged it.
```

Also add the commands to the CLI table in the template:

```swift
| `tbd conductor suggest \(name) --worktree <id> [--label "text"]` | Show navigation pill in UI |
| `tbd conductor clear-suggestion \(name)` | Clear navigation pill |
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Run existing template test**

Run: `swift test --filter templateContainsConductorName`
Expected: PASS. Update the test to also check for suggest commands:

In `Tests/TBDDaemonTests/ConductorManagerTests.swift`, modify `templateContainsConductorName`:

```swift
@Test func templateContainsConductorName() async throws {
    let template = ConductorManager.generateTemplate(
        name: "my-conductor",
        repos: ["*"]
    )
    #expect(template.contains("Conductor: my-conductor"))
    #expect(template.contains("tbd terminal output"))
    #expect(template.contains("tbd conductor suggest my-conductor"))
    #expect(template.contains("tbd conductor clear-suggestion my-conductor"))
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ConductorManagerTests`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Conductor/ConductorManager.swift \
  Tests/TBDDaemonTests/ConductorManagerTests.swift
git commit -m "feat: add suggest/clear-suggestion commands to conductor CLAUDE.md template"
```

---

### Task 8: Final build + test + manual verification

**Files:** None new — verification only.

- [ ] **Step 1: Full build**

Run: `swift build`
Expected: Build succeeds with no warnings related to conductor code.

- [ ] **Step 2: Run all tests**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 3: Commit if any fixups were needed**

Only commit if steps 1 or 2 required changes.
