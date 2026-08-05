import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Thread-safe collector for broadcast StateDeltas. Mirrors the pattern in
/// `RemoteProviderManagerTests`'s private `BroadcastDeltas` (not reusable
/// here — it's `private` to that file).
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}

// Tier 2: in-memory GRDB + a fake provider invoker, no real subprocess.
@Suite("RPCRouter remote.* handlers")
struct RPCRouterRemoteTests: ~Copyable {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let dir: URL
    let registryURL: URL

    init() throws {
        // All throwing work happens on locals before any stored property is
        // assigned — a noncopyable struct can't leave itself partially
        // initialized if a later throw fires (compiler-enforced).
        let localDB = try TBDDatabase(inMemory: true)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-remote-\(UUID().uuidString)")
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

    /// `manager: nil` models the daemon booting with the flag off (case b of
    /// the flag gate — no manager was ever constructed). Passing a manager
    /// models the daemon booting with the flag on. Passes the suite's own
    /// `subs` through (rather than letting `RPCRouter` default-construct its
    /// own `StateSubscriptionManager`) so broadcast assertions observe the
    /// same object the test subscribed to.
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

    private func router(invoker: FakeProviderInvoker) -> RPCRouter {
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        return router(manager: manager)
    }

    private func call(_ router: RPCRouter, _ method: String, _ params: String = "{}") async -> RPCResponse {
        await router.handle(RPCRequest(method: method, params: params))
    }

    @Test func remoteVerbsErrorWhenFlagOff() async throws {
        let r = router(invoker: FakeProviderInvoker(script: []))
        for method in ["remote.providers", "remote.sessions", "remote.create",
                       "remote.stop", "remote.send", "remote.log", "remote.rename", "remote.dismiss",
                       "remote.setPin"] {
            let response = await call(r, method,
                #"{"provider": "fake", "sessionID": "x", "text": "t", "title": "t", "paramsJSON": "{}"}"#)
            #expect(response.success == false, "expected \(method) to be gated")
            #expect(response.error == "remote backends disabled")
        }
    }

    /// Case (b) of the flag gate: the flag is ON in the DB (a user flipped
    /// it via `config.setRemoteBackends`) but the router has no manager
    /// because the daemon booted with the flag off and hasn't restarted.
    /// Must degrade to the same clear error as case (a), not crash or
    /// silently no-op.
    @Test func remoteVerbsErrorWhenManagerNilEvenIfFlagOn() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(manager: nil)
        for method in ["remote.providers", "remote.sessions", "remote.create",
                       "remote.stop", "remote.send", "remote.log", "remote.rename", "remote.dismiss",
                       "remote.setPin"] {
            let response = await call(r, method,
                #"{"provider": "fake", "sessionID": "x", "text": "t", "title": "t", "paramsJSON": "{}"}"#)
            #expect(response.success == false, "expected \(method) to be gated")
            #expect(response.error == "remote backends disabled")
        }
    }

    @Test func sessionsReturnsMirrorWhenFlagOn() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.sessions")
        #expect(response.success)
        let result = try response.decodeResult(RemoteSessionsResult.self)
        #expect(result.sessions.map(\.payload.id) == ["a"])
    }

    @Test func sessionsProjectsCachedActiveRowsUnknownAfterInventoryFailure() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"sessions": [{"id": "a", "state": "running", "agent_state": "working"}]}"#),
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "inventory unavailable"),
        ])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await manager.pollOnce(provider: provider)
        await manager.pollOnce(provider: provider)

        let response = await call(router(manager: manager), "remote.sessions")
        let result = try response.decodeResult(RemoteSessionsResult.self)
        let projected = try #require(result.sessions.first?.payload)
        #expect(projected.state == .unknown)
        #expect(projected.agentState == .unknown)

        // Projection is non-destructive: recovery still has the complete
        // last-good payload to replace or inspect.
        let rawRows = try await db.remoteSessions.list()
        let raw = rawRows.first?.decodedPayload
        #expect(raw?.state == .running)
        #expect(raw?.agentState == .working)
    }

    /// The display projection and the mutation gate must agree even when the
    /// persisted freshness row is unreadable. They previously did not: the gate
    /// failed closed off the actor's own state while `remote.sessions` consulted
    /// the DTO, whose `lastSuccessfulSnapshotAt` is nil after a failed read — so
    /// cached rows kept rendering as confidently `running` in exactly the case
    /// the daemon knew the least. Dropping `tbd_meta` makes the SELECT throw.
    @Test func sessionsDemoteCachedRowsWhenFreshnessRowIsUnreadable() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running, agentState: .working)],
            now: Date(timeIntervalSince1970: 1_700_000_000))
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE tbd_meta")
        }
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs,
            runner: FakeProviderInvoker(script: [
                ProviderResult(exitCode: 3, stdout: Data(), stderr: "inventory unavailable")
            ]),
            registryURL: registryURL)
        await manager.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let r = router(manager: manager)

        let response = await call(r, "remote.sessions")
        let result = try response.decodeResult(RemoteSessionsResult.self)
        let projected = try #require(result.sessions.first?.payload)
        #expect(projected.state == .unknown)
        #expect(projected.agentState == .unknown)

        // And the gate the projection is supposed to match still refuses.
        let stop = await call(r, "remote.stop", #"{"provider":"fake","sessionID":"a"}"#)
        #expect(stop.success == false)
        #expect(stop.error?.contains("inventory is stale") == true)
    }

    @Test func staleInventoryBlocksMutationsButKeepsLogInspectionAvailable() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"sessions": [{"id": "a", "state": "running"}]}"#),
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "inventory unavailable"),
            providerOK("last output"),
        ])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await manager.pollOnce(provider: provider)
        await manager.pollOnce(provider: provider)
        let r = router(manager: manager)

        let stop = await call(r, "remote.stop", #"{"provider":"fake","sessionID":"a"}"#)
        #expect(stop.success == false)
        #expect(stop.error?.contains("inventory is stale") == true)

        let log = await call(r, "remote.log", #"{"provider":"fake","sessionID":"a"}"#)
        #expect(log.success)
        #expect(try log.decodeResult(RemoteLogResult.self).text == "last output")
        #expect(invoker.calls == [["list"], ["list"], ["log", "a"]])
        #expect(await manager.providerStatuses().first?.health == .stale,
                "a successful read-only verb must not claim inventory recovered")
    }

    /// `remote.sessions` must surface the daemon's pinned repo resolution on
    /// the wire, and the returned `id` must match the deterministic
    /// derivation the app keys sidebar rows by.
    @Test func sessionsResultCarriesResolvedRepoIDAndDeterministicID() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let repo = try await db.repos.create(
            path: "/tmp/api", displayName: "api", defaultBranch: "main",
            remoteURL: "https://github.com/acme/api")
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running, meta: ["repo": "acme/api"])],
            now: Date())
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.sessions")
        #expect(response.success)
        let result = try response.decodeResult(RemoteSessionsResult.self)
        let session = try #require(result.sessions.first)
        #expect(session.resolvedRepoID == repo.id)
        #expect(session.id == RemoteSessionIdentity.uuid(provider: "fake", sessionID: "a"))
    }

    /// Unmatched sessions (no `meta["repo"]`, or no local repo matches) must
    /// still round-trip with `resolvedRepoID == nil` — the unmatched path
    /// keeps working exactly as before this feature.
    @Test func sessionsResultLeavesResolvedRepoIDNilWhenUnmatched() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.sessions")
        let result = try response.decodeResult(RemoteSessionsResult.self)
        #expect(result.sessions.first?.resolvedRepoID == nil)
    }

    @Test func createPassesParamsThroughAndReturnsSession() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "new-1", "state": "starting"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{\"repo\": \"acme/api\"}"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["create"]])
        let session = try response.decodeResult(RemoteSessionPayload.self)
        #expect(session.id == "new-1")
    }

    /// The exact create body is the whole point of `remote.create`'s
    /// contract — the caller's `params` must survive verbatim, and exactly
    /// one `idempotency_key` must be minted. This was previously unasserted:
    /// `createPassesParamsThroughAndReturnsSession` above only checks the
    /// verb name.
    @Test func createBodyContainsCallerParamsAndOneIdempotencyKey() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "new-1", "state": "starting"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{\"repo\": \"acme/api\"}"}"#)
        #expect(response.success)
        let stdin = try #require(invoker.stdinsSnapshot().first ?? nil)
        let body = try #require(
            try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["repo"] as? String == "acme/api")
        let key = try #require(body["idempotency_key"] as? String)
        #expect(!key.isEmpty)
        // Exactly one key in the body — not e.g. duplicated under another name.
        #expect(body.keys.sorted() == ["idempotency_key", "params"])
    }

    /// A timeout on the first `create` call must retry exactly once, with
    /// the SAME idempotency key — a fresh key on retry would defeat
    /// provider-side dedupe and double-create a remote session.
    @Test func createRetriesOnceOnTimeoutWithIdenticalStdin() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(outcomes: [
            .timeout,
            .result(providerOK(#"{"id": "new-1", "state": "starting"}"#)),
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{}"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["create"], ["create"]],
                "a timeout must produce exactly two create calls")
        let stdins = invoker.stdinsSnapshot()
        #expect(stdins.count == 2)
        #expect(stdins[0] == stdins[1],
                "the retry must reuse the SAME idempotency key, not mint a fresh one")
    }

    /// A timeout on both attempts must surface a readable message, not the
    /// raw `ProviderRunError` enum description.
    @Test func createSurfacesTimeoutMessageWhenBothAttemptsTimeOut() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(outcomes: [.timeout, .timeout])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{}"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("timeout(verb:") == false)
        #expect(response.error?.contains("fake") == true)
    }

    @Test func createRejectsNonObjectParamsJSON() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "[1,2,3]"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("JSON object") == true)
    }

    @Test func createNormalizesEmptyParamsJSONToEmptyObject() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "new-1", "state": "starting"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create", #"{"provider": "fake", "paramsJSON": ""}"#)
        #expect(response.success)
        let stdin = try #require(invoker.stdinsSnapshot().first ?? nil)
        let body = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        #expect((body["params"] as? [String: Any])?.isEmpty == true)
    }

    @Test func createSurfacesProviderErrorMessage() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 1,
                stdout: Data(#"{"error": {"code": "invalid_params", "message": "branch required"}}"#.utf8),
                stderr: "")
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.create",
            #"{"provider": "fake", "paramsJSON": "{}"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("branch required") == true)
    }

    @Test func logDecodesRawBytes() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 0, stdout: Data("line1\nline2\n".utf8), stderr: "")
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.log",
            #"{"provider": "fake", "sessionID": "a", "lines": 100}"#)
        #expect(response.success)
        let result = try response.decodeResult(RemoteLogResult.self)
        #expect(result.text == "line1\nline2\n")
        #expect(invoker.calls == [["log", "a", "--lines", "100"]])
    }

    @Test func stopAdoptsReturnedSessionIntoMirror() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "a", "state": "exited", "exit_code": 0}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.stop", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["stop", "a"]])
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.decodedPayload?.state == .exited)
    }

    @Test func sendDeliversTextAsStdin() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 0, stdout: Data(), stderr: "")
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.send",
            #"{"provider": "fake", "sessionID": "a", "text": "hello agent"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["send", "a"]])
        #expect(invoker.stdinsSnapshot().first ?? nil == Data("hello agent".utf8))
    }

    // MARK: - remote.rename (Task 10)

    @Test func renameInvokesRenameVerbWithIDAndTitle() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "a", "title": "new title", "state": "running"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.rename",
            #"{"provider": "fake", "sessionID": "a", "title": "new title"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["rename", "a", "new title"]])
    }

    /// A title containing spaces must survive as ONE argv element (the
    /// contract: "TBD invokes the provider directly, never through a shell,
    /// so the caller need not shell-escape it") — asserted via the exact
    /// verb array `FakeProviderInvoker` records, which preserves argv
    /// boundaries rather than a shell-joined string.
    @Test func renamePassesMultiWordTitleAsOneArgvElement() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "a", "state": "running"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.rename",
            #"{"provider": "fake", "sessionID": "a", "title": "fix the flaky CI job"}"#)
        #expect(response.success)
        #expect(invoker.calls == [["rename", "a", "fix the flaky CI job"]])
    }

    /// A successful rename must adopt the returned session (new title) into
    /// the mirror, mirroring `stopAdoptsReturnedSessionIntoMirror` — so a
    /// provider that reflects the rename immediately doesn't wait for the
    /// next 60s poll to show it.
    @Test func renameAdoptsReturnedSessionIntoMirror() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"id": "a", "title": "new title", "state": "running"}"#)
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.rename",
            #"{"provider": "fake", "sessionID": "a", "title": "new title"}"#)
        #expect(response.success)
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.decodedPayload?.title == "new title")
    }

    @Test func renameSurfacesProviderErrorMessage() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 1,
                stdout: Data(#"{"error": {"code": "not_found", "message": "no such session"}}"#.utf8),
                stderr: "")
        ])
        let r = router(invoker: invoker)
        let response = await call(r, "remote.rename",
            #"{"provider": "fake", "sessionID": "a", "title": "new title"}"#)
        #expect(response.success == false)
        #expect(response.error?.contains("no such session") == true)
    }

    @Test func dismissMarksRowDismissedAndBroadcastsChange() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake", sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.dismiss", #"{"provider": "fake", "sessionID": "a"}"#)
        #expect(response.success)
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.dismissed == true)
        let changeBroadcasts = deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }
        #expect(changeBroadcasts.count == 1, "dismiss must broadcast a change delta")
    }

    /// Dismissing an already-dismissed row (or an unknown session) changes
    /// nothing — no pointless broadcast, matching the store's other paths
    /// (`applySnapshot`/`markGone`) which gate broadcasts on `changed`.
    @Test func dismissDoesNotBroadcastWhenNothingChanged() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.dismiss", #"{"provider": "fake", "sessionID": "nonexistent"}"#)
        #expect(response.success)
        let changeBroadcasts = deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }
        #expect(changeBroadcasts.isEmpty)
    }

    @Test func setPinStampsPinnedAtAndBroadcastsChange() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake", sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let r = router(invoker: FakeProviderInvoker(script: []))
        let before = Date()
        let response = await call(r, "remote.setPin",
            #"{"provider": "fake", "sessionID": "a", "pinned": true}"#)
        #expect(response.success)
        // Stamped daemon-side, not supplied by the client — the timestamp
        // must land inside the window this call spanned.
        let pinnedAt = try #require(try await db.remoteSessions.list().first?.pinnedAt)
        #expect(pinnedAt >= before && pinnedAt <= Date())
        let changeBroadcasts = deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }
        #expect(changeBroadcasts.count == 1, "pinning must broadcast a change delta")
    }

    @Test func setPinUnpinsAndSurfacesPinnedAtOverTheWire() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake", sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let r = router(invoker: FakeProviderInvoker(script: []))
        #expect(await call(r, "remote.setPin", #"{"provider": "fake", "sessionID": "a", "pinned": true}"#).success)

        var sessions = try (await call(r, "remote.sessions")).decodeResult(RemoteSessionsResult.self).sessions
        #expect(sessions.first?.pinnedAt != nil, "remote.sessions must carry the pin to the app")

        #expect(await call(r, "remote.setPin", #"{"provider": "fake", "sessionID": "a", "pinned": false}"#).success)
        sessions = try (await call(r, "remote.sessions")).decodeResult(RemoteSessionsResult.self).sessions
        #expect(sessions.first?.pinnedAt == nil)
    }

    /// Same `changed`-gated broadcast contract `remote.dismiss` follows.
    @Test func setPinDoesNotBroadcastWhenNothingChanged() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.setPin",
            #"{"provider": "fake", "sessionID": "nonexistent", "pinned": true}"#)
        #expect(response.success)
        let changeBroadcasts = deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }
        #expect(changeBroadcasts.isEmpty)
    }

    /// Pinning is local-only, so unlike every other `remote.*` verb it needs
    /// no `RemoteProviderManager` to reach the DB — but it stays behind the
    /// same feature flag, in both of the gate's two failure modes.
    @Test func setPinIsGatedByTheFlagInBothModes() async throws {
        let params = #"{"provider": "fake", "sessionID": "x", "pinned": true}"#
        let flagOff = await call(router(invoker: FakeProviderInvoker(script: [])), "remote.setPin", params)
        #expect(flagOff.success == false)
        #expect(flagOff.error == "remote backends disabled")

        try await db.config.setRemoteBackendsEnabled(true)
        let noManager = await call(router(manager: nil), "remote.setPin", params)
        #expect(noManager.success == false)
        #expect(noManager.error == "remote backends disabled")
    }

    /// A pinned session the provider stopped reporting must still be
    /// unpinnable — no provider verb is involved, so `gone` is irrelevant.
    @Test func setPinWorksOnAGoneRow() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake", sessions: [RemoteSessionPayload(id: "a", state: .running)], now: Date())
        let r = router(invoker: FakeProviderInvoker(script: []))
        #expect(await call(r, "remote.setPin", #"{"provider": "fake", "sessionID": "a", "pinned": true}"#).success)
        _ = try await db.remoteSessions.markGone(provider: "fake", sessionID: "a")

        #expect(await call(r, "remote.setPin", #"{"provider": "fake", "sessionID": "a", "pinned": false}"#).success)
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.gone == true)
        #expect(rows.first?.pinnedAt == nil)
    }

    // MARK: - remote.reportAttachExit

    /// The wire path for attach-exit correlation: the app reports an
    /// auth-class exit and provider health moves, with the out-of-band probe
    /// supplying the remediation the exit code alone can't carry.
    @Test func reportAttachExitMovesProviderHealthOverTheWire() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(#"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "Sign in", "command": "acme-provider login"}}}"#.utf8),
                stderr: ""),
        ])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let r = router(manager: manager)

        let response = await call(r, "remote.reportAttachExit",
            #"{"provider": "fake", "sessionID": "a", "exitCode": 4}"#)

        #expect(response.success)
        let statuses = await manager.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(statuses.first?.remediationCommand == "acme-provider login")
    }

    /// The non-auth branch over the wire: still a success response (the
    /// report was accepted), but nothing about provider health moves.
    @Test func reportAttachExitIgnoresNonAuthExitCodes() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [])
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let r = router(manager: manager)

        let response = await call(r, "remote.reportAttachExit",
            #"{"provider": "fake", "sessionID": "a", "exitCode": 137}"#)

        #expect(response.success)
        #expect(await manager.providerStatuses().first?.health == .ok)
        #expect(invoker.callsSnapshot().isEmpty)
    }

    @Test func reportAttachExitForAnUnknownProviderErrors() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "remote.reportAttachExit",
            #"{"provider": "nope", "sessionID": "a", "exitCode": 4}"#)
        #expect(response.success == false)
    }

    @Test func reportAttachExitIsGatedByTheFlagInBothModes() async throws {
        let params = #"{"provider": "fake", "sessionID": "x", "exitCode": 4}"#
        let flagOff = await call(router(invoker: FakeProviderInvoker(script: [])), "remote.reportAttachExit", params)
        #expect(flagOff.success == false)
        #expect(flagOff.error == "remote backends disabled")

        try await db.config.setRemoteBackendsEnabled(true)
        let noManager = await call(router(manager: nil), "remote.reportAttachExit", params)
        #expect(noManager.success == false)
        #expect(noManager.error == "remote backends disabled")
    }

    @Test func configToggleRoundTrips() async throws {
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "config.setRemoteBackends", #"{"enabled": true}"#)
        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.remoteBackendsEnabled == true)
    }

    @Test func configToggleOffLeavesFlagFalse() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "config.setRemoteBackends", #"{"enabled": false}"#)
        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.remoteBackendsEnabled == false)
    }

    // MARK: - daemon.capabilities

    @Test func capabilitiesReportsFlagOffAndNotLiveByDefault() async throws {
        let r = router(manager: nil)
        let response = await call(r, "daemon.capabilities")
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.remoteBackendsEnabled == false)
        #expect(result.remoteBackendsLive == false)
    }

    /// The state a later task's settings copy depends on distinguishing:
    /// flag flipped on via RPC, but the router still holds the manager it
    /// was constructed with (nil) because the daemon hasn't restarted.
    @Test func capabilitiesReportsFlagOnButNotLiveWithoutRestart() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(manager: nil)
        let response = await call(r, "daemon.capabilities")
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.remoteBackendsEnabled == true)
        #expect(result.remoteBackendsLive == false)
    }

    @Test func capabilitiesReportsLiveWhenManagerPresent() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let r = router(invoker: FakeProviderInvoker(script: []))
        let response = await call(r, "daemon.capabilities")
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.remoteBackendsEnabled == true)
        #expect(result.remoteBackendsLive == true)
    }

    // MARK: - wire-value pin (item 5: ProviderHealth raw values are a wire
    // contract app tasks match on; a case rename would silently break them)

    @Test func providerHealthRawValuesArePinnedOnTheWire() async throws {
        try await db.config.setRemoteBackendsEnabled(true)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(#"{"error": {"code": "auth_expired", "message": "expired"}}"#.utf8),
                stderr: ""),
        ])
        let manager = RemoteProviderManager(db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        await manager.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let statuses = await manager.providerStatuses()
        let status = try #require(statuses.first)
        #expect(status.health == .needsAuth)
        let encoded = try JSONEncoder().encode(status)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains(#""health":"needs_auth""#),
                "ProviderHealth.needsAuth's raw wire value must stay \"needs_auth\" — app code matches on it literally")
    }

    /// Pins the remaining three `ProviderHealth` raw values directly against
    /// its `Codable` conformance — app code matches on all four literally
    /// (see the case above for `needs_auth` exercised through the full
    /// manager pipeline), so a rename to any of these would silently change
    /// the wire without this failing.
    @Test func providerHealthRemainingRawValuesArePinned() throws {
        let expected: [(ProviderHealth, String)] = [
            (.ok, "ok"),
            (.stale, "stale"),
            (.error, "error"),
        ]
        for (health, raw) in expected {
            let encoded = try JSONEncoder().encode(health)
            let json = try #require(String(data: encoded, encoding: .utf8))
            #expect(json == "\"\(raw)\"",
                    "ProviderHealth.\(health)'s raw wire value must stay \"\(raw)\" — app code matches on it literally")
        }
    }
}
