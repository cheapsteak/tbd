import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Pending-input veto for auto-hibernate RPC tests. Covers the
/// `config.setHibernateInputVeto` RPC and the extended `daemon.capabilities`
/// response carrying the hibernateInputVetoEnabled flag.
@Suite("Pending-input veto RPC")
struct HibernateInputVetoRPCTests {

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

    private func setHibernateInputVeto(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetHibernateInputVeto,
            params: ConfigSetHibernateInputVetoParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success)
    }

    // MARK: - config.setHibernateInputVeto

    @Test("config.setHibernateInputVeto persists the flag to true")
    func setVetoEnabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setHibernateInputVeto(router, enabled: true)
        #expect(try await db.config.get().hibernateInputVetoEnabled == true)
    }

    @Test("config.setHibernateInputVeto persists the flag to false")
    func setVetoDisabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setHibernateInputVeto(router, enabled: true)
        try await setHibernateInputVeto(router, enabled: false)
        #expect(try await db.config.get().hibernateInputVetoEnabled == false)
    }

    // MARK: - daemon.capabilities

    @Test("capabilities carries hibernateInputVetoEnabled")
    func capabilitiesCarriesVetoFlag() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setHibernateInputVeto(router, enabled: true)
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.hibernateInputVetoEnabled == true)
    }

    @Test("capabilities re-evaluates the veto flag without a daemon restart")
    func capabilitiesReEvaluatesVetoFlag() async throws {
        let (router, db) = try makeRouterAndDB()

        var response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        var result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.hibernateInputVetoEnabled == false)

        try await setHibernateInputVeto(router, enabled: true)
        response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.hibernateInputVetoEnabled == true)

        try await setHibernateInputVeto(router, enabled: false)
        response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.hibernateInputVetoEnabled == false)
    }

    /// Codable back-compat: capabilities JSON from a daemon without the new
    /// hibernateInputVetoEnabled key must still decode with a safe default.
    @Test("capabilities JSON without hibernateInputVetoEnabled decodes with default false")
    func capabilitiesDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.controlModeEnabled == true)
        #expect(result.hibernateInputVetoEnabled == false)
    }
}
