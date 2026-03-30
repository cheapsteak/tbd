# Auto-suspend/resume Claude Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-suspend idle Claude Code instances when switching worktrees and resume them when switching back, freeing 500MB–1GB per idle instance.

**Architecture:** Daemon-driven lifecycle management. App sends selection changes via RPC; daemon detects idle Claude instances, exits them gracefully, and recreates tmux windows on resume. `SuspendResumeCoordinator` actor serializes all operations with cancellation semantics.

**Tech Stack:** Swift, GRDB (SQLite), tmux, SwiftUI (NSViewRepresentable), Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-03-29-auto-suspend-claude-design.md`

---

### Task 1: Database migration and model updates

**Files:**
- Modify: `Sources/TBDDaemon/Database/Database.swift` (add migration v6)
- Modify: `Sources/TBDDaemon/Database/TerminalStore.swift` (add fields + new methods)
- Modify: `Sources/TBDShared/Models.swift` (add fields to Terminal)
- Test: `Tests/TBDDaemonTests/DatabaseTests.swift`

- [ ] **Step 1: Write failing test for new Terminal fields**

```swift
@Test func terminalSuspendFields() async throws {
    let db = try TBDDatabase(writer: DatabaseQueue())
    let repo = try await db.repos.create(path: "/tmp/test-repo")
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "test", branch: "main",
        path: "/tmp/test-repo/.tbd/worktrees/test", tmuxServer: "tbd-test"
    )

    // Create terminal with new fields
    let terminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@1", tmuxPaneID: "%1",
        label: "claude",
        claudeSessionID: "abc-123"
    )
    #expect(terminal.claudeSessionID == "abc-123")
    #expect(terminal.suspendedAt == nil)

    // Set suspended
    try await db.terminals.setSuspended(id: terminal.id, sessionID: "abc-123")
    let updated = try await db.terminals.get(id: terminal.id)
    #expect(updated?.suspendedAt != nil)
    #expect(updated?.claudeSessionID == "abc-123")

    // Clear suspended
    try await db.terminals.clearSuspended(id: terminal.id)
    let cleared = try await db.terminals.get(id: terminal.id)
    #expect(cleared?.suspendedAt == nil)

    // Update session ID
    try await db.terminals.updateSessionID(id: terminal.id, sessionID: "new-456")
    let refreshed = try await db.terminals.get(id: terminal.id)
    #expect(refreshed?.claudeSessionID == "new-456")
}

@Test func terminalSuspendedAtPreservesOnReconcile() async throws {
    // Verify that listing suspended terminals works for reconcile skip logic
    let db = try TBDDatabase(writer: DatabaseQueue())
    let repo = try await db.repos.create(path: "/tmp/test-repo")
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "test", branch: "main",
        path: "/tmp/test-repo/.tbd/worktrees/test", tmuxServer: "tbd-test"
    )
    let t = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
        label: "claude", claudeSessionID: "abc"
    )
    try await db.terminals.setSuspended(id: t.id, sessionID: "abc")

    let suspended = try await db.terminals.list(worktreeID: wt.id)
        .filter { $0.suspendedAt != nil }
    #expect(suspended.count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter terminalSuspendFields 2>&1 | tail -5`
Expected: Compilation errors — `claudeSessionID` param and methods don't exist yet.

- [ ] **Step 3: Add migration v6 to Database.swift**

In `Sources/TBDDaemon/Database/Database.swift`, after the `v5` migration block, add:

```swift
migrator.registerMigration("v6") { db in
    try db.alter(table: "terminal") { t in
        t.add(column: "claudeSessionID", .text)
        t.add(column: "suspendedAt", .datetime)
    }
}
```

- [ ] **Step 4: Update Terminal model in Models.swift**

Add fields to `Terminal` struct. Use custom `Codable` for backward compatibility:

```swift
public struct Terminal: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var tmuxWindowID: String
    public var tmuxPaneID: String
    public var label: String?
    public var createdAt: Date
    public var pinnedAt: Date?
    public var claudeSessionID: String?
    public var suspendedAt: Date?

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date(),
                pinnedAt: Date? = nil, claudeSessionID: String? = nil,
                suspendedAt: Date? = nil) {
        self.id = id
        self.worktreeID = worktreeID
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.label = label
        self.createdAt = createdAt
        self.pinnedAt = pinnedAt
        self.claudeSessionID = claudeSessionID
        self.suspendedAt = suspendedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, worktreeID, tmuxWindowID, tmuxPaneID, label, createdAt,
             pinnedAt, claudeSessionID, suspendedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        tmuxWindowID = try c.decode(String.self, forKey: .tmuxWindowID)
        tmuxPaneID = try c.decode(String.self, forKey: .tmuxPaneID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        suspendedAt = try c.decodeIfPresent(Date.self, forKey: .suspendedAt)
    }
}
```

