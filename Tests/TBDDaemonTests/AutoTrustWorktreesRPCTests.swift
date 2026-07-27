import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Worktree auto-trust RPC tests. Covers the `config.setAutoTrustWorktrees`
/// RPC, the `daemon.capabilities` field carrying the flag, and the Codable
/// back-compat defaults.
///
/// Unlike its soak-flag siblings this flag ships default **ON**: the trust
/// dialog asks a question TBD already knows the answer to for a worktree it
/// created from a registered repo, and it blocks before SessionStart, so a
/// stalled-on-trust session is machine-invisible and cannot be recovered from.
@Suite("Worktree auto-trust RPC")
struct AutoTrustWorktreesRPCTests {

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
            startTime: Date()
        )
        return (router, db)
    }

    private func setAutoTrust(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetAutoTrustWorktrees,
            params: ConfigSetAutoTrustWorktreesParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success)
    }

    // MARK: - config.setAutoTrustWorktrees

    @Test("config.setAutoTrustWorktrees persists the opt-out")
    func setDisabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setAutoTrust(router, enabled: false)
        #expect(try await db.config.get().autoTrustWorktrees == false)
    }

    @Test("config.setAutoTrustWorktrees persists the flag back to true")
    func setEnabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setAutoTrust(router, enabled: false)
        try await setAutoTrust(router, enabled: true)
        #expect(try await db.config.get().autoTrustWorktrees == true)
    }

    // MARK: - daemon.capabilities

    @Test("capabilities reports auto-trust ON by default")
    func capabilitiesDefaultsOn() async throws {
        let (router, _) = try makeRouterAndDB()
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.autoTrustWorktrees == true)
    }

    @Test("capabilities re-evaluates auto-trust without a daemon restart")
    func capabilitiesReEvaluatesFlag() async throws {
        let (router, _) = try makeRouterAndDB()

        try await setAutoTrust(router, enabled: false)
        var response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        var result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.autoTrustWorktrees == false)

        try await setAutoTrust(router, enabled: true)
        response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.autoTrustWorktrees == true)
    }

    // MARK: - Codable back-compat

    /// Capabilities JSON from a daemon without the new key must decode to the
    /// shipped default — ON, matching the column default.
    @Test("capabilities JSON without autoTrustWorktrees decodes as true")
    func capabilitiesDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.autoTrustWorktrees == true)
    }

    /// Config JSON persisted before v66 must decode to the shipped default.
    @Test("Config JSON without autoTrustWorktrees decodes as true")
    func configDecodeBackCompat() throws {
        let result = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(result.autoTrustWorktrees == true)
    }

    // MARK: - worktree.foreign_head (v67)

    @Test("worktree foreignHead defaults false and round-trips through the store")
    func foreignHeadRoundTrips() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/repoFH", displayName: "repoFH", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", displayName: "w", branch: "b",
            path: "/tmp/repoFH/w", tmuxServer: "s", status: .active)
        #expect(wt.foreignHead == false, "ordinary creates are TBD-authored contents")
        #expect(try await db.worktrees.get(id: wt.id)?.foreignHead == false)

        try await db.worktrees.markForeignHead(id: wt.id)
        #expect(try await db.worktrees.get(id: wt.id)?.foreignHead == true)
    }

    /// A row written before v67 has no value for the column. The migration
    /// backfills `false`, but the record type must also survive a NULL rather
    /// than failing to decode and dropping the worktree.
    @Test("worktree row with a NULL foreign_head reads as false")
    func nullForeignHeadReadsFalse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/repoFHNull", displayName: "repoFHNull", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", displayName: "w", branch: "b",
            path: "/tmp/repoFHNull/w", tmuxServer: "s", status: .active)

        try await db.writerForTests.write { database in
            try database.execute(
                sql: "UPDATE worktree SET foreign_head = NULL WHERE id = ?",
                arguments: [wt.id.uuidString])
        }

        let reread = try #require(try await db.worktrees.get(id: wt.id))
        #expect(reread.foreignHead == false)
    }

    /// Worktree JSON from a daemon without the new key must decode to false —
    /// pre-v67 rows predate fork-PR checkout tracking.
    @Test("Worktree JSON without foreignHead decodes as false")
    func worktreeDecodeBackCompat() throws {
        let json = Data(#"""
        {"id":"11111111-1111-1111-1111-111111111111","name":"w","displayName":"w",
         "branch":"b","path":"/tmp/w","status":"active","createdAt":0,"tmuxServer":"s"}
        """#.utf8)
        let wt = try JSONDecoder().decode(Worktree.self, from: json)
        #expect(wt.foreignHead == false)
    }
}
