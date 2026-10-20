import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The two model-proxy flags reach the daemon through `config.setModelProxyEnabled`
/// and `config.setTranscriptStreamingEnabled`, and come back to the app through
/// `daemon.capabilities` — resolved daemon-side, so a Settings toggle and the
/// daemon can never disagree about which of them last wrote the column.
///
/// The two flags are independent: each RPC writes its own column and leaves
/// the other alone. Transcript streaming comes from the session mod, not the
/// proxy.
@Suite("Model proxy config RPCs")
struct ModelProxyConfigRPCTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let tmux = TmuxManager(dryRun: true)
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog(tag: "model-proxy-rpc"))
    }

    private func capabilities() async throws -> DaemonCapabilitiesResult {
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        #expect(response.success)
        return try response.decodeResult(DaemonCapabilitiesResult.self)
    }

    // MARK: - The proxy gate

    @Test func settingTheProxyOnPersistsIt() async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true))

        let response = await router.handle(request)

        #expect(response.success)
        #expect(try await db.config.get().modelProxyEnabled)
    }

    /// Switching the proxy off leaves streaming on: the provisional rows come
    /// from the session mod's file, which the proxy has no part in.
    @Test func turningTheProxyOffLeavesStreamingOn() async throws {
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))
        #expect(try await db.config.get().transcriptStreamingEnabled)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: false)))

        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.modelProxyEnabled == false)
        #expect(config.transcriptStreamingEnabled)
    }

    /// Turning the proxy on is not a request for the provisional transcript
    /// rows, so streaming stays where it was.
    @Test func turningTheProxyOnLeavesStreamingAlone() async throws {
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true)))

        let config = try await db.config.get()
        #expect(config.modelProxyEnabled)
        #expect(config.transcriptStreamingEnabled == Config.transcriptStreamingDefault)
    }

    // MARK: - The streaming gate

    /// Asking for streaming is not asking for the proxy: the stream comes from
    /// the session mod.
    @Test func turningStreamingOnLeavesTheProxyAlone() async throws {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))

        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.transcriptStreamingEnabled)
        #expect(config.modelProxyEnabled == Config.modelProxyDefault)
    }

    /// Turning streaming off is not a request to stop routing either.
    @Test func turningStreamingOffLeavesTheProxyAlone() async throws {
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true)))
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: false)))

        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.transcriptStreamingEnabled == false)
        #expect(config.modelProxyEnabled)
    }

    // MARK: - Capabilities

    @Test func capabilitiesStartAtTheShippedDefaults() async throws {
        let caps = try await capabilities()

        #expect(caps.modelProxyEnabled == Config.modelProxyDefault)
        #expect(caps.transcriptStreamingEnabled == Config.transcriptStreamingDefault)
        // No supervisor wired into this router, so it cannot route a session,
        // and Settings has what it needs to say so.
        #expect(caps.modelProxySupported == false)
        #expect(caps.modelProxyPort == nil)
        #expect(caps.modelProxyVersion == nil)
    }

    @Test func capabilitiesReflectTheProxyToggle() async throws {
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true)))

        let caps = try await capabilities()

        #expect(caps.modelProxyEnabled)
        // The proxy alone does not stream.
        #expect(caps.transcriptStreamingEnabled == false)
    }

    @Test func capabilitiesReflectTheStreamingToggle() async throws {
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))

        let caps = try await capabilities()

        #expect(caps.modelProxyEnabled == Config.modelProxyDefault)
        #expect(caps.transcriptStreamingEnabled)
    }

    /// Streaming on with the proxy off is reported as streaming: the flag no
    /// longer depends on the proxy.
    @Test func capabilitiesReportStreamingWithTheProxyOff() async throws {
        try await db.config.setTranscriptStreamingEnabled(true)
        try await db.config.setModelProxyEnabled(false)

        let caps = try await capabilities()

        #expect(caps.modelProxyEnabled == false)
        #expect(caps.transcriptStreamingEnabled)
    }

    /// An older daemon sends none of these keys. It runs no proxy either, so
    /// the app must fall through to the shipped defaults rather than assume the
    /// route is live.
    @Test func anOlderDaemonsPayloadFollowsTheShippedDefaults() throws {
        let legacy = #"{"controlModeEnabled":false}"#

        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(legacy.utf8))

        #expect(decoded.modelProxyEnabled == Config.modelProxyDefault)
        #expect(decoded.transcriptStreamingEnabled == Config.transcriptStreamingDefault)
        #expect(decoded.modelProxySupported == false)
        #expect(decoded.modelProxyPort == nil)
        #expect(decoded.modelProxyVersion == nil)
    }

    // MARK: - The supervisor follows the flag

    /// **The flag reaches the daemon already running**, which is the half a
    /// column write cannot do on its own: the boot path starts a supervisor
    /// only when the flag was already on, so a user who turned the proxy on
    /// would otherwise get nothing until the next restart.
    @Test func turningTheProxyOnStartsTheSupervisor() async throws {
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true)))

        #expect(supervisor.startCalls == 1)
        #expect(supervisor.drainCalls == 0)
    }

    /// And off drains rather than either retiring or merely stopping. A proxy
    /// left listening holds `proxy.lock` and self-retires only after its own
    /// 24-hour idle window, so a toggle that only stopped the watch would leave
    /// the feature running for a day; a toggle that retired it on the spot
    /// would break every session already routed through the port. Draining is
    /// the third thing, and the supervisor is the only party that knows when it
    /// is finished.
    @Test func turningTheProxyOffDrainsIt() async throws {
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true)))

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: false)))

        #expect(supervisor.drainCalls == 1)
        #expect(supervisor.startCalls == 1, "the off flip must not also start one")
    }

    /// Streaming no longer arms the proxy, so turning it on starts no
    /// supervisor.
    @Test func turningStreamingOnStartsNoSupervisor() async throws {
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))

        #expect(supervisor.startCalls == 0)
        #expect(supervisor.drainCalls == 0)
    }

    /// Turning streaming off leaves the proxy column alone, so it must leave
    /// the supervisor alone as well: routes still route.
    @Test func turningStreamingOffDrainsNothing() async throws {
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: false)))

        #expect(supervisor.startCalls == 0)
        #expect(supervisor.drainCalls == 0)
    }

    /// The port and version are carried, not dropped, once a supervisor fills
    /// them in — pinned now so B2 wires a field that already round-trips.
    @Test func portAndVersionRoundTripThroughTheWire() throws {
        var sent = DaemonCapabilitiesResult(controlModeEnabled: false)
        sent.modelProxySupported = true
        sent.modelProxyPort = 47_821
        sent.modelProxyVersion = "1.2.3"

        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: JSONEncoder().encode(sent))

        #expect(decoded.modelProxySupported)
        #expect(decoded.modelProxyPort == 47_821)
        #expect(decoded.modelProxyVersion == "1.2.3")
    }
}
