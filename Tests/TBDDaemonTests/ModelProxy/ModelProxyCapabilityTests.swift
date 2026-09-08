import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// What `daemon.capabilities` says about the model proxy, which is the whole of
/// what Settings has to explain a greyed-out toggle with.
@Suite("Model proxy capabilities RPC")
struct ModelProxyCapabilityTests {

    private func makeRouter() throws -> (RPCRouter, TBDDatabase) {
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

    private func capabilities(_ router: RPCRouter) async throws -> DaemonCapabilitiesResult {
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        return try response.decodeResult(DaemonCapabilitiesResult.self)
    }

    /// The composition every test and every mock-mode daemon runs in. It cannot
    /// route a session, and saying anything else would offer a switch that
    /// changes nothing.
    @Test("no supervisor reports unsupported, with no port and no version")
    func noSupervisorReportsNothing() async throws {
        let (router, _) = try makeRouter()
        let result = try await capabilities(router)
        #expect(result.modelProxySupported == false)
        #expect(result.modelProxyPort == nil)
        #expect(result.modelProxyVersion == nil)
    }

    @Test("a live supervisor reports its port and version")
    func liveSupervisorReportsItsProxy() async throws {
        let (router, _) = try makeRouter()
        let supervisor = FakeModelProxySupervisor()
        supervisor.snapshot = ModelProxyCapabilitySnapshot(
            supported: true, port: 51_842, version: "abc123")
        router.modelProxySupervisor = supervisor

        let result = try await capabilities(router)
        #expect(result.modelProxySupported == true)
        #expect(result.modelProxyPort == 51_842)
        #expect(result.modelProxyVersion == "abc123")
    }

    /// **The discriminating case.** A daemon that hit a configuration defect
    /// still has the binary beside it, so `canSpawn` alone would keep answering
    /// "supported" while nothing is ever routed again until the daemon
    /// restarts. `supported` is the conjunction, and this is the leg that
    /// proves the second half is read.
    @Test("a permanently-down supervisor reports unsupported even with a binary present")
    func permanentlyDownReportsUnsupported() async throws {
        let (router, _) = try makeRouter()
        let supervisor = FakeModelProxySupervisor()
        supervisor.snapshot = ModelProxyCapabilitySnapshot(
            supported: false, port: nil, version: nil)
        router.modelProxySupervisor = supervisor

        let result = try await capabilities(router)
        #expect(result.modelProxySupported == false)
        #expect(result.modelProxyPort == nil)
    }

    /// The same conjunction asserted at its source, so the test above is not
    /// merely restating its own stub: a real supervisor with no spawner has
    /// nothing to route with, and says so.
    @Test("a supervisor with no spawner is not supported")
    func supervisorWithNoSpawnerIsUnsupported() async throws {
        let db = try TBDDatabase(inMemory: true)
        let home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-proxy-caps"))
        let supervisor = ModelProxySupervisor(
            config: db.config, home: home, spawner: nil, ownVersion: nil)
        let snapshot = await supervisor.capabilitySnapshot()
        #expect(snapshot == ModelProxyCapabilitySnapshot.none)
    }
}
