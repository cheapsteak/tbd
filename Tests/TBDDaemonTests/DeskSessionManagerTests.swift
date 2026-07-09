import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

// MARK: - Fake Dependencies

/// Fake database for testing DeskSessionManager.
actor FakeTBDDatabase: TBDDatabase {
    private(set) var createdScratchCalls: [(name: String, displayName: String, path: String)] = []
    private(set) var worktreeStorage: [UUID: Worktree] = [:]
    private(set) var terminalStorage: [UUID: [Terminal]] = [:]
    private(set) var allWorktrees: [Worktree] = []

    let worktrees: WorktreesStore = FakeWorktreesStore()
    let terminals: TerminalsStore = FakeTerminalsStore()
    let tabs: TabsStore = FakeTabsStore()
    let repos: ReposStore = FakeReposStore()
    let config: ConfigStore = FakeConfigStore()
    let audit: AuditStore = FakeAuditStore()

    func close() async throws {}
}

// Stub stores (minimal implementations)
actor FakeWorktreesStore: WorktreesStore {
    var created: [(name: String, displayName: String, path: String, tmuxServer: String)] = []
    var archived: [UUID] = []
    var storage: [UUID: Worktree] = [:]

    func createScratch(name: String, displayName: String, path: String, tmuxServer: String) async throws -> Worktree {
        created.append((name, displayName, path, tmuxServer))
        let wt = Worktree(
            id: UUID(), repoID: nil, name: name, displayName: displayName, path: path,
            tmuxServer: tmuxServer, status: .active, isScratch: true, promotedToRepoID: nil,
            hasDefaultDisplayName: true, autoArchiveOnMerge: false
        )
        storage[wt.id] = wt
        return wt
    }

    func findByPath(path: String) async throws -> Worktree? {
        storage.values.first { $0.path == path }
    }

    func get(id: UUID) async throws -> Worktree? { storage[id] }
    func list() async throws -> [Worktree] { Array(storage.values) }
    func list(repoID: UUID?, status: WorktreeStatus?) async throws -> [Worktree] {
        Array(storage.values.filter { ($0.repoID == repoID || repoID == nil) && ($0.status == status || status == nil) })
    }
    func archive(id: UUID) async throws { /* stub */ }
    func revive(id: UUID) async throws { /* stub */ }
    func setPromotedToRepoID(id: UUID, repoID: UUID) async throws { /* stub */ }
    func promoteScratchMigration(scratchID: UUID, mainWorktreeID: UUID, repoID: UUID, tmuxServer: String) async throws { /* stub */ }
    func delete(id: UUID) async throws { /* stub */ }
    func deleteForRepo(repoID: UUID) async throws { /* stub */ }
    func setAutoArchiveOnMerge(id: UUID, value: Bool) async throws { /* stub */ }
}

actor FakeTerminalsStore: TerminalsStore {
    var created: [(id: UUID, worktreeID: UUID, tmuxWindowID: Int, label: String)] = []
    var storage: [UUID: Terminal] = [:]

    func create(id: UUID, worktreeID: UUID, tmuxWindowID: Int, label: String, transcriptPath: String?, profileID: UUID?) async throws -> Terminal {
        let t = Terminal(
            id: id, worktreeID: worktreeID, tmuxWindowID: tmuxWindowID,
            label: label, transcriptPath: transcriptPath ?? "", profileID: profileID
        )
        created.append((id, worktreeID, tmuxWindowID, label))
        storage[id] = t
        return t
    }

    func list(worktreeID: UUID) async throws -> [Terminal] {
        storage.values.filter { $0.worktreeID == worktreeID }
    }

    func deleteForWorktree(worktreeID: UUID) async throws { /* stub */ }
    func get(id: UUID) async throws -> Terminal? { storage[id] }
}

actor FakeTabsStore: TabsStore {
    func deleteForWorktree(worktreeID: UUID) async throws { /* stub */ }
    func list(worktreeID: UUID) async throws -> [Tab] { [] }
}

actor FakeReposStore: ReposStore {
    func list() async throws -> [Repo] { [] }
    func get(id: UUID) async throws -> Repo? { nil }
}

actor FakeConfigStore: ConfigStore {
    func get() async throws -> Config {
        Config(
            nightwatchMode: .off, envSettingOverrides: [:], envOverrides: [:],
            primaryAgentPreference: .claude, modelProfileID: nil
        )
    }
    func setNightwatchMode(_ mode: NightwatchMode) async throws { /* stub */ }
}

actor FakeAuditStore: AuditStore {
    func list(since: Date?, action: AuditAction?) async throws -> [AuditLogEntry] { [] }
}

/// Fake TmuxManager for testing.
actor FakeTmuxManager: TmuxManager {
    private(set) var createdWindows: [(server: String, label: String, cwd: String, command: String)] = []
    private(set) var sentTexts: [(server: String, windowID: Int, text: String)] = []

    func ensureServer(server: String, session: String, cwd: String, cols: Int, rows: Int) async throws -> Int {
        1  // Return dummy windowID
    }

    func createWindow(server: String, label: String, cwd: String, command: String, sensitiveEnv: [String: String]) async throws -> Int {
        createdWindows.append((server, label, cwd, command))
        return createdWindows.count  // Return sequential window ID
    }

    func sendText(server: String, windowID: Int, text: String, enter: Bool) async throws {
        sentTexts.append((server, windowID, text))
    }

    func killWindow(server: String, windowID: Int) async throws { /* stub */ }
}

