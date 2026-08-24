import Foundation
import GRDB
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Scratch reconcile call paths")
struct ScratchReconcileCallPathTests {
    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []
        private var ownershipProbes = 0

        func append(_ command: [String]) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func contains(_ argument: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return commands.contains { $0.contains(argument) }
        }

        func contains(_ command: String, target: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return commands.contains { $0.contains(command) && $0.contains(target) }
        }

        func count(_ command: String, target: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return commands.count { $0.contains(command) && $0.contains(target) }
        }

        func recordOwnershipProbe() {
            lock.lock()
            ownershipProbes += 1
            lock.unlock()
        }

        func ownershipProbeCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return ownershipProbes
        }
    }

    /// Holds a dry-run `new-window` after tmux has made the window visible but
    /// before terminal.create can commit its owner row. The request using this
    /// recorder must run on `gateHoldingTask` because the callback is
    /// synchronous and waits on a semaphore.
    private final class BlockingCreateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var commands: [[String]] = []
        private var blocked = false
        private var stampedTerminalID: String?

        var createIsBlocked: Bool { lock.withLock { blocked } }
        var terminalID: String? { lock.withLock { stampedTerminalID } }

        var recorder: @Sendable ([String]) -> Void {
            { [self] command in
                let shouldBlock = lock.withLock { () -> Bool in
                    commands.append(command)
                    guard !blocked, command.contains("new-window") else { return false }
                    let joined = command.joined(separator: " ")
                    if let marker = joined.range(of: "TBD_TERMINAL_ID=") {
                        let suffix = joined[marker.upperBound...]
                        let candidate = String(suffix.prefix(36))
                        if UUID(uuidString: candidate) != nil {
                            stampedTerminalID = candidate.lowercased()
                        }
                    }
                    blocked = true
                    return true
                }
                if shouldBlock {
                    release.waitForGate("scratch terminal.create held before owner-row insert")
                }
            }
        }

        func releaseCreate() { release.signal() }

        func contains(_ command: String, target: String) -> Bool {
            lock.withLock {
                commands.contains { $0.contains(command) && $0.contains(target) }
            }
        }
    }

    private final class FailFirstKill: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0

        func error() -> Error? {
            lock.withLock {
                attempts += 1
                return attempts == 1 ? NSError(domain: "test.kill", code: 1) : nil
            }
        }
    }

    private struct AliasFixture {
        let db: TBDDatabase
        let tmux: TmuxManager
        let lifecycle: WorktreeLifecycle
        let recorder: CommandRecorder
        let staleTerminalID: UUID
        let currentWorktreeID: UUID
        let currentTerminalID: UUID
        let currentWindowID: String
        let server: String
    }

    private func makeAliasFixture(
        currentWindowID: String = "@2",
        additionalWindows: @escaping @Sendable (String) -> [(windowID: String, paneID: String)] = { _ in [] }
    ) async throws -> AliasFixture {
        let db = try TBDDatabase(inMemory: true)
        let recorder = CommandRecorder()
        let currentTerminalID = UUID()
        let server = "scratch-shared"
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunListWindows: { probed, _ in
                if probed == server {
                    return [(windowID: currentWindowID, paneID: "%1")]
                }
                return additionalWindows(probed)
            },
            dryRunPaneSendTarget: { _, _ in
                recorder.recordOwnershipProbe()
                return .live(terminalID: currentTerminalID.uuidString.lowercased())
            })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let staleScratch = try await db.worktrees.createScratch(
            name: "scratch-stale", displayName: "Scratch Stale",
            path: "/tmp/scratch-stale", tmuxServer: server)
        let currentScratch = try await db.worktrees.createScratch(
            name: "scratch-current", displayName: "Scratch Current",
            path: "/tmp/scratch-current", tmuxServer: server)
        let staleTerminal = try await db.terminals.create(
            worktreeID: staleScratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        return AliasFixture(
            db: db,
            tmux: tmux,
            lifecycle: lifecycle,
            recorder: recorder,
            staleTerminalID: staleTerminal.id,
            currentWorktreeID: currentScratch.id,
            currentTerminalID: currentTerminalID,
            currentWindowID: currentWindowID,
            server: server)
    }

    private func insertPlannedCurrentTerminal(_ fixture: AliasFixture) async throws {
        _ = try await fixture.db.terminals.create(
            id: fixture.currentTerminalID,
            worktreeID: fixture.currentWorktreeID,
            tmuxWindowID: fixture.currentWindowID,
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex)
    }

    @Test("cleanup reconciles scratch aliases with zero registered repos")
    func cleanupReconcilesScratchAliasesWithoutRepos() async throws {
        let fixture = try await makeAliasFixture()
        try await fixture.db.config.setGCEnabled(false)
        try await insertPlannedCurrentTerminal(fixture)
        let router = RPCRouter(
            db: fixture.db,
            lifecycle: fixture.lifecycle,
            tmux: fixture.tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        #expect(try await fixture.db.repos.list().isEmpty)

        let response = await router.handle(RPCRequest(method: RPCMethod.cleanup))

        #expect(response.success)
        let result = try response.decodeResult(CleanupResult.self)
        #expect(result.reposProcessed == 0)
        #expect(result.errors.isEmpty)
        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
        #expect(!fixture.recorder.contains("kill-window"))
    }

    @Test("cleanup reaps an untracked scratch window with zero registered repos")
    func cleanupReapsScratchOrphanWithoutRepos() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorder = CommandRecorder()
        let server = "scratch-orphan"
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunListWindows: { probed, _ in
                probed == server ? [(windowID: "@orphan", paneID: "%orphan")] : []
            })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        _ = try await db.worktrees.createScratch(
            name: "scratch-orphan", displayName: "Scratch Orphan",
            path: "/tmp/scratch-orphan", tmuxServer: server)
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())

        let response = await router.handle(RPCRequest(method: RPCMethod.cleanup))

        #expect(response.success)
        #expect(try response.decodeResult(CleanupResult.self).reposProcessed == 0)
        #expect(recorder.contains("kill-window", target: "@orphan"))
    }

    @Test("cleanup with a repo waits for an in-flight scratch terminal owner row")
    func cleanupWaitsForInFlightScratchCreate() async throws {
        let db = try TBDDatabase(inMemory: true)
        let scratchPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-create-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratchPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchPath) }
        let server = "scratch-create-race"
        let (repoRoot, repoPath) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let repoServer = TmuxManager.serverName(forRepoPath: repoPath.path)
        let recorder = BlockingCreateRecorder()
        let foreignTerminalID = UUID().uuidString.lowercased()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.recorder,
            dryRunListWindows: { probed, _ in
                switch probed {
                case server:
                    return [(windowID: "@mock-0", paneID: "%mock-0")]
                case repoServer:
                    return [(windowID: "@repo-orphan", paneID: "%repo-orphan")]
                default:
                    return []
                }
            },
            dryRunPaneSendTarget: { _, paneID in
                paneID == "%stale"
                    ? .live(terminalID: foreignTerminalID)
                    : .live(terminalID: recorder.terminalID)
            })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-create-race",
            displayName: "Scratch Create Race",
            path: scratchPath.path,
            tmuxServer: server)
        let repo = try await db.repos.create(
            path: repoPath.path, displayName: "acme", defaultBranch: "main")
        _ = try await db.worktrees.createMain(
            repoID: repo.id,
            name: "main",
            branch: "main",
            path: repoPath.path,
            tmuxServer: repoServer)
        let stale = try await db.terminals.create(
            worktreeID: scratch.id,
            tmuxWindowID: "@stale",
            tmuxPaneID: "%stale",
            label: "Codex",
            kind: .codex)
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let createRequest = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: scratch.id, cmd: "printf ready", type: .shell))

        let createTask = gateHoldingTask { await router.handle(createRequest) }
        #expect(await waitUntil { recorder.createIsBlocked })
        let cleanupTask = Task { await router.handle(RPCRequest(method: RPCMethod.cleanup)) }
        await Task.megaYield()

        // Cleanup has reached the same-server lock but cannot prune ownership
        // or inspect windows until terminal.create commits (or rolls back).
        #expect(try await db.terminals.get(id: stale.id) != nil)
        #expect(!recorder.contains("kill-window", target: "@mock-0"))

        recorder.releaseCreate()
        let createResponse = await createTask.value
        let cleanupResponse = await cleanupTask.value

        #expect(createResponse.success)
        #expect(cleanupResponse.success)
        let created = try createResponse.decodeResult(Terminal.self)
        #expect(try await db.terminals.get(id: created.id) != nil)
        #expect(try await db.terminals.get(id: stale.id) == nil)
        #expect(!recorder.contains("kill-window", target: "@mock-0"))
        #expect(recorder.contains("kill-window", target: "@repo-orphan"))
    }

    @Test("cleanup retries an orphan after terminal persistence and rollback kill fail")
    func cleanupRetriesFailedScratchCreateRollback() async throws {
        let db = try TBDDatabase(inMemory: true)
        let scratchPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-create-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratchPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchPath) }
        let server = "scratch-create-rollback"
        let recorder = CommandRecorder()
        let failFirstKill = FailFirstKill()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunListWindows: { probed, _ in
                probed == server ? [(windowID: "@mock-0", paneID: "%mock-0")] : []
            },
            dryRunKillWindowError: { _, _ in failFirstKill.error() })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-create-rollback",
            displayName: "Scratch Create Rollback",
            path: scratchPath.path,
            tmuxServer: server)
        try await db.writerForTests.write { connection in
            try connection.execute(sql: """
                CREATE TRIGGER reject_scratch_terminal_insert
                BEFORE INSERT ON terminal
                BEGIN
                    SELECT RAISE(ABORT, 'terminal insert rejected');
                END;
                """)
        }
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let createRequest = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: scratch.id, cmd: "printf ready", type: .shell))

        let createResponse = await router.handle(createRequest)
        #expect(!createResponse.success)
        #expect(try await db.terminals.list(worktreeID: scratch.id).isEmpty)
        #expect(recorder.count("kill-window", target: "@mock-0") == 1)

        let cleanupResponse = await router.handle(RPCRequest(method: RPCMethod.cleanup))

        #expect(cleanupResponse.success)
        #expect(recorder.count("kill-window", target: "@mock-0") == 2)
    }

    @Test("startup reconciliation repairs scratch aliases even when periodic GC is disabled")
    func startupReconcilesScratchAliasesWhenGCDisabled() async throws {
        let fixture = try await makeAliasFixture()
        try await fixture.db.config.setGCEnabled(false)
        try await insertPlannedCurrentTerminal(fixture)

        await Daemon().performStartupReconciliation(
            mockMode: nil,
            database: fixture.db,
            git: GitManager(),
            lifecycle: fixture.lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
        #expect(fixture.recorder.ownershipProbeCount() == 2)
        #expect(!fixture.recorder.contains("kill-window"))
    }

    @Test("cleanup reconciles repo resources without sweeping a shared live scratch creation")
    func cleanupWithRepoProtectsInFlightScratchWindow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let repoServer = TmuxManager.serverName(forRepoPath: repoDir.path)
        let fixture = try await makeAliasFixture { server in
            server == repoServer ? [(windowID: "@99", paneID: "%99")] : []
        }
        let repo = try await fixture.db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        _ = try await fixture.db.worktrees.createMain(
            repoID: repo.id,
            name: "main",
            branch: "main",
            path: repoDir.path,
            tmuxServer: repoServer)
        _ = try await fixture.db.worktrees.create(
            repoID: repo.id,
            name: "retired-promoted",
            branch: "retired-promoted",
            path: repoDir.appendingPathComponent("retired-promoted").path,
            tmuxServer: fixture.server,
            status: .archived)
        try await insertPlannedCurrentTerminal(fixture)
        let router = RPCRouter(
            db: fixture.db,
            lifecycle: fixture.lifecycle,
            tmux: fixture.tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())

        let response = await router.handle(RPCRequest(method: RPCMethod.cleanup))

        #expect(response.success)
        let result = try response.decodeResult(CleanupResult.self)
        #expect(result.reposProcessed == 1)
        #expect(result.errors.isEmpty)
        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(fixture.recorder.contains("kill-window", target: "@99"))
        #expect(!fixture.recorder.contains("kill-window", target: fixture.currentWindowID))
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
    }

    @Test("repo.add does not sweep a live scratch creation")
    func repoAddProtectsInFlightScratchWindow() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await makeAliasFixture()
        let router = RPCRouter(
            db: fixture.db,
            lifecycle: fixture.lifecycle,
            tmux: fixture.tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.repoAdd,
            params: RepoAddParams(path: repoDir.path)))

        #expect(response.success)
        #expect(!fixture.recorder.contains("kill-window", target: fixture.currentWindowID))
        try await insertPlannedCurrentTerminal(fixture)
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
    }

    @Test("cleanup protects an inherited scratch server after its source row is deleted")
    func cleanupProtectsPromotedServerWithoutScratchRows() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let recorder = CommandRecorder()
        let scratchServer = TmuxManager.serverName(forRepoPath: TBDConstants.scratchDir.path)
        let repoServer = TmuxManager.serverName(forRepoPath: repoDir.path)
        let existingTerminalID = UUID()
        let plannedTerminalID = UUID()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunListWindows: { server, _ in
                switch server {
                case scratchServer:
                    return [(windowID: "@1", paneID: "%1"), (windowID: "@2", paneID: "%2")]
                case repoServer:
                    return [(windowID: "@99", paneID: "%99")]
                default:
                    return []
                }
            },
            dryRunPaneSendTarget: { _, paneID in
                switch paneID {
                case "%1":
                    return .live(terminalID: existingTerminalID.uuidString.lowercased())
                case "%2":
                    return .live(terminalID: plannedTerminalID.uuidString.lowercased())
                default:
                    return .live(terminalID: nil)
                }
            })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let retiredScratch = try await db.worktrees.createScratch(
            name: "retired", displayName: "Retired",
            path: "/tmp/retired-scratch", tmuxServer: scratchServer)
        try await db.worktrees.delete(id: retiredScratch.id)
        #expect(try await db.worktrees.listLocal(scratchOnly: true).isEmpty)
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let promotedMain = try await db.worktrees.createMain(
            repoID: repo.id,
            name: "main",
            branch: "main",
            path: repoDir.path,
            tmuxServer: scratchServer)
        _ = try await db.terminals.create(
            id: existingTerminalID,
            worktreeID: promotedMain.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex)
        _ = try await db.terminals.create(
            id: plannedTerminalID,
            worktreeID: promotedMain.id,
            tmuxWindowID: "@2",
            tmuxPaneID: "%2",
            label: "Codex",
            kind: .codex)
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())

        let response = await router.handle(RPCRequest(method: RPCMethod.cleanup))

        #expect(response.success)
        #expect(recorder.contains("kill-server", target: repoServer))
        #expect(!recorder.contains("kill-window", target: "@2"))
        #expect(!recorder.contains("kill-server", target: scratchServer))
        #expect(try await db.terminals.get(id: plannedTerminalID) != nil)
    }

    @Test("hourly orphan maintenance leaves scratch ownership untouched when GC is disabled")
    func orphanMaintenanceSkipsScratchAliasesWhenGCDisabled() async throws {
        let fixture = try await makeAliasFixture()
        try await fixture.db.config.setGCEnabled(false)
        let gc = OrphanGC(
            db: fixture.db,
            git: GitManager(),
            broadcast: { _ in },
            lsofProvider: { [] })

        await Daemon.performOrphanMaintenance(
            orphanGC: gc,
            lifecycle: fixture.lifecycle,
            configStore: fixture.db.config,
            actuationLog: makeTestActuationLog())

        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) != nil)
        #expect(fixture.recorder.ownershipProbeCount() == 0)
        #expect(!fixture.recorder.contains("kill-window"))
    }

    @Test("hourly orphan maintenance reconciles scratch aliases when GC is enabled")
    func orphanMaintenanceReconcilesScratchAliasesWhenGCEnabled() async throws {
        let fixture = try await makeAliasFixture()
        try await fixture.db.config.setGCEnabled(true)
        let gc = OrphanGC(
            db: fixture.db,
            git: GitManager(),
            broadcast: { _ in },
            lsofProvider: { [] })

        await Daemon.performOrphanMaintenance(
            orphanGC: gc,
            lifecycle: fixture.lifecycle,
            configStore: fixture.db.config,
            actuationLog: makeTestActuationLog())

        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(fixture.recorder.ownershipProbeCount() == 1)
        #expect(!fixture.recorder.contains("kill-window"))
        try await insertPlannedCurrentTerminal(fixture)
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
    }
}
