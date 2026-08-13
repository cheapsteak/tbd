import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// RPC surface for the queued-prompt feature: the `config.setQueuedPrompt`
/// verb, the `daemon.capabilities` read-back, and the wire types the delivery
/// path (task 2) and the modal (task 3) will speak.
@Suite("Queued prompt RPC")
struct QueuedPromptRPCTests {

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

    private func setQueuedPrompt(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetQueuedPrompt,
            params: ConfigSetQueuedPromptParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success)
    }

    // MARK: - config.setQueuedPrompt

    @Test("config.setQueuedPrompt persists the opt-in")
    func setEnabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setQueuedPrompt(router, enabled: true)
        #expect(try await db.config.get().queuedPromptEnabled == true)
    }

    @Test("config.setQueuedPrompt persists an explicit opt-out")
    func setDisabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setQueuedPrompt(router, enabled: false)
        #expect(try await db.config.get().queuedPromptEnabled == false)
        // …and it is a real 0, not a NULL that merely resolves to the default.
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.queued_prompt_enabled
        }
        #expect(stored == false)
    }

    // MARK: - daemon.capabilities

    @Test("capabilities reports the queued-prompt flag OFF by default")
    func capabilitiesDefaultsOff() async throws {
        let (router, _) = try makeRouterAndDB()
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.queuedPromptEnabled == false)
    }

    @Test("capabilities re-evaluates the queued-prompt flag without a restart")
    func capabilitiesReEvaluatesFlag() async throws {
        let (router, _) = try makeRouterAndDB()

        try await setQueuedPrompt(router, enabled: true)
        var response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        var result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.queuedPromptEnabled == true)

        try await setQueuedPrompt(router, enabled: false)
        response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.queuedPromptEnabled == false)
    }

    // MARK: - Codable back-compat

    @Test("capabilities JSON without queuedPromptEnabled decodes as false")
    func capabilitiesDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.queuedPromptEnabled == false)
    }

    @Test("Config JSON without queuedPromptEnabled decodes to the shipped default")
    func configDecodeBackCompat() throws {
        let result = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(result.queuedPromptEnabled == Config.queuedPromptDefault)
    }

    // MARK: - Wire types

    @Test("WorktreeSetPendingPromptParams round-trips")
    func pendingPromptParamsRoundTrip() throws {
        let params = WorktreeSetPendingPromptParams(
            worktreeID: UUID(), text: "multi\nline \"quoted\"", submit: false)
        let decoded = try JSONDecoder().decode(
            WorktreeSetPendingPromptParams.self,
            from: try JSONEncoder().encode(params))
        #expect(decoded.worktreeID == params.worktreeID)
        #expect(decoded.text == params.text)
        #expect(decoded.submit == false)
    }

    /// Submitting is opt-in. A client that omits the key gets staging, never a
    /// turn: an unasked-for turn cannot be taken back, and a submitted delivery
    /// is no more verifiable than an unsubmitted one.
    @Test("WorktreeSetPendingPromptParams defaults submit to off")
    func pendingPromptParamsSubmitDefault() throws {
        let uuid = UUID()
        let json = Data(#"{"worktreeID":"\#(uuid.uuidString)","text":"hi"}"#.utf8)
        let decoded = try JSONDecoder().decode(WorktreeSetPendingPromptParams.self, from: json)
        #expect(decoded.submit == false)
        #expect(WorktreeSetPendingPromptParams(worktreeID: uuid, text: "hi").submit == false)
    }

    @Test(
        "WorktreeSetPendingPromptResult round-trips every case",
        arguments: [
            WorktreeSetPendingPromptResult.parkedForSpawn,
            .awaitingReady,
            .refused(reason: "queued_prompt_enabled is off"),
        ]
    )
    func pendingPromptResultRoundTrip(_ result: WorktreeSetPendingPromptResult) throws {
        let decoded = try JSONDecoder().decode(
            WorktreeSetPendingPromptResult.self,
            from: try JSONEncoder().encode(result))
        #expect(decoded == result)
    }

    /// An unrecognised status from a newer daemon must not throw — it reads as
    /// a refusal naming what arrived, which is the conservative outcome for a
    /// caller waiting to hear whether its prompt was parked.
    @Test("WorktreeSetPendingPromptResult decodes an unknown status as a refusal")
    func pendingPromptResultUnknownStatus() throws {
        let json = Data(#"{"status":"teleported"}"#.utf8)
        let decoded = try JSONDecoder().decode(WorktreeSetPendingPromptResult.self, from: json)
        guard case .refused(let reason) = decoded else {
            Issue.record("expected a refusal, got \(decoded)")
            return
        }
        #expect(reason.contains("teleported"))
    }
}
