import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 1: pure decode, no I/O.
@Suite("SnapshotCompleteness")
struct SnapshotCompletenessTests {
    private func envelope(_ json: String) throws -> RemoteSessionListEnvelope {
        try JSONDecoder().decode(RemoteSessionListEnvelope.self, from: Data(json.utf8))
    }

    /// The contract's default: "Absent — MUST be read as `true`. A provider
    /// that always enumerates everything need never emit the field."
    @Test func anAbsentCompleteFieldReadsAsTrue() throws {
        let decoded = try envelope(#"{"sessions": [{"id": "a", "state": "running"}]}"#)
        #expect(decoded.complete)
        #expect(decoded.sessions.map(\.id) == ["a"])
    }

    @Test func anExplicitFalseSurvivesDecoding() throws {
        let decoded = try envelope(#"{"complete": false, "sessions": []}"#)
        #expect(decoded.complete == false)
    }

    @Test func anExplicitTrueSurvivesDecoding() throws {
        let decoded = try envelope(#"{"complete": true, "sessions": []}"#)
        #expect(decoded.complete)
    }

    /// The memberwise init keeps its old call shape for every existing fixture.
    @Test func theMemberwiseInitDefaultsToComplete() {
        #expect(RemoteSessionListEnvelope(sessions: []).complete)
        #expect(RemoteSessionListEnvelope(sessions: [], complete: false).complete == false)
    }

    // MARK: - The store half

    private func payload(_ id: String) -> RemoteSessionPayload {
        RemoteSessionPayload(id: id, state: .running, agentState: .working)
    }

    /// The defect being fixed: a provider that can only ever enumerate part
    /// of its inventory would tombstone its own live lanes two polls after
    /// creating them.
    @Test func anIncompleteSnapshotNeverAdvancesMissingCount() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], complete: false, now: Date())
        for _ in 0..<5 {
            _ = try await db.remoteSessions.applySnapshot(
                provider: "p", sessions: [], complete: false, now: Date())
        }
        let rows = try await db.remoteSessions.list()
        #expect(rows.count == 1)
        #expect(rows[0].missingCount == 0)
        #expect(rows[0].gone == false)
    }

