import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `remote.archive` / `remote.unarchive` — Task 2 of
/// `docs/plans/2026-08-16-remote-lane-archive.md`. Tier 2: in-memory GRDB + a
/// fake provider invoker, no real subprocess. Mirrors the shape of
/// `RPCRouterRemoteTests`'s `remote.stop`/`remote.rename` coverage; kept in
/// its own file rather than appended there because a sibling task is also
/// touching this worktree concurrently.
@Suite("RPCRouter remote.archive / remote.unarchive")
struct RPCRouterRemoteArchiveTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        subs = StateSubscriptionManager()
        dir = localDir
        registryURL = localRegistryURL
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func router(manager: RemoteProviderManager?) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager, actuationLog: makeTestActuationLog())
    }

    /// `describeOutcome` is popped FIRST by the fake invoker (`loadRegistryAndDescribe`
    /// runs before the verb under test), so callers order their script
    /// `[describe, verb...]`.
    private func router(invoker: FakeProviderInvoker) async -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        await manager.loadRegistryAndDescribe()
        return router(manager: manager)
    }

    private func call(_ router: RPCRouter, _ method: String, _ params: String = "{}") async -> RPCResponse {
        await router.handle(RPCRequest(method: method, params: params))
    }

    private func describeDeclaring(_ capabilities: [String]) -> ProviderResult {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return providerOK(#"{"contract_versions": [1], "name": "fake", "capabilities": [\#(caps)]}"#)
    }

    // MARK: - flag off / no manager

    @Test func archiveAndUnarchiveErrorWhenFlagOff() async throws {
        let invoker = FakeProviderInvoker(script: [])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let r = router(manager: manager)
        for method in ["remote.archive", "remote.unarchive"] {
            let response = await call(r, method, #"{"provider": "fake", "sessionID": "a"}"#)
            #expect(response.success == false, "expected \(method) to be gated")
            #expect(response.error == "remote backends disabled")
        }
        #expect(invoker.callsSnapshot().isEmpty)
    }

    @Test func archiveAndUnarchiveErrorWhenManagerNilEvenIfFlagOn() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(manager: nil)
        for method in ["remote.archive", "remote.unarchive"] {
            let response = await call(r, method, #"{"provider": "fake", "sessionID": "a"}"#)
            #expect(response.success == false, "expected \(method) to be gated")
            #expect(response.error == "remote backends disabled")
        }
    }

    // MARK: - declared capability: invokes and upserts

    @Test func archiveInvokesVerbAndAdoptsReturnedSessionWhenDeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive", "unarchive"]),
            providerOK(#"{"id": "a", "state": "running", "archived": true}"#),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.archive", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["archive", "a"]])
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.decodedPayload?.isArchived == true)
    }

    @Test func unarchiveInvokesVerbAndAdoptsReturnedSessionWhenDeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive", "unarchive"]),
            providerOK(#"{"id": "a", "state": "running", "archived": false}"#),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.unarchive", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["unarchive", "a"]])
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.decodedPayload?.isArchived == false)
    }

    // MARK: - undeclared capability: refused, provider never spawned

    @Test func archiveRefusesAndNeverSpawnsWhenCapabilityUndeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["unarchive"]),
        ])
        let r = await router(invoker: invoker)
        #expect(invoker.calls == [["describe"]], "sanity: only describe ran so far")
        let response = await call(r, "remote.archive", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("archive") == true)
        // The refusal must not spawn the provider — no "archive" call recorded,
        // only the earlier "describe".
        #expect(invoker.calls == [["describe"]])
    }

    @Test func unarchiveRefusesAndNeverSpawnsWhenCapabilityUndeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive"]),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.unarchive", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("unarchive") == true)
        #expect(invoker.calls == [["describe"]])
    }

    /// A provider declaring only `stop` must also be refused for archive —
    /// the plan's explicit warning that `stop` is never substituted for a
    /// missing `archive`.
    @Test func archiveRefusesWhenOnlyStopIsDeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["stop"]),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.archive", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success == false)
        #expect(invoker.calls == [["describe"]])
    }

    /// No `describe` was ever recorded for this provider name at all (e.g.
    /// describe failed or the provider is unknown) — capabilities read as
    /// empty, so both verbs refuse rather than crash or fail open.
    @Test func archiveRefusesWhenProviderHasNoCachedDescribe() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 1, stdout: Data(), stderr: "describe failed"),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.archive", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success == false)
        #expect(invoker.calls == [["describe"]])
    }
}
