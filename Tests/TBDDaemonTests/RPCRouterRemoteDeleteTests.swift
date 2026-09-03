import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `remote.delete` — the destructive verb, behind the default-off
/// `remote_delete_enabled` flag. Tier 2: in-memory GRDB plus a fake provider
/// invoker, no real subprocess.
///
/// Wiring mirrors `RPCRouterRemoteExchangeTests`. The observable that matters
/// most here is `invoker.calls`: every refusal in this suite must be decided
/// *before* the provider is spawned, because a refusal that still ran `delete`
/// would pass a message assertion while having destroyed the session.
@Suite("RPCRouter remote delete")
struct RPCRouterRemoteDeleteTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL

    init() throws {
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localRegistryURL = localDir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "agentbox", "exec": "/nonexistent"}]"#
            .write(to: localRegistryURL, atomically: true, encoding: .utf8)
        db = localDB
        subs = StateSubscriptionManager()
        dir = localDir
        registryURL = localRegistryURL
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

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

    private let sessionID = "fix-flaky-ci"
    private func deleteParams(retain: Bool = false) -> String {
        #"{"provider": "agentbox", "sessionID": "\#(sessionID)", "retain": \#(retain)}"#
    }

    private let deletedJSON = #"{"id": "fix-flaky-ci", "deleted": true}"#
    // One line on purpose: inside a `#"""` raw literal a trailing backslash is
    // a literal backslash, not a line continuation, and the JSON would be
    // malformed in a way that reads as valid Swift.
    private let deletedWithReceiptJSON = #"{"id": "fix-flaky-ci", "deleted": true, "retained": {"key": "opaque-provider-string", "expires_at": "2026-10-01T00:00:00Z", "bytes": 148213}}"#

    /// Puts a mirror row in place, so "the row is gone afterwards" is a real
    /// observation rather than a vacuous one.
    @discardableResult
    private func mirrorSession(title: String = "fix flaky CI") async throws -> Bool {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "agentbox",
            sessions: [RemoteSessionPayload(
                id: sessionID, title: title, state: .running, agentState: .idle)],
            now: Date())
        return try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) != nil
    }

    private func adoptLane() async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: "agentbox", sessionID: sessionID, status: .active)
    }

    // MARK: - The gates, in order, none of which may spawn the provider

    /// The subsystem gate is outermost: with remote backends off, the answer is
    /// the subsystem's, not the feature flag's.
    @Test func deleteErrorsWhenTheSubsystemFlagIsOff() async throws {
        try await db.config.setRemoteDeleteEnabled(true)
        let invoker = FakeProviderInvoker(script: [])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let r = router(manager: manager)
        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success == false)
        #expect(response.error == "remote backends disabled")
        #expect(invoker.callsSnapshot().isEmpty)
    }

    /// **The flag's off branch.** The provider declares `delete` and would
    /// happily run it; the flag alone stops it, and the refusal names the flag
    /// so a soak participant knows which of three gates closed.
    @Test func deleteRefusesNamingTheFlagAndNeverSpawnsWhenFlagOff() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["delete", "retain"])])
        let r = await router(invoker: invoker)
        try await mirrorSession()

        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success == false)
        #expect(response.error?.contains("remote_delete_enabled") == true)
        #expect(invoker.calls == [["describe"]], "the flag must be read before anything is spawned")
        #expect(
            try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) != nil,
            "a refused delete must not drop the mirror row")
    }

    /// The flag's on branch, isolated: the same request the previous test
    /// refused now reaches the provider. Without this pair the flag could be
    /// wired to refuse unconditionally and both branches would look right.
    @Test func deleteProceedsWhenFlagOn() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerOK(deletedJSON),
        ])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["delete", sessionID]])
    }

    /// Flag on, capability absent: refused before anything is spawned, naming
    /// the capability.
    @Test func deleteRefusesWhenCapabilityUndeclared() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["retain", "recall"])])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success == false)
        #expect(response.error?.contains("delete") == true)
        #expect(invoker.calls == [["describe"]])
    }

    /// `--retain` is valid only where `retain` is also declared. A provider
    /// that declares `delete` alone must not be sent the flag: it would either
    /// ignore it and destroy a session the caller believed was being kept, or
    /// fail after the fact.
    @Test func retainRequestRequiresTheRetainCapability() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        let invoker = FakeProviderInvoker(script: [describeDeclaring(["delete"])])
        let r = await router(invoker: invoker)
        let response = await call(r, "remote.delete", deleteParams(retain: true))
        #expect(response.success == false)
        #expect(response.error?.contains("retain") == true)
        #expect(invoker.calls == [["describe"]], "nothing may be destroyed on the way to this refusal")
    }

    // MARK: - The successful delete

    /// **The immediate row drop.** The caller has positive knowledge that the
    /// session is gone, so the row goes at once rather than waiting for the
    /// drift rule's two absences.
    @Test func deleteDropsTheMirrorRowImmediately() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        #expect(try await mirrorSession())
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerOK(deletedJSON),
        ])
        let r = await router(invoker: invoker)

        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success)
        let outcome = try response.decodeResult(RemoteDeleteResult.self)
        #expect(outcome.deleted == true)
        #expect(outcome.retained == nil)
        #expect(
            try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) == nil,
            "the row must be gone now, not two polls from now")
    }

    /// Without `--retain` nothing is stored, and no receipt row is written —
    /// retention is never implied by the provider declaring `retain`.
    @Test func deleteWithoutRetainStoresNoReceipt() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete", "retain"]),
            providerOK(deletedJSON),
        ])
        let r = await router(invoker: invoker)
        #expect(await call(r, "remote.delete", deleteParams()).success)
        #expect(invoker.calls == [["describe"], ["delete", sessionID]])
        #expect(try await db.retainedTranscripts.all().isEmpty)
    }

    /// With `--retain` the flag reaches the provider and the receipt is
    /// recorded — a key TBD does not write down is a retained transcript nobody
    /// can ever recall.
    @Test func deleteWithRetainPassesTheFlagAndStoresTheReceipt() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        try await mirrorSession()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete", "retain"]),
            providerOK(deletedWithReceiptJSON),
        ])
        let r = await router(invoker: invoker)

        let response = await call(r, "remote.delete", deleteParams(retain: true))
        #expect(response.success)
        #expect(invoker.calls == [["describe"], ["delete", sessionID, "--retain"]])

        let outcome = try response.decodeResult(RemoteDeleteResult.self)
        #expect(outcome.retained?.key == "opaque-provider-string")
        #expect(outcome.retained?.bytes == 148213)

        let stored = try await db.retainedTranscripts.find(
            provider: "agentbox", key: "opaque-provider-string")
        #expect(stored?.bytes == 148213)
        #expect(stored?.sourceSessionID == sessionID)
        #expect(stored?.sourceTitle == "fix flaky CI",
                "the receipt must be written before the mirror row it reads from is dropped")
    }

    /// The receipt links the lane, which is what makes Revive-as-reseed
    /// possible later — and the lane is filed rather than lost, so a deleted
    /// lane keeps its place in the repo's Archived tab.
    @Test func deleteLinksAndArchivesTheAdoptedLane() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        let lane = try await adoptLane()
        try await mirrorSession()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete", "retain"]),
            providerOK(deletedWithReceiptJSON),
        ])
        let r = await router(invoker: invoker)

        #expect(await call(r, "remote.delete", deleteParams(retain: true)).success)
        let stored = try await db.retainedTranscripts.find(
            provider: "agentbox", key: "opaque-provider-string")
        #expect(stored?.originWorktreeID == lane.id)
        #expect(try await db.worktrees.get(id: lane.id)?.status == .archived)
        // Filing a deleted lane calls nothing on the provider: the session it
        // named no longer exists there.
        #expect(invoker.calls == [["describe"], ["delete", sessionID, "--retain"]])
    }

    /// `deleted: false` — an unknown or already-deleted id — is a success per
    /// the contract, matching `rm -f`. The row goes too: the provider has just
    /// stated the session is not there.
    @Test func deletedFalseForAnUnknownIDIsSuccess() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        try await mirrorSession()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerOK(#"{"id": "fix-flaky-ci", "deleted": false}"#),
        ])
        let r = await router(invoker: invoker)

        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success, "asking for a state the session is already in is not an error")
        #expect(response.error == nil)
        #expect(try response.decodeResult(RemoteDeleteResult.self).deleted == false)
        #expect(try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) == nil)
    }

    // MARK: - Failures keep the row

    @Test func deleteSurfacesTheProvidersErrorMessageAndKeepsTheRow() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        try await mirrorSession()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerError("permission_denied", "cannot end compute for this session"),
        ])
        let r = await router(invoker: invoker)

        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success == false)
        #expect(response.error == "cannot end compute for this session")
        #expect(try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) != nil)
    }

    /// Exit 0 with an unreadable body: TBD cannot say the session is gone, so
    /// it does not drop the row on a guess.
    @Test func unreadableDeleteResultIsReportedAndKeepsTheRow() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        try await mirrorSession()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerOK(#"{"nonsense": true}"#),
        ])
        let r = await router(invoker: invoker)

        let response = await call(r, "remote.delete", deleteParams())
        #expect(response.success == false)
        #expect(response.error?.contains("unreadable") == true)
        #expect(try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) != nil)
    }

    // MARK: - A poll in flight across the delete

    /// The manager the router is built on, so a test can drive a poll through
    /// it directly — `router(invoker:)` keeps its own to itself.
    private func managerAndRouter(
        invoker: FakeProviderInvoker
    ) async -> (RemoteProviderManager, RPCRouter) {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: makeTestActuationLog())
        await manager.loadRegistryAndDescribe()
        return (manager, router(manager: manager))
    }

    private func staleSighting() -> [RemoteSessionPayload] {
        [RemoteSessionPayload(id: sessionID, title: "fix flaky CI", state: .running, agentState: .idle)]
    }

    /// The interlock, and the reason `remote.delete` is not just "call the verb
    /// then DELETE the row". A `list` that captured its snapshot before the
    /// provider committed the destruction lands *after* the row is dropped and
    /// re-inserts it with `gone` false — the two-poll limbo the immediate drop
    /// exists to prevent, arrived at from the other side. Without the deletion
    /// watermark this test finds the row back in the mirror.
    @Test func aSnapshotCapturedBeforeTheDeleteCannotResurrectTheRow() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        try await mirrorSession()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerOK(deletedJSON),
        ])
        let (manager, r) = await managerAndRouter(invoker: invoker)
        // The poll went out a second before the delete, so nothing in its
        // answer can have accounted for one.
        let pollStartedAt = Date().addingTimeInterval(-1)
        let inFlight = staleSighting()

        #expect(await call(r, "remote.delete", deleteParams()).success)
        #expect(try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) == nil)

        try await manager.apply(
            snapshot: inFlight, provider: "agentbox", now: Date(),
            requestStartedAt: pollStartedAt)
        #expect(
            try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) == nil,
            "a snapshot captured before the delete must not put the row back")
    }

    /// The other branch, and what keeps the watermark from being a permanent
    /// blocklist: it suppresses stale answers, not the id. A poll whose request
    /// began after the delete returned is reporting something it learned
    /// afterwards — a session genuinely re-created under the same id — and it
    /// mirrors exactly as it always did.
    @Test func aSnapshotTakenAfterTheDeleteMirrorsTheSessionAgain() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        try await mirrorSession()
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerOK(deletedJSON),
        ])
        let (manager, r) = await managerAndRouter(invoker: invoker)

        #expect(await call(r, "remote.delete", deleteParams()).success)
        #expect(try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) == nil)

        try await manager.apply(
            snapshot: staleSighting(), provider: "agentbox", now: Date(),
            requestStartedAt: Date())
        #expect(
            try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) != nil,
            "the watermark must not hide a session the provider reports after the delete")
    }

    /// A delete that failed destroyed nothing, so its watermark is taken back
    /// rather than left to hide a session that is still alive. No mirror row is
    /// seeded here on purpose: a watermark left standing would suppress the
    /// INSERT, which is the observable this asserts.
    @Test func aFailedDeleteWithdrawsItsWatermark() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        try await db.config.setRemoteDeleteEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            describeDeclaring(["delete"]),
            providerError("permission_denied", "cannot end compute for this session"),
        ])
        let (manager, r) = await managerAndRouter(invoker: invoker)
        let pollStartedAt = Date().addingTimeInterval(-1)

        #expect(await call(r, "remote.delete", deleteParams()).success == false)
        #expect(await manager.deletionWatermark(provider: "agentbox", sessionID: sessionID) == nil)

        try await manager.apply(
            snapshot: staleSighting(), provider: "agentbox", now: Date(),
            requestStartedAt: pollStartedAt)
        #expect(
            try await db.remoteSessions.row(provider: "agentbox", sessionID: sessionID) != nil,
            "a session nothing destroyed must keep being mirrored")
    }
}
