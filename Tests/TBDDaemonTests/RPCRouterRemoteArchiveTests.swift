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

    private func router(
        manager: RemoteProviderManager?, actuationLog: ActuationLog = makeTestActuationLog()
    ) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager, actuationLog: actuationLog)
    }

    /// `describeOutcome` is popped FIRST by the fake invoker (`loadRegistryAndDescribe`
    /// runs before the verb under test), so callers order their script
    /// `[describe, verb...]`.
    ///
    /// The manager gets the SAME actuation log as the router, exactly as
    /// `Daemon.swift` shares one — and, like `RemoteLaneFixture`, it gets one
    /// at all. `syncFilingDecisions` fails closed when the manager's log is
    /// nil, so a manager built without one silently disables every row-filing
    /// side effect the handlers' `applyUpsert` reaches, leaving the mirror
    /// payload (which updates unconditionally) as the only observable.
    private func router(invoker: FakeProviderInvoker) async -> RPCRouter {
        let log = makeTestActuationLog(tag: "rpc-remote-archive")
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: log)
        await manager.loadRegistryAndDescribe()
        return router(manager: manager, actuationLog: log)
    }

    /// Pre-adopts the remote worktree row bound to the session under test.
    ///
    /// Without it `findRemote(provider:sessionID:)` resolves nothing and the
    /// filing sync skips the session entirely — so the row-status assertions
    /// below would be vacuous and only the mirror payload would be under test.
    @discardableResult
    private func seedLane(sessionID: String = "a", status: WorktreeStatus) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "fake", sessionID: sessionID, status: status)
    }

    private func status(of worktree: Worktree) async throws -> WorktreeStatus? {
        try await db.worktrees.get(id: worktree.id)?.status
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

    /// Two observables, and only the second can regress silently: the mirror
    /// payload records what the provider said (`applyUpsert` writes it
    /// unconditionally), while the worktree row's status is the filing
    /// decision travelling back through `syncFilingDecisions`. Assert both.
    @Test func archiveInvokesVerbAndAdoptsReturnedSessionWhenDeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .active)
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
        #expect(try await status(of: lane) == .archived)
    }

    /// The mirror-plus-row pair again, in the other direction. See
    /// `archiveInvokesVerbAndAdoptsReturnedSessionWhenDeclared`.
    @Test func unarchiveInvokesVerbAndAdoptsReturnedSessionWhenDeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .archived)
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
        #expect(try await status(of: lane) == .active)
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
