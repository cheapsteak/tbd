# TBD Daemon + CLI Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless daemon (`tbdd`) and CLI (`tbd`) so that agents and users can create/list/archive worktrees, manage repos, send notifications, and manage terminals — all from the command line.

**Architecture:** Three SPM targets: `TBDShared` (library with models + protocol types), `TBDDaemon` (executable daemon with SQLite, Unix socket + HTTP server, tmux/git/hook managers), and `TBDCLI` (executable CLI that connects to daemon socket). The daemon is the sole owner of state; the CLI is a thin RPC client.

**Tech Stack:** Swift 6.0, SPM, GRDB.swift (SQLite), swift-argument-parser (CLI), Swift NIO (networking), macOS 14+

**Spec:** `docs/superpowers/specs/2026-03-21-tbd-design.md`

**Phase 2 (SwiftUI App)** will be a separate plan covering terminal rendering with SwiftTerm, the sidebar UI, split layout system, and settings.

---

## File Structure

```
Sources/
├── TBDShared/
│   ├── Models.swift              # Repo, Worktree, Terminal, Notification structs
│   ├── RPCProtocol.swift         # RPCRequest, RPCResponse, all method/param types
│   └── Constants.swift           # Paths (~/.tbd/), version string, socket path
│
├── TBDDaemon/
│   ├── main.swift                # Entry point, signal handlers, lifecycle
│   ├── Daemon.swift              # Top-level daemon orchestrator
│   ├── Database/
│   │   ├── Database.swift        # GRDB DatabasePool setup, WAL mode, migrations
│   │   ├── RepoStore.swift       # Repo CRUD operations
│   │   ├── WorktreeStore.swift   # Worktree CRUD operations
│   │   ├── TerminalStore.swift   # Terminal CRUD operations
│   │   └── NotificationStore.swift # Notification CRUD + unread aggregation
│   ├── Git/
│   │   └── GitManager.swift      # git fetch, worktree add/remove/list, branch detection
│   ├── Tmux/
│   │   └── TmuxManager.swift     # tmux server lifecycle, window CRUD, pane ID queries
│   ├── Hooks/
│   │   └── HookResolver.swift    # Priority chain resolution + execution
│   ├── Names/
│   │   ├── NameGenerator.swift   # YYYYMMDD-adjective-animal generation
│   │   ├── Adjectives.swift      # Word list (~500 adjectives)
│   │   └── Animals.swift         # Word list (~500 animals)
│   ├── Lifecycle/
│   │   └── WorktreeLifecycle.swift # Orchestrates create/archive/revive/reconcile
│   ├── Server/
│   │   ├── RPCRouter.swift       # Maps RPC method names to handler functions
│   │   ├── SocketServer.swift    # Unix domain socket server (NIO)
│   │   ├── HTTPServer.swift      # HTTP server on localhost (NIO)
│   │   └── StateSubscription.swift # Streaming state deltas to connected clients
│   └── PIDFile.swift             # PID file management + stale detection
│
├── TBDCLI/
│   ├── TBD.swift                 # @main entry, top-level argument parser command
│   ├── SocketClient.swift        # Connects to daemon socket, sends RPC, reads response
│   ├── Commands/
│   │   ├── RepoCommands.swift    # repo add/remove/list
│   │   ├── WorktreeCommands.swift # worktree create/list/archive/revive/rename
│   │   ├── TerminalCommands.swift # terminal create/list/send
│   │   ├── NotifyCommand.swift   # notify --type --message
│   │   ├── DaemonCommands.swift  # daemon status
│   │   └── SetupHooksCommand.swift # setup-hooks --global/--repo
│   └── PathResolver.swift        # PWD-to-worktree/repo resolution
│
Tests/
├── TBDSharedTests/
│   └── ModelsTests.swift         # Codable round-trip tests
├── TBDDaemonTests/
│   ├── DatabaseTests.swift       # Store CRUD tests (in-memory DB)
│   ├── NameGeneratorTests.swift  # Format + uniqueness tests
│   ├── GitManagerTests.swift     # Git operations with temp repos
│   ├── HookResolverTests.swift   # Priority chain resolution tests
│   ├── TmuxManagerTests.swift    # Tmux command generation tests
│   ├── WorktreeLifecycleTests.swift # Integration tests
│   └── RPCRouterTests.swift      # Request routing tests
└── IntegrationTests/
    └── DaemonCLITests.swift      # Start daemon, run CLI commands, verify
```

---

### Task 1: Package.swift + Project Scaffolding

**Files:**
- Create: `Package.swift`
- Create: `Sources/TBDShared/Constants.swift`
- Create: `Sources/TBDDaemon/main.swift`
- Create: `Sources/TBDCLI/TBD.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TBD",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "TBDShared",
            path: "Sources/TBDShared"
        ),
        .executableTarget(
            name: "TBDDaemon",
            dependencies: [
                "TBDShared",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/TBDDaemon"
        ),
        .executableTarget(
            name: "TBDCLI",
            dependencies: [
                "TBDShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/TBDCLI"
        ),
        .testTarget(
            name: "TBDSharedTests",
            dependencies: ["TBDShared"]
        ),
        .testTarget(
            name: "TBDDaemonTests",
            dependencies: [
                "TBDDaemon",
                "TBDShared",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Create minimal source files so the package compiles**

`Sources/TBDShared/Constants.swift`:
```swift
import Foundation

public enum TBDConstants {
    public static let version = "0.1.0"
    public static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tbd")
    public static let socketPath = configDir.appendingPathComponent("sock").path
    public static let databasePath = configDir.appendingPathComponent("state.db").path
    public static let pidFilePath = configDir.appendingPathComponent("tbdd.pid").path
    public static let portFilePath = configDir.appendingPathComponent("port").path
}
```

`Sources/TBDDaemon/main.swift`:
```swift
import Foundation
print("tbdd v\(TBDConstants.version)")
```

Note: `main.swift` must `import TBDShared` — add that import.

`Sources/TBDCLI/TBD.swift`:
```swift
import ArgumentParser

@main
struct TBDCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tbd",
        abstract: "TBD workspace manager CLI",
        version: "0.1.0"
    )
}
```

- [ ] **Step 3: Verify the package builds**

Run: `cd /Users/chang/projects/tbd && swift build 2>&1`
Expected: Build succeeds for all three targets.

- [ ] **Step 4: Create empty test files and verify tests run**

`Tests/TBDSharedTests/ModelsTests.swift`:
```swift
import XCTest
@testable import TBDShared

final class ModelsTests: XCTestCase {
    func testConstantsExist() {
        XCTAssertEqual(TBDConstants.version, "0.1.0")
    }
}
```

Run: `swift test 2>&1`
Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/ Tests/
git commit -m "feat: initial package scaffolding with three targets"
```

---

### Task 2: Shared Data Models + RPC Protocol Types

