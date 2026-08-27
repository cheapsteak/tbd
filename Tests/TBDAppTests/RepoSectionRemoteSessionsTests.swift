import Testing
import Foundation
@testable import TBDApp
import TBDShared

/// Task 9d (remote worktrees inside repo sections). Covers
/// `RepoSectionView.matchedRemoteSessions(_:repoID:worktrees:)` — the filter
/// that picks a repo's resolved remote sessions out of the full mirror, drops
/// the ones a worktree row already stands for, and orders the rest by
/// creation time.
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

    /// A worktree row bound to one provider session, as the adoption path
    /// mints it: `location` carries the `(provider, sessionID)` pair and
    /// `path` is the synthetic `remote://` URI, never a filesystem path.
    private func remoteWorktree(
        provider: String = "acme", sessionID: String, displayName: String = "adopted lane"
    ) -> Worktree {
        let location = WorktreeLocation.remote(provider: provider, sessionID: sessionID)
        return Worktree(
            repoID: UUID(), name: "remote-\(sessionID)", displayName: displayName,
            branch: "feature", path: location.storagePath ?? "", tmuxServer: "",
            location: location)
    }

    private func localWorktree(displayName: String = "local lane") -> Worktree {
        Worktree(
            repoID: UUID(), name: "local", displayName: displayName,
            branch: "feature", path: "/tmp/x", tmuxServer: "tbd-x")
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
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoA, worktrees: [])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func excludesDismissedSessions() {
        let repoID = UUID()
        let sessions = [
            session(id: "s1", resolvedRepoID: repoID, dismissed: true),
            session(id: "s2", resolvedRepoID: repoID, dismissed: false),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID, worktrees: [])
        #expect(result.map(\.payload.id) == ["s2"])
    }

    @Test func emptyWhenNoSessionResolvesToTheRepo() {
        let sessions = [session(id: "s1", resolvedRepoID: UUID())]
        #expect(RepoSectionView.matchedRemoteSessions(sessions, repoID: UUID(), worktrees: []).isEmpty)
    }

    // MARK: - dedup against adopted worktree rows

    /// The defect this filter closes: a session adopted into a worktree row
    /// renders as that row, so it must NOT also render as a session row —
    /// otherwise every adopted lane appears twice under its repo.
    @Test func excludesSessionsThatAlreadyOwnAWorktreeRow() {
        let repoID = UUID()
        let sessions = [
            session(id: "adopted", resolvedRepoID: repoID),
            session(id: "unadopted", resolvedRepoID: repoID),
        ]
        let result = RepoSectionView.matchedRemoteSessions(
            sessions, repoID: repoID, worktrees: [remoteWorktree(sessionID: "adopted")])
        #expect(result.map(\.payload.id) == ["unadopted"])
    }

    /// The regression guard for the dedup above: a repo with adopted lanes
    /// must still render the sessions that have no worktree row. Deleting the
    /// feature outright would pass the exclusion test and fail this one.
    @Test func keepsSessionsWithNoWorktreeRowEvenWhenOtherLanesAreAdopted() {
        let repoID = UUID()
        let sessions = [session(id: "unadopted", resolvedRepoID: repoID)]
        let result = RepoSectionView.matchedRemoteSessions(
            sessions,
            repoID: repoID,
            worktrees: [remoteWorktree(sessionID: "other"), localWorktree()])
        #expect(result.map(\.payload.id) == ["unadopted"])
    }

    /// The join is on `(provider, sessionID)`, not on session ID alone: two
    /// providers may legitimately use the same session ID, and only the one
    /// actually bound to a row is the duplicate.
    @Test func excludesOnlyTheMatchingProvidersSession() {
        let repoID = UUID()
        let sessions = [session(id: "s1", resolvedRepoID: repoID)]
        let result = RepoSectionView.matchedRemoteSessions(
            sessions,
            repoID: repoID,
            worktrees: [remoteWorktree(provider: "other-provider", sessionID: "s1")])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    /// Nothing about a LOCAL worktree row can suppress a remote session row —
    /// the exclusion set is built from `location`, never from display name or
    /// branch, which adoption seeds once and the user may then change.
    @Test func localWorktreeRowsNeverExcludeASession() {
        let repoID = UUID()
        let sessions = [session(id: "s1", resolvedRepoID: repoID)]
        let result = RepoSectionView.matchedRemoteSessions(
            sessions, repoID: repoID, worktrees: [localWorktree(displayName: "s1")])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    // MARK: - ordering — ascending creation time

    @Test func ordersOldestFirst() {
        let repoID = UUID()
        let sessions = [
            session(id: "newer", resolvedRepoID: repoID, createdAt: "2026-07-24T18:10:00Z"),
            session(id: "older", resolvedRepoID: repoID, createdAt: "2026-07-24T18:00:00Z"),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID, worktrees: [])
        #expect(result.map(\.payload.id) == ["older", "newer"])
    }

    @Test func undatedSessionsSortAfterDatedOnes() {
        let repoID = UUID()
        let sessions = [
            session(id: "undated", resolvedRepoID: repoID, createdAt: nil),
            session(id: "dated", resolvedRepoID: repoID, createdAt: "2026-07-24T18:00:00Z"),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID, worktrees: [])
        #expect(result.map(\.payload.id) == ["dated", "undated"])
    }

    @Test func unparseableCreatedAtIsTreatedAsUndated() {
        let repoID = UUID()
        let sessions = [
            session(id: "garbage", resolvedRepoID: repoID, createdAt: "not-a-date"),
            session(id: "dated", resolvedRepoID: repoID, createdAt: "2026-07-24T18:00:00Z"),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID, worktrees: [])
        #expect(result.map(\.payload.id) == ["dated", "garbage"])
    }

    /// Two undated sessions must still sort deterministically (by their own
    /// stable `id`), regardless of input array order — not left in
    /// whatever order they happened to arrive in.
    @Test func tiesAmongUndatedSessionsAreDeterministic() {
        let repoID = UUID()
        let a = session(id: "s1", resolvedRepoID: repoID, createdAt: nil)
        let b = session(id: "s2", resolvedRepoID: repoID, createdAt: nil)
        let forward = RepoSectionView.matchedRemoteSessions([a, b], repoID: repoID, worktrees: [])
        let backward = RepoSectionView.matchedRemoteSessions([b, a], repoID: repoID, worktrees: [])
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

    /// The contract's example is whole-second, but doesn't pin a profile — a
    /// conforming provider may emit fractional seconds. A default-options
    /// `ISO8601DateFormatter` rejects this shape outright.
    @Test func parsedCreatedAt_fractionalSecondsParses() {
        #expect(RepoSectionView.parsedCreatedAt("2026-07-24T18:02:11.123Z") != nil)
    }

    /// Both shapes must parse to sensible, comparable dates — a
    /// fractional-second row must not sort as "undated" (last) relative to a
    /// whole-second row from the same moment.
    @Test func parsedCreatedAt_fractionalAndWholeSecondSortCorrectly() {
        let repoID = UUID()
        let sessions = [
            session(id: "fractional", resolvedRepoID: repoID, createdAt: "2026-07-24T18:10:00.500Z"),
            session(id: "whole", resolvedRepoID: repoID, createdAt: "2026-07-24T18:00:00Z"),
        ]
        let result = RepoSectionView.matchedRemoteSessions(sessions, repoID: repoID, worktrees: [])
        #expect(result.map(\.payload.id) == ["whole", "fractional"])
    }
}

/// Covers the two gates behind the repo context menu's create items —
/// `RepoSectionView.remoteSessionMenuProviders(providers:)` for the generic
/// "New Remote Session…" item, and
/// `cloudSessionMenuEntry(providers:claudeCloudEnabled:)` for the compiled
/// provider's "New Cloud Session…" item beside it. Both are pure, view-free
/// forms of what the menu renders, so every branch is decided somewhere a
/// test can reach without an `AppState` or a view hierarchy.
@Suite("RepoSectionView — remote create menu items")
struct RepoSectionRemoteCreateMenuTests {

    private func provider(
        _ name: String, health: ProviderHealth = .ok, freshnessUnreadable: Bool = false
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
            describe: ProviderDescribe(contractVersions: [2], name: name, capabilities: ["send"]),
            health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            freshnessUnreadable: freshnessUnreadable)
    }

    private var both: [RemoteProviderStatus] {
        [provider("acme"), provider(ClaudeCloudProvider.name)]
    }

    private func names(_ providers: [RemoteProviderStatus]) -> [String] {
        RepoSectionView.remoteSessionMenuProviders(providers: providers).map(\.config.name)
    }

    private func cloudName(
        _ providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> String? {
        RepoSectionView.cloudSessionMenuEntry(
            providers: providers, claudeCloudEnabled: claudeCloudEnabled)?.config.name
    }

    // MARK: - the generic item enumerates registry providers only

    /// No provider registered → the item is omitted whole, not shown disabled.
    @Test func noRegisteredProviderLeavesNothingToOffer() {
        #expect(names([]).isEmpty)
    }

    @Test func registryProvidersFillTheItemInOrder() {
        #expect(names([provider("acme"), provider("widgets")]) == ["acme", "widgets"])
    }

    /// The compiled provider has an item of its own, so it is never a member
    /// of this enumeration — which is also what keeps the one-versus-many
    /// count (button versus submenu) a count of registry providers.
    @Test func theCloudProviderIsNeverListedInTheGenericItem() {
        #expect(names(both) == ["acme"])
        #expect(names([provider(ClaudeCloudProvider.name)]).isEmpty)
    }

    /// A stale registry provider keeps its row — the view disables it.
    @Test func aStaleRegistryProviderIsStillListed() {
        let stale = provider("acme", health: .stale, freshnessUnreadable: true)
        #expect(stale.hasStaleSnapshot)
        #expect(names([stale]) == ["acme"])
    }

    // MARK: - the cloud item's own gate

    @Test func theCloudItemIsOmittedWhenTheFlagIsOff() {
        #expect(cloudName(both, claudeCloudEnabled: false) == nil)
    }

    /// The discriminating half: with the flag on the item is offered, so the
    /// gate did not simply delete it.
    @Test func theCloudItemIsOfferedWhenTheFlagIsOn() {
        #expect(cloudName(both, claudeCloudEnabled: true) == ClaudeCloudProvider.name)
    }

    /// The flipped-on-without-restart state: the daemon never registered the
    /// provider, so there is nothing to offer whichever way the flag points.
    @Test func theCloudItemIsOmittedWhenTheProviderWasNeverRegistered() {
        for flag in [true, false] {
            #expect(cloudName([provider("acme")], claudeCloudEnabled: flag) == nil)
        }
    }

    /// Staleness disables rather than withdraws: the item stays so the menu
    /// can name its own reason, exactly as the generic item does for a stale
    /// registry provider.
    @Test func aStaleCloudProviderStillOffersItsItem() {
        let stale = provider(ClaudeCloudProvider.name, health: .stale, freshnessUnreadable: true)
        #expect(stale.hasStaleSnapshot)
        #expect(cloudName([provider("acme"), stale], claudeCloudEnabled: true)
            == ClaudeCloudProvider.name)
    }
}
