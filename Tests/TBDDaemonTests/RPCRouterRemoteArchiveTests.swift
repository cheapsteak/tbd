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
    /// The suite owns the log path rather than taking `makeTestActuationLog`'s
    /// hidden one, because half the watermark tests below assert on what the
    /// record *does not* contain — an extra daemon-rail row filed by a poll
    /// that interleaved with the verb — and that is unreadable without the path.
    let logPath: String

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
        logPath = localDir.appendingPathComponent("actuations.jsonl").path
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
        await wiring(invoker: invoker).router
    }

    /// The same wiring, with the manager handed back — the watermark tests read
    /// `filingDecision(for:)` off it and drive a competing poll through it.
    private func wiring(
        invoker: FakeProviderInvoker
    ) async -> (router: RPCRouter, manager: RemoteProviderManager) {
        let log = ActuationLog(path: logPath)
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: log)
        await manager.loadRegistryAndDescribe()
        return (router(manager: manager, actuationLog: log), manager)
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

    // MARK: - The filing watermark

    private func remoteParams(_ sessionID: String = "a") -> String {
        #"{"provider": "fake", "sessionID": "\#(sessionID)"}"#
    }

    private func payload(archived: Bool) -> RemoteSessionPayload {
        RemoteSessionPayload(
            id: "a", state: .running, agentState: .idle, meta: nil, archived: archived)
    }

    /// The provider commits the retirement partway through a call that may take
    /// 30 seconds, so the watermark has to be on file before the verb is
    /// invoked — not after it returns. Read from inside the call itself, which
    /// is the only moment at which "before it returns" is a fact rather than an
    /// inference.
    @Test("archive stamps the bound row's watermark before the verb returns")
    func archiveWatermarksTheBoundRowBeforeTheVerbReturns() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .active)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive", "unarchive"]),
            providerOK(#"{"id": "a", "state": "running", "archived": true}"#),
        ])
        let (r, manager) = await wiring(invoker: invoker)
        let observed = MidVerbObservation()
        let laneID = lane.id
        let startedAt = Date()
        invoker.onCall = { [manager] verb in
            guard verb.first == "archive" else { return }
            observed.watermark = await manager.filingDecision(for: laneID)
        }

        let response = await call(r, "remote.archive", remoteParams())

        #expect(response.success)
        let stamped = try #require(
            observed.watermark, "no filing watermark was on file while `archive` was still running")
        #expect(stamped >= startedAt)
    }

    /// Same obligation in the other direction. See
    /// `archiveWatermarksTheBoundRowBeforeTheVerbReturns`.
    @Test("unarchive stamps the bound row's watermark before the verb returns")
    func unarchiveWatermarksTheBoundRowBeforeTheVerbReturns() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .archived)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive", "unarchive"]),
            providerOK(#"{"id": "a", "state": "running", "archived": false}"#),
        ])
        let (r, manager) = await wiring(invoker: invoker)
        let observed = MidVerbObservation()
        let laneID = lane.id
        let startedAt = Date()
        invoker.onCall = { [manager] verb in
            guard verb.first == "unarchive" else { return }
            observed.watermark = await manager.filingDecision(for: laneID)
        }

        let response = await call(r, "remote.unarchive", remoteParams())

        #expect(response.success)
        let stamped = try #require(
            observed.watermark,
            "no filing watermark was on file while `unarchive` was still running")
        #expect(stamped >= startedAt)
    }

    /// The failure the watermark exists to prevent, driven end to end: a `list`
    /// posed before the gesture lands while the verb is still outstanding,
    /// carrying the provider's already-committed `archived: true`. Unwatermarked
    /// it files the row on the daemon's own `remote-filing-sync` rail and
    /// announces that the *provider* retired a session the *user* just retired.
    ///
    /// The discriminating assertions are the ones read mid-verb. By the time the
    /// RPC returns the row is archived either way — what differs is who filed
    /// it, and only the record and the notification taken at that moment can
    /// tell them apart.
    @Test("a poll landing while `archive` runs does not file the bound row itself")
    func pollDuringArchiveDoesNotFileTheRow() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .active)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive", "unarchive"]),
            providerOK(#"{"id": "a", "state": "running", "archived": true}"#),
        ])
        let (r, manager) = await wiring(invoker: invoker)
        // The poll's request went out before the gesture did, so its response
        // provably could not have accounted for this archive — however fresh
        // the `archived: true` it carries.
        let pollStartedAt = Date()
        let observed = MidVerbObservation()
        let laneID = lane.id
        let path = logPath
        let archivedPayload = payload(archived: true)
        invoker.onCall = { [db, manager] verb in
            guard verb.first == "archive" else { return }
            try? await manager.apply(
                snapshot: [archivedPayload], provider: "fake", now: Date(),
                requestStartedAt: pollStartedAt)
            await observed.capture(db: db, worktreeID: laneID, logPath: path)
        }

        let response = await call(r, "remote.archive", remoteParams())

        #expect(response.success)
        #expect(
            observed.status == .active,
            "the interleaved poll filed a row the user's own gesture was already retiring")
        #expect(observed.notifications == 0)
        #expect(observed.filingSyncRails == 0)
        // The gesture's own mirrored response is what files it, once.
        #expect(try await status(of: lane) == .archived)
    }

    /// The mirror image: a stale `list` carrying `archived: false` arriving
    /// while `unarchive` runs would return the row on the daemon rail, earning a
    /// second actuation for a gesture the user made once.
    @Test("a poll landing while `unarchive` runs does not return the bound row itself")
    func pollDuringUnarchiveDoesNotReturnTheRow() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .archived)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive", "unarchive"]),
            providerOK(#"{"id": "a", "state": "running", "archived": false}"#),
        ])
        let (r, manager) = await wiring(invoker: invoker)
        let pollStartedAt = Date()
        let observed = MidVerbObservation()
        let laneID = lane.id
        let path = logPath
        let returnedPayload = payload(archived: false)
        invoker.onCall = { [db, manager] verb in
            guard verb.first == "unarchive" else { return }
            try? await manager.apply(
                snapshot: [returnedPayload], provider: "fake", now: Date(),
                requestStartedAt: pollStartedAt)
            await observed.capture(db: db, worktreeID: laneID, logPath: path)
        }

        let response = await call(r, "remote.unarchive", remoteParams())

        #expect(response.success)
        #expect(
            observed.status == .archived,
            "the interleaved poll returned a row the user's own gesture was already returning")
        #expect(observed.filingSyncRails == 0)
        #expect(try await status(of: lane) == .active)
    }

    /// A verb that failed did not happen, and a watermark recorded for it is as
    /// wrong afterwards as the retirement would have been. Both halves are under
    /// test: it must be there while the verb runs, and gone once it fails.
    @Test("a failed archive withdraws the watermark it wrote")
    func failedArchiveWithdrawsItsOwnWatermark() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .active)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive"]),
            ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "busy", "message": "session is busy"}}"#.utf8),
                stderr: ""),
        ])
        let (r, manager) = await wiring(invoker: invoker)
        let observed = MidVerbObservation()
        let laneID = lane.id
        invoker.onCall = { [manager] verb in
            guard verb.first == "archive" else { return }
            observed.watermark = await manager.filingDecision(for: laneID)
        }

        let response = await call(r, "remote.archive", remoteParams())

        #expect(response.success == false)
        #expect(
            observed.watermark != nil,
            "no filing watermark was on file while `archive` was still running")
        #expect(await manager.filingDecision(for: laneID) == nil)
        #expect(try await status(of: lane) == .active)
    }

    /// Withdrawal restores, it does not delete: the row may carry an earlier
    /// decision that did happen and whose window is still open, and a gesture
    /// that failed has no business closing it.
    @Test("a timed-out unarchive restores an earlier watermark rather than deleting it")
    func failedUnarchiveRestoresTheEarlierWatermark() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let lane = try await seedLane(status: .archived)
        let invoker = FakeProviderInvoker(outcomes: [
            .result(describeDeclaring(["unarchive"])),
            .timeout,
        ])
        let (r, manager) = await wiring(invoker: invoker)
        let laneID = lane.id
        let earlier = Date().addingTimeInterval(-5)
        await manager.noteFilingDecision(worktreeID: laneID, at: earlier)
        let observed = MidVerbObservation()
        invoker.onCall = { [manager] verb in
            guard verb.first == "unarchive" else { return }
            observed.watermark = await manager.filingDecision(for: laneID)
        }

        let response = await call(r, "remote.unarchive", remoteParams())

        #expect(response.success == false)
        let duringVerb = try #require(
            observed.watermark,
            "no filing watermark was on file while `unarchive` was still running")
        #expect(duringVerb > earlier, "the gesture's own decision never moved the watermark forward")
        #expect(await manager.filingDecision(for: laneID) == earlier)
    }

    /// This surface is addressed by `(provider, sessionID)`, not by worktree, so
    /// it reaches sessions nobody has adopted. There is no row to watermark
    /// then, and that is an ordinary outcome rather than an error: the verb
    /// still runs and the response is still mirrored.
    @Test("a session with no bound worktree row archives cleanly, unwatermarked")
    func archiveWithNoBoundRowIsACleanNoOp() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["archive"]),
            providerOK(#"{"id": "a", "state": "running", "archived": true}"#),
        ])
        let (r, _) = await wiring(invoker: invoker)

        let response = await call(r, "remote.archive", remoteParams())

        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["archive", "a"]])
        #expect(try await db.worktrees.findRemote(provider: "fake", sessionID: "a") == nil)
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.decodedPayload?.isArchived == true)
    }
}

/// Capture point for facts read from inside a provider call, where a `@Sendable`
/// closure cannot write to a local `var`. Written and read on the one task that
/// runs the hook inline, so it needs no lock of its own.
private final class MidVerbObservation: @unchecked Sendable {
    var watermark: Date?
    var status: WorktreeStatus?
    var notifications = 0
    /// Actuation requests the filing sync wrote on the daemon's own rail.
    var filingSyncRails = 0

    func capture(db: TBDDatabase, worktreeID: UUID, logPath: String) async {
        status = ((try? await db.worktrees.get(id: worktreeID)) ?? nil)?.status
        notifications = ((try? await db.notifications.unread(worktreeID: worktreeID)) ?? []).count
        filingSyncRails = decodedActuationRows(at: logPath).count {
            ($0["actor"] as? [String: Any])?["rail"] as? String == ActuationRail.remoteFilingSync
        }
    }
}

/// The actuation log as decoded rows, readable from a `@Sendable` context —
/// the suite's own helper cannot be, since it is a method on a `~Copyable`
/// struct.
private func decodedActuationRows(at path: String) -> [[String: Any]] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return contents
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                return nil
            }
            return object as? [String: Any]
        }
}