**Files:**
- Create: `Sources/TBDShared/Models.swift`
- Create: `Sources/TBDShared/RPCProtocol.swift`
- Test: `Tests/TBDSharedTests/ModelsTests.swift`

- [ ] **Step 1: Write tests for model Codable round-trips**

```swift
import XCTest
@testable import TBDShared

final class ModelsTests: XCTestCase {
    func testConstantsExist() {
        XCTAssertEqual(TBDConstants.version, "0.1.0")
    }

    func testRepoRoundTrip() throws {
        let repo = Repo(
            id: UUID(),
            path: "/Users/test/project",
            remoteURL: "git@github.com:test/project.git",
            displayName: "project",
            defaultBranch: "main",
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(Repo.self, from: data)
        XCTAssertEqual(repo.id, decoded.id)
        XCTAssertEqual(repo.path, decoded.path)
        XCTAssertEqual(repo.defaultBranch, decoded.defaultBranch)
    }

    func testWorktreeRoundTrip() throws {
        let wt = Worktree(
            id: UUID(),
            repoID: UUID(),
            name: "20260321-fuzzy-penguin",
            displayName: "fuzzy-penguin",
            branch: "tbd/20260321-fuzzy-penguin",
            path: "/Users/test/project/.tbd/worktrees/20260321-fuzzy-penguin",
            status: .active,
            createdAt: Date(),
            archivedAt: nil,
            tmuxServer: "tbd-a1b2c3d4"
        )
        let data = try JSONEncoder().encode(wt)
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)
        XCTAssertEqual(wt.id, decoded.id)
        XCTAssertEqual(wt.status, .active)
    }

    func testNotificationTypeOrdering() {
        XCTAssertTrue(NotificationType.error.severity > NotificationType.attentionNeeded.severity)
        XCTAssertTrue(NotificationType.attentionNeeded.severity > NotificationType.taskComplete.severity)
        XCTAssertTrue(NotificationType.taskComplete.severity > NotificationType.responseComplete.severity)
    }

    func testRPCRequestRoundTrip() throws {
        let request = RPCRequest(
            method: "worktree.create",
            params: .worktreeCreate(WorktreeCreateParams(repoID: UUID()))
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(decoded.method, "worktree.create")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: FAIL — types don't exist yet.

- [ ] **Step 3: Write Models.swift**

```swift
import Foundation

public struct Repo: Codable, Sendable, Identifiable {
    public let id: UUID
    public var path: String
    public var remoteURL: String?
    public var displayName: String
    public var defaultBranch: String
    public var createdAt: Date

    public init(id: UUID = UUID(), path: String, remoteURL: String? = nil,
                displayName: String, defaultBranch: String = "main", createdAt: Date = Date()) {
        self.id = id
        self.path = path
        self.remoteURL = remoteURL
        self.displayName = displayName
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
    }
}

public enum WorktreeStatus: String, Codable, Sendable {
    case active, archived
}

public struct Worktree: Codable, Sendable, Identifiable {
    public let id: UUID
    public var repoID: UUID
    public var name: String
    public var displayName: String
    public var branch: String
    public var path: String
    public var status: WorktreeStatus
    public var createdAt: Date
    public var archivedAt: Date?
    public var tmuxServer: String

    public init(id: UUID = UUID(), repoID: UUID, name: String, displayName: String,
                branch: String, path: String, status: WorktreeStatus = .active,
                createdAt: Date = Date(), archivedAt: Date? = nil, tmuxServer: String) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.displayName = displayName
        self.branch = branch
        self.path = path
        self.status = status
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.tmuxServer = tmuxServer
    }
}

public struct Terminal: Codable, Sendable, Identifiable {
    public let id: UUID
    public var worktreeID: UUID
    public var tmuxWindowID: String
    public var tmuxPaneID: String
    public var label: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.label = label
        self.createdAt = createdAt
    }
}

public enum NotificationType: String, Codable, Sendable {
    case responseComplete = "response_complete"
    case error
    case taskComplete = "task_complete"
    case attentionNeeded = "attention_needed"

    public var severity: Int {
        switch self {
        case .error: 4
        case .attentionNeeded: 3
        case .taskComplete: 2
        case .responseComplete: 1
        }
    }
}

