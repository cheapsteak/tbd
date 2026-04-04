# Conductor Phase 1a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a minimal viable conductor — a Claude Code session that can manually poll and interact with other terminals via `tbd` CLI commands.

**Architecture:** Add `.conductor` WorktreeStatus, a `conductor` DB table, a synthetic "conductors" pseudo-repo, `terminal.output` RPC, conductor lifecycle management (setup/start/stop/teardown), CLI commands, and a CLAUDE.md template. Conductors run in a dedicated `tbd-conductor` tmux server.

**Tech Stack:** Swift 6, GRDB, ArgumentParser, tmux

**Spec:** `docs/superpowers/specs/2026-04-02-conductor-pattern-design.md`

---

### File Map

**Create:**
- `Sources/TBDShared/ConductorModels.swift` — Conductor model struct + ConductorConfig
- `Sources/TBDDaemon/Conductor/ConductorStore.swift` — GRDB store for conductor table
- `Sources/TBDDaemon/Conductor/ConductorManager.swift` — Lifecycle: setup, start, stop, teardown, template generation
- `Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift` — RPC handlers for conductor.* and terminal.output
- `Sources/TBDCLI/Commands/ConductorCommands.swift` — CLI commands
- `Tests/TBDDaemonTests/ConductorStoreTests.swift` — DB store tests
- `Tests/TBDDaemonTests/ConductorManagerTests.swift` — Lifecycle tests

**Modify:**
- `Sources/TBDShared/Models.swift` — Add `.conductor` to WorktreeStatus
- `Sources/TBDShared/RPCProtocol.swift` — Add RPC method constants + param/result structs
- `Sources/TBDShared/Constants.swift` — Add conductorsDir path
- `Sources/TBDDaemon/Database/Database.swift` — Add v9 migration (conductor table + synthetic repo)
- `Sources/TBDDaemon/Server/RPCRouter.swift` — Wire conductor handlers + add ConductorManager dependency
- `Sources/TBDDaemon/Server/StateSubscription.swift` — Suppress conductor worktree deltas
- `Sources/TBDDaemon/Daemon.swift` — Initialize ConductorManager
- `Sources/TBDCLI/TBD.swift` — Register ConductorCommand
- `Sources/TBDDaemon/Database/WorktreeStore.swift` — Add list filter to exclude .conductor by default

---

### Task 1: Add WorktreeStatus.conductor + Conductor Model

**Files:**
- Modify: `Sources/TBDShared/Models.swift:22-24`
- Create: `Sources/TBDShared/ConductorModels.swift`
- Modify: `Sources/TBDShared/Constants.swift`
- Test: `Tests/TBDSharedTests/ModelsTests.swift`

- [ ] **Step 1: Write test for new WorktreeStatus case**

```swift
// In Tests/TBDSharedTests/ModelsTests.swift, add:

@Test func conductorStatusRoundTrips() throws {
    let status = WorktreeStatus.conductor
    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(WorktreeStatus.self, from: data)
    #expect(decoded == .conductor)
}

@Test func conductorModelRoundTrips() throws {
    let conductor = Conductor(
        id: UUID(),
        name: "test-conductor",
        repos: ["*"],
        permissions: "observe",
        heartbeatIntervalMinutes: 10,
        createdAt: Date()
    )
    let data = try JSONEncoder().encode(conductor)
    let decoded = try JSONDecoder().decode(Conductor.self, from: data)
    #expect(decoded.name == "test-conductor")
    #expect(decoded.repos == ["*"])
    #expect(decoded.permissions == "observe")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter conductorStatusRoundTrips 2>&1 | tail -5`
Expected: Compilation error — `.conductor` not defined

- [ ] **Step 3: Add WorktreeStatus.conductor**

In `Sources/TBDShared/Models.swift:22-24`, change:

```swift
public enum WorktreeStatus: String, Codable, Sendable {
    case active, archived, main, creating, conductor
}
```

- [ ] **Step 4: Create Conductor model**

Create `Sources/TBDShared/ConductorModels.swift`:

