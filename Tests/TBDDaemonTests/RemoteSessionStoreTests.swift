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
        let first = try await db.remoteSessions.dismiss(provider: "p", sessionID: "a")
        #expect(first == true)
        let rows = try await db.remoteSessions.list()
        #expect(rows[0].dismissed == true)
        // Second dismiss of an already-dismissed session must be a no-op:
        // exercises the `AND dismissed = 0` predicate itself, not just an
        // unknown-id miss (which would return false even without it).
        let second = try await db.remoteSessions.dismiss(provider: "p", sessionID: "a")
        #expect(second == false)
    }

    // MARK: - Sidebar-dock pin

    @Test func setPinnedStampsAndClearsPinnedAt() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        var rows = try await db.remoteSessions.list()
        #expect(rows[0].pinnedAt == nil, "a freshly mirrored session is never pinned")

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let pinned = try await db.remoteSessions.setPinned(provider: "p", sessionID: "a", pinnedAt: stamp)
        #expect(pinned)
        rows = try await db.remoteSessions.list()
        #expect(rows[0].pinnedAt == stamp)

        let unpinned = try await db.remoteSessions.setPinned(provider: "p", sessionID: "a", pinnedAt: nil)
        #expect(unpinned)
        rows = try await db.remoteSessions.list()
        #expect(rows[0].pinnedAt == nil)
    }

    /// Both no-op branches of the `changed` contract: unpinning something
    /// that was never pinned, and pinning a session that isn't mirrored.
    @Test func setPinnedReportsNoChangeWhenThereIsNothingToChange() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        let unpinUnpinned = try await db.remoteSessions.setPinned(
            provider: "p", sessionID: "a", pinnedAt: nil)
        #expect(unpinUnpinned == false)
        let unknown = try await db.remoteSessions.setPinned(
            provider: "p", sessionID: "nope", pinnedAt: Date())
        #expect(unknown == false)
    }

    /// The whole point of storing the pin on the mirror row: a pin has to
    /// outlive ordinary provider churn. A session that goes absent twice
    /// (gone), then comes back, keeps its pin the entire way through.
    @Test func pinSurvivesSnapshotChurnIncludingGoneAndReappearance() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        _ = try await db.remoteSessions.setPinned(provider: "p", sessionID: "a", pinnedAt: Date())

        // Ordinary re-poll with changed agent state.
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a", agent: .waitingInput)], now: Date())
        #expect(try await db.remoteSessions.list()[0].pinnedAt != nil)

        // Two absences → gone. The pin must not be collateral damage.
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [], now: Date())
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [], now: Date())
        var rows = try await db.remoteSessions.list()
        #expect(rows[0].gone)
        #expect(rows[0].pinnedAt != nil)

        // Reappears → still pinned, still in the dock.
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        rows = try await db.remoteSessions.list()
        #expect(rows[0].gone == false)
        #expect(rows[0].pinnedAt != nil)
    }

    @Test func pinSurvivesAnEventDrivenUpsertOne() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        _ = try await db.remoteSessions.setPinned(provider: "p", sessionID: "a", pinnedAt: Date())
        _ = try await db.remoteSessions.upsertOne(
            provider: "p", session: payload("a", agent: .waitingInput), now: Date())
        #expect(try await db.remoteSessions.list()[0].pinnedAt != nil)
    }

    /// Dismiss means "get rid of it", so it drops the pin in the same
    /// statement — a dismissed row must not keep an invisible pin that would
    /// resurrect it in the dock.
    @Test func dismissClearsThePin() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        _ = try await db.remoteSessions.setPinned(provider: "p", sessionID: "a", pinnedAt: Date())
        #expect(try await db.remoteSessions.dismiss(provider: "p", sessionID: "a"))
        let rows = try await db.remoteSessions.list()
        #expect(rows[0].dismissed)
        #expect(rows[0].pinnedAt == nil)
    }

    @Test func pinsAreScopedToOneProviderSessionPair() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a"), payload("b")], now: Date())
        _ = try await db.remoteSessions.applySnapshot(provider: "q", sessions: [payload("a")], now: Date())
        _ = try await db.remoteSessions.setPinned(provider: "p", sessionID: "a", pinnedAt: Date())
        let rows = try await db.remoteSessions.list()
        #expect(rows.first { $0.provider == "p" && $0.sessionID == "a" }?.pinnedAt != nil)
        #expect(rows.first { $0.provider == "p" && $0.sessionID == "b" }?.pinnedAt == nil)
        #expect(rows.first { $0.provider == "q" && $0.sessionID == "a" }?.pinnedAt == nil)
    }

    @Test func upsertOneAppliesEdgeDetectionWithoutTouchingOtherRows() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [payload("a"), payload("b")], now: Date())
        // Absent from this single-session upsert; a snapshot would have
        // bumped its missingCount, but upsertOne must leave it alone.
        let outcome = try await db.remoteSessions.upsertOne(
            provider: "p", session: payload("a", agent: .waitingInput), now: Date())
        #expect(outcome.changed)
        #expect(outcome.attention.map(\.id) == ["a"])
        let rows = try await db.remoteSessions.list()
        #expect(rows.first(where: { $0.sessionID == "b" })?.missingCount == 0)
        #expect(rows.first(where: { $0.sessionID == "b" })?.gone == false)
        // Same state again → no re-notification, matching applySnapshot.
        let again = try await db.remoteSessions.upsertOne(
            provider: "p", session: payload("a", agent: .waitingInput), now: Date())
        #expect(again.attention.isEmpty)
    }

    @Test func markGoneSetsGoneImmediatelySkippingTwoAbsenceRule() async throws {
        _ = try await db.remoteSessions.applySnapshot(provider: "p", sessions: [payload("a")], now: Date())
        var rows = try await db.remoteSessions.list()
        #expect(rows[0].gone == false)
        // A single explicit removal is enough — unlike a single snapshot
        // absence, which only bumps missingCount to 1.
        let changed = try await db.remoteSessions.markGone(provider: "p", sessionID: "a")
        #expect(changed, "marking a live row gone must report a change so the UI broadcast fires")
        rows = try await db.remoteSessions.list()
        #expect(rows[0].gone == true)
        // Nothing left to change: re-removing, or removing a session that was
        // never mirrored, must report false so callers skip the broadcast.
        let again = try await db.remoteSessions.markGone(provider: "p", sessionID: "a")
        #expect(again == false)
        let unknown = try await db.remoteSessions.markGone(provider: "p", sessionID: "nope")
        #expect(unknown == false)
    }

    @Test func configFlagDefaultsOffAndPersists() async throws {
        let config = try await db.config.get()
        #expect(config.remoteBackendsEnabled == false)
        try await db.config.setRemoteBackendsEnabled(true)
        let updated = try await db.config.get()
        #expect(updated.remoteBackendsEnabled == true)
    }

    // MARK: - resolvedRepoID: matching, pinning, late resolution

    private func metaPayload(_ id: String, repo: String?,
                             state: RemoteProcessState = .running) -> RemoteSessionPayload {
        RemoteSessionPayload(id: id, state: state, meta: repo.map { ["repo": $0] })
    }

    @Test func firstSightingResolvesAgainstAnAlreadyRegisteredRepo() async throws {
        let repo = try await db.repos.create(path: "/tmp/api", displayName: "api",
                                             defaultBranch: "main", remoteURL: "https://github.com/acme/api")
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/api")], now: Date())
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == repo.id)
    }

    @Test func noMetaRepoLeavesResolvedRepoIDNil() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: nil)], now: Date())
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == nil)
    }

    @Test func noMatchingLocalRepoLeavesResolvedRepoIDNil() async throws {
        _ = try await db.repos.create(path: "/tmp/other", displayName: "other",
                                      defaultBranch: "main", remoteURL: "https://github.com/acme/other")
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/api")], now: Date())
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == nil)
    }

    /// Pinning: once resolved, a later poll reporting a DIFFERENT
    /// `meta["repo"]` must not move the row to a different repo.
    @Test func resolvedRepoIDIsPinnedAndSurvivesAChangedMetaRepo() async throws {
        let first = try await db.repos.create(path: "/tmp/api", displayName: "api",
                                              defaultBranch: "main", remoteURL: "https://github.com/acme/api")
        _ = try await db.repos.create(path: "/tmp/other", displayName: "other",
                                      defaultBranch: "main", remoteURL: "https://github.com/acme/other")
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/api")], now: Date())
        var rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == first.id)

        // Provider now reports a different repo for the same session id.
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/other")], now: Date())
        rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == first.id,
                "an already-pinned row must never migrate to a different repo")
    }

    /// Late resolution: a session first seen before its repo was registered
    /// in TBD resolves on a LATER poll, once the repo shows up — because the
    /// stored value stays null until resolution succeeds.
    @Test func lateResolutionSucceedsOnceTheRepoIsRegistered() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/api")], now: Date())
        var rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == nil)

        let repo = try await db.repos.create(path: "/tmp/api", displayName: "api",
                                             defaultBranch: "main", remoteURL: "https://github.com/acme/api")
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/api")], now: Date())
        rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == repo.id)
    }

    /// Resolving on a later poll (not just first sighting) must report
    /// `changed == true` so the daemon broadcasts and the sidebar re-renders
    /// the row into its new repo section.
    @Test func lateResolutionReportsChangedForBroadcast() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/api")], now: Date())
        _ = try await db.repos.create(path: "/tmp/api", displayName: "api",
                                      defaultBranch: "main", remoteURL: "https://github.com/acme/api")
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: "p", sessions: [metaPayload("a", repo: "acme/api")], now: Date())
        #expect(outcome.changed, "late resolution must report a change so the UI broadcast fires")
    }

    @Test func upsertOneAlsoResolvesAndPinsRepo() async throws {
        let repo = try await db.repos.create(path: "/tmp/api", displayName: "api",
                                             defaultBranch: "main", remoteURL: "https://github.com/acme/api")
        _ = try await db.remoteSessions.upsertOne(
            provider: "p", session: metaPayload("a", repo: "acme/api"), now: Date())
        let rows = try await db.remoteSessions.list()
        #expect(rows.first?.resolvedRepoIDUUID == repo.id)
    }
}
