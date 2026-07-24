import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 2: in-memory GRDB only.
@Suite("RemoteSessionStore")
struct RemoteSessionStoreTests {
    let db: TBDDatabase
    init() throws { db = try TBDDatabase(inMemory: true) }

    private func payload(_ id: String, state: RemoteProcessState = .running,
                         agent: RemoteAgentState = .working) -> RemoteSessionPayload {
        RemoteSessionPayload(id: id, state: state, agentState: agent)
    }

    @Test func firstSnapshotInsertsWithoutAttention() async throws {
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput)], now: Date())
        #expect(outcome.changed)
        // First sighting never notifies — only observed transitions do.
        #expect(outcome.attention.isEmpty)
        let rows = try await db.remoteSessions.list()
        #expect(rows.count == 1)
        #expect(rows[0].agentState == "waiting_input")
    }

    @Test func agentStateEdgeIntoWaitingInputIsAttention() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput)], now: Date())
        #expect(outcome.attention.map(\.id) == ["a"])
        // Same state again → no re-notification.
        let again = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput)], now: Date())
        #expect(again.attention.isEmpty)
    }

    @Test func edgeIntoExitedIsAttention_workingIsNot() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a", agent: .waitingInput)], now: Date())
        let toWorking = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        #expect(toWorking.attention.isEmpty)
        let toExited = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", state: .exited, agent: .exited)], now: Date())
        #expect(toExited.attention.map(\.id) == ["a"])
    }

    @Test func twoConsecutiveAbsencesMarkGone() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [], now: Date())
        var rows = try await db.remoteSessions.list()
        #expect(rows[0].gone == false)   // one absence is not enough
        #expect(rows[0].missingCount == 1)
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [], now: Date())
        rows = try await db.remoteSessions.list()
        #expect(rows[0].gone == true)
        // Reappearing clears gone + missingCount.
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        rows = try await db.remoteSessions.list()
        #expect(rows[0].gone == false)
        #expect(rows[0].missingCount == 0)
    }

    @Test func snapshotsAreProviderScoped() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p1", sessions: [payload("a")], now: Date())
        // p2's empty snapshot must not touch p1's rows.
        _ = try await db.remoteSessions.applySnapshot(provider: "p2", sessions: [], now: Date())
        let rows = try await db.remoteSessions.list()
        #expect(rows.count == 1)
        #expect(rows[0].missingCount == 0)
    }

    @Test func dismissHidesRow() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        try await db.remoteSessions.dismiss(provider: "p", sessionID: "a")
        let rows = try await db.remoteSessions.list()
        #expect(rows[0].dismissed == true)
    }

    @Test func configFlagDefaultsOffAndPersists() async throws {
        let config = try await db.config.get()
        #expect(config.remoteBackendsEnabled == false)
        try await db.config.setRemoteBackendsEnabled(true)
        let updated = try await db.config.get()
        #expect(updated.remoteBackendsEnabled == true)
    }
}
