import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// `SidebarSessionPlacement`'s sessions under a provider:
/// - `sessions(in:forProvider:knownRepoIDs:)` — per-provider filtering, with
///   dismissed tombstones and archived sessions excluded, and a session
///   resolved to a known repo left to that repo's section.
/// - `knownRepoIDs(repos:repoFilter:)` — which repos count as known under a
///   repo filter, and for a hidden repo.
@Suite("SidebarSessionPlacement — sessions under a provider")
struct SidebarSessionPlacementProviderTests {

    private func session(
        provider: String,
        id: String,
        state: RemoteProcessState = .running,
        gone: Bool = false,
        dismissed: Bool = false
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: state),
            gone: gone, dismissed: dismissed, lastSeen: Date()
        )
    }

    // MARK: - sessions(in:forProvider:)

    @Test func filtersToOnlyTheRequestedProvider() {
        let sessions = [
            session(provider: "acme", id: "s1"),
            session(provider: "other", id: "s2"),
        ]
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func excludesDismissedSessions() {
        let sessions = [
            session(provider: "acme", id: "s1", dismissed: true),
            session(provider: "acme", id: "s2", dismissed: false),
        ]
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s2"])
    }

    @Test func includesGoneButNotDismissedSessions() {
        // `gone` sessions still render (dimmed, with a Dismiss action) —
        // only `dismissed` (the user's tombstone action) removes a row.
        let sessions = [session(provider: "acme", id: "s1", gone: true, dismissed: false)]
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func emptyWhenNoSessionsMatchProvider() {
        let sessions = [session(provider: "other", id: "s1")]
        #expect(SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: []).isEmpty)
    }

    /// A session resolved to a local repo renders inside that repo's section
    /// instead (`SidebarSessionPlacement.matchedRemoteSessionIndices`) — it must
    /// NOT also appear under its provider.
    @Test func excludesSessionsResolvedToARepo() {
        let repoID = UUID()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repoID),
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s2", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: nil),
        ]
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [repoID])
        #expect(result.map(\.payload.id) == ["s2"])
    }

    /// Fix pass 1, item 1: a row pinned to a repo that has since been
    /// removed from TBD must fall back into the provider section instead of
    /// rendering nowhere — `resolvedRepoID` is a plain, un-cascaded value
    /// the daemon never clears, so the app must independently notice the id
    /// no longer names a repo it knows about.
    @Test func aSessionResolvedToARepoThatNoLongerExistsFallsBackToTheProviderSection() {
        let removedRepoID = UUID()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: removedRepoID),
        ]
        // knownRepoIDs deliberately does NOT contain removedRepoID — the
        // repo was removed after the row was pinned.
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    // MARK: - archived sessions are display policy, applied here

    /// Built through the PRODUCTION decode path — the payload is decoded from
    /// provider-shaped JSON, so the absent-reads-as-false semantics of
    /// `archived` are the real ones and not a hand-assembled stand-in.
    private func decodedSession(
        provider: String = "acme", id: String, archivedJSON: String? = nil
    ) throws -> RemoteSessionInfo {
        var fields = ["\"id\": \"\(id)\"", "\"state\": \"running\""]
        if let archivedJSON { fields.append("\"archived\": \(archivedJSON)") }
        let json = "{ \(fields.joined(separator: ", ")) }"
        let payload = try JSONDecoder().decode(RemoteSessionPayload.self, from: Data(json.utf8))
        return RemoteSessionInfo(
            provider: provider, payload: payload,
            gone: false, dismissed: false, lastSeen: Date())
    }

    /// Same display policy as `SidebarSessionPlacement.matchedRemoteSessionIndices`: the
    /// provider keeps archived sessions in `list`, and the caller decides
    /// which of them a human sees.
    @Test func providerSectionExcludesArchivedSessions() throws {
        let sessions = [
            try decodedSession(id: "archived", archivedJSON: "true"),
            try decodedSession(id: "active"),
        ]
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["active"])
    }

    /// The other arm — an explicit `false` and an omitted key both stay.
    @Test func providerSectionIncludesUnarchivedSessions() throws {
        let sessions = [
            try decodedSession(id: "explicit-false", archivedJSON: "false"),
            try decodedSession(id: "absent"),
        ]
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(Set(result.map(\.payload.id)) == ["explicit-false", "absent"])
    }

    // MARK: - knownRepoIDs(repos:repoFilter:) — final review item 3

    private func repo(id: UUID = UUID(), hidden: Bool = false) -> Repo {
        Repo(id: id, path: "/tmp/\(id)", displayName: "repo", defaultBranch: "main", hidden: hidden)
    }

    /// No filter, no hidden repos: every repo is "known" — the pre-existing
    /// behavior for the common case.
    @Test func knownRepoIDs_noFilterIncludesAllRepos() {
        let visible = repo()
        let known = SidebarSessionPlacement.knownRepoIDs(repos: [visible], repoFilter: nil)
        #expect(known == [visible.id])
    }

    /// The hidden-repo half of the decision: a hidden repo's id counts as
    /// "known" even though `AppState.sidebarShownRepos` doesn't render a
    /// section for it (when no filter chooses it and Show Hidden Repos is
    /// off) — so a session
    /// matched to it is excluded from THIS section too, by analogy with a
    /// hidden repo's local worktrees vanishing from the sidebar entirely.
    /// This function deliberately never consults the hidden flag: hiding a
    /// repo hides its remote sessions along with it.
    @Test func knownRepoIDs_hiddenRepoStillCountsAsKnown() {
        let hiddenRepo = repo(hidden: true)
        let known = SidebarSessionPlacement.knownRepoIDs(repos: [hiddenRepo], repoFilter: nil)
        #expect(known == [hiddenRepo.id], "a hidden repo must still count as known, not fall through to Remote")
    }

    /// The repo-filter half of the decision: with a filter active, only the
    /// filtered repo counts as known — every OTHER repo (even though it's
    /// still a normal, non-hidden repo in `appState.repos`) must NOT count
    /// as known, so its matched sessions fall through to this section
    /// instead of rendering nowhere while the filter narrows the sidebar to
    /// one repo section.
    @Test func knownRepoIDs_activeFilterExcludesEveryOtherRepo() {
        let filtered = repo()
        let other = repo()
        let known = SidebarSessionPlacement.knownRepoIDs(repos: [filtered, other], repoFilter: filtered.id)
        #expect(known == [filtered.id])
        #expect(!known.contains(other.id), "an unfiltered-out repo must not count as known while a filter is active")
    }

    /// End-to-end (via `sessions(in:forProvider:knownRepoIDs:)`): a session
    /// matched to a repo excluded only by an active filter renders in the
    /// Remote section rather than nowhere.
    @Test func filteredOutRepoSessionFallsBackToRemoteSection() {
        let filtered = repo()
        let other = repo()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: other.id),
        ]
        let known = SidebarSessionPlacement.knownRepoIDs(repos: [filtered, other], repoFilter: filtered.id)
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: known)
        #expect(result.map(\.payload.id) == ["s1"])
    }

    /// End-to-end: a session matched to a HIDDEN repo does not fall back to
    /// the Remote section — the deliberate "hide sessions along with the
    /// repo" choice, not a regression of the filtered-repo fix above.
    @Test func hiddenRepoSessionDoesNotFallBackToRemoteSection() {
        let hiddenRepo = repo(hidden: true)
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: hiddenRepo.id),
        ]
        let known = SidebarSessionPlacement.knownRepoIDs(repos: [hiddenRepo], repoFilter: nil)
        let result = SidebarSessionPlacement.sessions(in: sessions, forProvider: "acme", knownRepoIDs: known)
        #expect(result.isEmpty)
    }
}