- [ ] **Step 5: Update TerminalRecord and TerminalStore**

In `TerminalStore.swift`, add fields to `TerminalRecord`:

```swift
struct TerminalRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "terminal"

    var id: String
    var worktreeID: String
    var tmuxWindowID: String
    var tmuxPaneID: String
    var label: String?
    var createdAt: Date
    var pinnedAt: Date?
    var claudeSessionID: String?
    var suspendedAt: Date?

    init(from terminal: Terminal) {
        self.id = terminal.id.uuidString
        self.worktreeID = terminal.worktreeID.uuidString
        self.tmuxWindowID = terminal.tmuxWindowID
        self.tmuxPaneID = terminal.tmuxPaneID
        self.label = terminal.label
        self.createdAt = terminal.createdAt
        self.pinnedAt = terminal.pinnedAt
        self.claudeSessionID = terminal.claudeSessionID
        self.suspendedAt = terminal.suspendedAt
    }

    func toModel() -> Terminal {
        Terminal(
            id: UUID(uuidString: id)!,
            worktreeID: UUID(uuidString: worktreeID)!,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            label: label,
            createdAt: createdAt,
            pinnedAt: pinnedAt,
            claudeSessionID: claudeSessionID,
            suspendedAt: suspendedAt
        )
    }
}
```

Update `create` to accept `claudeSessionID`:

```swift
public func create(
    worktreeID: UUID,
    tmuxWindowID: String,
    tmuxPaneID: String,
    label: String? = nil,
    claudeSessionID: String? = nil
) async throws -> Terminal {
    let terminal = Terminal(
        worktreeID: worktreeID,
        tmuxWindowID: tmuxWindowID,
        tmuxPaneID: tmuxPaneID,
        label: label,
        claudeSessionID: claudeSessionID
    )
    let record = TerminalRecord(from: terminal)
    try await writer.write { db in
        try record.insert(db)
    }
    return terminal
}
```

Add new methods:

```swift
/// Mark a terminal as suspended.
public func setSuspended(id: UUID, sessionID: String) async throws {
    try await writer.write { db in
        guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
            throw DatabaseError(message: "Terminal not found")
        }
        record.suspendedAt = Date()
        record.claudeSessionID = sessionID
        try record.update(db)
    }
}

/// Clear the suspended state.
public func clearSuspended(id: UUID) async throws {
    try await writer.write { db in
        guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
            throw DatabaseError(message: "Terminal not found")
        }
        record.suspendedAt = nil
        try record.update(db)
    }
}

/// Update the Claude session ID (e.g. after resume generates a new one).
public func updateSessionID(id: UUID, sessionID: String) async throws {
    try await writer.write { db in
        guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
            throw DatabaseError(message: "Terminal not found")
        }
        record.claudeSessionID = sessionID
        try record.update(db)
    }
}

/// Update tmux window/pane IDs (e.g. after resume creates a new window).
public func updateTmuxIDs(id: UUID, windowID: String, paneID: String) async throws {
    try await writer.write { db in
        guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
            throw DatabaseError(message: "Terminal not found")
        }
        record.tmuxWindowID = windowID
        record.tmuxPaneID = paneID
        try record.update(db)
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter "terminalSuspend" 2>&1 | tail -5`
Expected: Both tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDShared/Models.swift Sources/TBDDaemon/Database/Database.swift Sources/TBDDaemon/Database/TerminalStore.swift Tests/TBDDaemonTests/DatabaseTests.swift
git commit -m "feat: add claudeSessionID and suspendedAt to terminal model (migration v6)"
```

---

### Task 2: TmuxManager helper methods

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/TmuxManager.swift`
- Test: `Tests/TBDDaemonTests/TmuxManagerTests.swift`

- [ ] **Step 1: Write tests for new command builders**

