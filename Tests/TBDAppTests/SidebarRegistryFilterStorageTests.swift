import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Storage, pruning and cache invalidation for the per-repo "hide registry
/// remote sessions" filter.
/// Spec: docs/specs/2026-11-19-sidebar-remote-session-filter-design.md.
@MainActor
@Suite("Sidebar registry filter storage")
struct SidebarRegistryFilterStorageTests {
    private static let key = AppState.sidebarRegistryRemoteHiddenRepoIDsKey

    private static func session(_ id: String, lastSeen: Date = Date(timeIntervalSince1970: 100)) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: "acme",
            payload: RemoteSessionPayload(id: id, state: .running),
            gone: false, dismissed: false, lastSeen: lastSeen)
    }

    private static func emptyGroups() -> SidebarRemoteGroups {
        SidebarRemoteGroups(roots: [], remainder: [], allWorktrees: [], inventory: [], providers: [])
    }

    private static func seedCaches(_ state: AppState, repoID: UUID) {
        state.sidebarRegistryFilterCache[repoID] = SidebarRegistryRemoteFilter.none
        state.sidebarParentRemoteGroupsCache[UUID()] = emptyGroups()
    }

    private static func cachesAreEmpty(_ state: AppState) -> Bool {
        state.sidebarRegistryFilterCache.isEmpty && state.sidebarParentRemoteGroupsCache.isEmpty
    }

    @Test func aToggleRoundTripsThroughTheDefaults() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let a = UUID(), b = UUID()
        let state = AppState(userDefaults: suite.defaults)
        state.toggleSidebarRegistryRemoteFilter(repoID: a)
        state.toggleSidebarRegistryRemoteFilter(repoID: b)
        #expect(state.isSidebarRegistryRemoteFilterOn(repoID: a))
        #expect(suite.defaults.stringArray(forKey: Self.key) == [a.uuidString, b.uuidString].sorted())
        #expect(AppState(userDefaults: suite.defaults).sidebarRegistryRemoteHiddenRepoIDs == [a, b])

        state.toggleSidebarRegistryRemoteFilter(repoID: a)
        #expect(!state.isSidebarRegistryRemoteFilterOn(repoID: a))
        #expect(AppState(userDefaults: suite.defaults).sidebarRegistryRemoteHiddenRepoIDs == [b])
    }

    @Test func absentEmptyAndUnreadableEntriesMeanNoFilter() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let a = UUID()
        #expect(AppState.restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: suite.defaults).isEmpty)
        suite.defaults.set([String](), forKey: Self.key)
        #expect(AppState.restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: suite.defaults).isEmpty)
        suite.defaults.set(["not-a-uuid", a.uuidString], forKey: Self.key)
        #expect(AppState.restoredSidebarRegistryRemoteHiddenRepoIDs(defaults: suite.defaults) == [a])
    }

    @Test func constructingAppStateWritesNothing() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        _ = AppState(userDefaults: suite.defaults)
        _ = AppState(userDefaults: suite.defaults)
        #expect(suite.defaults.object(forKey: Self.key) == nil)
    }

    @Test func removingARepoForgetsItsFilter() async {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let repoA = Repo(path: "/tmp/acme-a", displayName: "acme-a")
        let repoB = Repo(path: "/tmp/acme-b", displayName: "acme-b")
        let state = AppState(userDefaults: suite.defaults)
        state.repos = [repoA, repoB]
        state.sidebarRegistryRemoteHiddenRepoIDs = [repoA.id, repoB.id]

        state.repoRemover = { _, _ in throw DaemonClientError.connectionFailed("boom") }
        await state.removeRepo(repoID: repoA.id)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [repoA.id, repoB.id])

        state.repoRemover = { _, _ in }
        await state.removeRepo(repoID: repoA.id)
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [repoB.id])
        #expect(suite.defaults.stringArray(forKey: Self.key) == [repoB.id.uuidString])
    }

    @Test func refreshReposPrunesOnlyOnASuccessfulFetch() async {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let kept = Repo(path: "/tmp/acme", displayName: "acme")
        let goneID = UUID()
        state.sidebarRegistryRemoteHiddenRepoIDs = [kept.id, goneID]

        state.reposFetcher = { throw DaemonClientError.connectionFailed("boom") }
        await state.refreshRepos()
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [kept.id, goneID])

        state.reposFetcher = { [kept] }
        await state.refreshRepos()
        #expect(state.sidebarRegistryRemoteHiddenRepoIDs == [kept.id])
    }

    @Test func savedSetChangesClearBothCaches() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let repoID = UUID()
        let state = AppState(userDefaults: suite.defaults)
        Self.seedCaches(state, repoID: repoID)
        state.toggleSidebarRegistryRemoteFilter(repoID: repoID)
        #expect(Self.cachesAreEmpty(state))
    }

    @Test func selectionClearsTheCachesOnlyWhileARepoIsFiltered() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let repoID = UUID()
        let state = AppState(userDefaults: suite.defaults)

        Self.seedCaches(state, repoID: repoID)
        state.selectedWorktreeIDs = [UUID()]
        state.selectedRemoteSession = RemoteSessionSelection(provider: "acme", sessionID: "s1")
        #expect(!state.sidebarRegistryFilterCache.isEmpty)
        #expect(!state.sidebarParentRemoteGroupsCache.isEmpty)

        state.sidebarRegistryRemoteHiddenRepoIDs = [repoID]
        Self.seedCaches(state, repoID: repoID)
        state.selectedWorktreeIDs = [UUID()]
        #expect(Self.cachesAreEmpty(state))

        Self.seedCaches(state, repoID: repoID)
        state.selectedRemoteSession = RemoteSessionSelection(provider: "acme", sessionID: "s2")
        #expect(Self.cachesAreEmpty(state))
    }

    @Test func onlyMatchInputChangesClearTheFilterCache() {
        let suite = TestDefaultsSuite("SidebarRegistryFilterStorageTests")
        defer { suite.tearDown() }
        let repoID = UUID()
        let state = AppState(userDefaults: suite.defaults)
        state.remoteSessions = [Self.session("s1")]

        state.sidebarRegistryFilterCache[repoID] = SidebarRegistryRemoteFilter.none
        state.remoteSessions = [Self.session("s1", lastSeen: Date(timeIntervalSince1970: 999))]
        #expect(!state.sidebarRegistryFilterCache.isEmpty)

        state.remoteSessions = [Self.session("s1"), Self.session("s2")]
        #expect(state.sidebarRegistryFilterCache.isEmpty)

        state.sidebarRegistryFilterCache[repoID] = SidebarRegistryRemoteFilter.none
        state.worktrees = [:]
        #expect(state.sidebarRegistryFilterCache.isEmpty)
    }
}
