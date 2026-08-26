import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2: in-memory GRDB only.
///
/// The failure this pins, observed on a live fleet: a provider reported
/// thirteen sessions working and one still waiting for input, and TBD's
/// sidebar kept attention hands on all fourteen. Two independent defects
/// produced that; this suite covers the mirror half — an out-of-order
/// sighting reinstating an agent state the provider had already moved on
/// from. The render half is `RemoteSessionRowAttentionStalenessTests` in
/// `TBDAppTests`.
@Suite("Remote session ordering")
struct RemoteSessionOrderingTests {
    let db: TBDDatabase
    init() throws { db = try TBDDatabase(inMemory: true) }

    private let earlier = "2026-08-26T07:10:00Z"
    private let later = "2026-08-26T07:14:00Z"
    /// Well after both stamps, so neither is future-dated relative to "now"
    /// and the ordering check is armed.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func payload(
        _ id: String,
        state: RemoteProcessState = .running,
        agent: RemoteAgentState,
        at stamp: String?,
        reason: String? = nil,
        title: String? = nil
    ) -> RemoteSessionPayload {
        RemoteSessionPayload(
            id: id, title: title, state: state, agentState: agent,
            agentStateReason: reason, agentStateAt: stamp)
    }

    private func row(_ id: String) async throws -> RemoteSessionRow? {
        try await db.remoteSessions.list().first { $0.sessionID == id }
    }

    // MARK: - The reported failure

    @Test("a late-arriving older snapshot cannot reinstate a cleared waiting_input")
    func olderSightingDoesNotReinstateWaiting() async throws {
        // The provider asked for input, then went back to work.
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("fix-flaky-ci", agent: .waitingInput, at: earlier)], now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("fix-flaky-ci", agent: .working, at: later)], now: now)

        // A `list` response that was already in flight lands afterwards,
        // carrying the older observation.
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("fix-flaky-ci", agent: .waitingInput, at: earlier)], now: now)

        let mirrored = try await row("fix-flaky-ci")
        #expect(mirrored?.agentState == "working")
        // And it must not re-notify: an edge TBD never observed going
        // forward is not an edge to raise a banner for.
        #expect(outcome.attention.isEmpty)
        #expect(outcome.changed == false)
    }

    @Test("the genuinely waiting session keeps waiting")
    func genuineWaitingSurvives() async throws {
        // The one hand that was correct on screen: a session actually blocked
        // on a question. Nothing here may clear it.
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("export-report", agent: .working, at: earlier)], now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("export-report", agent: .waitingInput, at: later, reason: "permission_prompt")],
            now: now)
        // A later poll that still reports waiting, with the same stamp.
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("export-report", agent: .waitingInput, at: later, reason: "permission_prompt")],
            now: now)

        let mirrored = try await row("export-report")
        #expect(mirrored?.agentState == "waiting_input")
    }

    @Test("quota wait, then credential rotation, then resumed working")
    func quotaWaitThenRotationThenWorking() async throws {
        let stamps = [
            "2026-08-26T07:00:00Z",   // blocked on quota
            "2026-08-26T07:05:00Z",   // still blocked, credential being rotated
            "2026-08-26T07:12:00Z",   // resumed
        ]
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("build-indexer", agent: .working, at: "2026-08-26T06:00:00Z")],
            now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("build-indexer", agent: .waitingInput, at: stamps[0], reason: "quota_exhausted")],
            now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("build-indexer", agent: .waitingInput, at: stamps[1], reason: "credential_rotating")],
            now: now)
        let resumed = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("build-indexer", agent: .working, at: stamps[2])], now: now)

        let mirrored = try await row("build-indexer")
        #expect(mirrored?.agentState == "working")
        #expect(resumed.changed)
        // Every step moved forward, so none of them was withheld — and the
        // reason string from the blocked phase is gone with it.
        let stored = try #require(mirrored?.payload)
        #expect(stored.contains("quota_exhausted") == false)
        #expect(stored.contains("credential_rotating") == false)
    }

    // MARK: - What the rejection must not cost

    @Test("an out-of-order sighting is still evidence the session exists")
    func presenceSurvivesRejection() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput, at: earlier)], now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .working, at: later)], now: now)
        // One absence: the session is now one snapshot from being called gone.
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [], now: now)
        let afterAbsence = try await row("a")
        #expect(afterAbsence?.missingCount == 1)

        // An out-of-order sighting still says the session was there.
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput, at: earlier)], now: now)

        let stored = try #require(await row("a"))
        #expect(stored.missingCount == 0)
        #expect(stored.gone == false)
        #expect(stored.agentState == "working")
        // The row genuinely changed (it was one absence from gone), so the
        // UI is told — the withheld half is the state, never the presence.
        #expect(outcome.changed)
    }

    @Test("an out-of-order response still delivers the fields it is authoritative about")
    func nonAgentFieldsStillApply() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput, at: earlier, title: "old")],
            now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .working, at: later, title: "old")], now: now)

        // A `rename` response echoes the session with the new title and the
        // agent stamp it happened to hold. `agent_state_at` timestamps the
        // agent axis and nothing else, so the rename must land.
        _ = try await db.remoteSessions.upsertOne(
            provider: "p",
            session: payload("a", agent: .waitingInput, at: earlier, title: "renamed"), now: now)

        let stored = try #require(await row("a"))
        #expect(stored.agentState == "working")
        #expect(stored.payload.contains("renamed"))
    }

    @Test("a terminal exit reported alongside an older agent stamp still lands")
    func terminalStateStillApplies() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput, at: earlier)], now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .working, at: later)], now: now)

        _ = try await db.remoteSessions.applySnapshot(
            provider: "p",
            sessions: [payload("a", state: .exited, agent: .waitingInput, at: earlier)], now: now)

        let stored = try #require(await row("a"))
        #expect(stored.state == "exited")
        #expect(stored.agentState == "working")
    }

    // MARK: - Providers that send no stamp are untouched

    @Test("without agent_state_at the mirror behaves exactly as before")
    func noStampMeansLastWriterWins() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .working, at: nil)], now: now)
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput, at: nil)], now: now)

        let mirrored = try await row("a")
        #expect(mirrored?.agentState == "waiting_input")
        #expect(outcome.attention.map(\.id) == ["a"])
    }

    @Test("a stamp appearing for the first time is not treated as out of order")
    func firstStampApplies() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput, at: nil)], now: now)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .working, at: earlier)], now: now)

        let mirrored = try await row("a")
        #expect(mirrored?.agentState == "working")
    }

    @Test("the merge helper leaves the agent state and its stamp consistent")
    func mergedPayloadKeepsTheAxisTogether() throws {
        let storedPayload = String(
            data: try JSONEncoder().encode(
                payload("a", agent: .working, at: later, reason: nil)),
            encoding: .utf8) ?? "{}"

        let merged = RemoteSessionStore.withFreshestAgentAxis(
            incoming: payload("a", agent: .waitingInput, at: earlier, reason: "permission_prompt"),
            storedPayload: storedPayload, provider: "p", now: now)

        // Both halves of the axis move together or neither does — a payload
        // whose `agent_state` and `agent_state_at` disagree would make the
        // next ordering decision meaningless.
        #expect(merged.agentState == .working)
        #expect(merged.agentStateAt == later)
        #expect(merged.agentStateReason == nil)
    }
}