```swift
@Test func capturePaneCommand() {
    let args = TmuxManager.capturePaneCommand(server: "tbd-test", paneID: "%42")
    #expect(args == ["-L", "tbd-test", "capture-pane", "-p", "-t", "%42"])
}

@Test func paneCurrentCommandQuery() {
    let args = TmuxManager.paneCurrentCommandQuery(server: "tbd-test", paneID: "%42")
    #expect(args == ["-L", "tbd-test", "list-panes", "-t", "%42", "-F", "#{pane_current_command}"])
}

@Test func panePIDQuery() {
    let args = TmuxManager.panePIDQuery(server: "tbd-test", paneID: "%42")
    #expect(args == ["-L", "tbd-test", "list-panes", "-t", "%42", "-F", "#{pane_pid}"])
}

@Test func sendCommandWithEnter() {
    let args = TmuxManager.sendCommandArgs(server: "tbd-test", paneID: "%42", command: "/exit")
    #expect(args == ["-L", "tbd-test", "send-keys", "-t", "%42", "/exit", "Enter"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "capturePane\|paneCurrentCommand\|panePID\|sendCommand" 2>&1 | tail -5`
Expected: Compilation errors.

- [ ] **Step 3: Implement command builders and instance methods**

Add to `TmuxManager.swift` in the static command builders section:

```swift
public static func capturePaneCommand(server: String, paneID: String) -> [String] {
    ["-L", server, "capture-pane", "-p", "-t", paneID]
}

public static func paneCurrentCommandQuery(server: String, paneID: String) -> [String] {
    ["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_current_command}"]
}

public static func panePIDQuery(server: String, paneID: String) -> [String] {
    ["-L", server, "list-panes", "-t", paneID, "-F", "#{pane_pid}"]
}

/// send-keys without -l so "Enter" is interpreted as a key name, not literal text.
public static func sendCommandArgs(server: String, paneID: String, command: String) -> [String] {
    ["-L", server, "send-keys", "-t", paneID, command, "Enter"]
}
```

Add instance methods:

```swift
/// Capture the visible content of a tmux pane.
public func capturePaneOutput(server: String, paneID: String) async throws -> String {
    if dryRun { return "" }
    let args = Self.capturePaneCommand(server: server, paneID: paneID)
    return try await runTmux(args)
}

/// Get the current foreground command name for a pane.
public func paneCurrentCommand(server: String, paneID: String) async throws -> String {
    if dryRun { return "zsh" }
    let args = Self.paneCurrentCommandQuery(server: server, paneID: paneID)
    return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Get the PID of the process running in a pane.
public func panePID(server: String, paneID: String) async throws -> String {
    if dryRun { return "0" }
    let args = Self.panePIDQuery(server: server, paneID: paneID)
    return try await runTmux(args).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Send a command string followed by Enter to a pane.
public func sendCommand(server: String, paneID: String, command: String) async throws {
    if dryRun { return }
    let args = Self.sendCommandArgs(server: server, paneID: paneID, command: command)
    try await runTmux(args)
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "TmuxManager" 2>&1 | tail -5`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/TmuxManager.swift Tests/TBDDaemonTests/TmuxManagerTests.swift
git commit -m "feat: add tmux capture-pane, pane inspection, and sendCommand helpers"
```

---

### Task 3: ClaudeStateDetector

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ClaudeStateDetector.swift`
- Create: `Tests/TBDDaemonTests/ClaudeStateDetectorTests.swift`

- [ ] **Step 1: Write tests for idle detection**