public struct TBDNotification: Codable, Sendable, Identifiable {
    public let id: UUID
    public var worktreeID: UUID
    public var type: NotificationType
    public var message: String?
    public var read: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, type: NotificationType,
                message: String? = nil, read: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.type = type
        self.message = message
        self.read = read
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Write RPCProtocol.swift**

```swift
import Foundation

public struct RPCRequest: Codable, Sendable {
    public let method: String
    public let params: RPCParams

    public init(method: String, params: RPCParams) {
        self.method = method
        self.params = params
    }
}

public enum RPCParams: Codable, Sendable {
    case repoAdd(RepoAddParams)
    case repoRemove(RepoRemoveParams)
    case repoList
    case worktreeCreate(WorktreeCreateParams)
    case worktreeList(WorktreeListParams)
    case worktreeArchive(WorktreeArchiveParams)
    case worktreeRevive(WorktreeReviveParams)
    case worktreeRename(WorktreeRenameParams)
    case terminalCreate(TerminalCreateParams)
    case terminalList(TerminalListParams)
    case terminalSend(TerminalSendParams)
    case notify(NotifyParams)
    case daemonStatus
    case stateSubscribe
    case resolvePath(ResolvePathParams)
}

// Parameter structs
public struct RepoAddParams: Codable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct RepoRemoveParams: Codable, Sendable {
    public let repoID: UUID
    public let force: Bool
    public init(repoID: UUID, force: Bool = false) { self.repoID = repoID; self.force = force }
}

public struct WorktreeCreateParams: Codable, Sendable {
    public let repoID: UUID
    public init(repoID: UUID) { self.repoID = repoID }
}

public struct WorktreeListParams: Codable, Sendable {
    public let repoID: UUID?
    public let status: WorktreeStatus?
    public init(repoID: UUID? = nil, status: WorktreeStatus? = nil) {
        self.repoID = repoID; self.status = status
    }
}

public struct WorktreeArchiveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let force: Bool
    public init(worktreeID: UUID, force: Bool = false) {
        self.worktreeID = worktreeID; self.force = force
    }
}

public struct WorktreeReviveParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct WorktreeRenameParams: Codable, Sendable {
    public let worktreeID: UUID
    public let displayName: String
    public init(worktreeID: UUID, displayName: String) {
        self.worktreeID = worktreeID; self.displayName = displayName
    }
}

public struct TerminalCreateParams: Codable, Sendable {
    public let worktreeID: UUID
    public let cmd: String?
    public init(worktreeID: UUID, cmd: String? = nil) {
        self.worktreeID = worktreeID; self.cmd = cmd
    }
}

public struct TerminalListParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct TerminalSendParams: Codable, Sendable {
    public let terminalID: UUID
    public let text: String
    public init(terminalID: UUID, text: String) {
        self.terminalID = terminalID; self.text = text
    }
}

public struct NotifyParams: Codable, Sendable {
    public let worktreeID: UUID?
    public let type: NotificationType
    public let message: String?
    public init(worktreeID: UUID? = nil, type: NotificationType, message: String? = nil) {
        self.worktreeID = worktreeID; self.type = type; self.message = message
    }
}

public struct ResolvePathParams: Codable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

// Response types
public struct RPCResponse: Codable, Sendable {
    public let success: Bool
    public let result: RPCResult?
    public let error: String?

    public init(result: RPCResult) {
        self.success = true; self.result = result; self.error = nil
    }
    public init(error: String) {
        self.success = false; self.result = nil; self.error = error
    }
}

public enum RPCResult: Codable, Sendable {
    case repo(Repo)
    case repos([Repo])
    case worktree(Worktree)
    case worktrees([Worktree])
    case terminal(Terminal)
    case terminals([Terminal])
    case notification(TBDNotification)
    case daemonStatus(DaemonStatusResult)
    case ok
    case resolvedPath(ResolvedPathResult)
}

public struct DaemonStatusResult: Codable, Sendable {
    public let version: String
    public let uptime: TimeInterval
    public let connectedClients: Int
    public init(version: String, uptime: TimeInterval, connectedClients: Int) {
        self.version = version; self.uptime = uptime; self.connectedClients = connectedClients
    }
}

public struct ResolvedPathResult: Codable, Sendable {
    public let repoID: UUID?
    public let worktreeID: UUID?
    public init(repoID: UUID?, worktreeID: UUID?) {
        self.repoID = repoID; self.worktreeID = worktreeID
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDShared/ Tests/TBDSharedTests/
git commit -m "feat: add shared data models and RPC protocol types"
```

---

### Task 3: SQLite Database Layer

**Files:**
- Create: `Sources/TBDDaemon/Database/Database.swift`
- Create: `Sources/TBDDaemon/Database/RepoStore.swift`
- Create: `Sources/TBDDaemon/Database/WorktreeStore.swift`
- Create: `Sources/TBDDaemon/Database/TerminalStore.swift`
- Create: `Sources/TBDDaemon/Database/NotificationStore.swift`
- Test: `Tests/TBDDaemonTests/DatabaseTests.swift`

- [ ] **Step 1: Write database tests**

```swift
import XCTest
import GRDB
@testable import TBDShared
@testable import TBDDaemon

final class DatabaseTests: XCTestCase {
    var db: TBDDatabase!

    override func setUp() async throws {
        db = try TBDDatabase(inMemory: true)
    }

    // Repo tests
    func testCreateAndListRepos() async throws {
        let repo = try await db.repos.create(path: "/tmp/test-repo", displayName: "test", defaultBranch: "main")
        XCTAssertEqual(repo.displayName, "test")

        let repos = try await db.repos.list()
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].id, repo.id)
    }

    func testRemoveRepo() async throws {
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        try await db.repos.remove(id: repo.id)
        let repos = try await db.repos.list()
        XCTAssertTrue(repos.isEmpty)
    }

    // Worktree tests
    func testCreateAndListWorktrees() async throws {
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "20260321-fuzzy-penguin",
            branch: "tbd/20260321-fuzzy-penguin",
            path: "/tmp/test/.tbd/worktrees/20260321-fuzzy-penguin",
            tmuxServer: "tbd-a1b2c3d4"
        )
        XCTAssertEqual(wt.status, .active)
        XCTAssertEqual(wt.displayName, "20260321-fuzzy-penguin")

        let worktrees = try await db.worktrees.list(repoID: repo.id)
        XCTAssertEqual(worktrees.count, 1)
    }

    func testArchiveWorktree() async throws {
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.archive(id: wt.id)
        let archived = try await db.worktrees.get(id: wt.id)
        XCTAssertEqual(archived?.status, .archived)
        XCTAssertNotNil(archived?.archivedAt)
    }

    func testRenameWorktree() async throws {
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        try await db.worktrees.rename(id: wt.id, displayName: "My Feature")
        let renamed = try await db.worktrees.get(id: wt.id)
        XCTAssertEqual(renamed?.displayName, "My Feature")
    }

    // Terminal tests
    func testCreateAndListTerminals() async throws {
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        let term = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0", label: "claude"
        )
        XCTAssertEqual(term.label, "claude")

        let terminals = try await db.terminals.list(worktreeID: wt.id)
        XCTAssertEqual(terminals.count, 1)
    }

    // Notification tests
    func testCreateAndReadNotifications() async throws {
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        _ = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        _ = try await db.notifications.create(worktreeID: wt.id, type: .error, message: "build failed")

        let unread = try await db.notifications.unread(worktreeID: wt.id)
        XCTAssertEqual(unread.count, 2)

        try await db.notifications.markRead(worktreeID: wt.id)
        let afterRead = try await db.notifications.unread(worktreeID: wt.id)
        XCTAssertTrue(afterRead.isEmpty)
    }

    func testHighestSeverityNotification() async throws {
        let repo = try await db.repos.create(path: "/tmp/test", displayName: "test", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: "/tmp/test/.tbd/worktrees/test-wt", tmuxServer: "tbd-a1b2c3d4"
        )
        _ = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        _ = try await db.notifications.create(worktreeID: wt.id, type: .error)

        let highest = try await db.notifications.highestSeverity(worktreeID: wt.id)
        XCTAssertEqual(highest, .error)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DatabaseTests 2>&1`
Expected: FAIL — types don't exist yet.

- [ ] **Step 3: Implement Database.swift**

Create `Sources/TBDDaemon/Database/Database.swift` with:
- `TBDDatabase` class that holds a GRDB `DatabasePool` (or `DatabaseQueue` for in-memory)
- `init(path:)` for production, `init(inMemory:)` for tests
- Enable WAL mode
- Run migrations to create all 4 tables matching the spec's schema
- Expose `.repos`, `.worktrees`, `.terminals`, `.notifications` store accessors

Use GRDB's `DatabaseMigrator` with a single `v1` migration that creates all tables.

- [ ] **Step 4: Implement RepoStore.swift**

CRUD for repos table: `create(path:displayName:defaultBranch:remoteURL:)`, `list()`, `get(id:)`, `remove(id:)`, `findByPath(path:)`.

- [ ] **Step 5: Implement WorktreeStore.swift**

CRUD for worktrees: `create(repoID:name:branch:path:tmuxServer:)`, `list(repoID:status:)`, `get(id:)`, `archive(id:)`, `revive(id:)`, `rename(id:displayName:)`, `findByPath(path:)`, `deleteForRepo(repoID:)`.

- [ ] **Step 6: Implement TerminalStore.swift**

CRUD for terminals: `create(worktreeID:tmuxWindowID:tmuxPaneID:label:)`, `list(worktreeID:)`, `get(id:)`, `delete(id:)`, `deleteForWorktree(worktreeID:)`.

- [ ] **Step 7: Implement NotificationStore.swift**

CRUD for notifications: `create(worktreeID:type:message:)`, `unread(worktreeID:)`, `markRead(worktreeID:)`, `highestSeverity(worktreeID:)`.

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --filter DatabaseTests 2>&1`
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/TBDDaemon/Database/ Tests/TBDDaemonTests/
git commit -m "feat: add SQLite database layer with GRDB"
```

---

### Task 4: Name Generator

**Files:**
- Create: `Sources/TBDDaemon/Names/NameGenerator.swift`
- Create: `Sources/TBDDaemon/Names/Adjectives.swift`
- Create: `Sources/TBDDaemon/Names/Animals.swift`
- Test: `Tests/TBDDaemonTests/NameGeneratorTests.swift`

- [ ] **Step 1: Write tests**

```swift
import XCTest
@testable import TBDDaemon

final class NameGeneratorTests: XCTestCase {
    func testNameFormat() {
        let name = NameGenerator.generate()
        let parts = name.split(separator: "-")
        // Format: YYYYMMDD-adjective-animal
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 8) // YYYYMMDD
        XCTAssertTrue(Int(parts[0]) != nil) // numeric date
    }

    func testNamesAreUnique() {
        let names = (0..<100).map { _ in NameGenerator.generate() }
        let uniqueNames = Set(names)
        // With ~500 adjectives * ~500 animals, collisions in 100 tries should be near-zero
        XCTAssertEqual(names.count, uniqueNames.count)
    }

    func testDatePrefix() {
        let name = NameGenerator.generate()
        let dateStr = String(name.prefix(8))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        XCTAssertNotNil(formatter.date(from: dateStr))
    }

    func testWordListsArePopulated() {
        XCTAssertGreaterThan(NameGenerator.adjectives.count, 100)
        XCTAssertGreaterThan(NameGenerator.animals.count, 100)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NameGeneratorTests 2>&1`
Expected: FAIL.

- [ ] **Step 3: Create word lists**

`Adjectives.swift`: A static array of ~500 common, fun adjectives (e.g. "fuzzy", "brave", "calm", "dizzy", "eager", "fancy", ...). All lowercase, no hyphens.

`Animals.swift`: A static array of ~500 animals (e.g. "penguin", "falcon", "otter", "panda", "gecko", ...). All lowercase, no hyphens.

Find word lists online or generate them. They should be large enough that collisions within a day are extremely unlikely (500 * 500 = 250,000 combinations per day).

- [ ] **Step 4: Implement NameGenerator.swift**

```swift
import Foundation

public enum NameGenerator {
    public static let adjectives: [String] = WordLists.adjectives
    public static let animals: [String] = WordLists.animals

    public static func generate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: Date())
        let adj = adjectives.randomElement()!
        let animal = animals.randomElement()!
        return "\(date)-\(adj)-\(animal)"
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter NameGeneratorTests 2>&1`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Names/ Tests/TBDDaemonTests/
git commit -m "feat: add YYYYMMDD-adjective-animal name generator"
```

---

### Task 5: Git Manager

**Files:**
- Create: `Sources/TBDDaemon/Git/GitManager.swift`
- Test: `Tests/TBDDaemonTests/GitManagerTests.swift`

- [ ] **Step 1: Write tests**

Tests use a temporary git repo created in `setUp`:

```swift
import XCTest
@testable import TBDDaemon

final class GitManagerTests: XCTestCase {
    var tempDir: URL!
    var repoDir: URL!
    var git: GitManager!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repoDir = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // Init a bare-ish repo with an initial commit
        try await shell("git init", at: repoDir)
        try await shell("git commit --allow-empty -m 'init'", at: repoDir)
        git = GitManager()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDetectDefaultBranch() async throws {
        let branch = try await git.detectDefaultBranch(repoPath: repoDir.path)
        // Fresh git init uses "main" or "master" depending on config
        XCTAssertTrue(["main", "master"].contains(branch))
    }