```swift
import Foundation

public struct Conductor: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var repos: [String]             // repo IDs or ["*"]
    public var worktrees: [String]?        // worktree name patterns, nil = all
    public var terminalLabels: [String]?   // terminal labels to monitor, nil = all
    public var permissions: String          // "observe" or "observe+interact"
    public var heartbeatIntervalMinutes: Int
    public var terminalID: UUID?           // FK to terminal (conductor's own terminal)
    public var worktreeID: UUID?           // FK to synthetic worktree
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        repos: [String] = ["*"],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil,
        permissions: String = "observe",
        heartbeatIntervalMinutes: Int = 10,
        terminalID: UUID? = nil,
        worktreeID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.repos = repos
        self.worktrees = worktrees
        self.terminalLabels = terminalLabels
        self.permissions = permissions
        self.heartbeatIntervalMinutes = heartbeatIntervalMinutes
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 5: Add conductorsDir to Constants**

In `Sources/TBDShared/Constants.swift`, add:

```swift
public static let conductorsDir = configDir.appendingPathComponent("conductors")
public static let conductorsTmuxServer = "tbd-conductor"
/// Well-known UUID for the synthetic "conductors" pseudo-repo.
/// Inserted by migration v9. Used as repoID for all conductor worktrees.
public static let conductorsRepoID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter "conductorStatusRoundTrips|conductorModelRoundTrips" 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDShared/ Tests/TBDSharedTests/
git commit -m "feat: add WorktreeStatus.conductor and Conductor model"
```

---

### Task 2: DB Migration v9 — Conductor Table + Synthetic Repo

**Files:**
- Modify: `Sources/TBDDaemon/Database/Database.swift:134-137`
- Create: `Sources/TBDDaemon/Conductor/ConductorStore.swift`
- Test: `Tests/TBDDaemonTests/ConductorStoreTests.swift`

- [ ] **Step 1: Write ConductorStore tests**

Create `Tests/TBDDaemonTests/ConductorStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct ConductorStoreTests {
    func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    @Test func createAndList() async throws {
        let db = try makeDB()
        let conductor = try await db.conductors.create(
            name: "test",
            repos: ["*"],
            permissions: "observe",
            heartbeatIntervalMinutes: 10
        )
        #expect(conductor.name == "test")
        #expect(conductor.repos == ["*"])

        let all = try await db.conductors.list()
        #expect(all.count == 1)
        #expect(all[0].name == "test")
    }

    @Test func getByName() async throws {
        let db = try makeDB()
        _ = try await db.conductors.create(name: "alpha", repos: ["*"], permissions: "observe", heartbeatIntervalMinutes: 10)
        let found = try await db.conductors.get(name: "alpha")
        #expect(found != nil)
        #expect(found?.name == "alpha")

        let notFound = try await db.conductors.get(name: "nope")
        #expect(notFound == nil)
    }

    @Test func delete() async throws {
        let db = try makeDB()
        let conductor = try await db.conductors.create(name: "doomed", repos: ["*"], permissions: "observe", heartbeatIntervalMinutes: 10)
        try await db.conductors.delete(id: conductor.id)
        let all = try await db.conductors.list()
        #expect(all.isEmpty)
    }

    @Test func duplicateNameFails() async throws {
        let db = try makeDB()
        _ = try await db.conductors.create(name: "unique", repos: ["*"], permissions: "observe", heartbeatIntervalMinutes: 10)
        do {
            _ = try await db.conductors.create(name: "unique", repos: ["*"], permissions: "observe", heartbeatIntervalMinutes: 10)
            Issue.record("Expected duplicate name to fail")
        } catch {
            // Expected — UNIQUE constraint on name
        }
    }

    @Test func syntheticRepoExists() async throws {
        let db = try makeDB()
        let repo = try await db.repos.get(id: TBDConstants.conductorsRepoID)
        #expect(repo != nil)
        #expect(repo?.displayName == "Conductors")
    }

    @Test func updateTerminalID() async throws {
        let db = try makeDB()
        let conductor = try await db.conductors.create(name: "test", repos: ["*"], permissions: "observe", heartbeatIntervalMinutes: 10)
        let termID = UUID()
        try await db.conductors.updateTerminalID(conductorID: conductor.id, terminalID: termID)
        let updated = try await db.conductors.get(name: "test")
        #expect(updated?.terminalID == termID)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ConductorStoreTests 2>&1 | tail -5`
Expected: Compilation error — `db.conductors` doesn't exist

- [ ] **Step 3: Add v9 migration**

In `Sources/TBDDaemon/Database/Database.swift`, before `try migrator.migrate(writer)`:

```swift
migrator.registerMigration("v9") { db in
    // Conductor table
    try db.create(table: "conductor") { t in
        t.primaryKey("id", .text).notNull()
        t.column("name", .text).notNull().unique()
        t.column("repos", .text).notNull().defaults(to: "[\"*\"]")
        t.column("worktrees", .text)
        t.column("terminalLabels", .text)
        t.column("permissions", .text).notNull().defaults(to: "observe")
        t.column("heartbeatIntervalMinutes", .integer).notNull().defaults(to: 10)
        t.column("terminalID", .text)
            .references("terminal", onDelete: .setNull)
        t.column("worktreeID", .text)
            .references("worktree", onDelete: .setNull)
        t.column("createdAt", .datetime).notNull()
    }

    // Synthetic "conductors" pseudo-repo
    try db.execute(
        sql: """
        INSERT OR IGNORE INTO repo (id, path, displayName, defaultBranch, createdAt)
        VALUES (?, ?, 'Conductors', 'main', ?)
        """,
        arguments: [
            TBDConstants.conductorsRepoID.uuidString,
            TBDConstants.conductorsDir.path,
            Date()
        ]
    )
}
```

- [ ] **Step 4: Add `conductors` store to TBDDatabase**

In `Sources/TBDDaemon/Database/Database.swift`, add property:

```swift
public let conductors: ConductorStore
```

And initialize in both `init(path:)` and `init(inMemory:)`:

```swift
self.conductors = ConductorStore(writer: pool)  // or queue for inMemory
```

- [ ] **Step 5: Create ConductorStore**

Create `Sources/TBDDaemon/Conductor/ConductorStore.swift`:

```swift
import Foundation
import GRDB
import TBDShared

struct ConductorRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conductor"

    var id: String
    var name: String
    var repos: String           // JSON array
    var worktrees: String?      // JSON array
    var terminalLabels: String? // JSON array
    var permissions: String
    var heartbeatIntervalMinutes: Int
    var terminalID: String?
    var worktreeID: String?
    var createdAt: Date

    init(from conductor: Conductor) {
        self.id = conductor.id.uuidString
        self.name = conductor.name
        self.repos = (try? String(data: JSONEncoder().encode(conductor.repos), encoding: .utf8)) ?? "[\"*\"]"
        if let wt = conductor.worktrees {
            self.worktrees = try? String(data: JSONEncoder().encode(wt), encoding: .utf8)
        }
        if let labels = conductor.terminalLabels {
            self.terminalLabels = try? String(data: JSONEncoder().encode(labels), encoding: .utf8)
        }
        self.permissions = conductor.permissions
        self.heartbeatIntervalMinutes = conductor.heartbeatIntervalMinutes
        self.terminalID = conductor.terminalID?.uuidString
        self.worktreeID = conductor.worktreeID?.uuidString
        self.createdAt = conductor.createdAt
    }

    func toModel() -> Conductor {
        let reposList: [String] = {
            guard let data = repos.data(using: .utf8) else { return ["*"] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? ["*"]
        }()
        let worktreesList: [String]? = {
            guard let json = worktrees, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }()
        let labelsList: [String]? = {
            guard let json = terminalLabels, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }()
        return Conductor(
            id: UUID(uuidString: id)!,
            name: name,
            repos: reposList,
            worktrees: worktreesList,
            terminalLabels: labelsList,
            permissions: permissions,
            heartbeatIntervalMinutes: heartbeatIntervalMinutes,
            terminalID: terminalID.flatMap { UUID(uuidString: $0) },
            worktreeID: worktreeID.flatMap { UUID(uuidString: $0) },
            createdAt: createdAt
        )
    }
}

public struct ConductorStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(
        name: String,
        repos: [String],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil,
        permissions: String,
        heartbeatIntervalMinutes: Int
    ) async throws -> Conductor {
        let conductor = Conductor(
            name: name,
            repos: repos,
            worktrees: worktrees,
            terminalLabels: terminalLabels,
            permissions: permissions,
            heartbeatIntervalMinutes: heartbeatIntervalMinutes
        )
        let record = ConductorRecord(from: conductor)
        try await writer.write { db in
            try record.insert(db)
        }
        return conductor
    }

    public func list() async throws -> [Conductor] {
        try await writer.read { db in
            try ConductorRecord.fetchAll(db).map { $0.toModel() }
        }
    }

    public func get(name: String) async throws -> Conductor? {
        try await writer.read { db in
            try ConductorRecord
                .filter(Column("name") == name)
                .fetchOne(db)?
                .toModel()
        }
    }

    public func get(id: UUID) async throws -> Conductor? {
        try await writer.read { db in
            try ConductorRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try ConductorRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func updateTerminalID(conductorID: UUID, terminalID: UUID?) async throws {
        try await writer.write { db in
            guard var record = try ConductorRecord.fetchOne(db, key: conductorID.uuidString) else {
                throw DatabaseError(message: "Conductor not found")
            }
            record.terminalID = terminalID?.uuidString
            try record.update(db)
        }
    }

    public func updateWorktreeID(conductorID: UUID, worktreeID: UUID?) async throws {
        try await writer.write { db in
            guard var record = try ConductorRecord.fetchOne(db, key: conductorID.uuidString) else {
                throw DatabaseError(message: "Conductor not found")
            }
            record.worktreeID = worktreeID?.uuidString
            try record.update(db)
        }
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter ConductorStoreTests 2>&1 | tail -10`
Expected: All 6 tests PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Database/Database.swift Sources/TBDDaemon/Conductor/
git add Tests/TBDDaemonTests/ConductorStoreTests.swift
git commit -m "feat: add conductor DB table, store, and v9 migration"
```

---

### Task 3: terminal.output RPC + CLI Command

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`
- Modify: `Sources/TBDCLI/Commands/TerminalCommands.swift`
- Test: `Tests/TBDDaemonTests/RPCRouterTests.swift`

- [ ] **Step 1: Write test for terminal.output handler**

Add to `Tests/TBDDaemonTests/RPCRouterTests.swift`:

```swift
@Test func terminalOutputReturnsError_whenTerminalNotFound() async throws {
    let db = try TBDDatabase(inMemory: true)
    let tmux = TmuxManager(dryRun: true)
    let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
    let router = RPCRouter(db: db, lifecycle: lifecycle, tmux: tmux)

    let params = TerminalOutputParams(terminalID: UUID())
    let request = try RPCRequest(method: RPCMethod.terminalOutput, params: params)
    let response = await router.handle(request)
    #expect(!response.success)
    #expect(response.error?.contains("Terminal not found") == true)
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter terminalOutputReturnsError 2>&1 | tail -5`
Expected: Compilation error — `TerminalOutputParams` and `RPCMethod.terminalOutput` don't exist

- [ ] **Step 3: Add RPC protocol types**

In `Sources/TBDShared/RPCProtocol.swift`, add to `RPCMethod`:

```swift
public static let terminalOutput = "terminal.output"
public static let conductorSetup = "conductor.setup"
public static let conductorStart = "conductor.start"
public static let conductorStop = "conductor.stop"
public static let conductorTeardown = "conductor.teardown"
public static let conductorList = "conductor.list"
public static let conductorStatus = "conductor.status"
```

Add param/result structs at the end of the file:

```swift
// MARK: - Terminal Output

public struct TerminalOutputParams: Codable, Sendable {
    public let terminalID: UUID
    public let lines: Int?
    public init(terminalID: UUID, lines: Int? = nil) {
        self.terminalID = terminalID; self.lines = lines
    }
}

public struct TerminalOutputResult: Codable, Sendable {
    public let output: String
    public init(output: String) { self.output = output }
}

// MARK: - Conductor

public struct ConductorSetupParams: Codable, Sendable {
    public let name: String
    public let repos: [String]?
    public let worktrees: [String]?
    public let terminalLabels: [String]?
    public let interact: Bool?
    public let heartbeatIntervalMinutes: Int?
    public init(name: String, repos: [String]? = nil, worktrees: [String]? = nil,
                terminalLabels: [String]? = nil, interact: Bool? = nil,
                heartbeatIntervalMinutes: Int? = nil) {
        self.name = name; self.repos = repos; self.worktrees = worktrees
        self.terminalLabels = terminalLabels; self.interact = interact
        self.heartbeatIntervalMinutes = heartbeatIntervalMinutes
    }
}

public struct ConductorNameParams: Codable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct ConductorListResult: Codable, Sendable {
    public let conductors: [Conductor]
    public init(conductors: [Conductor]) { self.conductors = conductors }
}

public struct ConductorStatusResult: Codable, Sendable {
    public let conductor: Conductor
    public let isRunning: Bool
    public init(conductor: Conductor, isRunning: Bool) {
        self.conductor = conductor; self.isRunning = isRunning
    }
}
```

- [ ] **Step 4: Add terminal.output handler**

In `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`, add:

```swift
func handleTerminalOutput(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(TerminalOutputParams.self, from: paramsData)

    guard let terminal = try await db.terminals.get(id: params.terminalID) else {
        return RPCResponse(error: "Terminal not found: \(params.terminalID)")
    }

    guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
        return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
    }

    let rawOutput = try await tmux.capturePaneOutput(
        server: worktree.tmuxServer,
        paneID: terminal.tmuxPaneID
    )

    let lines = params.lines ?? 50
    let outputLines = rawOutput.split(separator: "\n", omittingEmptySubsequences: false)
    let trimmed = outputLines.suffix(lines).joined(separator: "\n")

    return try RPCResponse(result: TerminalOutputResult(output: trimmed))
}
```

- [ ] **Step 5: Add CLI command**

In `Sources/TBDCLI/Commands/TerminalCommands.swift`, add `TerminalOutput` to subcommands:

```swift
static let configuration = CommandConfiguration(
    commandName: "terminal",
    abstract: "Manage terminals",
    subcommands: [TerminalCreate.self, TerminalList.self, TerminalSend.self, TerminalOutput.self]
)
```

Add the command:

```swift
// MARK: - terminal output

struct TerminalOutput: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "output",
        abstract: "Capture terminal output"
    )

    @Argument(help: "Terminal ID")
    var terminal: String

    @Option(name: .long, help: "Number of lines to capture (default 50)")
    var lines: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let terminalID = UUID(uuidString: terminal) else {
            throw CLIError.invalidArgument("Invalid terminal ID: \(terminal)")
        }

        let client = SocketClient()
        let result: TerminalOutputResult = try client.call(
            method: RPCMethod.terminalOutput,
            params: TerminalOutputParams(terminalID: terminalID, lines: lines),
            resultType: TerminalOutputResult.self
        )

        if json {
            printJSON(result)
        } else {
            print(result.output)
        }
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter terminalOutputReturnsError 2>&1 | tail -5`
Expected: PASS (the handler is wired in Task 5, but the test should compile now)

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift Sources/TBDDaemon/Server/
git add Sources/TBDCLI/Commands/TerminalCommands.swift
git commit -m "feat: add terminal.output RPC and CLI command"
```

---

### Task 4: ConductorManager — Lifecycle + CLAUDE.md Template

**Files:**
- Create: `Sources/TBDDaemon/Conductor/ConductorManager.swift`
- Test: `Tests/TBDDaemonTests/ConductorManagerTests.swift`

- [ ] **Step 1: Write tests**

Create `Tests/TBDDaemonTests/ConductorManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct ConductorManagerTests {
    func makeDB() throws -> TBDDatabase {
        try TBDDatabase(inMemory: true)
    }

    @Test func setupCreatesDirectoryAndDBRow() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        let conductor = try await manager.setup(
            name: "test",
            repos: ["*"],
            interact: false,
            heartbeatIntervalMinutes: 10
        )
        #expect(conductor.name == "test")
        #expect(conductor.permissions == "observe")

        // Verify DB row
        let found = try await db.conductors.get(name: "test")
        #expect(found != nil)

        // Verify synthetic worktree
        #expect(conductor.worktreeID != nil)
        let wt = try await db.worktrees.get(id: conductor.worktreeID!)
        #expect(wt?.status == .conductor)
        #expect(wt?.branch == "conductor")

        // Verify directory exists
        let dirPath = TBDConstants.conductorsDir.appendingPathComponent("test").path
        #expect(FileManager.default.fileExists(atPath: dirPath))

        // Verify CLAUDE.md exists
        let claudePath = TBDConstants.conductorsDir
            .appendingPathComponent("test")
            .appendingPathComponent("CLAUDE.md").path
        #expect(FileManager.default.fileExists(atPath: claudePath))

        // Cleanup
        try? FileManager.default.removeItem(atPath: dirPath)
    }

    @Test func setupInteractConflictFails() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        _ = try await manager.setup(name: "first", repos: ["*"], interact: true, heartbeatIntervalMinutes: 10)
        do {
            _ = try await manager.setup(name: "second", repos: ["*"], interact: true, heartbeatIntervalMinutes: 10)
            Issue.record("Expected interact conflict")
        } catch {
            #expect("\(error)".contains("interact"))
        }

        // Cleanup
        let dir1 = TBDConstants.conductorsDir.appendingPathComponent("first").path
        let dir2 = TBDConstants.conductorsDir.appendingPathComponent("second").path
        try? FileManager.default.removeItem(atPath: dir1)
        try? FileManager.default.removeItem(atPath: dir2)
    }

    @Test func teardownRemovesEverything() async throws {
        let db = try makeDB()
        let tmux = TmuxManager(dryRun: true)
        let manager = ConductorManager(db: db, tmux: tmux)

        let conductor = try await manager.setup(name: "doomed", repos: ["*"], interact: false, heartbeatIntervalMinutes: 10)
        try await manager.teardown(name: "doomed")

        let found = try await db.conductors.get(name: "doomed")
        #expect(found == nil)

        // Synthetic worktree should be gone
        let wt = try await db.worktrees.get(id: conductor.worktreeID!)
        #expect(wt == nil)

        // Directory should be gone
        let dirPath = TBDConstants.conductorsDir.appendingPathComponent("doomed").path
        #expect(!FileManager.default.fileExists(atPath: dirPath))
    }

    @Test func templateContainsConductorName() async throws {
        let template = ConductorManager.generateTemplate(
            name: "my-conductor",
            repos: ["*"],
            permissions: "observe+interact"
        )
        #expect(template.contains("Conductor: my-conductor"))
        #expect(template.contains("observe+interact"))
        #expect(template.contains("tbd terminal output"))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ConductorManagerTests 2>&1 | tail -5`
Expected: Compilation error — `ConductorManager` doesn't exist

- [ ] **Step 3: Implement ConductorManager**

Create `Sources/TBDDaemon/Conductor/ConductorManager.swift`:

```swift
import Foundation
import TBDShared

public final class ConductorManager: Sendable {
    let db: TBDDatabase
    let tmux: TmuxManager

    public init(db: TBDDatabase, tmux: TmuxManager) {
        self.db = db
        self.tmux = tmux
    }

    // MARK: - Setup

    public func setup(
        name: String,
        repos: [String] = ["*"],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil,
        interact: Bool = false,
        heartbeatIntervalMinutes: Int = 10
    ) async throws -> Conductor {
        let permissions = interact ? "observe+interact" : "observe"

        // Check interact conflict
        if interact {
            let existing = try await db.conductors.list()
            for c in existing where c.permissions == "observe+interact" {
                let overlap = repos.contains("*") || c.repos.contains("*") ||
                    !Set(repos).intersection(Set(c.repos)).isEmpty
                if overlap {
                    throw ConductorError.interactConflict(existingName: c.name)
                }
            }
        }

        // Create config directory
        let conductorDir = TBDConstants.conductorsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: conductorDir, withIntermediateDirectories: true)

        // Create synthetic worktree
        let syntheticWorktree = Worktree(
            repoID: TBDConstants.conductorsRepoID,
            name: "conductor-\(name)",
            displayName: "conductor-\(name)",
            branch: "conductor",
            path: conductorDir.path,
            status: .conductor,
            tmuxServer: TBDConstants.conductorsTmuxServer
        )
        try await db.worktrees.create(syntheticWorktree)

        // Create DB row
        var conductor = try await db.conductors.create(
            name: name,
            repos: repos,
            worktrees: worktrees,
            terminalLabels: terminalLabels,
            permissions: permissions,
            heartbeatIntervalMinutes: heartbeatIntervalMinutes
        )
        conductor.worktreeID = syntheticWorktree.id
        try await db.conductors.updateWorktreeID(conductorID: conductor.id, worktreeID: syntheticWorktree.id)

        // Write CLAUDE.md
        let repoDisplay = repos.contains("*") ? "All repos" : repos.joined(separator: ", ")
        let template = Self.generateTemplate(name: name, repos: repos, permissions: permissions)
        let claudePath = conductorDir.appendingPathComponent("CLAUDE.md")
        try template.write(to: claudePath, atomically: true, encoding: .utf8)

        return conductor
    }

    // MARK: - Start

    public func start(name: String) async throws -> Terminal {
        guard let conductor = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }
        guard let worktreeID = conductor.worktreeID else {
            throw ConductorError.noWorktree(name: name)
        }

        let conductorDir = TBDConstants.conductorsDir.appendingPathComponent(name)
        let shellCommand = "claude --dangerously-skip-permissions"

        try await tmux.ensureServer(
            server: TBDConstants.conductorsTmuxServer,
            session: "main",
            cwd: conductorDir.path
        )

        let window = try await tmux.createWindow(
            server: TBDConstants.conductorsTmuxServer,
            session: "main",
            cwd: conductorDir.path,
            shellCommand: shellCommand
        )

        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: "conductor:\(name)"
        )

        try await db.conductors.updateTerminalID(conductorID: conductor.id, terminalID: terminal.id)

        return terminal
    }

    // MARK: - Stop

    public func stop(name: String) async throws {
        guard let conductor = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }

        if let terminalID = conductor.terminalID,
           let terminal = try await db.terminals.get(id: terminalID) {
            try? await tmux.killWindow(
                server: TBDConstants.conductorsTmuxServer,
                windowID: terminal.tmuxWindowID
            )
            try await db.terminals.delete(id: terminalID)
        }

        try await db.conductors.updateTerminalID(conductorID: conductor.id, terminalID: nil)
    }

    // MARK: - Teardown

    public func teardown(name: String) async throws {
        try await stop(name: name)

        guard let conductor = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }

        // Delete synthetic worktree (cascades terminal records)
        if let worktreeID = conductor.worktreeID {
            try await db.worktrees.delete(id: worktreeID)
        }

        // Delete conductor DB row
        try await db.conductors.delete(id: conductor.id)

        // Remove directory
        let conductorDir = TBDConstants.conductorsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: conductorDir)
    }

    // MARK: - Template

    public static func generateTemplate(
        name: String,
        repos: [String],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil,
        permissions: String = "observe"
    ) -> String {
        let repoDisplay = repos.contains("*") ? "All repos" : repos.joined(separator: ", ")
        let worktreeDisplay = worktrees?.joined(separator: ", ") ?? "All worktrees"
        let labelDisplay = terminalLabels?.joined(separator: ", ") ?? "All terminals"

        return """
        # Conductor: \(name)

        You are a conductor — a persistent Claude Code session that monitors and
        orchestrates other Claude terminals managed by TBD.

        ## Your Scope
        - Repos: \(repoDisplay)
        - Worktrees: \(worktreeDisplay)
        - Terminal labels: \(labelDisplay)
        - Permissions: \(permissions)

        ## Startup Checklist

        Run this when you first start, after a restart, or after context compaction:
        1. Read `./state.json` if it exists (restore context from previous session)
        2. Run `tbd worktree list --json` to see active worktrees
        3. Run `tbd terminal list --json` to discover terminal IDs
        4. Run `tbd conductor status \(name) --json` to verify your scope
        5. Log startup in `./task-log.md`
        6. Output: "Conductor \(name) online. N terminals found across M worktrees."

        ## How You Work (Manual Polling)

        You must actively poll terminals to check on them:

        1. Run `tbd worktree list --json` to get worktree names/IDs
        2. For each worktree, run `tbd terminal list <worktree-name> --json` to get terminal IDs
        3. For each terminal of interest, run `tbd terminal output <id> --lines 50`
        4. Review the output — is the agent waiting for input?
        5. If waiting: decide to auto-respond or escalate
        6. If running: leave it alone

        ## Core Rules

        1. **Never send to running terminals.** Only respond to terminals that are
           waiting for input (look for the ❯ prompt with no "esc to interrupt" indicator).
        2. **When unsure, escalate.** The cost of a false escalation (user gets a notification)
           is much lower than a wrong auto-response (agent goes off track).
        3. **Log everything.** Every action goes in `./task-log.md`.
        4. **Keep responses SHORT.** Status updates: 1-3 sentences. Use bullet points.
        5. **Don't poll in a loop.** Check when asked or when relevant. If no terminals are
           active, say so and wait.

        ## CLI Commands

        | Command | Description |
        |---------|-------------|
        | `tbd worktree list --json` | List all worktrees with IDs |
        | `tbd terminal list <worktree> --json` | List terminals in a worktree |
        | `tbd terminal output <id> --lines 50` | Read last 50 lines of terminal output |
        | `tbd terminal send --terminal <id> --text "message"` | Send message to a terminal |
        | `tbd conductor list --json` | List all conductors |
        | `tbd conductor status \(name) --json` | Your own scope and config |
        | `tbd notify --type attention_needed "message"` | Escalate to user via macOS notification |

        Terminal IDs are UUIDs. Use the full ID from `tbd terminal list` output.

        ## Terminal States

        When reading terminal output, look for these indicators:
        - **Waiting for input:** ❯ prompt visible, status bar shows "⏵⏵" or "? for shortcuts"
        - **Running/busy:** Status bar shows "esc to interrupt" or "to stop agents"
        - **Idle (no Claude):** Shell prompt (zsh/bash), no Claude process running
        - **Unknown:** Can't determine — terminal may be dead. Escalate if persistent.

        ## Auto-Response Guidelines

        ### Safe to Auto-Respond
        - "Should I proceed?" / "Should I continue?" → Yes, if the plan looks reasonable
        - "Tests passed. What's next?" → Direct to the next logical step
        - Compilation/lint errors with obvious fixes → Suggest the fix
        - Questions about project conventions → Answer from context

        ### Always Escalate
        - Destructive actions (delete, force-push, drop table)
        - Security issues
        - Design decisions with multiple valid approaches
        - Requests for credentials or API keys
        - "I'm stuck and don't know how to proceed"
        - Anything you're unsure about

        ## Handling Send Rejections

        If `tbd terminal send` returns an error, the terminal may have transitioned
        since you last checked. Do NOT retry immediately. Re-read the terminal output
        to see its current state, then decide what to do.

        ## Escalation

        When escalating, notify the user:
        ```
        tbd notify --type attention_needed "worktree-name: brief description"
        ```

        ## State Management

        Maintain `./state.json` for context across context compactions:
        ```json
        {
          "terminals": {},
          "last_checked": null,
          "auto_responses_today": 0,
          "escalations_today": 0
        }
        ```

        Read state.json at the start of each interaction. Update it after taking action.

        ## Task Log

        Append every action to `./task-log.md` with timestamps.
        """
    }
}

public enum ConductorError: Error, LocalizedError {
    case notFound(name: String)
    case noWorktree(name: String)
    case interactConflict(existingName: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): "Conductor not found: \(name)"
        case .noWorktree(let name): "Conductor has no worktree: \(name)"
        case .interactConflict(let existing):
            "Cannot grant interact permission: conductor '\(existing)' already has interact on overlapping repos"
        }
    }
}
```

- [ ] **Step 4: Add WorktreeStore.create and delete methods if missing**

Check `Sources/TBDDaemon/Database/WorktreeStore.swift` — it should already have create/delete. If `create` takes a `Worktree` directly, it works as-is. If not, add a convenience method. Also add a `delete(id:)` method if missing.

- [ ] **Step 5: Run tests**

Run: `swift test --filter ConductorManagerTests 2>&1 | tail -10`
Expected: All 4 tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Conductor/ConductorManager.swift
git add Tests/TBDDaemonTests/ConductorManagerTests.swift
git commit -m "feat: add ConductorManager with lifecycle and CLAUDE.md template"
```

---

### Task 5: RPC Handlers + Router Wiring

**Files:**
- Create: `Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Modify: `Sources/TBDDaemon/Daemon.swift`

- [ ] **Step 1: Create conductor RPC handlers**

Create `Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift`:

```swift
import Foundation
import TBDShared

extension RPCRouter {
    func handleConductorSetup(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorSetupParams.self, from: paramsData)
        let conductor = try await conductorManager.setup(
            name: params.name,
            repos: params.repos ?? ["*"],
            worktrees: params.worktrees,
            terminalLabels: params.terminalLabels,
            interact: params.interact ?? false,
            heartbeatIntervalMinutes: params.heartbeatIntervalMinutes ?? 10
        )
        return try RPCResponse(result: conductor)
    }

    func handleConductorStart(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        let terminal = try await conductorManager.start(name: params.name)
        return try RPCResponse(result: terminal)
    }

    func handleConductorStop(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        try await conductorManager.stop(name: params.name)
        return .ok()
    }

    func handleConductorTeardown(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        try await conductorManager.teardown(name: params.name)
        return .ok()
    }

    func handleConductorList() async throws -> RPCResponse {
        let conductors = try await db.conductors.list()
        return try RPCResponse(result: ConductorListResult(conductors: conductors))
    }

    func handleConductorStatus(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConductorNameParams.self, from: paramsData)
        guard let conductor = try await db.conductors.get(name: params.name) else {
            return RPCResponse(error: "Conductor not found: \(params.name)")
        }
        var isRunning = false
        if let terminalID = conductor.terminalID,
           let terminal = try await db.terminals.get(id: terminalID) {
            isRunning = await tmux.windowExists(
                server: TBDConstants.conductorsTmuxServer,
                windowID: terminal.tmuxWindowID
            )
        }
        return try RPCResponse(result: ConductorStatusResult(conductor: conductor, isRunning: isRunning))
    }
}
```

- [ ] **Step 2: Add ConductorManager to RPCRouter**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add property:

```swift
public let conductorManager: ConductorManager
```

Update `init` to accept and store it:

```swift
public init(
    db: TBDDatabase,
    lifecycle: WorktreeLifecycle,
    tmux: TmuxManager,
    git: GitManager = GitManager(),
    startTime: Date = Date(),
    subscriptions: StateSubscriptionManager = StateSubscriptionManager(),
    prManager: PRStatusManager = PRStatusManager(),
    conductorManager: ConductorManager? = nil
) {
    self.db = db
    self.lifecycle = lifecycle
    self.tmux = tmux
    self.git = git
    self.startTime = startTime
    self.subscriptions = subscriptions
    self.prManager = prManager
    self.suspendResumeCoordinator = SuspendResumeCoordinator(db: db, tmux: tmux)
    self.conductorManager = conductorManager ?? ConductorManager(db: db, tmux: tmux)
}
```

Add cases to the `handle` switch:

```swift
case RPCMethod.terminalOutput:
    return try await handleTerminalOutput(request.paramsData)
case RPCMethod.conductorSetup:
    return try await handleConductorSetup(request.paramsData)
case RPCMethod.conductorStart:
    return try await handleConductorStart(request.paramsData)
case RPCMethod.conductorStop:
    return try await handleConductorStop(request.paramsData)
case RPCMethod.conductorTeardown:
    return try await handleConductorTeardown(request.paramsData)
case RPCMethod.conductorList:
    return try await handleConductorList()
case RPCMethod.conductorStatus:
    return try await handleConductorStatus(request.paramsData)
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift
git add Sources/TBDDaemon/Server/RPCRouter.swift Sources/TBDDaemon/Daemon.swift
git commit -m "feat: wire conductor RPC handlers into router"
```

---

### Task 6: CLI Commands

**Files:**
- Create: `Sources/TBDCLI/Commands/ConductorCommands.swift`
- Modify: `Sources/TBDCLI/TBD.swift`

- [ ] **Step 1: Create ConductorCommands**

Create `Sources/TBDCLI/Commands/ConductorCommands.swift`:

```swift
import ArgumentParser
import Foundation
import TBDShared

struct ConductorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conductor",
        abstract: "Manage conductors",
        subcommands: [
            ConductorSetup.self,
            ConductorStart.self,
            ConductorStop.self,
            ConductorTeardown.self,
            ConductorListCmd.self,
            ConductorStatusCmd.self,
        ]
    )
}

// MARK: - conductor setup

struct ConductorSetup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create a new conductor"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Option(name: .long, help: "Comma-separated repo IDs (default: all)")
    var repos: String?

    @Option(name: .long, help: "Comma-separated worktree name patterns")
    var worktrees: String?

    @Option(name: .long, help: "Comma-separated terminal labels to monitor")
    var terminalLabels: String?

    @Flag(name: .long, help: "Grant interact permission (can send to terminals)")
    var interact = false

    @Option(name: .long, help: "Heartbeat interval in minutes (default: 10, 0 = disabled)")
    var heartbeat: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let reposList = repos?.split(separator: ",").map(String.init)
        let worktreesList = worktrees?.split(separator: ",").map(String.init)
        let labelsList = terminalLabels?.split(separator: ",").map(String.init)

        let conductor: Conductor = try client.call(
            method: RPCMethod.conductorSetup,
            params: ConductorSetupParams(
                name: name,
                repos: reposList,
                worktrees: worktreesList,
                terminalLabels: labelsList,
                interact: interact,
                heartbeatIntervalMinutes: heartbeat
            ),
            resultType: Conductor.self
        )

        if json {
            printJSON(conductor)
        } else {
            print("Created conductor: \(conductor.name)")
            print("  ID:          \(conductor.id)")
            print("  Repos:       \(conductor.repos.joined(separator: ", "))")
            print("  Permissions: \(conductor.permissions)")
            print("  Heartbeat:   \(conductor.heartbeatIntervalMinutes)m")
        }
    }
}

// MARK: - conductor start

struct ConductorStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a conductor session"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let terminal: Terminal = try client.call(
            method: RPCMethod.conductorStart,
            params: ConductorNameParams(name: name),
            resultType: Terminal.self
        )

        if json {
            printJSON(terminal)
        } else {
            print("Started conductor: \(name)")
            print("  Terminal: \(terminal.id)")
            print("  Window:   \(terminal.tmuxWindowID)")
        }
    }
}

// MARK: - conductor stop

struct ConductorStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a conductor session"
    )

    @Argument(help: "Conductor name")
    var name: String

    mutating func run() async throws {
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.conductorStop,
            params: ConductorNameParams(name: name)
        )
        print("Stopped conductor: \(name)")
    }
}

// MARK: - conductor teardown

struct ConductorTeardown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teardown",
        abstract: "Remove a conductor completely"
    )

    @Argument(help: "Conductor name")
    var name: String

    mutating func run() async throws {
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.conductorTeardown,
            params: ConductorNameParams(name: name)
        )
        print("Removed conductor: \(name)")
    }
}

// MARK: - conductor list

struct ConductorListCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all conductors"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let result: ConductorListResult = try client.call(
            method: RPCMethod.conductorList,
            params: EmptyParams(),
            resultType: ConductorListResult.self
        )

        if json {
            printJSON(result.conductors)
        } else {
            if result.conductors.isEmpty {
                print("No conductors configured.")
                return
            }
            let header = String(format: "%-20s  %-20s  %-18s  %s", "NAME", "REPOS", "PERMISSIONS", "HEARTBEAT")
            print(header)
            print(String(repeating: "-", count: 75))
            for c in result.conductors {
                let reposStr = c.repos.contains("*") ? "*" : c.repos.joined(separator: ",")
                let line = String(format: "%-20s  %-20s  %-18s  %dm",
                    c.name as NSString,
                    String(reposStr.prefix(20)) as NSString,
                    c.permissions as NSString,
                    c.heartbeatIntervalMinutes)
                print(line)
            }
        }
    }
}

// MARK: - conductor status

struct ConductorStatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show conductor status"
    )

    @Argument(help: "Conductor name")
    var name: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let result: ConductorStatusResult = try client.call(
            method: RPCMethod.conductorStatus,
            params: ConductorNameParams(name: name),
            resultType: ConductorStatusResult.self
        )

        if json {
            printJSON(result)
        } else {
            let c = result.conductor
            print("Conductor: \(c.name)")
            print("  ID:          \(c.id)")
            print("  Running:     \(result.isRunning)")
            print("  Repos:       \(c.repos.joined(separator: ", "))")
            print("  Permissions: \(c.permissions)")
            print("  Heartbeat:   \(c.heartbeatIntervalMinutes)m")
            if let wt = c.worktrees { print("  Worktrees:   \(wt.joined(separator: ", "))") }
            if let labels = c.terminalLabels { print("  Labels:      \(labels.joined(separator: ", "))") }
        }
    }
}

// Empty params for list endpoints
private struct EmptyParams: Codable {}
```

- [ ] **Step 2: Register ConductorCommand**

In `Sources/TBDCLI/TBD.swift`, add to subcommands:

```swift
subcommands: [
    RepoCommand.self,
    WorktreeCommand.self,
    TerminalCommand.self,
    ConductorCommand.self,
    NotifyCommand.self,
    DaemonCommand.self,
    SetupHooksCommand.self,
    CleanupCommand.self,
]
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDCLI/Commands/ConductorCommands.swift Sources/TBDCLI/TBD.swift
git commit -m "feat: add conductor CLI commands"
```

---

### Task 7: StateDelta Suppression + Worktree List Filtering

**Files:**
- Modify: `Sources/TBDDaemon/Server/StateSubscription.swift`
- Modify: `Sources/TBDDaemon/Database/WorktreeStore.swift`
- Test: `Tests/TBDDaemonTests/DatabaseTests.swift`

- [ ] **Step 1: Write test for worktree list filtering**

Add to `Tests/TBDDaemonTests/DatabaseTests.swift`:

```swift
@Test func worktreeListExcludesConductorByDefault() async throws {
    let db = try TBDDatabase(inMemory: true)

    // The synthetic conductors repo is already inserted by v9 migration
    let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "Test")

    // Create a normal worktree
    let normal = Worktree(repoID: repo.id, name: "normal", displayName: "normal",
                          branch: "main", path: "/tmp/normal", status: .active,
                          tmuxServer: "test")
    try await db.worktrees.create(normal)

    // Create a conductor worktree
    let conductor = Worktree(repoID: TBDConstants.conductorsRepoID,
                             name: "conductor-test", displayName: "conductor-test",
                             branch: "conductor", path: "/tmp/conductor",
                             status: .conductor, tmuxServer: "tbd-conductor")
    try await db.worktrees.create(conductor)

    // Default list should exclude conductor
    let defaultList = try await db.worktrees.list()
    #expect(defaultList.count == 1)
    #expect(defaultList[0].name == "normal")

    // Explicit conductor list
    let conductorList = try await db.worktrees.list(status: .conductor)
    #expect(conductorList.count == 1)
    #expect(conductorList[0].name == "conductor-test")
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter worktreeListExcludesConductorByDefault 2>&1 | tail -5`
Expected: FAIL — conductor worktrees not filtered

- [ ] **Step 3: Update WorktreeStore.list to exclude .conductor by default**

In `Sources/TBDDaemon/Database/WorktreeStore.swift`, find the `list` method and update it to exclude `.conductor` when no status filter is specified:

```swift
public func list(repoID: UUID? = nil, status: WorktreeStatus? = nil) async throws -> [Worktree] {
    try await writer.read { db in
        var request = WorktreeRecord.all()
        if let repoID {
            request = request.filter(Column("repoID") == repoID.uuidString)
        }
        if let status {
            request = request.filter(Column("status") == status.rawValue)
        } else {
            // Exclude conductor worktrees from default listing
            request = request.filter(Column("status") != WorktreeStatus.conductor.rawValue)
        }
        return try request.fetchAll(db).map { $0.toModel() }
    }
}
```

- [ ] **Step 4: Suppress conductor deltas in StateSubscriptionManager**

In `Sources/TBDDaemon/Server/StateSubscription.swift`, update `broadcast`:

```swift
public func broadcast(delta: StateDelta) {
    // Suppress deltas for conductor worktrees — app can't display them yet
    switch delta {
    case .worktreeCreated(let d):
        if d.name.hasPrefix("conductor-") { return }
    case .worktreeArchived, .worktreeRevived:
        break // These don't carry name; conductor worktrees are rarely archived/revived
    default:
        break
    }

    guard let data = try? JSONEncoder().encode(delta) else { return }

    lock.lock()
    let currentSubscribers = subscribers
    lock.unlock()

    for (_, callback) in currentSubscribers {
        callback(data)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter worktreeListExcludesConductorByDefault 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (existing + new)

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Database/WorktreeStore.swift
git add Sources/TBDDaemon/Server/StateSubscription.swift
git add Tests/TBDDaemonTests/DatabaseTests.swift
git commit -m "feat: filter conductor worktrees from listings and suppress deltas"
```

---

### Task 8: Filter Synthetic Repo from repo.list

**Files:**
- Modify: `Sources/TBDDaemon/Database/RepoStore.swift`
- Test: `Tests/TBDDaemonTests/DatabaseTests.swift`

- [ ] **Step 1: Write test**

Add to `Tests/TBDDaemonTests/DatabaseTests.swift`:

```swift
@Test func repoListExcludesSyntheticConductorsRepo() async throws {
    let db = try TBDDatabase(inMemory: true)

    // Create a real repo
    let repo = try await db.repos.create(path: "/tmp/real-repo", displayName: "Real")

    // Default list should only show real repos, not the synthetic conductors repo
    let all = try await db.repos.list()
    #expect(all.count == 1)
    #expect(all[0].displayName == "Real")
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter repoListExcludesSyntheticConductorsRepo 2>&1 | tail -5`
Expected: FAIL — synthetic repo appears in list

- [ ] **Step 3: Update RepoStore.list**

In `Sources/TBDDaemon/Database/RepoStore.swift`, filter out the synthetic repo:

```swift
public func list() async throws -> [Repo] {
    try await writer.read { db in
        try RepoRecord
            .filter(Column("id") != TBDConstants.conductorsRepoID.uuidString)
            .fetchAll(db)
            .map { $0.toModel() }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter repoListExcludesSyntheticConductorsRepo 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Database/RepoStore.swift Tests/TBDDaemonTests/DatabaseTests.swift
git commit -m "feat: filter synthetic conductors repo from repo.list"
```

---

### Task 9: Final Integration — Build + Smoke Test

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors

- [ ] **Step 2: Full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Verify CLI help**

Run: `swift run tbd conductor --help 2>&1`
Expected: Shows subcommands: setup, start, stop, teardown, list, status

Run: `swift run tbd terminal output --help 2>&1`
Expected: Shows terminal output usage

- [ ] **Step 4: Commit any final fixups**

If any compilation issues were found and fixed, commit them:

```bash
git add -A
git commit -m "fix: resolve Phase 1a integration issues"
```