```swift
import Testing
@testable import TBDDaemonLib

@Test func idleWithBarePromptAndStatusBar() {
    let lines = """
    some output above

    ─────────────────────────
    ❯\u{00a0}
    ─────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    #expect(ClaudeStateDetector.checkIdle(output: lines) == true)
}

@Test func notIdleWithUserInput() {
    let lines = """
    ─────────────────────────
    ❯ fix the bug
    ─────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func notIdleNoPrompt() {
    let lines = """
    ⏺ Working on something...
      Reading file.swift
    ─────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func notIdleNoStatusBar() {
    let lines = """
    ─────────────────────────
    ❯\u{00a0}
    ─────────────────────────
    Enter to select · ↑/↓ to navigate · Esc to cancel
    """
    #expect(ClaudeStateDetector.checkIdle(output: lines) == false)
}

@Test func idleWithQuestionForShortcuts() {
    let lines = """
    ─────────────────────────
    ❯
    ─────────────────────────
      ? for shortcuts
    """
    #expect(ClaudeStateDetector.checkIdle(output: lines) == true)
}

@Test func claudeProcessPatternMatchesSemver() {
    #expect(ClaudeStateDetector.isClaudeProcess("2.1.86") == true)
    #expect(ClaudeStateDetector.isClaudeProcess("2.1.85") == true)
    #expect(ClaudeStateDetector.isClaudeProcess("10.0.1") == true)
    #expect(ClaudeStateDetector.isClaudeProcess("zsh") == false)
    #expect(ClaudeStateDetector.isClaudeProcess("bash") == false)
    #expect(ClaudeStateDetector.isClaudeProcess("node") == false)
    #expect(ClaudeStateDetector.isClaudeProcess("git") == false)
}

@Test func parseSessionFile() {
    let json = """
    {"pid": 12345, "sessionId": "abc-def-123", "cwd": "/tmp", "startedAt": 1000, "kind": "interactive", "entrypoint": "cli"}
    """
    let result = ClaudeStateDetector.parseSessionID(from: json)
    #expect(result == "abc-def-123")
}

@Test func parseSessionFileBadJSON() {
    let result = ClaudeStateDetector.parseSessionID(from: "not json")
    #expect(result == nil)
}

@Test func parseSessionFilePartialJSON() {
    let result = ClaudeStateDetector.parseSessionID(from: "{\"pid\": 123")
    #expect(result == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "ClaudeStateDetector" 2>&1 | tail -5`
Expected: Compilation errors — `ClaudeStateDetector` doesn't exist.

- [ ] **Step 3: Implement ClaudeStateDetector**

Create `Sources/TBDDaemon/Tmux/ClaudeStateDetector.swift`:

```swift
import Foundation

/// Detects Claude Code idle state and captures session IDs.
/// Pattern constants are centralized here — Claude Code UI details with no stability contract.
public struct ClaudeStateDetector: Sendable {

    // MARK: - Pattern Constants

    /// Claude appears as a semver string in tmux's pane_current_command (e.g. "2.1.86").
    static let claudeProcessRegex = try! Regex(#"^\d+\.\d+\.\d+"#)

    /// The prompt character Claude shows when waiting for input.
    static let promptRegex = try! Regex(#"^❯[\s\u{00a0}]*$"#)

    /// Status bar indicators that confirm Claude is at its idle prompt.
    static let statusIndicators = ["⏵⏵", "bypass", "auto mode", "? for shortcuts"]

    // MARK: - Public API

    /// Check if a pane_current_command value looks like a Claude process.
    public static func isClaudeProcess(_ command: String) -> Bool {
        command.firstMatch(of: claudeProcessRegex) != nil
    }

    /// Check if captured pane output shows an idle Claude prompt.
    /// Requires BOTH a bare prompt line AND a status bar indicator in the last 5 lines.
    public static func checkIdle(output: String) -> Bool {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let lastLines = lines.suffix(5).map(String.init)
        let text = lastLines.joined(separator: "\n")

        let hasStatusBar = statusIndicators.contains { text.contains($0) }
        let hasPrompt = lastLines.contains { $0.firstMatch(of: promptRegex) != nil }

        return hasStatusBar && hasPrompt
    }

    /// Parse a session ID from Claude Code's session file JSON.
    public static func parseSessionID(from json: String) -> String? {
        struct SessionFile: Decodable {
            let sessionId: String
        }
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SessionFile.self, from: data) else {
            return nil
        }
        return parsed.sessionId
    }

    // MARK: - Tmux-dependent methods

    private let tmux: TmuxManager

    public init(tmux: TmuxManager) {
        self.tmux = tmux
    }

    /// Full idle check: verify pane_current_command is Claude, then check pane output.
    public func isIdle(server: String, paneID: String) async -> Bool {
        do {
            let command = try await tmux.paneCurrentCommand(server: server, paneID: paneID)
            guard Self.isClaudeProcess(command) else { return false }

            let output = try await tmux.capturePaneOutput(server: server, paneID: paneID)
            return Self.checkIdle(output: output)
        } catch {
            return false
        }
    }

    /// Debounced idle check — calls isIdle twice with a 1s gap.
    public func isIdleConfirmed(server: String, paneID: String) async -> Bool {
        guard await isIdle(server: server, paneID: paneID) else { return false }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return false }
        return await isIdle(server: server, paneID: paneID)
    }

    /// Capture the Claude session ID from a running instance's PID file.
    public func captureSessionID(server: String, paneID: String) async -> String? {
        do {
            let pidStr = try await tmux.panePID(server: server, paneID: paneID)
            guard let shellPID = Int(pidStr) else { return nil }

            // Find the claude child process
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(shellPID), "-x", "claude"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .compactMap { Int($0) }

            // Skip if multiple matches (ambiguous)
            guard pids.count == 1, let claudePID = pids.first else { return nil }

            // Read session file
            let sessionPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/sessions/\(claudePID).json")
            guard let json = try? String(contentsOf: sessionPath, encoding: .utf8) else { return nil }

            return Self.parseSessionID(from: json)
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "ClaudeStateDetector" 2>&1 | tail -5`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ClaudeStateDetector.swift Tests/TBDDaemonTests/ClaudeStateDetectorTests.swift
git commit -m "feat: add ClaudeStateDetector for idle detection and session ID capture"
```

---

### Task 4: RPC method and selection tracking

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift` (add method + param struct)
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift` (add handler dispatch)
- Create: `Sources/TBDDaemon/Server/RPCRouter+SelectionHandlers.swift` (handler)
- Modify: `Sources/TBDApp/DaemonClient.swift` (add client method)
- Modify: `Sources/TBDApp/ContentView.swift` (wire onChange)
- Modify: `Sources/TBDApp/AppState.swift` (send on reconnect)

- [ ] **Step 1: Add RPC method constant and param struct**

In `Sources/TBDShared/RPCProtocol.swift`, add to `RPCMethod`:

```swift
public static let worktreeSelectionChanged = "worktree.selectionChanged"
```

Add param struct after the existing ones:

```swift
public struct WorktreeSelectionChangedParams: Codable, Sendable {
    public let selectedWorktreeIDs: [UUID]
    public init(selectedWorktreeIDs: [UUID]) {
        self.selectedWorktreeIDs = selectedWorktreeIDs
    }
}
```

- [ ] **Step 2: Add handler dispatch in RPCRouter.swift**

In the `handle(_:)` switch, add:

```swift
case RPCMethod.worktreeSelectionChanged:
    return try await handleWorktreeSelectionChanged(request.paramsData)
