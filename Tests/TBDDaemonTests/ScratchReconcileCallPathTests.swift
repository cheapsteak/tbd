import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Scratch reconcile call paths")
struct ScratchReconcileCallPathTests {
    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []

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
                .live(terminalID: currentTerminalID.uuidString.lowercased())
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
        #expect(!fixture.recorder.contains("kill-window"))
        try await insertPlannedCurrentTerminal(fixture)
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
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
        try await insertPlannedCurrentTerminal(fixture)
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
    }

    @Test("hourly orphan maintenance reconciles scratch aliases safely")
    func orphanMaintenanceReconcilesScratchAliases() async throws {
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
            actuationLog: makeTestActuationLog())

        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(!fixture.recorder.contains("kill-window"))
        try await insertPlannedCurrentTerminal(fixture)
        #expect(try await fixture.db.terminals.get(id: fixture.currentTerminalID) != nil)
    }
}
