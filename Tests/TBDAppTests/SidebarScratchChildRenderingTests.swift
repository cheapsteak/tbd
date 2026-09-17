import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

@MainActor
private struct ScratchChildFixture {
    let suite = "SidebarScratchChildRenderingTests.\(UUID().uuidString)"
    let state: AppState
    let parent: Worktree
    let scratch: Worktree

    init(remoteParent: Bool) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AppState.scratchSectionExpandedKey)
        state = AppState(userDefaults: defaults)
        let repo = UUID()
        parent = SidebarGroupFixtures.row("parent", repoID: repo, remote: remoteParent ? "parent" : nil)
        var scratch = SidebarGroupFixtures.row("scratch", repoID: repo)
        scratch.repoID = nil
        self.scratch = scratch
        state.worktrees = [repo: [parent]]
        state.scratchWorktrees = [scratch]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        state.remoteSessions = [SidebarGroupFixtures.session("parent", state: .exited)]
    }

    func cleanUp() {
        state.userDefaults.removePersistentDomain(forName: suite)
    }
}

private struct ScratchParentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private final class ScratchParentGeometry {
    var height: CGFloat = 0
}

@MainActor
@Suite("Reparented Scratch rows retain one flat render location")
struct SidebarScratchChildRenderingTests {
    @Test(arguments: [false, true])
    func scratchStaysFlatWithoutLosingDescendantLiveness(remoteParent: Bool) {
        let fixture = ScratchChildFixture(remoteParent: remoteParent)
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.scratchWorktrees[0].parentWorktreeID = fixture.parent.id
        let groups = state.sidebarRemoteGroups(parentID: fixture.parent.id)
        #expect(groups.localRoots.isEmpty)
        #expect(groups.remoteRoots.isEmpty)
        #expect(groups.exitedRoots.isEmpty)
        #expect(state.sidebarScratchHibernation.workingRoots.map(\.id) == [fixture.scratch.id])
        #expect(state.sidebarRemoteSnapshot.children[fixture.parent.id]?.map(\.id) == [fixture.scratch.id])
        if remoteParent {
            let outer = state.sidebarRemoteGroups(repoID: fixture.parent.repoID!)
            #expect(outer.remoteRoots.map(\.id) == [fixture.parent.id])
            #expect(outer.exitedRoots.isEmpty, "The snapshot must still conservatively retain local work")
        }
    }

    @Test func reparentingScratchDoesNotAddASecondRenderedRow() async throws {
        let fixture = ScratchChildFixture(remoteParent: false)
        defer { fixture.cleanUp() }
        let state = fixture.state
        let geometry = ScratchParentGeometry()
        let host = OffscreenHost(
            root: VStack(alignment: .leading, spacing: 0) {
                ScratchSectionView()
                WorktreeSubtreeView(worktree: fixture.parent, depth: 0, sectionRepoID: fixture.parent.repoID!)
            }
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ScratchParentHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(ScratchParentHeightKey.self) { height in
                Task { @MainActor in geometry.height = height }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(state).defaultAppStorage(state.userDefaults),
            size: NSSize(width: 320, height: 300))
        defer { host.tearDown() }
        let mounted = await host.settle { geometry.height > 0 }
        try #require(mounted, "The Scratch section and parent subtree must lay out")
        await host.pump(times: 5)
        let flatHeight = geometry.height

        state.scratchWorktrees[0].parentWorktreeID = fixture.parent.id
        let rendered = await host.settle { state.sidebarParentRemoteGroupsCache[fixture.parent.id] != nil }
        try #require(rendered, "The source mutation must reach the real parent renderer")
        await host.pump(times: 10)
        #expect(abs(geometry.height - flatHeight) < 0.5,
                "Reparenting Scratch must not render its row again beneath the parent")

        // Positive control: a repo-backed child still reaches this same native
        // subtree and adds a row, proving the geometry can detect duplication.
        let child = SidebarGroupFixtures.row("local child", repoID: fixture.parent.repoID!, parent: fixture.parent.id)
        state.worktrees[fixture.parent.repoID!]?.append(child)
        let added = await host.settle {
            abs(geometry.height - flatHeight - WorktreeRowView.rowHeight) < 0.5
        }
        #expect(added, "A real local child must still add exactly one rendered row")
        #expect(state.sidebarScratchHibernation.workingRoots.map(\.id) == [fixture.scratch.id])
    }
}