    func testIsGitRepo() async throws {
        XCTAssertTrue(try await git.isGitRepo(path: repoDir.path))
        XCTAssertFalse(try await git.isGitRepo(path: tempDir.path))
    }

    func testWorktreeAddAndList() async throws {
        let wtPath = tempDir.appendingPathComponent("wt1").path
        let branch = try await git.detectDefaultBranch(repoPath: repoDir.path)
        try await git.worktreeAdd(repoPath: repoDir.path, worktreePath: wtPath, branch: "tbd/test", baseBranch: branch)

        let worktrees = try await git.worktreeList(repoPath: repoDir.path)
        XCTAssertTrue(worktrees.count >= 2) // main + new worktree

        // Verify the worktree directory exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))
    }

    func testWorktreeRemove() async throws {
        let wtPath = tempDir.appendingPathComponent("wt1").path
        let branch = try await git.detectDefaultBranch(repoPath: repoDir.path)
        try await git.worktreeAdd(repoPath: repoDir.path, worktreePath: wtPath, branch: "tbd/remove-test", baseBranch: branch)
        try await git.worktreeRemove(repoPath: repoDir.path, worktreePath: wtPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }

    func testGetRemoteURL() async throws {
        // No remote on a fresh repo
        let url = try await git.getRemoteURL(repoPath: repoDir.path)
        XCTAssertNil(url)
    }

    // Helper
    private func shell(_ command: String, at dir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(process.terminationStatus))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitManagerTests 2>&1`
Expected: FAIL.

- [ ] **Step 3: Implement GitManager.swift**

A struct with async methods that shell out to git:
- `isGitRepo(path:) -> Bool` — runs `git rev-parse --git-dir`
- `detectDefaultBranch(repoPath:) -> String` — tries `git symbolic-ref refs/remotes/origin/HEAD`, falls back to checking local HEAD branch name
- `getRemoteURL(repoPath:) -> String?` — runs `git remote get-url origin`
- `fetch(repoPath:branch:) throws` — runs `git fetch origin <branch>`
- `worktreeAdd(repoPath:worktreePath:branch:baseBranch:) throws` — runs `git worktree add <path> -b <branch> <baseBranch>`
- `worktreeRemove(repoPath:worktreePath:) throws` — runs `git worktree remove <path>`
- `worktreeList(repoPath:) -> [(path: String, branch: String)]` — parses `git worktree list --porcelain`

All methods use a private `run(command:at:)` helper that creates a `Process`, captures stdout/stderr, and throws on non-zero exit.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitManagerTests 2>&1`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Git/ Tests/TBDDaemonTests/
git commit -m "feat: add git manager for worktree and branch operations"
```

---

### Task 6: Hook Resolver

**Files:**
- Create: `Sources/TBDDaemon/Hooks/HookResolver.swift`
- Test: `Tests/TBDDaemonTests/HookResolverTests.swift`

- [ ] **Step 1: Write tests**

```swift
import XCTest
@testable import TBDDaemon

final class HookResolverTests: XCTestCase {
    var tempDir: URL!
    var resolver: HookResolver!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testConductorJsonSetupHook() throws {
        // Create conductor.json
        let conductorJSON = """
        {"scripts":{"setup":"scripts/setup.sh","archive":"scripts/archive.sh"}}
        """
        try conductorJSON.write(toFile: tempDir.appendingPathComponent("conductor.json").path,
                                atomically: true, encoding: .utf8)
        // Create the script
        let scriptsDir = tempDir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try "#!/bin/bash\necho setup".write(
            toFile: scriptsDir.appendingPathComponent("setup.sh").path,
            atomically: true, encoding: .utf8)

        let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: nil)
        XCTAssertNotNil(hook)
        XCTAssertTrue(hook!.contains("scripts/setup.sh"))
    }

    func testDmuxHookFallback() throws {
        // No conductor.json, but .dmux-hooks/worktree_created exists
        let dmuxDir = tempDir.appendingPathComponent(".dmux-hooks")
        try FileManager.default.createDirectory(at: dmuxDir, withIntermediateDirectories: true)
        let hookPath = dmuxDir.appendingPathComponent("worktree_created").path
        try "#!/bin/bash\necho dmux".write(toFile: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

        let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: nil)
        XCTAssertNotNil(hook)
        XCTAssertTrue(hook!.contains(".dmux-hooks/worktree_created"))
    }

    func testAppConfigTrumpsAll() throws {
        // Both conductor.json and app config exist — app config wins
        let conductorJSON = """
        {"scripts":{"setup":"scripts/setup.sh"}}
        """
        try conductorJSON.write(toFile: tempDir.appendingPathComponent("conductor.json").path,
                                atomically: true, encoding: .utf8)

        let appHookPath = tempDir.appendingPathComponent("app-hook.sh").path
        try "#!/bin/bash\necho app".write(toFile: appHookPath, atomically: true, encoding: .utf8)

        let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: appHookPath)
        XCTAssertEqual(hook, appHookPath)
    }

