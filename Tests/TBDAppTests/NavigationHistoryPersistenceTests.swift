import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Sidebar back/forward history survives an app restart. A second AppState
/// built on the same throwaway UserDefaults suite stands in for a relaunch.
/// See docs/specs/2026-10-14-sidebar-navigation-history-persistence-design.md.
@MainActor
@Suite("Navigation history persistence")
struct NavigationHistoryPersistenceTests {

    private func withSuite(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suiteName = "TBDAppTests.NavHistoryPersist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }

    private func makeWorktree(id: UUID, repoID: UUID) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "test-\(id.uuidString.prefix(8))",
            displayName: "Test \(id.uuidString.prefix(8))",
            branch: "main",
            path: "/tmp/test",
            status: .active,
            tmuxServer: "test-server"
        )
    }

    private func saveSelectionOrder(_ ids: [UUID], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(ids.map(\.uuidString)), forKey: "com.tbd.app.selectionOrder")
    }

    @Test func roundTripKeepsPositionAndForward() async {
        await withSuite { defaults in
            let repoID = UUID(), p = UUID(), q = UUID(), r = UUID()
            let wts = [repoID: [p, q, r].map { makeWorktree(id: $0, repoID: repoID) }]

            let first = AppState(userDefaults: defaults)
            first.worktrees = wts
            first.selectedWorktreeIDs = [p]
            first.selectedWorktreeIDs = [q]
            first.selectedWorktreeIDs = [r]
            first.navigateBack() // now on Q

            let second = AppState(userDefaults: defaults)
            #expect(second.navigationEntries == [.worktrees([p]), .worktrees([q]), .worktrees([r])])
            #expect(second.navigationIndex == 1)

            second.worktrees = wts
            second.updateNavigationFlags()
            #expect(second.canGoBack)
            #expect(second.canGoForward)
            second.navigateBack()
            #expect(second.selectedWorktreeIDs == [p])
        }
    }

    @Test func everyEntryKindRoundTrips() async {
        await withSuite { defaults in
            let a = UUID(), b = UUID(), repo = UUID()
            let remote = RemoteSessionSelection(provider: "acme", sessionID: "s-1")
            let first = AppState(userDefaults: defaults)
            first.recordNavigation(.worktrees([b, a]))
            first.recordNavigation(.repo(repo))
            first.recordNavigation(.remoteSession(remote))

            let second = AppState(userDefaults: defaults)
            #expect(second.navigationEntries == [.worktrees([b, a]), .repo(repo), .remoteSession(remote)])
            #expect(second.navigationIndex == 2)
        }
    }

    @Test func matchingRestoredSelectionKeepsForward() async throws {
        try await withSuite { defaults in
            let repoID = UUID(), p = UUID(), q = UUID(), r = UUID()
            let first = AppState(userDefaults: defaults)
            // Lists first: flags are computed against them, and navigateBack
            // is a no-op while canGoBack is false.
            first.worktrees = [repoID: [p, q, r].map { makeWorktree(id: $0, repoID: repoID) }]
            first.recordNavigation(.worktrees([p]))
            first.recordNavigation(.worktrees([q]))
            first.recordNavigation(.worktrees([r]))
            first.navigateBack() // on Q
            try saveSelectionOrder([q], in: defaults)

            let second = AppState(userDefaults: defaults)
            second.restoreSavedSelection(validWorktreeIDs: [p, q, r])
            #expect(second.selectedWorktreeIDs == [q])
            #expect(second.navigationEntries == [.worktrees([p]), .worktrees([q]), .worktrees([r])])
            #expect(second.navigationIndex == 1)
        }
    }

    @Test func differingRestoredSelectionAppendsAndCutsForward() async throws {
        try await withSuite { defaults in
            let repoID = UUID(), p = UUID(), q = UUID(), r = UUID(), s = UUID()
            let first = AppState(userDefaults: defaults)
            // Lists first: flags are computed against them, and navigateBack
            // is a no-op while canGoBack is false.
            first.worktrees = [repoID: [p, q, r].map { makeWorktree(id: $0, repoID: repoID) }]
            first.recordNavigation(.worktrees([p]))
            first.recordNavigation(.worktrees([q]))
            first.recordNavigation(.worktrees([r]))
            first.navigateBack() // on Q
            try saveSelectionOrder([s], in: defaults)

            let second = AppState(userDefaults: defaults)
            second.restoreSavedSelection(validWorktreeIDs: [p, q, r, s])
            #expect(second.selectedWorktreeIDs == [s])
            #expect(second.navigationEntries == [.worktrees([p]), .worktrees([q]), .worktrees([s])])
            #expect(second.navigationIndex == 2)
        }
    }

    /// Pins the on-disk format: a literal in the synthesized Codable shape
    /// must keep decoding, so renaming an entry case or a field (which
    /// silently empties every saved history) goes red here.
    @Test func savedFormatFixtureDecodes() async {
        await withSuite { defaults in
            let raw = """
            {"entries":[\
            {"worktrees":{"_0":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"]}},\
            {"repo":{"_0":"33333333-3333-3333-3333-333333333333"}},\
            {"remoteSession":{"_0":{"provider":"acme","sessionID":"s-1"}}}\
            ],"index":2}
            """
            defaults.set(Data(raw.utf8), forKey: AppState.navigationHistoryKey)

            let state = AppState(userDefaults: defaults)
            let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let r = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            #expect(state.navigationEntries == [
                .worktrees([a, b]),
                .repo(r),
                .remoteSession(RemoteSessionSelection(provider: "acme", sessionID: "s-1")),
            ])
            #expect(state.navigationIndex == 2)
        }
    }

    @Test(arguments: [
        "not json",
        #"{"entries":[],"index":0}"#,
        #"{"entries":[{"repo":{"_0":"6F9619FF-8B86-D011-B42D-00CF4FC964FF"}}],"index":1}"#,
        #"{"entries":[{"repo":{"_0":"6F9619FF-8B86-D011-B42D-00CF4FC964FF"}}],"index":-1}"#,
        #"{"entries":[{"futureKind":{"_0":"x"}}],"index":0}"#,
    ])
    func damagedDataLoadsEmpty(raw: String) async {
        await withSuite { defaults in
            defaults.set(Data(raw.utf8), forKey: AppState.navigationHistoryKey)
            let state = AppState(userDefaults: defaults)
            #expect(state.navigationEntries.isEmpty)
            #expect(state.navigationIndex == -1)
        }
    }

    @Test func overCapSnapshotLoadsEmpty() async throws {
        try await withSuite { defaults in
            let entries = (0..<101).map { _ in NavigationEntry.repo(UUID()) }
            let data = try JSONEncoder().encode(NavigationHistorySnapshot(entries: entries, index: 100))
            defaults.set(data, forKey: AppState.navigationHistoryKey)
            let state = AppState(userDefaults: defaults)
            #expect(state.navigationEntries.isEmpty)
            #expect(state.navigationIndex == -1)
        }
    }

    @Test func capHoldsAfterReload() async {
        await withSuite { defaults in
            let first = AppState(userDefaults: defaults)
            let ids = (0..<100).map { _ in UUID() }
            for id in ids { first.recordNavigation(.repo(id)) }

            let second = AppState(userDefaults: defaults)
            #expect(second.navigationEntries.count == 100)
            second.recordNavigation(.repo(UUID()))
            #expect(second.navigationEntries.count == 100)
            #expect(second.navigationEntries.first == .repo(ids[1]))
            #expect(second.navigationIndex == 99)
        }
    }

    @Test func staleRestoredEntriesAreSkippedAndKept() async {
        await withSuite { defaults in
            let repoID = UUID(), gone = UUID(), p = UUID(), q = UUID()
            let first = AppState(userDefaults: defaults)
            first.recordNavigation(.worktrees([p]))
            first.recordNavigation(.worktrees([gone]))
            first.recordNavigation(.worktrees([q]))

            let second = AppState(userDefaults: defaults)
            second.worktrees = [repoID: [p, q].map { makeWorktree(id: $0, repoID: repoID) }]
            second.updateNavigationFlags()
            second.navigateBack()
            #expect(second.selectedWorktreeIDs == [p])

            let third = AppState(userDefaults: defaults)
            #expect(third.navigationEntries.contains(.worktrees([gone])))
        }
    }

    @Test func everyMutationSaves() async {
        await withSuite { defaults in
            let repoID = UUID(), a = UUID(), b = UUID(), c = UUID()
            let state = AppState(userDefaults: defaults)
            state.worktrees = [repoID: [a, b, c].map { makeWorktree(id: $0, repoID: repoID) }]

            /// A relaunch must see exactly the live history, entries and index.
            @MainActor func expectSaved(sourceLocation: SourceLocation = #_sourceLocation) {
                let fresh = AppState(userDefaults: defaults)
                #expect(fresh.navigationEntries == state.navigationEntries, sourceLocation: sourceLocation)
                #expect(fresh.navigationIndex == state.navigationIndex, sourceLocation: sourceLocation)
            }

            state.recordNavigation(.worktrees([a]))
            expectSaved()
            state.recordNavigation(.worktrees([b]))
            expectSaved()
            state.recordNavigation(.worktrees([c]))
            expectSaved()
            #expect(state.navigationIndex == 2)

            state.navigateBack()
            expectSaved()
            #expect(state.navigationIndex == 1)

            state.navigateForward()
            expectSaved()
            #expect(state.navigationIndex == 2)

            #expect(state.navigateBackPastArchived(c))
            expectSaved()
            #expect(state.navigationIndex == 1)
            #expect(state.navigationEntries.count == 3)
        }
    }

    @Test func arrowsEnableAfterReposLoad() async {
        await withSuite { defaults in
            let r1 = UUID(), r2 = UUID()
            let first = AppState(userDefaults: defaults)
            first.recordNavigation(.repo(r1))
            first.recordNavigation(.repo(r2))

            let second = AppState(userDefaults: defaults)
            #expect(second.navigationIndex == 1)
            #expect(!second.canGoBack) // lists empty at launch

            let repos = [
                Repo(id: r1, path: "/tmp/r1", displayName: "r1", defaultBranch: "main"),
                Repo(id: r2, path: "/tmp/r2", displayName: "r2", defaultBranch: "main"),
            ]
            second.reposFetcher = { repos }
            await second.refreshRepos()
            #expect(second.canGoBack)
        }
    }

    /// The terminal and note fetches that follow the worktree merge go
    /// through `daemonClient` and fail without a daemon; the arrows are
    /// refreshed before them, so the failure does not affect this check.
    @Test func arrowsEnableAfterWorktreesLoad() async {
        await withSuite { defaults in
            let repoID = UUID(), p = UUID(), q = UUID()
            let first = AppState(userDefaults: defaults)
            first.recordNavigation(.worktrees([p]))
            first.recordNavigation(.worktrees([q]))

            let second = AppState(userDefaults: defaults)
            #expect(second.navigationIndex == 1)
            #expect(!second.canGoBack) // lists empty at launch

            let wts = [p, q].map { makeWorktree(id: $0, repoID: repoID) }
            second.worktreesFetcher = { _ in wts }
            await second.refreshWorktrees()
            #expect(second.canGoBack)
        }
    }

    @Test func arrowsEnableAfterRemoteSessionsLoad() async {
        await withSuite { defaults in
            let a = RemoteSessionSelection(provider: "acme", sessionID: "s-1")
            let b = RemoteSessionSelection(provider: "acme", sessionID: "s-2")
            let first = AppState(userDefaults: defaults)
            first.recordNavigation(.remoteSession(a))
            first.recordNavigation(.remoteSession(b))

            let second = AppState(userDefaults: defaults)
            #expect(second.navigationIndex == 1)
            #expect(!second.canGoBack) // lists empty at launch

            let sessions = [a, b].map {
                RemoteSessionInfo(
                    provider: $0.provider,
                    payload: RemoteSessionPayload(id: $0.sessionID, state: .running),
                    gone: false, dismissed: false, lastSeen: Date())
            }
            second.remoteProvidersFetcher = { RemoteProvidersResult(providers: []) }
            second.remoteSessionsFetcher = { RemoteSessionsResult(sessions: sessions) }
            second.retainedTranscriptsFetcher = { [] }
            await second.refreshRemote()
            #expect(second.canGoBack)
        }
    }
}