```

- [ ] **Step 3: Create handler file**

Create `Sources/TBDDaemon/Server/RPCRouter+SelectionHandlers.swift`:

```swift
import Foundation
import TBDShared

extension RPCRouter {
    func handleWorktreeSelectionChanged(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSelectionChangedParams.self, from: data)
        let newSelection = Set(params.selectedWorktreeIDs)

        // TODO: Task 5 will add SuspendResumeCoordinator integration here.
        // For now, just store the selection.

        return .ok()
    }
}
```

- [ ] **Step 4: Add client method in DaemonClient.swift**

Add to `DaemonClient`:

```swift
func worktreeSelectionChanged(selectedWorktreeIDs: Set<UUID>) async throws {
    let params = WorktreeSelectionChangedParams(selectedWorktreeIDs: Array(selectedWorktreeIDs))
    let request = try RPCRequest(method: RPCMethod.worktreeSelectionChanged, params: params)
    _ = try await send(request)
}
```

- [ ] **Step 5: Wire into ContentView.swift onChange**

In the existing `onChange(of: appState.selectedWorktreeIDs)` handler, add the RPC call:

```swift
Task {
    try? await appState.daemonClient?.worktreeSelectionChanged(
        selectedWorktreeIDs: appState.selectedWorktreeIDs
    )
}
```

- [ ] **Step 6: Wire into AppState reconnect path**

In `AppState`'s refresh/reconnect method (where it re-fetches worktrees and terminals after daemon connection), add:

```swift
// Re-send current selection so daemon has accurate baseline after restart
Task {
    try? await daemonClient?.worktreeSelectionChanged(
        selectedWorktreeIDs: selectedWorktreeIDs
    )
}
```

- [ ] **Step 7: Build and verify**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: Build complete.

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift Sources/TBDDaemon/Server/RPCRouter.swift Sources/TBDDaemon/Server/RPCRouter+SelectionHandlers.swift Sources/TBDApp/DaemonClient.swift Sources/TBDApp/ContentView.swift Sources/TBDApp/AppState.swift
git commit -m "feat: add worktreeSelectionChanged RPC method"
```