    func testNoHooksReturnsNil() {
        let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: nil)
        XCTAssertNil(hook)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookResolverTests 2>&1`
Expected: FAIL.

- [ ] **Step 3: Implement HookResolver.swift**

```swift
import Foundation

public enum HookEvent: String {
    case setup
    case archive

    var conductorKey: String {
        switch self {
        case .setup: return "setup"
        case .archive: return "archive"
        }
    }

    var dmuxHookName: String {
        switch self {
        case .setup: return "worktree_created"
        case .archive: return "before_worktree_remove"
        }
    }
}

public struct HookResolver {
    let globalHooksDir: String

    public init(globalHooksDir: String = TBDConstants.configDir
            .appendingPathComponent("hooks/default").path) {
        self.globalHooksDir = globalHooksDir
    }

    /// Resolves which hook script to run. First match wins, no chaining.
    /// Priority: appHookPath > conductor.json > .dmux-hooks > global default
    public func resolve(event: HookEvent, repoPath: String, appHookPath: String?) -> String? {
        // 1. App per-repo config
        if let path = appHookPath, FileManager.default.fileExists(atPath: path) {
            return path
        }

        // 2. conductor.json
        if let path = resolveConductor(event: event, repoPath: repoPath) {
            return path
        }

        // 3. .dmux-hooks
        if let path = resolveDmux(event: event, repoPath: repoPath) {
            return path
        }

        // 4. Global default
        let globalPath = (globalHooksDir as NSString).appendingPathComponent(event.rawValue)
        if FileManager.default.isExecutableFile(atPath: globalPath) {
            return globalPath
        }

        return nil
    }

