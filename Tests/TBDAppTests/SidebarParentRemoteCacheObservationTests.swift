import AppKit
import SwiftUI
import Testing
@testable import TBDApp

@MainActor
private final class ParentProjectionRenderRecord {
    var count = 0
    var groups: SidebarRemoteGroups?

    func record(_ groups: SidebarRemoteGroups) {
        count += 1
        self.groups = groups
    }
}

private struct ParentProjectionProbe: View {
    let parentID: UUID
    let record: ParentProjectionRenderRecord
    @Environment(AppState.self) private var appState

    var body: some View {
        let groups = appState.sidebarRemoteGroups(parentID: parentID)
        let _ = record.record(groups)
        VStack {
            Text(appState.alertMessage ?? "acme")
            Text(groups.summary.text)
            Text("\(groups.remoteRoots.count) active roots; \(groups.exitedRoots.count) exited roots")
        }
    }
}

private struct ParentSubtreeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private final class ParentSubtreeGeometry {
    var height: CGFloat = 0
}

@MainActor
@Suite("Parent projection warm-cache rendering")
struct SidebarParentRemoteCacheObservationTests {
    @Test(arguments: ParentGroupCacheInput.allCases)
    func inputMutationReachesTheCacheServedBody(_ input: ParentGroupCacheInput) async throws {
        let fixture = ParentGroupCacheFixture()
        defer { fixture.cleanUp() }
        let record = ParentProjectionRenderRecord()
        let host = OffscreenHost(
            root: ParentProjectionProbe(parentID: fixture.parent.id, record: record).environment(fixture.state),
            size: NSSize(width: 320, height: 180))
        defer { host.tearDown() }
        let mounted = await host.settle { record.count > 0 }
        try #require(mounted, "The probe must evaluate before measuring a warm render")
        await host.pump(times: 5)
        try #require(fixture.state.sidebarParentRemoteGroupsCache[fixture.parent.id] != nil)
        #expect(record.groups?.exitedRoots.map(\.id) == [fixture.worker.id])

        let coldCount = record.count
        fixture.state.alertMessage = "Force a warm-cache render"
        let warmed = await host.settle { record.count > coldCount }
        try #require(warmed, "An unrelated tracked write must force the cache-served evaluation")
        await host.pump(times: 5)
        let warmCount = record.count
        fixture.mutate(input)
        let changed = await host.settle {
            record.count > warmCount && record.groups.map { fixture.reflectsMutation($0, input: input) } == true
        }
        #expect(changed, "A \(input) mutation did not reach the warm-cache SwiftUI body")
    }

    @Test func renderedSubtreeRemovesExitedDisclosureWhenProviderBecomesStale() async throws {
        let fixture = ParentGroupCacheFixture()
        defer { fixture.cleanUp() }
        let state = fixture.state
        state.expandedSidebarGroups = [
            .init(owner: .parent(fixture.parent.id), kind: .remote),
            .init(owner: .parent(fixture.parent.id), kind: .exited)
        ]
        // The actual renderer mounts against an already-warm projection.
        _ = state.sidebarRemoteGroups(parentID: fixture.parent.id)
        let geometry = ParentSubtreeGeometry()
        let host = OffscreenHost(
            root: VStack(alignment: .leading, spacing: 0) {
                WorktreeSubtreeView(worktree: fixture.parent, depth: 0, sectionRepoID: fixture.parent.repoID!)
            }
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ParentSubtreeHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(ParentSubtreeHeightKey.self) { height in
                Task { @MainActor in geometry.height = height }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(state).defaultAppStorage(state.userDefaults),
            size: NSSize(width: 320, height: 300))
        defer { host.tearDown() }
        let mounted = await host.settle { geometry.height > 0 }
        try #require(mounted, "The inner subtree must lay out before measuring")
        await host.pump(times: 5)
        let initialHeight = geometry.height
        fixture.mutate(.providers)
        let changed = await host.settle { geometry.height < initialHeight }
        try #require(changed, "The stale provider must remove the Exited header")
        await host.pump(times: 5)
        let expandedHeight = geometry.height
        #expect(state.sidebarRemoteGroups(parentID: fixture.parent.id).remoteRoots.map(\.id) == [fixture.worker.id])

        // One worker is still mounted under Remote. Collapsing that group
        // must remove exactly its row, independently of the model assertion.
        state.toggleSidebarGroup(.init(owner: .parent(fixture.parent.id), kind: .remote))
        let collapsed = await host.settle {
            abs(expandedHeight - geometry.height - WorktreeRowView.rowHeight) < 0.5
        }
        #expect(collapsed, "Remote must retain the worker row after its Exited subgroup disappears")
    }
}
