import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `config.setUpdateMode` and `daemon.checkForUpdate` — the write half of the
/// update setting and the explicit-gesture check
/// (`docs/specs/2026-09-04-automatic-version-updates-design.md` §§5–6, 9).
///
/// The column's states and the store setter behind the method are guarded by
/// `UpdateModeFlagTests`. What is asserted here is the part that would make the
/// setting unusable without it: that a gesture arriving over the socket reaches
/// that setter at all, that the read halves report what it wrote, and that a
/// router with no checker wired answers honestly rather than failing.
@Suite("Update mode RPC")
struct UpdateModeRPCTests {

    private func makeRouterAndDB() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        return (router, db)
    }

    private func setMode(_ router: RPCRouter, _ mode: UpdateMode) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetUpdateMode,
            params: ConfigSetUpdateModeParams(mode: mode))
        let response = await router.handle(request)
        #expect(response.success)
    }

    // MARK: - The gesture reaches the store

    @Test("config.setUpdateMode persists check")
    func setCheckPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setMode(router, .check)
        #expect(try await db.config.get().updateMode == .check)
    }

    /// A handler that ignored its params would pass the test above. Each of the
    /// other two values is its own branch of the same gate.
    @Test("config.setUpdateMode persists auto")
    func setAutoPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setMode(router, .auto)
        #expect(try await db.config.get().updateMode == .auto)
    }

    @Test("config.setUpdateMode persists off, and off is a choice not an absence")
    func setOffPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setMode(router, .auto)
        try await setMode(router, .off)
        #expect(try await db.config.get().updateMode == .off)
    }

    // MARK: - The read halves agree

    @Test("daemon.capabilities reports the mode the gesture wrote")
    func capabilitiesReportTheMode() async throws {
        let (router, _) = try makeRouterAndDB()
        try await setMode(router, .check)
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.updateMode == .check)
    }

    @Test("config.get reports the mode the gesture wrote")
    func configGetReportsTheMode() async throws {
        let (router, _) = try makeRouterAndDB()
        try await setMode(router, .auto)
        let response = await router.handle(RPCRequest(method: RPCMethod.configGet))
        let config = try response.decodeResult(Config.self)
        #expect(config.updateMode == .auto)
    }

    // MARK: - daemon.status and daemon.checkForUpdate without a checker

    /// A router with no checker wired — a test router, or a daemon that failed
    /// to build one — must not carry an `update` field claiming an observation
    /// nobody made.
    @Test("daemon.status omits update when no checker is wired")
    func statusOmitsUpdateWithoutAChecker() async throws {
        let (router, _) = try makeRouterAndDB()
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonStatus))
        let status = try response.decodeResult(DaemonStatusResult.self)
        #expect(status.update == nil)
    }

    /// And the explicit check answers "nothing observed" rather than erroring:
    /// a user who asked deserves an answer, and "I cannot tell" is one.
    @Test("daemon.checkForUpdate answers unobserved when no checker is wired")
    func checkForUpdateWithoutAChecker() async throws {
        let (router, _) = try makeRouterAndDB()
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCheckForUpdate))
        #expect(response.success)
        let status = try response.decodeResult(UpdateStatus.self)
        #expect(status.relation == .unknown)
        #expect(status.latestCommit == nil)
    }

    // MARK: - The other branch: a checker IS wired

    /// A checker that has observed something puts it on `daemon.status`, which
    /// is the only path the app and `tbd version` read.
    @Test("daemon.status carries the checker's observation once it has one")
    func statusCarriesTheObservation() async throws {
        let (router, _) = try makeRouterAndDB()
        let latest = "2222222222222222222222222222222222222222"
        let checker = UpdateChecker(
            ourCommit: "1111111111111111111111111111111111111111",
            sourceWorktree: "/w",
            readMode: { .check },
            resolveRemote: { _ in "git@github.com:acme/tbd.git" },
            remoteHead: { _, _ in latest },
            isAncestor: { _, _, _ in true },
            behindCount: { _, _, _ in 3 },
            launch: { _ in
                Issue.record("check mode must never launch")
                return false
            })
        router.updateChecker = checker

        // Before any tick, the field is absent rather than a fabricated
        // "up to date".
        var response = await router.handle(RPCRequest(method: RPCMethod.daemonStatus))
        #expect(try response.decodeResult(DaemonStatusResult.self).update == nil)

        // `daemon.checkForUpdate` is the gesture that produces one.
        response = await router.handle(RPCRequest(method: RPCMethod.daemonCheckForUpdate))
        #expect(try response.decodeResult(UpdateStatus.self).relation == .behind)

        response = await router.handle(RPCRequest(method: RPCMethod.daemonStatus))
        let status = try response.decodeResult(DaemonStatusResult.self)
        #expect(status.update?.latestCommit == latest)
        #expect(status.update?.behindBy == 3)
    }
}