    /// Execute a hook synchronously with timeout. Returns (success, output).
    public func execute(hookPath: String, cwd: String, env: [String: String],
                        timeout: TimeInterval = 60) async throws -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookPath]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Timeout handling
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output)
    }

    // MARK: - Private

    private func resolveConductor(event: HookEvent, repoPath: String) -> String? {
        let conductorPath = (repoPath as NSString).appendingPathComponent("conductor.json")
        guard FileManager.default.fileExists(atPath: conductorPath),
              let data = FileManager.default.contents(atPath: conductorPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String],
              let scriptRelPath = scripts[event.conductorKey] else {
            return nil
        }
        let fullPath = (repoPath as NSString).appendingPathComponent(scriptRelPath)
        return FileManager.default.fileExists(atPath: fullPath) ? fullPath : nil
    }

    private func resolveDmux(event: HookEvent, repoPath: String) -> String? {
        let hookPath = (repoPath as NSString)
            .appendingPathComponent(".dmux-hooks/\(event.dmuxHookName)")
        return FileManager.default.isExecutableFile(atPath: hookPath) ? hookPath : nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HookResolverTests 2>&1`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Hooks/ Tests/TBDDaemonTests/
git commit -m "feat: add hook resolver with conductor/dmux/global fallback chain"
```

---

### Task 7: Tmux Manager

**Files:**
- Create: `Sources/TBDDaemon/Tmux/TmuxManager.swift`
- Test: `Tests/TBDDaemonTests/TmuxManagerTests.swift`

- [ ] **Step 1: Write tests**

Tests verify command generation (not actual tmux execution, since tmux may not be available in CI):

```swift
import XCTest
@testable import TBDDaemon

final class TmuxManagerTests: XCTestCase {
    func testServerName() {
        let id = UUID()
        let name = TmuxManager.serverName(forRepoID: id)
        XCTAssertTrue(name.hasPrefix("tbd-"))
        XCTAssertEqual(name.count, 4 + 8) // "tbd-" + 8 hex chars
    }

    func testNewWindowCommand() {
        let cmd = TmuxManager.newWindowCommand(
            server: "tbd-a1b2c3d4",
            session: "main",
            cwd: "/tmp/worktree",
            shellCommand: "claude --dangerously-skip-permissions"
        )
        XCTAssertTrue(cmd.contains("-L tbd-a1b2c3d4"))
        XCTAssertTrue(cmd.contains("-t main"))
        XCTAssertTrue(cmd.contains("-c /tmp/worktree"))
        XCTAssertTrue(cmd.contains("claude --dangerously-skip-permissions"))
    }

    func testNewServerCommand() {
        let cmd = TmuxManager.newServerCommand(
            server: "tbd-a1b2c3d4",
            session: "main",
            cwd: "/tmp/repo"
        )
        XCTAssertTrue(cmd.contains("-L tbd-a1b2c3d4"))
        XCTAssertTrue(cmd.contains("new-session"))
        XCTAssertTrue(cmd.contains("-s main"))
    }

    func testSendKeysCommand() {
        let cmd = TmuxManager.sendKeysCommand(
            server: "tbd-a1b2c3d4",
            paneID: "%3",
            text: "hello world"
        )
        XCTAssertTrue(cmd.contains("-L tbd-a1b2c3d4"))
        XCTAssertTrue(cmd.contains("send-keys"))
        XCTAssertTrue(cmd.contains("-l"))
        XCTAssertTrue(cmd.contains("-t %3"))
    }

    func testKillWindowCommand() {
        let cmd = TmuxManager.killWindowCommand(
            server: "tbd-a1b2c3d4",
            windowID: "@5"
        )
        XCTAssertTrue(cmd.contains("kill-window"))
        XCTAssertTrue(cmd.contains("-t @5"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TmuxManagerTests 2>&1`
Expected: FAIL.

- [ ] **Step 3: Implement TmuxManager.swift**

A struct with:
- Static command builders: `serverName(forRepoID:)`, `newServerCommand(...)`, `newWindowCommand(...)`, `killWindowCommand(...)`, `sendKeysCommand(...)`, `listWindowsCommand(...)`
- Async execution methods that actually run the commands and parse output: `ensureServer(...)`, `createWindow(...)`, `killWindow(...)`, `sendKeys(...)`, `listWindows(...)`, `queryPaneID(windowID:server:)`
- The `queryPaneID` method runs `tmux -L <server> list-panes -t <windowID> -F '#{pane_id}'` to get the pane ID for a window

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TmuxManagerTests 2>&1`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ Tests/TBDDaemonTests/
git commit -m "feat: add tmux manager for server and window lifecycle"
```

---

### Task 8: Worktree Lifecycle Orchestrator

**Files:**
- Create: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift`
- Test: `Tests/TBDDaemonTests/WorktreeLifecycleTests.swift`

- [ ] **Step 1: Write tests**

Integration tests using a real temporary git repo but mocked tmux (since we can't rely on tmux in tests):

```swift
import XCTest
@testable import TBDDaemon
@testable import TBDShared

final class WorktreeLifecycleTests: XCTestCase {
    var tempDir: URL!
    var repoDir: URL!
    var db: TBDDatabase!
    var lifecycle: WorktreeLifecycle!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repoDir = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try await shell("git init && git commit --allow-empty -m 'init'", at: repoDir)

        db = try TBDDatabase(inMemory: true)
        lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true), // don't actually run tmux
            hooks: HookResolver()
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateWorktree() async throws {
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main"
        )
        let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        XCTAssertEqual(result.status, .active)
        XCTAssertTrue(result.name.contains("-")) // has adjective-animal
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }

    func testArchiveWorktree() async throws {
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main"
        )
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: false)

        let archived = try await db.worktrees.get(id: wt.id)
        XCTAssertEqual(archived?.status, .archived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
    }

    func testReviveWorktree() async throws {
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "test", defaultBranch: "main"
        )
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: false)
        let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

        XCTAssertEqual(revived.status, .active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: revived.path))
    }

    private func shell(_ command: String, at dir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(process.terminationStatus))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorktreeLifecycleTests 2>&1`
Expected: FAIL.

- [ ] **Step 3: Implement WorktreeLifecycle.swift**

Orchestrator that coordinates git, db, tmux, and hooks:

- `createWorktree(repoID:skipClaude:) -> Worktree`: Implements the full creation flow from the spec (fetch, name generation, git worktree add, db insert, tmux window creation, hook execution). Takes `skipClaude` parameter to skip launching claude in tests.
- `archiveWorktree(worktreeID:force:)`: Archive flow (hook execution, tmux cleanup, git worktree remove, db update).
- `reviveWorktree(worktreeID:skipClaude:) -> Worktree`: Revival flow.
- `reconcile(repoID:)`: Compares `git worktree list` against the db ledger and syncs.

The `TmuxManager` should accept a `dryRun` flag that logs commands instead of executing them, for testability.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorktreeLifecycleTests 2>&1`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/ Tests/TBDDaemonTests/
git commit -m "feat: add worktree lifecycle orchestrator (create/archive/revive)"
```

---

### Task 9: RPC Router

**Files:**
- Create: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Test: `Tests/TBDDaemonTests/RPCRouterTests.swift`

- [ ] **Step 1: Write tests**

```swift
import XCTest
@testable import TBDDaemon
@testable import TBDShared

final class RPCRouterTests: XCTestCase {
    var db: TBDDatabase!
    var router: RPCRouter!

    override func setUp() async throws {
        db = try TBDDatabase(inMemory: true)
        router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }

    func testRepoAddAndList() async throws {
        // Create a temp git repo for the test
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "git init && git commit --allow-empty -m 'init'"]
        process.currentDirectoryURL = tempDir
        try process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let addReq = RPCRequest(method: "repo.add", params: .repoAdd(RepoAddParams(path: tempDir.path)))
        let addResp = try await router.handle(addReq)
        XCTAssertTrue(addResp.success)