---

### Task 5: SuspendResumeCoordinator actor

**Files:**
- Create: `Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift` (add coordinator property)
- Modify: `Sources/TBDDaemon/Server/RPCRouter+SelectionHandlers.swift` (integrate)

- [ ] **Step 1: Create the coordinator**

Create `Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift`:

```swift
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SuspendResume")

/// Serializes suspend/resume operations per terminal.
/// Handles rapid switching by cancelling in-flight suspends before the point of no return.
public actor SuspendResumeCoordinator {
    private let db: TBDDatabase
    private let tmux: TmuxManager
    private let detector: ClaudeStateDetector
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var lastKnownSelection: Set<UUID> = []

    public init(db: TBDDatabase, tmux: TmuxManager) {
        self.db = db
        self.tmux = tmux
        self.detector = ClaudeStateDetector(tmux: tmux)
    }

    /// Called when app reports a new selection. Diffs against last-known and triggers suspend/resume.
    public func selectionChanged(to newSelection: Set<UUID>) {
        let departing = lastKnownSelection.subtracting(newSelection)
        let arriving = newSelection.subtracting(lastKnownSelection)
        lastKnownSelection = newSelection

        for worktreeID in departing {
            scheduleSuspend(worktreeID: worktreeID)
        }
        for worktreeID in arriving {
            scheduleResume(worktreeID: worktreeID)
        }
    }

    // MARK: - Suspend

    private func scheduleSuspend(worktreeID: UUID) {
        Task {
            let terminals = try? await db.terminals.list(worktreeID: worktreeID)
            guard let terminals else { return }
            for terminal in terminals {
                guard terminal.label?.hasPrefix("claude") == true,
                      terminal.pinnedAt == nil,
                      terminal.suspendedAt == nil,
                      terminal.claudeSessionID != nil else { continue }

                // Cancel any in-flight operation for this terminal
                inFlight[terminal.id]?.cancel()

                let task = Task<Void, Never> {
                    await suspendTerminal(terminal)
                }
                inFlight[terminal.id] = task
            }
        }
    }

    private func suspendTerminal(_ terminal: Terminal) async {
        let server = await worktreeServer(for: terminal.worktreeID)
        guard let server else { return }

        // Steps 1-5: cancellable phase
        guard await detector.isIdleConfirmed(server: server, paneID: terminal.tmuxPaneID) else {
            return
        }

        // Check cancellation before point of no return
        guard !Task.isCancelled else { return }

        // Step 6: POINT OF NO RETURN — send /exit
        do {
            try await tmux.sendCommand(server: server, paneID: terminal.tmuxPaneID, command: "/exit")
        } catch {
            logger.warning("Failed to send /exit to \(terminal.id): \(error)")
            return
        }

        // Step 7: verify exit (poll for up to 3s)
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
               !ClaudeStateDetector.isClaudeProcess(cmd) {
                break // Claude exited
            }
        }

        // Step 8: mark suspended regardless of whether Claude exited yet
        do {
            try await db.terminals.setSuspended(id: terminal.id, sessionID: terminal.claudeSessionID!)
            logger.info("Suspended terminal \(terminal.id)")
        } catch {
            logger.warning("Failed to mark terminal \(terminal.id) suspended: \(error)")
        }

        inFlight[terminal.id] = nil
    }

    // MARK: - Resume

    private func scheduleResume(worktreeID: UUID) {
        Task {
            let terminals = try? await db.terminals.list(worktreeID: worktreeID)
            guard let terminals else { return }
            for terminal in terminals where terminal.suspendedAt != nil {
                // Cancel any in-flight suspend (only effective if still in cancellable phase)
                inFlight[terminal.id]?.cancel()

                let task = Task<Void, Never> {
                    await resumeTerminal(terminal)
                }
                inFlight[terminal.id] = task
            }
        }
    }

    private func resumeTerminal(_ terminal: Terminal) async {
        let server = await worktreeServer(for: terminal.worktreeID)
        guard let server, let sessionID = terminal.claudeSessionID else { return }

        // Step 1: check if Claude is still/already running (pending /exit or user restarted)
        if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
           ClaudeStateDetector.isClaudeProcess(cmd) {
            // Wait up to 5s for queued /exit to process
            var stillRunning = true
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(200))
                if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
                   !ClaudeStateDetector.isClaudeProcess(cmd) {
                    stillRunning = false
                    break
                }
            }
            if stillRunning {
                // User restarted it — just clear suspended state and re-capture session
                try? await db.terminals.clearSuspended(id: terminal.id)
                if let newID = await detector.captureSessionID(server: server, paneID: terminal.tmuxPaneID) {
                    try? await db.terminals.updateSessionID(id: terminal.id, sessionID: newID)
                }
                inFlight[terminal.id] = nil
                return
            }
        }

        // Step 2-4: pane is dead — create new window
        let worktree = try? await db.worktrees.get(id: terminal.worktreeID)
        guard let worktree else {
            inFlight[terminal.id] = nil
            return
        }

        let resumeCommand = "claude --resume \(sessionID) --dangerously-skip-permissions"
        do {
            let window = try await tmux.createWindow(
                server: server,
                session: "main",
                cwd: worktree.path,
                shellCommand: resumeCommand
            )
            try await db.terminals.updateTmuxIDs(
                id: terminal.id,
                windowID: window.windowID,
                paneID: window.paneID
            )
            try await db.terminals.clearSuspended(id: terminal.id)
            logger.info("Resumed terminal \(terminal.id) in new window \(window.windowID)")

            // Step 7: re-capture session ID after ~5s
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let newID = await detector.captureSessionID(server: server, paneID: window.paneID) {
                    try? await db.terminals.updateSessionID(id: terminal.id, sessionID: newID)
                    logger.info("Re-captured session ID for terminal \(terminal.id): \(newID)")
                } else {
                    logger.warning("Failed to re-capture session ID for terminal \(terminal.id)")
                }
            }
        } catch {
            logger.warning("Failed to resume terminal \(terminal.id): \(error)")
        }

        inFlight[terminal.id] = nil
    }

    // MARK: - Helpers

    private func worktreeServer(for worktreeID: UUID) async -> String? {
        guard let wt = try? await db.worktrees.get(id: worktreeID) else { return nil }
        return wt.tmuxServer
    }

    /// Reconcile suspended terminals on startup.
    public func reconcileOnStartup() async {
        let allTerminals = (try? await db.terminals.list()) ?? []
        for terminal in allTerminals where terminal.suspendedAt != nil {
            let server = await worktreeServer(for: terminal.worktreeID)
            guard let server else { continue }

            let alive = await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID)
            if alive {
                if let cmd = try? await tmux.paneCurrentCommand(server: server, paneID: terminal.tmuxPaneID),
                   ClaudeStateDetector.isClaudeProcess(cmd) {
                    // Claude is running — clear suspended state
                    try? await db.terminals.clearSuspended(id: terminal.id)
                    logger.info("Startup reconcile: cleared suspendedAt for running terminal \(terminal.id)")
                }
            }
            // If pane is dead, leave suspendedAt set — will be resumed on next selection
        }
    }
}
```

