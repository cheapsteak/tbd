import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Paths the daemon wrote during a test, so `deinit` can take them away again.
/// A reference type because the suite is `~Copyable` and `deinit` must see what
/// the test body recorded.
private final class WrittenPathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        paths.append(path)
    }
    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = paths
        paths = []
        return out
    }
}

/// `remote.retain` / `remote.import` / `remote.recall` — the transcript
/// exchange. Tier 2: in-memory GRDB plus a fake provider invoker, no real
/// subprocess.
///
/// Mirrors `RPCRouterRemoteArchiveTests`'s wiring exactly; the interesting
/// difference is that these verbs write a `retained_transcript` row, so almost
/// every test has two observables — what the provider was asked, and what TBD
/// wrote down about the answer. A key TBD does not write down is a retained
/// transcript nobody can recall, so the second observable is not decoration.
@Suite("RPCRouter transcript exchange")
struct RPCRouterRemoteExchangeTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL
    /// Files this suite let the daemon write under `TBD_HOME`, removed in
    /// `deinit`. `scripts/test.sh` already points `TBD_HOME` at a scratch dir,
    /// so nothing here can reach the developer's real `~/tbd`; this only keeps
    /// the scratch tidy across a long run.
    private let writtenPaths: WrittenPathBox

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-exchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "agentbox", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        subs = StateSubscriptionManager()
        dir = localDir
        registryURL = localRegistryURL
        writtenPaths = WrittenPathBox()
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
        for path in writtenPaths.drain() {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func router(manager: RemoteProviderManager?) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager, actuationLog: makeTestActuationLog())
    }

    /// `describe` is popped FIRST — `loadRegistryAndDescribe` runs before the
    /// verb under test — so scripts read `[describe, verb...]`.
    private func router(invoker: FakeProviderInvoker) async -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: makeTestActuationLog())
        await manager.loadRegistryAndDescribe()
        return router(manager: manager)
    }

    private func call(_ router: RPCRouter, _ method: String, _ params: String) async -> RPCResponse {
        await router.handle(RPCRequest(method: method, params: params))
    }

    private func describeDeclaring(_ capabilities: [String]) -> ProviderResult {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return providerOK(#"{"contract_versions": [1], "name": "agentbox", "capabilities": [\#(caps)]}"#)
    }

    private func providerError(_ code: String, _ message: String, exitCode: Int32 = 1) -> ProviderResult {
        ProviderResult(
            exitCode: exitCode,
            stdout: Data(#"{"error": {"code": "\#(code)", "message": "\#(message)"}}"#.utf8),
            stderr: "")
    }

    private let retainParams = #"{"provider": "agentbox", "sessionID": "fix-flaky-ci"}"#
    private let importParams = #"{"provider": "agentbox", "jsonl": "{\"type\":\"user\"}\n"}"#
    private func recallParams(key: String, saveLocally: Bool = false) -> String {
        #"{"provider": "agentbox", "key": "\#(key)", "saveLocally": \#(saveLocally)}"#
    }

    private let receiptJSON = #"""
        {"key": "opaque-provider-string", "expires_at": "2026-10-01T00:00:00Z", "bytes": 12}
        """#

    // MARK: - The subsystem gate

    @Test func exchangeVerbsErrorWhenFlagOff() async throws {
        let invoker = FakeProviderInvoker(script: [])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let r = router(manager: manager)
        for (method, params) in [
            ("remote.retain", retainParams),
            ("remote.import", importParams),
            ("remote.recall", recallParams(key: "k")),
        ] {
            let response = await call(r, method, params)
            #expect(response.success == false, "expected \(method) to be gated")
            #expect(response.error == "remote backends disabled")
        }
        #expect(invoker.callsSnapshot().isEmpty)
    }

    // MARK: - Undeclared capability: refused, provider never spawned

    /// The contract forbids invoking a verb whose capability the provider has
    /// not declared. The discriminating half of each of these is
    /// `invoker.calls`: a refusal that still spawned the provider would pass a
    /// message assertion and fail the contract.
    @Test func retainRefusesAndNeverSpawnsWhenCapabilityUndeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["import", "recall"])])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.retain", retainParams)
        #expect(response.success == false)
        #expect(response.error?.contains("retain") == true)
        #expect(invoker.calls == [["describe"]])
    }

    @Test func importRefusesAndNeverSpawnsWhenCapabilityUndeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["retain", "recall"])])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.import", importParams)
        #expect(response.success == false)
        #expect(response.error?.contains("import") == true)
        #expect(invoker.calls == [["describe"]])
    }

    @Test func recallRefusesAndNeverSpawnsWhenCapabilityUndeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["retain", "import"])])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.recall", recallParams(key: "k"))
        #expect(response.success == false)
        #expect(response.error?.contains("recall") == true)
        #expect(invoker.calls == [["describe"]])
    }

    /// `retain` and `import` are two capabilities precisely because a backend
    /// may be able to snapshot its own sessions and not accept a foreign blob.
    /// Declaring one must never admit the other.
    @Test func declaringRetainDoesNotAdmitImport() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["retain"])])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.import", importParams)
        #expect(response.success == false)
        #expect(invoker.calls == [["describe"]])
    }

    /// No cached `describe` at all — capabilities read as empty, so every
    /// exchange verb refuses rather than failing open.
    @Test func exchangeVerbsRefuseWhenProviderHasNoCachedDescribe() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 1, stdout: Data(), stderr: "describe failed"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.retain", retainParams)
        #expect(response.success == false)
        #expect(invoker.calls == [["describe"]])
    }

    // MARK: - retain

    @Test func retainInvokesTheVerbAndStoresTheReceiptRow() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["retain"]),
            providerOK(receiptJSON),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.retain", retainParams)
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["retain", "fix-flaky-ci"]])

        let receipt = try response.decodeResult(RetainReceipt.self)
        #expect(receipt.key == "opaque-provider-string")
        #expect(receipt.bytes == 12)

        let stored = try await db.retainedTranscripts.find(
            provider: "agentbox", key: "opaque-provider-string")
        #expect(stored?.bytes == 12)
        #expect(stored?.sourceSessionID == "fix-flaky-ci")
        #expect(stored?.expiresAt == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
    }

    /// A receipt with no stated expiry stores a NULL — "the provider makes no
    /// claim", never "kept forever".
    @Test func retainStoresAnAbsentExpiryAsNoClaim() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["retain"]),
            providerOK(#"{"key": "k", "bytes": 5}"#),
        ])
        let r = await router(invoker: invoker)
        #expect(await call(r, "remote.retain", retainParams).success)
        let stored = try await db.retainedTranscripts.find(provider: "agentbox", key: "k")
        #expect(stored != nil)
        #expect(stored?.expiresAt == nil)
    }

    /// The receipt row is what makes a deleted lane's Revive-as-reseed
    /// possible, so `retain` on an adopted session must link the lane and keep
    /// the title the human recognises the conversation by.
    @Test func retainLinksTheAdoptedLaneAndItsTitle() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let lane = try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "agentbox", sessionID: "fix-flaky-ci", status: .active)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "agentbox",
            sessions: [RemoteSessionPayload(
                id: "fix-flaky-ci", title: "fix flaky CI", state: .running, agentState: .idle)],
            now: Date())

        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["retain"]),
            providerOK(receiptJSON),
        ])
        let r = await router(invoker: invoker)
        #expect(await call(r, "remote.retain", retainParams).success)

        let stored = try await db.retainedTranscripts.find(
            provider: "agentbox", key: "opaque-provider-string")
        #expect(stored?.originWorktreeID == lane.id)
        #expect(stored?.sourceTitle == "fix flaky CI")
    }

    @Test func retainSurfacesTheProvidersErrorMessage() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["retain"]),
            providerError("not_found", "no such session"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.retain", retainParams)
        #expect(response.success == false)
        #expect(response.error == "no such session")
        #expect(try await db.retainedTranscripts.all().isEmpty)
    }

    @Test func retainReportsATimeoutInWords() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(outcomes: [
            .result(describeDeclaring(["retain"])),
            .timeout,
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.retain", retainParams)
        #expect(response.success == false)
        #expect(response.error == "provider 'agentbox' timed out running 'retain'")
    }

    // MARK: - import

    @Test func importFeedsJSONLOnStdinAndStoresTheReceipt() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["import"]),
            providerOK(receiptJSON),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.import", importParams)
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["import"]])
        let sent = invoker.stdinsSnapshot().last ?? nil
        #expect(sent.map { String(decoding: $0, as: UTF8.self) } == "{\"type\":\"user\"}\n")

        let stored = try await db.retainedTranscripts.find(
            provider: "agentbox", key: "opaque-provider-string")
        #expect(stored != nil)
        // No session on this provider was involved, so there is none to name.
        #expect(stored?.sourceSessionID == nil)
        #expect(stored?.originWorktreeID == nil)
    }

    /// Malformed JSONL is the provider's `invalid_params`, surfaced as an
    /// ordinary failure — TBD does not pre-validate, because the contract makes
    /// the provider the validator of record.
    @Test func importSurfacesInvalidParams() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["import"]),
            providerError("invalid_params", "line 3 is not JSON"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.import", importParams)
        #expect(response.success == false)
        #expect(response.error == "line 3 is not JSON")
        #expect(try await db.retainedTranscripts.all().isEmpty)
    }

    // MARK: - recall

    @Test func recallReturnsJSONLAndWritesNoFileByDefault() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["recall"]),
            providerOK("{\"type\":\"user\"}\n"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.recall", recallParams(key: "opaque-key"))
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["recall", "opaque-key"]])
        let result = try response.decodeResult(RemoteRecallResult.self)
        #expect(result.jsonl == "{\"type\":\"user\"}\n")
        #expect(result.localPath == nil)
        let expected = TBDConstants.retainedTranscriptPath(provider: "agentbox", key: "opaque-key")
        #expect(FileManager.default.fileExists(atPath: expected.path) == false)
    }

    @Test func recallWithSaveLocallyWritesTheFileAndRecordsThePath() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let key = "saved-\(UUID().uuidString)"
        try await db.retainedTranscripts.insert(
            RetainedTranscript(provider: "agentbox", key: key, bytes: 16))
        let body = "{\"type\":\"user\"}\n"
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["recall"]),
            providerOK(body),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.recall", recallParams(key: key, saveLocally: true))
        #expect(response.success)
        let result = try response.decodeResult(RemoteRecallResult.self)

        let expected = TBDConstants.retainedTranscriptPath(provider: "agentbox", key: key)
        writtenPaths.add(expected.path)
        #expect(result.localPath == expected.path)
        #expect(result.jsonl == body, "the records come back whether or not they were saved")
        #expect(try String(contentsOf: expected, encoding: .utf8) == body)

        let stored = try await db.retainedTranscripts.find(provider: "agentbox", key: key)
        #expect(stored?.localPath == expected.path)
    }

    /// Truncation is detected against the receipt's `bytes` and reported in the
    /// log, never by failing the call: the records that arrived are real, and
    /// refusing them would turn a partial transcript into no transcript.
    @Test func aShortRecallStillReturnsTheBytesItGot() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.retainedTranscripts.insert(
            RetainedTranscript(provider: "agentbox", key: "short", bytes: 148_213))
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["recall"]),
            providerOK("{\"type\":\"user\"}\n"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.recall", recallParams(key: "short"))
        #expect(response.success)
        let result = try response.decodeResult(RemoteRecallResult.self)
        #expect(result.jsonl == "{\"type\":\"user\"}\n")
    }

    /// An aged-out key must say the record lapsed rather than claim it never
    /// existed, so `expired`'s message reaches the caller intact.
    @Test func recallSurfacesTheExpiredCode() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["recall"]),
            providerError("expired", "that transcript has aged out"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.recall", recallParams(key: "old"))
        #expect(response.success == false)
        #expect(response.error == "that transcript has aged out")
    }

    @Test func recallSurfacesTheNotFoundCode() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["recall"]),
            providerError("not_found", "unknown key"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.recall", recallParams(key: "nope"))
        #expect(response.success == false)
        #expect(response.error == "unknown key")
    }
}
