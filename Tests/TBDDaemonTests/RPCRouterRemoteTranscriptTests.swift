import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `remote.transcript` — a live session's conversation, as Claude Code
/// transcript JSONL (`docs/remote-provider-contract.md` § `transcript <id>`).
///
/// Tier 2: in-memory GRDB plus a fake provider invoker, no real subprocess.
/// Wiring mirrors `RPCRouterRemoteExchangeTests` — `describe` is popped first,
/// so scripts read `[describe, transcript]`.
@Suite("RPCRouter remote.transcript")
struct RPCRouterRemoteTranscriptTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "agentbox", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        subs = StateSubscriptionManager()
        dir = localDir
        registryURL = localRegistryURL
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func router(invoker: FakeProviderInvoker) async -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: makeTestActuationLog())
        await manager.loadRegistryAndDescribe()
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager, actuationLog: makeTestActuationLog())
    }

    private func call(_ router: RPCRouter, _ params: String) async -> RPCResponse {
        await router.handle(RPCRequest(method: "remote.transcript", params: params))
    }

    private func describeDeclaring(_ capabilities: [String]) -> ProviderResult {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return providerOK(#"{"contract_versions": [1], "name": "agentbox", "capabilities": [\#(caps)]}"#)
    }

    private let params = #"{"provider": "agentbox", "sessionID": "fix-flaky-ci"}"#

    @Test func errorsWhenTheSubsystemIsOff() async throws {
        let invoker = FakeProviderInvoker(script: [])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let r = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true), startTime: Date(), subscriptions: subs,
            remoteManager: manager, actuationLog: makeTestActuationLog())
        let response = await call(r, params)
        #expect(response.success == false)
        #expect(response.error == "remote backends disabled")
        #expect(invoker.callsSnapshot().isEmpty)
    }

    /// The discriminating half is `invoker.calls`: the contract forbids
    /// invoking a verb the provider has not declared, so a refusal that still
    /// spawned the provider would pass a message assertion and fail the
    /// contract.
    @Test func refusesAndNeverSpawnsWhenCapabilityUndeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["log", "recall"])])
        let r = await router(invoker: invoker)
        let response = await call(r, params)
        #expect(response.success == false)
        #expect(response.error?.contains("transcript") == true)
        #expect(invoker.calls == [["describe"]])
    }

    /// `log` is raw scrollback and `transcript` is structured records; the
    /// contract states they are different data and a caller MUST NOT substitute
    /// one for the other. Declaring `log` must therefore not admit this verb.
    @Test func declaringLogDoesNotAdmitTranscript() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["log"])])
        let r = await router(invoker: invoker)
        #expect(await call(r, params).success == false)
        #expect(invoker.calls == [["describe"]])
    }

    @Test func returnsTheRecordsVerbatim() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let jsonl = "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n"
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["transcript"]),
            ProviderResult(exitCode: 0, stdout: Data(jsonl.utf8), stderr: ""),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, params)
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["transcript", "fix-flaky-ci"]])
        #expect(try response.decodeResult(RemoteTranscriptResult.self).jsonl == jsonl)
    }

    /// The cursor envelope on stderr is the contract's one stderr exception,
    /// and this RPC reads the whole transcript in one call — so it is dropped
    /// rather than carried to a caller with nowhere to keep it. The records
    /// must arrive unaffected.
    @Test func ignoresTheCursorEnvelopeOnStderr() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["transcript"]),
            ProviderResult(
                exitCode: 0, stdout: Data("{\"type\":\"user\"}\n".utf8),
                stderr: #"{"cursor": "abc123"}"#),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, params)
        #expect(response.success)
        let result = try response.decodeResult(RemoteTranscriptResult.self)
        #expect(result.jsonl == "{\"type\":\"user\"}\n")
        #expect(result.jsonl.contains("cursor") == false)
    }

    @Test func surfacesTheProvidersErrorMessage() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["transcript"]),
            ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "not_found", "message": "no such session"}}"#.utf8),
                stderr: ""),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, params)
        #expect(response.success == false)
        #expect(response.error == "no such session")
    }

    @Test func reportsATimeoutInWords() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(outcomes: [
            .result(describeDeclaring(["transcript"])),
            .timeout,
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, params)
        #expect(response.success == false)
        #expect(response.error == "provider 'agentbox' timed out running 'transcript'")
    }
}