- [ ] **Step 2: Add coordinator to RPCRouter**

In `RPCRouter`, add property:

```swift
public let suspendResumeCoordinator: SuspendResumeCoordinator
```

Update the `init` to create it:

```swift
self.suspendResumeCoordinator = SuspendResumeCoordinator(db: db, tmux: tmux)
```

- [ ] **Step 3: Wire selection handler to coordinator**

Update `RPCRouter+SelectionHandlers.swift`:

```swift
import Foundation
import TBDShared

extension RPCRouter {
    func handleWorktreeSelectionChanged(_ data: Data) async throws -> RPCResponse {
        let params = try decoder.decode(WorktreeSelectionChangedParams.self, from: data)
        let newSelection = Set(params.selectedWorktreeIDs)
        await suspendResumeCoordinator.selectionChanged(to: newSelection)
        return .ok()
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift Sources/TBDDaemon/Server/RPCRouter.swift Sources/TBDDaemon/Server/RPCRouter+SelectionHandlers.swift
git commit -m "feat: add SuspendResumeCoordinator actor with suspend/resume flows"
```

---

### Task 6: Reconcile fix, terminal creation, and startup

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift`
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`
- Modify: `Sources/TBDDaemon/Daemon.swift` (startup reconcile)

- [ ] **Step 1: Fix reconcile to skip suspended terminals**

