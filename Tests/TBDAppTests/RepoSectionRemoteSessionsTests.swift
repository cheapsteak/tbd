import Testing
import Foundation
@testable import TBDApp
import TBDShared

/// Task 9d (remote worktrees inside repo sections). Covers
/// `RepoSectionView.matchedRemoteSessions(_:repoID:)` — the filter that
/// picks a repo's resolved remote sessions out of the full mirror, and its
/// creation-time ordering.
@Suite("RepoSectionView — matched remote sessions")
struct RepoSectionRemoteSessionsTests {

    private func session(
        id: String, resolvedRepoID: UUID?, createdAt: String? = nil, dismissed: Bool = false
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: "acme",
            payload: RemoteSessionPayload(id: id, createdAt: createdAt, state: .running),
            gone: false, dismissed: dismissed, lastSeen: Date(),
            resolvedRepoID: resolvedRepoID)
    }

    // MARK: - matchedRemoteSessions(_:repoID:) — filtering

    @Test func includesOnlySessionsResolvedToTheGivenRepo() {
        let repoA = UUID()
        let repoB = UUID()
        let sessions = [
            session(id: "s1", resolvedRepoID: repoA),
            session(id: "s2", resolvedRepoID: repoB),
            session(id: "s3", resolvedRepoID: nil),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoA)
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func excludesDismissedSessions() {
        let repoID = UUID()
        let sessions = [
            session(id: "s1", resolvedRepoID: repoID, dismissed: true),
            session(id: "s2", resolvedRepoID: repoID, dismissed: false),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID)
        #expect(result.map(\.payload.id) == ["s2"])
    }

    @Test func emptyWhenNoSessionResolvesToTheRepo() {
        let sessions = [session(id: "s1", resolvedRepoID: UUID())]
        #expect(RepoSectionView.matchedRemoteSessions(sessions, repoID: UUID()).isEmpty)
    }

    // MARK: - ordering — ascending creation time

    @Test func ordersOldestFirst() {
        let repoID = UUID()
        let sessions = [
            session(id: "newer", resolvedRepoID: repoID, createdAt: "2026-07-24T18:10:00Z"),
            session(id: "older", resolvedRepoID: repoID, createdAt: "2026-07-24T18:00:00Z"),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID)
        #expect(result.map(\.payload.id) == ["older", "newer"])
    }

    @Test func undatedSessionsSortAfterDatedOnes() {
        let repoID = UUID()
        let sessions = [
            session(id: "undated", resolvedRepoID: repoID, createdAt: nil),
            session(id: "dated", resolvedRepoID: repoID, createdAt: "2026-07-24T18:00:00Z"),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID)
        #expect(result.map(\.payload.id) == ["dated", "undated"])
    }

    @Test func unparseableCreatedAtIsTreatedAsUndated() {
        let repoID = UUID()
        let sessions = [
            session(id: "garbage", resolvedRepoID: repoID, createdAt: "not-a-date"),
            session(id: "dated", resolvedRepoID: repoID, createdAt: "2026-07-24T18:00:00Z"),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID)
        #expect(result.map(\.payload.id) == ["dated", "garbage"])
    }

    /// Two undated sessions must still sort deterministically (by their own
    /// stable `id`), regardless of input array order — not left in
    /// whatever order they happened to arrive in.
    @Test func tiesAmongUndatedSessionsAreDeterministic() {
        let repoID = UUID()
        let a = session(id: "s1", resolvedRepoID: repoID, createdAt: nil)
        let b = session(id: "s2", resolvedRepoID: repoID, createdAt: nil)
        let forward = RepoSectionView.matchedRemoteSessions([a, b], repoID: repoID)
        let backward = RepoSectionView.matchedRemoteSessions([b, a], repoID: repoID)
        #expect(forward.map(\.id) == backward.map(\.id))
    }

    // MARK: - parsedCreatedAt

    @Test func parsedCreatedAt_nilIsNil() {
        #expect(RepoSectionView.parsedCreatedAt(nil) == nil)
    }

    @Test func parsedCreatedAt_unparseableIsNil() {
        #expect(RepoSectionView.parsedCreatedAt("not-a-date") == nil)
    }

    @Test func parsedCreatedAt_validISO8601Parses() {
        #expect(RepoSectionView.parsedCreatedAt("2026-07-24T18:00:00Z") != nil)
    }
}