        let listReq = RPCRequest(method: "repo.list", params: .repoList)
        let listResp = try await router.handle(listReq)
        XCTAssertTrue(listResp.success)
        if case .repos(let repos) = listResp.result {
            XCTAssertEqual(repos.count, 1)
        } else {
            XCTFail("Expected repos result")
        }
    }

    func testDaemonStatus() async throws {
        let req = RPCRequest(method: "daemon.status", params: .daemonStatus)
        let resp = try await router.handle(req)
        XCTAssertTrue(resp.success)
        if case .daemonStatus(let status) = resp.result {
            XCTAssertEqual(status.version, TBDConstants.version)
        } else {
            XCTFail("Expected daemon status result")
        }
    }

    func testUnknownMethod() async throws {
        let req = RPCRequest(method: "foo.bar", params: .daemonStatus)
        let resp = try await router.handle(req)
        XCTAssertFalse(resp.success)
        XCTAssertTrue(resp.error?.contains("Unknown method") ?? false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RPCRouterTests 2>&1`
Expected: FAIL.

- [ ] **Step 3: Implement RPCRouter.swift**

A struct that takes an `RPCRequest`, switches on `method`, calls the appropriate handler, and returns an `RPCResponse`:

- `repo.add` → validate git repo, detect default branch, detect remote URL, insert into db
- `repo.remove` → check for active worktrees, cascade-archive if `--force`, remove from db
- `repo.list` → query db
- `worktree.create` → delegate to `WorktreeLifecycle.createWorktree`
- `worktree.list` → query db with filters
- `worktree.archive` → delegate to `WorktreeLifecycle.archiveWorktree`
- `worktree.revive` → delegate to `WorktreeLifecycle.reviveWorktree`
- `worktree.rename` → update db
- `terminal.create` → create tmux window, insert into db
- `terminal.list` → query db
- `terminal.send` → send keys to tmux
- `notify` → insert notification into db
- `daemon.status` → return version, uptime, connected clients
- `resolve.path` → find repo/worktree by filesystem path

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RPCRouterTests 2>&1`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter.swift Tests/TBDDaemonTests/
git commit -m "feat: add RPC router mapping methods to handlers"
```

---

### Task 10: Unix Socket + HTTP Server

**Files:**
- Create: `Sources/TBDDaemon/Server/SocketServer.swift`
- Create: `Sources/TBDDaemon/Server/HTTPServer.swift`

- [ ] **Step 1: Implement SocketServer.swift**

Using Swift NIO:
- Bind to Unix domain socket at `~/.tbd/sock`
- Accept connections, read newline-delimited JSON (one `RPCRequest` per line)
- Pass to `RPCRouter.handle()`, write back `RPCResponse` as JSON + newline
- Handle `state.subscribe` specially — keep the connection open and stream deltas
- Track connected client count for `daemon.status`
- Clean up stale socket file on start

- [ ] **Step 2: Implement HTTPServer.swift**

Using Swift NIO + NIOHTTP1:
- Bind to `localhost:0` (auto-assign port), write port to `~/.tbd/port`
- Accept POST requests to `/rpc` with JSON body
- Same routing through `RPCRouter.handle()`
- Return JSON response

- [ ] **Step 3: Manual verification**

Build and run the daemon, then test with curl:
```bash
swift build --product TBDDaemon
# In one terminal:
.build/debug/TBDDaemon
# In another:
curl -X POST http://localhost:$(cat ~/.tbd/port)/rpc \
  -H 'Content-Type: application/json' \
  -d '{"method":"daemon.status","params":"daemonStatus"}'
```
Expected: JSON response with version and uptime.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Server/
git commit -m "feat: add Unix socket and HTTP servers with NIO"
```

---

### Task 11: State Subscription (Streaming Deltas)

**Files:**
- Create: `Sources/TBDDaemon/Server/StateSubscription.swift`

- [ ] **Step 1: Implement StateSubscription.swift**

A class that:
- Maintains a list of connected subscriber channels (NIO `Channel` references)
- Provides a `broadcast(delta:)` method that sends a JSON event to all subscribers
- Delta events are typed: `worktreeCreated`, `worktreeArchived`, `worktreeRevived`, `worktreeRenamed`, `notificationReceived`, `repoAdded`, `repoRemoved`, `terminalCreated`, `terminalRemoved`
- Wire into the `RPCRouter` — after any mutation, call `broadcast()`
- Handle subscriber disconnect (remove from list)

- [ ] **Step 2: Manual verification**

Connect via socket, send `state.subscribe`, then from another terminal create a worktree via CLI. Verify the subscriber receives the delta.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Server/StateSubscription.swift
git commit -m "feat: add state subscription for streaming deltas to clients"
```

---

### Task 12: PID File + Daemon Entry Point

**Files:**
- Create: `Sources/TBDDaemon/PIDFile.swift`
- Modify: `Sources/TBDDaemon/Daemon.swift`
- Modify: `Sources/TBDDaemon/main.swift`

- [ ] **Step 1: Implement PIDFile.swift**

```swift
import Foundation

public struct PIDFile {
    let path: String

    public init(path: String = TBDConstants.pidFilePath) {
        self.path = path
    }

    public func write() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func read() -> pid_t? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    public func isStale() -> Bool {
        guard let pid = read() else { return false }
        // Check if process is alive
        return kill(pid, 0) != 0
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func cleanupIfStale() {
        if isStale() {
            remove()
            // Also clean up stale socket
            try? FileManager.default.removeItem(atPath: TBDConstants.socketPath)
        }
    }
}
```

- [ ] **Step 2: Implement Daemon.swift**

Top-level daemon orchestrator:
- `start()`: Create `~/.tbd/` directory if needed, cleanup stale PID/socket, write PID file, init database, init all managers, start socket server + HTTP server, start FSEvents watcher for known repos, reconcile worktrees for all repos, install signal handlers (SIGTERM/SIGINT → graceful shutdown)
- `stop()`: Stop servers, remove PID file, remove socket file
- Hold references to all subsystems

- [ ] **Step 3: Update main.swift**

```swift
import Foundation
import TBDShared

let daemon = Daemon()

// Handle graceful shutdown
signal(SIGTERM) { _ in
    Task { await daemon.stop() }
}
signal(SIGINT) { _ in
    Task { await daemon.stop() }
}

print("tbdd v\(TBDConstants.version) starting...")
try await daemon.start()

// Keep the process alive
dispatchMain()
```

- [ ] **Step 4: Build and run**

Run: `swift build --product TBDDaemon && .build/debug/TBDDaemon`
Expected: Daemon starts, prints version, creates `~/.tbd/` directory, PID file, and listens on socket + HTTP.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/
git commit -m "feat: add daemon entry point with PID file and graceful shutdown"
```

---

### Task 13: CLI Tool

**Files:**
- Modify: `Sources/TBDCLI/TBD.swift`
- Create: `Sources/TBDCLI/SocketClient.swift`
- Create: `Sources/TBDCLI/PathResolver.swift`
- Create: `Sources/TBDCLI/Commands/RepoCommands.swift`
- Create: `Sources/TBDCLI/Commands/WorktreeCommands.swift`
- Create: `Sources/TBDCLI/Commands/TerminalCommands.swift`
- Create: `Sources/TBDCLI/Commands/NotifyCommand.swift`
- Create: `Sources/TBDCLI/Commands/DaemonCommands.swift`
- Create: `Sources/TBDCLI/Commands/SetupHooksCommand.swift`

- [ ] **Step 1: Implement SocketClient.swift**

A simple client that:
- Connects to Unix domain socket at `~/.tbd/sock`
- Sends an `RPCRequest` as JSON + newline
- Reads back an `RPCResponse`
- Exits with error if socket doesn't exist (daemon not running)
- Uses NIO `ClientBootstrap` with `UnixDomainSocket`

- [ ] **Step 2: Implement PathResolver.swift**

Resolves `$PWD` or a `--repo`/`--worktree` argument to the appropriate ID:
- `resolveRepo(path:)` → sends `resolve.path` RPC to daemon, returns repo ID
- `resolveWorktree(path:)` → same RPC, returns worktree ID
- Falls back to walking up directory tree to find repo root if needed

- [ ] **Step 3: Implement RepoCommands.swift**

```swift
import ArgumentParser
import TBDShared

struct RepoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Manage repositories",
        subcommands: [RepoAdd.self, RepoRemove.self, RepoList.self]
    )
}

struct RepoAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")

    @Argument(help: "Path to git repository")
    var path: String = "."

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let resolved = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardized.path
        let client = try SocketClient()
        let response = try await client.send(RPCRequest(
            method: "repo.add",
            params: .repoAdd(RepoAddParams(path: resolved))
        ))
        // Print human-friendly or JSON output
    }
}
// ... RepoRemove, RepoList similarly
```

- [ ] **Step 4: Implement WorktreeCommands.swift**

Subcommands: `create`, `list`, `archive`, `revive`, `rename`. Each resolves repo/worktree from path or argument, sends RPC, prints result.

- [ ] **Step 5: Implement TerminalCommands.swift**

Subcommands: `create`, `list`, `send`. `send` requires explicit `--terminal` ID.

- [ ] **Step 6: Implement NotifyCommand.swift**

`tbd notify --type <type> [--message "..."] [--worktree <id>]`
Auto-resolves worktree from `$PWD` if `--worktree` not given. Exits silently (code 0) if daemon isn't running or not in a worktree.

- [ ] **Step 7: Implement DaemonCommands.swift**

`tbd daemon status` — prints version, uptime, connected clients.

- [ ] **Step 8: Implement SetupHooksCommand.swift**

`tbd setup-hooks --global` — reads `~/.claude/settings.json`, adds the Stop hook entry, writes back.
`tbd setup-hooks --repo [path]` — same but for project-level `.claude/settings.json`.

Both are careful to merge into existing settings (not overwrite).

- [ ] **Step 9: Update TBD.swift with all subcommands**

```swift
@main
struct TBDCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tbd",
        abstract: "TBD workspace manager CLI",
        version: TBDConstants.version,
        subcommands: [
            RepoCommand.self,
            WorktreeCommand.self,
            TerminalCommand.self,
            NotifyCommand.self,
            DaemonCommand.self,
            SetupHooksCommand.self,
        ]
    )
}
```

- [ ] **Step 10: Manual end-to-end test**

```bash
swift build
# Start daemon in background
.build/debug/TBDDaemon &
# Test CLI commands
.build/debug/TBDCLI repo add /path/to/some/git/repo
.build/debug/TBDCLI repo list
.build/debug/TBDCLI worktree create --repo /path/to/repo
.build/debug/TBDCLI worktree list
.build/debug/TBDCLI daemon status
# Cleanup
kill %1
```

- [ ] **Step 11: Commit**

```bash
git add Sources/TBDCLI/
git commit -m "feat: add CLI tool with all commands"
```

---

### Task 14: Integration Tests

**Files:**
- Create: `Tests/IntegrationTests/DaemonCLITests.swift`

- [ ] **Step 1: Write integration tests**

These tests start the daemon in-process, create a temporary git repo, and exercise the full flow through the RPC interface (not through the CLI binary, but through the same `RPCRouter`):

```swift
import XCTest
@testable import TBDDaemon
@testable import TBDShared

final class DaemonCLITests: XCTestCase {
    var tempDir: URL!
    var repoDir: URL!
    var router: RPCRouter!
    var db: TBDDatabase!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repoDir = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try await shell("git init && git commit --allow-empty -m 'init'", at: repoDir)

        db = try TBDDatabase(inMemory: true)
        router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFullWorktreeLifecycle() async throws {
        // Add repo
        let addResp = try await router.handle(RPCRequest(
            method: "repo.add",
            params: .repoAdd(RepoAddParams(path: repoDir.path))
        ))
        XCTAssertTrue(addResp.success)
        guard case .repo(let repo) = addResp.result else { XCTFail("Expected repo"); return }

        // Create worktree
        let createResp = try await router.handle(RPCRequest(
            method: "worktree.create",
            params: .worktreeCreate(WorktreeCreateParams(repoID: repo.id))
        ))
        XCTAssertTrue(createResp.success)
        guard case .worktree(let wt) = createResp.result else { XCTFail("Expected worktree"); return }
        XCTAssertEqual(wt.status, .active)

        // List worktrees
        let listResp = try await router.handle(RPCRequest(
            method: "worktree.list",
            params: .worktreeList(WorktreeListParams(repoID: repo.id))
        ))
        guard case .worktrees(let wts) = listResp.result else { XCTFail("Expected worktrees"); return }
        XCTAssertEqual(wts.count, 1)

        // Rename
        let renameResp = try await router.handle(RPCRequest(
            method: "worktree.rename",
            params: .worktreeRename(WorktreeRenameParams(worktreeID: wt.id, displayName: "My Feature"))
        ))
        XCTAssertTrue(renameResp.success)

        // Send notification
        let notifyResp = try await router.handle(RPCRequest(
            method: "notify",
            params: .notify(NotifyParams(worktreeID: wt.id, type: .responseComplete))
        ))
        XCTAssertTrue(notifyResp.success)

        // Archive
        let archiveResp = try await router.handle(RPCRequest(
            method: "worktree.archive",
            params: .worktreeArchive(WorktreeArchiveParams(worktreeID: wt.id))
        ))
        XCTAssertTrue(archiveResp.success)

        // Verify archived
        let archivedList = try await router.handle(RPCRequest(
            method: "worktree.list",
            params: .worktreeList(WorktreeListParams(repoID: repo.id, status: .archived))
        ))
        guard case .worktrees(let archived) = archivedList.result else { XCTFail(""); return }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived[0].displayName, "My Feature")

        // Revive
        let reviveResp = try await router.handle(RPCRequest(
            method: "worktree.revive",
            params: .worktreeRevive(WorktreeReviveParams(worktreeID: wt.id))
        ))
        XCTAssertTrue(reviveResp.success)
    }

    func testPathResolution() async throws {
        let addResp = try await router.handle(RPCRequest(
            method: "repo.add",
            params: .repoAdd(RepoAddParams(path: repoDir.path))
        ))
        guard case .repo(let repo) = addResp.result else { XCTFail(""); return }

        let resolveResp = try await router.handle(RPCRequest(
            method: "resolve.path",
            params: .resolvePath(ResolvePathParams(path: repoDir.path))
        ))
        guard case .resolvedPath(let resolved) = resolveResp.result else { XCTFail(""); return }
        XCTAssertEqual(resolved.repoID, repo.id)
    }

    private func shell(_ command: String, at dir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(process.terminationStatus))
        }
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/IntegrationTests/
git commit -m "feat: add integration tests for full worktree lifecycle"
```

---

## Post-Phase 1 Verification

After all tasks are complete:

1. **Build all products**: `swift build`
2. **Run all tests**: `swift test`
3. **Manual smoke test**:
   - Start daemon: `.build/debug/TBDDaemon &`
   - Add a real repo: `.build/debug/TBDCLI repo add /path/to/repo`
   - Create worktree: `.build/debug/TBDCLI worktree create --repo /path/to/repo`
   - List worktrees: `.build/debug/TBDCLI worktree list`
   - Archive: `.build/debug/TBDCLI worktree archive <name>`
   - Check daemon status: `.build/debug/TBDCLI daemon status`
   - Stop daemon: `kill $(cat ~/.tbd/tbdd.pid)`

Phase 2 (SwiftUI App) will be planned separately once Phase 1 is solid.
