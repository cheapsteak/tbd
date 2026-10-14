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

    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "TBDAppTests.NavHistoryPersist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
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

    @Test func roundTripKeepsPositionAndForward() {
        withSuite { defaults in
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

    @Test func everyEntryKindRoundTrips() {
        withSuite { defaults in
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

    @Test func matchingRestoredSelectionKeepsForward() throws {
        try withSuite { defaults in
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
            #expect(second.navigationEntries == [.worktrees([p]), .worktrees([q]), .worktrees([r])])
            #expect(second.navigationIndex == 1)
        }
    }

    @Test func differingRestoredSelectionAppendsAndCutsForward() throws {
        try withSuite { defaults in
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
            #expect(second.navigationEntries == [.worktrees([p]), .worktrees([q]), .worktrees([s])])
            #expect(second.navigationIndex == 2)
        }
    }

    @Test(arguments: [
        "not json",
        #"{"entries":[],"index":0}"#,
        #"{"entries":[{"repo":{"_0":"6F9619FF-8B86-D011-B42D-00CF4FC964FF"}}],"index":1}"#,
        #"{"entries":[{"repo":{"_0":"6F9619FF-8B86-D011-B42D-00CF4FC964FF"}}],"index":-1}"#,
        #"{"entries":[{"futureKind":{"_0":"x"}}],"index":0}"#,
    ])
    func damagedDataLoadsEmpty(raw: String) {
        withSuite { defaults in
            defaults.set(Data(raw.utf8), forKey: AppState.navigationHistoryKey)
            let state = AppState(userDefaults: defaults)
            #expect(state.navigationEntries.isEmpty)
            #expect(state.navigationIndex == -1)
        }
    }

    @Test func overCapSnapshotLoadsEmpty() throws {
        try withSuite { defaults in
            let entries = (0..<101).map { _ in NavigationEntry.repo(UUID()) }
            let data = try JSONEncoder().encode(NavigationHistorySnapshot(entries: entries, index: 100))
            defaults.set(data, forKey: AppState.navigationHistoryKey)
            let state = AppState(userDefaults: defaults)
            #expect(state.navigationEntries.isEmpty)
            #expect(state.navigationIndex == -1)
        }
    }

    @Test func capHoldsAfterReload() {
        withSuite { defaults in
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

    @Test func staleRestoredEntriesAreSkippedAndKept() {
        withSuite { defaults in
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

    @Test func everyMutationSaves() {
        withSuite { defaults in
            let repoID = UUID(), a = UUID(), b = UUID(), c = UUID()
            let state = AppState(userDefaults: defaults)
            state.worktrees = [repoID: [a, b, c].map { makeWorktree(id: $0, repoID: repoID) }]

            func reloaded() -> (entries: [NavigationEntry], index: Int) {
                let fresh = AppState(userDefaults: defaults)
                return (fresh.navigationEntries, fresh.navigationIndex)
            }

            state.recordNavigation(.worktrees([a]))
            state.recordNavigation(.worktrees([b]))
            state.recordNavigation(.worktrees([c]))
            #expect(reloaded().index == 2)

            state.navigateBack()
            #expect(reloaded().index == 1)

            state.navigateForward()
            #expect(reloaded().index == 2)

            #expect(state.navigateBackPastArchived(c))
            #expect(reloaded().index == 1)
            #expect(reloaded().entries.count == 3)
        }
    }
}
