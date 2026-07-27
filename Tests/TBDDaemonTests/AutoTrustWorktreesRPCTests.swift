import Foundation
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
}
