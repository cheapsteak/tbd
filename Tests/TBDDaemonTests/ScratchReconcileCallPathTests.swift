import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Which call paths reach scratch terminals. Scratch spaces have no repo row,
/// so no per-repo reconcile pass reaches their terminals, and each caller that
/// should reconcile them has to ask on its own — including on an install with
/// no registered repo at all.
@Suite("Scratch reconcile call paths")
struct ScratchReconcileCallPathTests {

    private struct Fixture {
        let db: TBDDatabase
        let lifecycle: WorktreeLifecycle
        let probe: RecordingLeftoverTmuxProbe
        let staleTerminalID: UUID
        let server: String
    }

    /// A scratch space whose one Codex tab names no thread, on a tmux server
    /// the probe finds gone: the row any pass that reaches scratch terminals
    /// deletes, and that nothing else touches.
    private func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let server = "scratch-shared"
        let probe = RecordingLeftoverTmuxProbe(answer: { _ in .absent })
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            leftoverTmuxProbe: probe.probe)
        let scratch = try await db.worktrees.createScratch(
            name: "scratch-stale", displayName: "Scratch Stale",
            path: "/tmp/scratch-stale", tmuxServer: server)
        let staleTerminal = try await db.terminals.create(
            worktreeID: scratch.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        return Fixture(
            db: db, lifecycle: lifecycle, probe: probe,
            staleTerminalID: staleTerminal.id, server: server)
    }

    private func makeRouter(_ fixture: Fixture) -> RPCRouter {
        RPCRouter(
            db: fixture.db,
            lifecycle: fixture.lifecycle,
            startTime: Date(),
            actuationLog: makeTestActuationLog())
    }

    /// The `OrphanGC` the hourly maintenance runs, with every base its sweep
    /// walks under a root nothing creates: the sweep is incidental here, and
    /// left on the process-global `TBD_HOME` it would drain and delete what
    /// other suites put there.
    private func makeGC(db: TBDDatabase) -> OrphanGC {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdgcsr"), isDirectory: true)
        return OrphanGC(
            db: db,
            git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: root.appendingPathComponent("s", isDirectory: true),
            profileDirBase: root.appendingPathComponent("p", isDirectory: true),
            hangStackBase: root.appendingPathComponent("hs", isDirectory: true),
            holdersBase: root.appendingPathComponent("h", isDirectory: true),
            attachmentsBase: root.appendingPathComponent("a", isDirectory: true),
            remoteTranscriptsEnvironment: ["TBD_HOME": root.path],
            reposBase: root.appendingPathComponent("repos", isDirectory: true),
            sessionsBase: root.appendingPathComponent("se", isDirectory: true),
            devServersBase: root.appendingPathComponent("ds", isDirectory: true),
            retainedTranscriptsBase: root.appendingPathComponent("rt", isDirectory: true),
            scratchSpacesBase: root.appendingPathComponent("sc", isDirectory: true),
            worktreesBase: root.appendingPathComponent("wt", isDirectory: true))
    }

    @Test("cleanup reconciles scratch terminals with zero registered repos")
    func cleanupReconcilesScratchTerminalsWithoutRepos() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setGCEnabled(false)
        #expect(try await fixture.db.repos.list().isEmpty)

        let response = await makeRouter(fixture).handle(RPCRequest(method: RPCMethod.cleanup))

        #expect(response.success)
        let result = try response.decodeResult(CleanupResult.self)
        #expect(result.reposProcessed == 0)
        #expect(result.errors.isEmpty)
        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(fixture.probe.servers == [fixture.server])
    }

    @Test("startup reconciliation reconciles scratch terminals even when periodic GC is disabled")
    func startupReconcilesScratchTerminalsWhenGCDisabled() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setGCEnabled(false)

        await Daemon().performStartupReconciliation(
            mockMode: nil,
            database: fixture.db,
            git: GitManager(),
            lifecycle: fixture.lifecycle,
            actuationLog: makeTestActuationLog())

        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(fixture.probe.servers == [fixture.server])
    }

    /// `repo.add` reconciles the repo it added, and that repo only.
    @Test("repo.add leaves scratch terminals alone")
    func repoAddLeavesScratchTerminalsAlone() async throws {
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await makeFixture()

        let response = await makeRouter(fixture).handle(try RPCRequest(
            method: RPCMethod.repoAdd,
            params: RepoAddParams(path: repoDir.path)))

        #expect(response.success)
        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) != nil)
        #expect(!fixture.probe.servers.contains(fixture.server),
                "repo.add asked about a scratch server: \(fixture.probe.servers)")
    }

    @Test("hourly orphan maintenance leaves scratch terminals untouched when GC is disabled")
    func orphanMaintenanceSkipsScratchTerminalsWhenGCDisabled() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setGCEnabled(false)
        let gc = makeGC(db: fixture.db)

        await Daemon.performOrphanMaintenance(
            orphanGC: gc,
            lifecycle: fixture.lifecycle,
            configStore: fixture.db.config,
            actuationLog: makeTestActuationLog())

        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) != nil)
        #expect(fixture.probe.servers.isEmpty)
    }

    @Test("hourly orphan maintenance reconciles scratch terminals when GC is enabled")
    func orphanMaintenanceReconcilesScratchTerminalsWhenGCEnabled() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setGCEnabled(true)
        let gc = makeGC(db: fixture.db)

        await Daemon.performOrphanMaintenance(
            orphanGC: gc,
            lifecycle: fixture.lifecycle,
            configStore: fixture.db.config,
            actuationLog: makeTestActuationLog())

        #expect(try await fixture.db.terminals.get(id: fixture.staleTerminalID) == nil)
        #expect(fixture.probe.servers == [fixture.server])
    }
}
