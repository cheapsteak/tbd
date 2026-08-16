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
}