In `WorktreeLifecycle+Reconcile.swift`, in the terminal cleanup loop (around line 130), change:

```swift
// Before:
if !alive {
    try? await db.terminals.delete(id: terminal.id)
}

// After:
if !alive && terminal.suspendedAt == nil {
    try? await db.terminals.delete(id: terminal.id)
}
```

- [ ] **Step 2: Add --session-id to terminal creation**

In `WorktreeLifecycle+Create.swift`, where the Claude command is built (around line 188), change:

```swift
// Before:
let claudeCommand: String
if skipClaude {
    claudeCommand = defaultShell
} else {
    claudeCommand = "claude --dangerously-skip-permissions"
}

// After:
let claudeCommand: String
let claudeSessionID: String?
if skipClaude {
    claudeCommand = defaultShell
    claudeSessionID = nil
} else {
    let sessionUUID = UUID().uuidString
    claudeCommand = "claude --dangerously-skip-permissions --session-id \(sessionUUID)"
    claudeSessionID = sessionUUID
}
```

And update the `db.terminals.create` call to pass it:

```swift
_ = try await db.terminals.create(
    worktreeID: worktreeID,
    tmuxWindowID: window1.windowID,
    tmuxPaneID: window1.paneID,
    label: skipClaude ? "shell" : "claude",
    claudeSessionID: claudeSessionID
)
```

- [ ] **Step 3: Add startup reconcile to Daemon.swift**

In `Daemon.swift`, after the RPCRouter is created but before (or at the start of) the existing reconcile, add:

```swift
await router.suspendResumeCoordinator.reconcileOnStartup()
```

- [ ] **Step 4: Build and run tests**

Run: `swift build 2>&1 | grep -E "error:|Build complete"` then `swift test 2>&1 | tail -5`
Expected: Build complete, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift Sources/TBDDaemon/Daemon.swift
git commit -m "feat: reconcile skip for suspended terminals, --session-id at creation, startup sweep"
```

---

### Task 7: App UI reconnection

**Files:**
- Modify: `Sources/TBDApp/Panes/PanePlaceholder.swift`

- [ ] **Step 1: Change view identity to include tmuxWindowID**

In `PanePlaceholder.swift`, find the `.id(terminalID)` on the `TerminalPanelView` (around line 176) and change it:

```swift
// Before:
.id(terminalID)

// After:
.id("\(terminal.id)-\(terminal.tmuxWindowID)")
```

This requires the `terminal` object to be available in scope. The `terminalContent` function already looks up the terminal (line 160: `if let terminal = terminal(for: terminalID)`), so use `terminal.id` and `terminal.tmuxWindowID` directly.

- [ ] **Step 2: Trigger immediate refresh after selection RPC**

In `ContentView.swift`, in the `onChange` handler where we call `worktreeSelectionChanged`, trigger an immediate terminal refresh after the RPC returns:

```swift
Task {
    try? await appState.daemonClient?.worktreeSelectionChanged(
        selectedWorktreeIDs: appState.selectedWorktreeIDs
    )
    // Immediate refresh so UI picks up new tmuxWindowID from resume
    await appState.refreshTerminals()
}
```

(If `refreshTerminals` doesn't exist as a standalone method, extract the terminal-refresh logic from the existing poll timer into a callable method.)

- [ ] **Step 3: Build and verify**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: Build complete.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Panes/PanePlaceholder.swift Sources/TBDApp/ContentView.swift
git commit -m "feat: composite view identity for UI reconnection on resume"
```

---

### Task 8: Integration test and final verification

**Files:**
- All modified files

- [ ] **Step 1: Build the full project**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: Build complete.

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Manual smoke test**

1. Run `scripts/restart.sh` to rebuild and restart
2. Open TBD app, create a worktree
3. Verify the Claude terminal launches with `--session-id` (check `/tmp/tbd-bridge.log` or tmux output)
4. Wait for Claude to reach idle prompt
5. Switch to a different worktree
6. Wait ~2s for the suspend flow
7. Switch back — verify Claude resumes with the conversation intact

- [ ] **Step 4: Final commit if any fixups needed**

```bash
git add -A
git commit -m "fix: integration fixups from smoke testing"
```
