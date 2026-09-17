import Foundation
import Observation
import Testing
@testable import TBDApp
import TBDShared

enum ParentGroupCacheInput: CaseIterable {
    case worktrees, scratch, sessions, providers, worktreeUnread, remoteUnread
}

@MainActor
struct ParentGroupCacheFixture {
    let suite: String
    let state: AppState
    let parent: Worktree
    let worker: Worktree
    let other: Worktree

    init() {
        let suiteName = "SidebarParentRemoteCacheTests.\(UUID().uuidString)"
        suite = suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        state = AppState(userDefaults: defaults)
        let repo = UUID()
        parent = SidebarGroupFixtures.row("director", repoID: repo)
        other = SidebarGroupFixtures.row("other", repoID: repo)
        worker = SidebarGroupFixtures.row("worker", repoID: repo, remote: "worker", parent: parent.id)
        state.worktrees = [repo: [parent, other, worker]]
        state.remoteSessions = [SidebarGroupFixtures.session("worker", state: .exited)]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
    }

    func cleanUp() {
        state.userDefaults.removePersistentDomain(forName: suite)
    }

    func mutate(_ input: ParentGroupCacheInput) {
        switch input {
        case .worktrees:
            state.worktrees[parent.repoID!]?[2].parentWorktreeID = other.id
        case .scratch:
            // Scratch is flat in the UI, but snapshot membership still affects
            // whether a remote subtree is known to contain local work.
            var child = SidebarGroupFixtures.row("local child", repoID: parent.repoID!, parent: worker.id)
            child.repoID = nil
            state.scratchWorktrees = [child]
        case .sessions:
            state.remoteSessions = [SidebarGroupFixtures.session("worker")]
        case .providers:
            state.remoteProviders = [SidebarGroupFixtures.provider(health: .stale)]
        case .worktreeUnread:
            state.unreadByWorktree[worker.id] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
        case .remoteUnread:
            let key = RemoteSessionSelection(provider: "acme", sessionID: "worker")
            state.unreadByRemoteSession[key] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
        }
    }

    func reflectsMutation(_ groups: SidebarRemoteGroups, input: ParentGroupCacheInput) -> Bool {
        switch input {
        case .worktrees: groups.isEmpty
        case .scratch: groups.remoteRoots.map(\.id) == [worker.id] && groups.exitedRoots.isEmpty
        case .sessions: groups.summary.counts == [.running: 1] && groups.exitedRoots.isEmpty
        case .providers: groups.summary.counts == [.unknown: 1] && groups.exitedRoots.isEmpty
        case .worktreeUnread, .remoteUnread:
            groups.summary.attention == .attentionNeeded && groups.exitedSummary.attention == .attentionNeeded
        }
    }
}

@MainActor
private final class ParentCacheChangeRecord {
    var count = 0
}

@MainActor
@Suite("Parent remote projection memoization")
struct SidebarParentRemoteCacheTests {
    @Test(arguments: ParentGroupCacheInput.allCases)
    func everyInputInvalidatesAndRemainsTrackedWhenWarm(_ input: ParentGroupCacheInput) {
        let fixture = ParentGroupCacheFixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        let initial = state.sidebarRemoteGroups(parentID: fixture.parent.id)
        #expect(initial.exitedRoots.map(\.id) == [fixture.worker.id])
        _ = state.sidebarRemoteGroups(parentID: fixture.other.id)
        #expect(state.sidebarParentRemoteGroupsCache.count == 2)

        let changed = ParentCacheChangeRecord()
        withObservationTracking {
            _ = state.sidebarRemoteGroups(parentID: fixture.parent.id)
        } onChange: {
            MainActor.assumeIsolated { changed.count += 1 }
        }
        fixture.mutate(input)
        #expect(changed.count == 1, "A warm read lost its dependency on \(input)")
        #expect(state.sidebarParentRemoteGroupsCache.isEmpty)
        let updated = state.sidebarRemoteGroups(parentID: fixture.parent.id)
        #expect(fixture.reflectsMutation(updated, input: input))
        if case .worktrees = input {
            #expect(state.sidebarRemoteGroups(parentID: fixture.other.id).exitedRoots.map(\.id) == [fixture.worker.id])
        }
    }

    @Test func clearingUnreadUpdatesBothSummariesWithoutRebuildingSnapshot() {
        let fixture = ParentGroupCacheFixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        for input in [ParentGroupCacheInput.worktreeUnread, .remoteUnread] {
            fixture.mutate(input)
            #expect(state.sidebarRemoteGroups(parentID: fixture.parent.id).summary.attention == .attentionNeeded)
            state.unreadByWorktree = [:]
            state.unreadByRemoteSession = [:]
            #expect(state.sidebarRemoteSnapshotCache != nil)
            let cleared = state.sidebarRemoteGroups(parentID: fixture.parent.id)
            #expect(cleared.summary.attention == nil)
            #expect(cleared.exitedSummary.attention == nil)
        }
    }

    @Test func unrelatedPresentationChangesKeepTheParentProjection() {
        let fixture = ParentGroupCacheFixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        _ = state.sidebarRemoteGroups(parentID: fixture.parent.id)
        state.alertMessage = "acme"
        state.selectedWorktreeIDs = [fixture.parent.id]
        state.toggleSidebarGroup(.init(owner: .parent(fixture.parent.id), kind: .remote))
        state.terminals[fixture.parent.id] = []
        #expect(state.sidebarParentRemoteGroupsCache.count == 1)
        #expect(state.sidebarRemoteGroups(parentID: fixture.parent.id).exitedRoots.map(\.id) == [fixture.worker.id])
    }

    /// Report comparable cold/warm work at the renderer's depth bound. Timings
    /// are diagnostics, never a machine-dependent pass/fail threshold.
    @Test func measuresColdAndWarmFiftyLevelProjectionPasses() {
        let fixture = ParentGroupCacheFixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        var rows = [fixture.parent]
        for index in 1...50 {
            rows.append(SidebarGroupFixtures.row("worker-\(index)", repoID: fixture.parent.repoID!,
                                                remote: "worker-\(index)", parent: rows.last!.id))
        }
        state.worktrees = [fixture.parent.repoID!: rows]
        state.remoteSessions = (1...50).map { SidebarGroupFixtures.session("worker-\($0)") }
        let parents = rows.dropLast().map(\.id)
        let passes = 20
        func run(clearEachPass: Bool) -> Int {
            var total = 0
            for _ in 0..<passes {
                if clearEachPass { state.sidebarParentRemoteGroupsCache.removeAll() }
                for parent in parents {
                    total += state.sidebarRemoteGroups(parentID: parent).summary.counts[.running, default: 0]
                }
            }
            return total
        }
        let clock = ContinuousClock()
        let coldStart = clock.now
        let coldTotal = run(clearEachPass: true)
        let cold = coldStart.duration(to: clock.now)
        let warmStart = clock.now
        let warmTotal = run(clearEachPass: false)
        let warm = warmStart.duration(to: clock.now)
        #expect(coldTotal == passes * 50 * 51 / 2)
        #expect(warmTotal == coldTotal)
        #expect(state.sidebarParentRemoteGroupsCache.count == parents.count)
        print("Parent remote projections: depth=50 passes=\(passes) cold=\(cold) warm=\(warm)")
    }
}
