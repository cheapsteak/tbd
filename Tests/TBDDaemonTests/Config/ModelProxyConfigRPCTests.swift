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
/// The coupling the assertions here pin belongs to `ConfigStore`, not to the
/// handlers; these tests exist to prove the RPC layer actually routes to those
/// setters rather than to a second, uncoupled write.
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

    /// The coupling in the proxy's direction: switching the proxy off has
    /// switched streaming off whether or not the operator knows the second flag
    /// exists, because the provisional row reads a file only the proxy writes.
    @Test func turningTheProxyOffAlsoTurnsStreamingOff() async throws {
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
        #expect(config.transcriptStreamingEnabled == false)
    }

    /// And not the other way about: turning the proxy back on is not a request
    /// for the provisional transcript row, so streaming stays where it was.
    @Test func turningTheProxyOnLeavesStreamingAlone() async throws {
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true)))

        let config = try await db.config.get()
        #expect(config.modelProxyEnabled)
        #expect(config.transcriptStreamingEnabled == Config.transcriptStreamingDefault)
    }

    // MARK: - The streaming gate

    /// The coupling in streaming's direction: the file it reads does not exist
    /// without the proxy, so asking for streaming is asking for both.
    @Test func turningStreamingOnAlsoTurnsTheProxyOn() async throws {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))

        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.transcriptStreamingEnabled)
        #expect(config.modelProxyEnabled)
    }

    /// Turning streaming off is not a request to stop routing: a session may
    /// still want the proxy without the transcript's provisional row.
    @Test func turningStreamingOffLeavesTheProxyAlone() async throws {
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
        // The proxy alone does not stream; the reported value is the conjunction.
        #expect(caps.transcriptStreamingEnabled == false)
    }

    @Test func capabilitiesReflectTheStreamingToggle() async throws {
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))

        let caps = try await capabilities()

        #expect(caps.modelProxyEnabled)
        #expect(caps.transcriptStreamingEnabled)
    }

    /// `daemon.capabilities` reports the *effective* value, so a row holding a
    /// combination no toggle can produce — streaming on, proxy off — is
    /// reported as not streaming rather than passed to the app to re-derive.
    @Test func capabilitiesReportTheConjunctionNotTheRawColumn() async throws {
        try await db.config.setTranscriptStreamingEnabled(true)
        // Reach past the coupled setter, the way a hand-edited database would.
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE config SET model_proxy_enabled = 0 WHERE id = ?",
                arguments: [ConfigStore.singletonID])
        }
        #expect(try await db.config.get().transcriptStreamingEnabled)

        let caps = try await capabilities()

        #expect(caps.modelProxyEnabled == false)
        #expect(caps.transcriptStreamingEnabled == false)
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
        #expect(supervisor.retireCalls == 0)
    }

    /// And off retires rather than merely stopping. A proxy left listening
    /// holds `proxy.lock` and self-retires only after its own 24-hour idle
    /// window, so a toggle that only stopped the watch would leave the feature
    /// running for a day after the user switched it off.
    @Test func turningTheProxyOffRetiresIt() async throws {
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: true)))

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetModelProxyEnabled,
            params: ConfigSetModelProxyEnabledParams(enabled: false)))

        #expect(supervisor.retireCalls == 1)
        #expect(supervisor.startCalls == 1, "the off flip must not also start one")
    }

    /// Streaming on writes the proxy column on, in the same transaction, so it
    /// is a second way to arm the supervisor and has to start one too — a user
    /// who asked for the provisional row and got no proxy would watch for a
    /// stream file that never appears.
    @Test func turningStreamingOnStartsTheSupervisor() async throws {
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: true)))

        #expect(supervisor.startCalls == 1)
        #expect(supervisor.retireCalls == 0)
    }

    /// Turning streaming off leaves the proxy column alone, so it must leave
    /// the supervisor alone as well: routes still route.
    @Test func turningStreamingOffRetiresNothing() async throws {
        let supervisor = FakeModelProxySupervisor()
        router.modelProxySupervisor = supervisor

        _ = await router.handle(try RPCRequest(
            method: RPCMethod.configSetTranscriptStreamingEnabled,
            params: ConfigSetTranscriptStreamingParams(enabled: false)))

        #expect(supervisor.startCalls == 0)
        #expect(supervisor.retireCalls == 0)
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
