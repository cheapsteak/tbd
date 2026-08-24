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
    }

    private struct AliasFixture {
        let db: TBDDatabase
        let tmux: TmuxManager
        let lifecycle: WorktreeLifecycle
        let recorder: CommandRecorder
        let staleTerminalID: UUID
        let currentWorktreeID: UUID
        let currentTerminalID: UUID
    }

    private func makeAliasFixture() async throws -> AliasFixture {
        let db = try TBDDatabase(inMemory: true)
        let recorder = CommandRecorder()
        let currentTerminalID = UUID()
        let server = "scratch-shared"
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: recorder.append,
            dryRunListWindows: { probed, _ in
                probed == server ? [(windowID: "@1", paneID: "%1")] : []
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
            currentTerminalID: currentTerminalID)
    }

    private func insertPlannedCurrentTerminal(_ fixture: AliasFixture) async throws {
        _ = try await fixture.db.terminals.create(
            id: fixture.currentTerminalID,
            worktreeID: fixture.currentWorktreeID,
            tmuxWindowID: "@1",
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