    /// The discriminating pair: the SAME absence under a complete snapshot
    /// must still retire, or the fix would have disabled the rule outright.
    @Test func aCompleteSnapshotStillRetiresOnTwoAbsences() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], complete: true, now: Date())
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [], complete: true, now: Date())
        #expect(try await db.remoteSessions.list()[0].missingCount == 1)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [], complete: true, now: Date())
        #expect(try await db.remoteSessions.list()[0].gone)
    }

    /// An incomplete snapshot is authoritative about PRESENCE, so a session
    /// it sighted is still adopted into the mirror.
    @Test func anIncompleteSnapshotStillInsertsASessionItSighted() async throws {
        let db = try TBDDatabase(inMemory: true)
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], complete: false, now: Date())
        #expect(outcome.changed)
        #expect(try await db.remoteSessions.list().map(\.sessionID) == ["a"])
    }

    /// The persisted half of freshness. Without this the partial view
    /// survives a daemon restart looking fresh.
    @Test func anIncompleteSnapshotWritesNoPersistedFreshnessKey() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], complete: false,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await db.remoteSessions.lastSuccessfulSnapshotAt(provider: "p") == nil)
    }

    @Test func aCompleteSnapshotStillWritesThePersistedFreshnessKey() async throws {
        let db = try TBDDatabase(inMemory: true)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], complete: true, now: at)
        #expect(try await db.remoteSessions.lastSuccessfulSnapshotAt(provider: "p") == at)
    }

    /// A later incomplete snapshot must not CLOBBER a good persisted stamp
    /// either — suppression means "leave it where it was", not "write now".
    @Test func anIncompleteSnapshotLeavesAnEarlierFreshnessStampIntact() async throws {
        let db = try TBDDatabase(inMemory: true)
        let good = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], complete: true, now: good)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], complete: false,
            now: Date(timeIntervalSince1970: 1_700_009_999))
        #expect(try await db.remoteSessions.lastSuccessfulSnapshotAt(provider: "p") == good)
    }

    /// Omitting the argument keeps today's behavior, which is what lets every
    /// pre-existing call site stand.
    @Test func theDefaultedArgumentBehavesAsComplete() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a")], now: Date())
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [], now: Date())
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [], now: Date())
        #expect(try await db.remoteSessions.list()[0].gone)
    }

    // MARK: - The manager half

    /// The whole point of the field for `claude-cloud`: a provider whose
    /// snapshots are always incomplete never claims freshness, so a restart
    /// cannot recover a timestamp it never earned.
    @Test func anIncompleteSnapshotDoesNotStampInMemoryFreshness() async throws {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"complete": false, "sessions": [{"id": "a", "state": "running"}]}"#)
        ])
        let m = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        let status = await m.providerStatuses().first
        // The provider ANSWERED, so degraded health clears…
        #expect(status?.health == .ok)
        // …but nothing claims a complete inventory was ever held.
        #expect(status?.lastSuccessfulSnapshotAt == nil)
        // And the row it sighted was still adopted into the mirror.
        #expect(try await db.remoteSessions.list().map(\.sessionID) == ["a"])
        // Mutations stay available: `isStaleSnapshot` deliberately excludes a
        // provider confirmed never to have snapshotted, so Send renders.
        #expect(await m.hasStaleSnapshot(provider: "fake") == false)
        #expect(status?.hasStaleSnapshot == false)
    }

    @Test func aCompleteSnapshotStillStampsInMemoryFreshness() async throws {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"complete": true, "sessions": [{"id": "a", "state": "running"}]}"#)
        ])
        let m = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        #expect(await m.providerStatuses().first?.lastSuccessfulSnapshotAt != nil)
    }

    /// A provider that only ever answers incompletely must still recover from
    /// a transport failure — "the provider answered" is what clears degraded
    /// health, and conflating it with freshness would wedge Send forever.
    @Test func anIncompleteSnapshotClearsDegradedHealth() async throws {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "offline"),
            providerOK(#"{"complete": false, "sessions": []}"#),
        ])
        let m = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")

        await m.pollOnce(provider: provider)
        #expect(await m.providerStatuses().first?.health == .stale)

        await m.pollOnce(provider: provider)
        #expect(await m.providerStatuses().first?.health == .ok)
    }

    /// A recovered-from-disk stamp is knowledge the manager legitimately has;
    /// an incomplete snapshot must not overwrite it with `now`.
    @Test func anIncompleteSnapshotLeavesARecoveredStampAlone() async throws {
        let db = try TBDDatabase(inMemory: true)
        let good = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake", sessions: [RemoteSessionPayload(id: "a", state: .running)],
            complete: true, now: good)
        let subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let m = RemoteProviderManager(
            db: db, subscriptions: subs,
            runner: FakeProviderInvoker(script: [providerOK(#"{"complete": false, "sessions": []}"#)]),
            registryURL: registryURL)

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        #expect(await m.providerStatuses().first?.lastSuccessfulSnapshotAt == good)
    }

    /// The other half of the same `if complete` gate: an incomplete snapshot
    /// must not clear `snapshotFreshnessUnreadable` either, or a partial view
    /// would silently launder a prior "freshness could not be read" state
    /// into a clean one. Reuses the `DROP TABLE tbd_meta` technique from
    /// `unreadableFreshnessStateGatesMutationsInsteadOfFailingOpen` in
    /// RemoteProviderManagerTests to induce the flag.
    ///
    /// This reads the flag through `freshnessUnreadableForTests` rather than
    /// `providerStatuses()`/`hasStaleSnapshot()`. Both of those call
    /// `recoverLastSuccessfulSnapshotAtIfNeeded` first, which — while
    /// `lastSuccessfulSnapshotAt["fake"]` stays nil, which it does throughout
    /// this test — unconditionally re-derives the flag from a fresh
    /// `tbd_meta` read on every single call. Checked empirically: a version
    /// of this test built on `providerStatuses()` alone read `true` after the
    /// incomplete apply *regardless* of whether `apply`'s own gate was
    /// correct, because that trailing status read re-threw against the still
    /// dropped table and stamped the flag back to `true` on its own. Going
    /// through the plain accessor observes `apply`'s effect before any
    /// recovery call gets a chance to launder it.
    @Test func anIncompleteSnapshotLeavesFreshnessUnreadableSet() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running)],
            now: Date(timeIntervalSince1970: 1_700_000_000))
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE tbd_meta")
        }
        let subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let m = RemoteProviderManager(
            db: db, subscriptions: subs,
            runner: FakeProviderInvoker(script: [
                ProviderResult(exitCode: 3, stdout: Data(), stderr: "offline")
            ]),
            registryURL: registryURL)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")

        // Establish the unreadable state: the read that recovers
        // `lastSuccessfulSnapshotAt` from the (now-dropped) `tbd_meta` table
        // fails, so `hasStaleSnapshot` sets `snapshotFreshnessUnreadable`.
        await m.pollOnce(provider: provider)
        #expect(await m.freshnessUnreadableForTests(provider: "fake") == true)

        // An incomplete apply must not touch the flag one way or the other,
        // so the table's readability is irrelevant to this call — leave it
        // dropped.
        try await m.apply(
            snapshot: [], provider: "fake", complete: false,
            now: Date(timeIntervalSince1970: 1_700_000_500))

        #expect(await m.freshnessUnreadableForTests(provider: "fake") == true)
    }
}
