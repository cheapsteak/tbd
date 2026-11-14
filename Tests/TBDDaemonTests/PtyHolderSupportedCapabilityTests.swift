import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// `daemon.capabilities`' `ptyHolderSupported`: whether this daemon could
/// start a pty holder at all. Every new session opens on one, so with this
/// false the daemon refuses every new session, and Settings shows the caption
/// that names the missing `TBDHolder` helper.
@Suite("Pty holder supported capability")
struct PtyHolderSupportedCapabilityTests {

    private func makeRouter() throws -> RPCRouter {
        let db = try TBDDatabase(inMemory: true)
        return RPCRouter(
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
    }

    private func capabilities(_ router: RPCRouter) async throws -> DaemonCapabilitiesResult {
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        return try response.decodeResult(DaemonCapabilitiesResult.self)
    }

    /// No registry at all, the state every unit-test router starts in.
    @Test("capabilities reports the transport unsupported with no registry")
    func capabilitiesUnsupportedWithoutRegistry() async throws {
        let router = try makeRouter()
        #expect(try await capabilities(router).ptyHolderSupported == false)
    }

    /// A registry that exists but has no spawner — a daemon whose `TBDHolder`
    /// binary an upgrade moved away. The registry is still built, because
    /// adoption reaches a running holder through its socket; it just cannot
    /// start a new one, so the spawn gate refuses and this must say so.
    @Test("capabilities reports unsupported for a registry that cannot spawn")
    func capabilitiesUnsupportedWithoutSpawner() async throws {
        let router = try makeRouter()
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-ph-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [] },
            spawner: nil)
        #expect(try await capabilities(router).ptyHolderSupported == false)
    }

    /// The opposite branch, so the field is not merely a constant false: a
    /// registry holding a spawner reports supported. `canSpawn` is decided in
    /// `init` from the spawner's presence alone, so nothing is launched here.
    @Test("capabilities reports supported for a registry that can spawn")
    func capabilitiesSupportedWithSpawner() async throws {
        let router = try makeRouter()
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-ph-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [] },
            spawner: HolderSpawner(
                executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder")))
        #expect(try await capabilities(router).ptyHolderSupported == true)
    }

    /// An older daemon that does not send the field has no holder path at all,
    /// so the absence reads false.
    @Test("capabilities JSON without the field decodes as unsupported")
    func capabilitiesDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.ptyHolderSupported == false)
    }

    /// …and a daemon that does send it is believed, in both directions, so the
    /// decoder is not just returning its fallback.
    @Test("capabilities JSON carrying the field round-trips")
    func capabilitiesDecodeCarriesValues() throws {
        let on = Data(#"{"controlModeEnabled":false,"ptyHolderSupported":true}"#.utf8)
        #expect(try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: on).ptyHolderSupported)
        let off = Data(#"{"controlModeEnabled":false,"ptyHolderSupported":false}"#.utf8)
        #expect(try !JSONDecoder().decode(DaemonCapabilitiesResult.self, from: off).ptyHolderSupported)
    }
}