/// Fake WorktreeLifecycle for testing.
actor FakeWorktreeLifecycle: WorktreeLifecycle {
    func spawnPrimaryTerminals(
        worktree: Worktree, repo: Repo?,
        worktreePath: String?,
        skipClaude: Bool,
        archivedClaudeSessions: [String]?,
        initialPrompt: String?,
        cols: Int?,
        rows: Int?,
        preSessionTerminalID: UUID?,
        overrideProfileID: UUID?
    ) async throws -> [(id: UUID, label: String)] {
        return []  // stub
    }
}

// Minimal stub implementations

actor FakeModelProfileResolver: ModelProfileResolver {
    func resolve(repoID: UUID?, override: UUID?) async throws -> ResolvedModelProfile? { nil }
}

// MARK: - Tests

struct DeskSessionManagerTests {

    @Test("ensureDeskSession creates a new scratch space on first call")
    async func testEnsureDeskSessionCreatesNew() async throws {
        let db = FakeTBDDatabase()
        let lifecycle = FakeWorktreeLifecycle()
        let profileResolver = FakeModelProfileResolver()
        let tmux = FakeTmuxManager()

        let desker = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: profileResolver,
            tmux: tmux
        )

        let desk1 = try await desker.ensureDeskSession(mode: .daywatch)
        #expect(!desk1.id.uuidString.isEmpty)
        #expect(desk1.displayName == "◐ Watch Desk")
        #expect(desk1.isScratch)

        // Verify a terminal was created
        let createdTerminals = try await db.terminals.list(worktreeID: desk1.id)
        #expect(createdTerminals.count == 1)
        #expect(createdTerminals.first?.label == TerminalLabel.primary)
    }

    @Test("ensureDeskSession is idempotent (called twice → one session)")
    async func testEnsureDeskSessionIdempotent() async throws {
        let db = FakeTBDDatabase()
        let lifecycle = FakeWorktreeLifecycle()
        let profileResolver = FakeModelProfileResolver()
        let tmux = FakeTmuxManager()

        let desker = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: profileResolver,
            tmux: tmux
        )

        let desk1 = try await desker.ensureDeskSession(mode: .daywatch)
        let desk2 = try await desker.ensureDeskSession(mode: .daywatch)

        #expect(desk1.id == desk2.id, "Same desk should be returned on idempotent calls")

        let createdTerminals1 = try await db.terminals.list(worktreeID: desk1.id)
        let createdTerminals2 = try await db.terminals.list(worktreeID: desk2.id)

        #expect(createdTerminals1.count == createdTerminals2.count)
    }

    @Test("ensureDeskSession creates terminal with daywatch model (Sonnet)")
    async func testDaywatchModel() async throws {
        let db = FakeTBDDatabase()
        let lifecycle = FakeWorktreeLifecycle()
        let profileResolver = FakeModelProfileResolver()
        let tmux = FakeTmuxManager()

        let desker = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: profileResolver,
            tmux: tmux
        )

        let desk = try await desker.ensureDeskSession(mode: .daywatch)

        let windows = await tmux.createdWindows
        let lastWindow = windows.last
        #expect(lastWindow?.command.contains("claude-3-5-sonnet") == true,
                "Daywatch should use Sonnet model")
    }

    @Test("ensureDeskSession creates terminal with nightwatch model (Opus)")
    async func testNightwatchModel() async throws {
        let db = FakeTBDDatabase()
        let lifecycle = FakeWorktreeLifecycle()
        let profileResolver = FakeModelProfileResolver()
        let tmux = FakeTmuxManager()

        let desker = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: profileResolver,
            tmux: tmux
        )

        let desk = try await desker.ensureDeskSession(mode: .nightwatch)

        let windows = await tmux.createdWindows
        let lastWindow = windows.last
        #expect(lastWindow?.command.contains("claude-3-5-opus") == true,
                "Nightwatch should use Opus model")
    }

    @Test("closeDeskSession archives the worktree")
    async func testCloseDeskSession() async throws {
        let db = FakeTBDDatabase()
        let lifecycle = FakeWorktreeLifecycle()
        let profileResolver = FakeModelProfileResolver()
        let tmux = FakeTmuxManager()

        let desker = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: profileResolver,
            tmux: tmux
        )

        let desk = try await desker.ensureDeskSession(mode: .daywatch)
        await desker.closeDeskSession()

        // Verify that closing again doesn't fail (idempotent)
        await desker.closeDeskSession()
    }

    @Test("nudgeDeskSession sends text to the terminal")
    async func testNudgeDeskSession() async throws {
        let db = FakeTBDDatabase()
        let lifecycle = FakeWorktreeLifecycle()
        let profileResolver = FakeModelProfileResolver()
        let tmux = FakeTmuxManager()

        let desker = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: profileResolver,
            tmux: tmux
        )

        let desk = try await desker.ensureDeskSession(mode: .daywatch)
        await desker.nudgeDeskSession(worktreeID: desk.id, act: false)

        let sentTexts = await tmux.sentTexts
        #expect(!sentTexts.isEmpty, "Nudge should send text to terminal")
    }
}
