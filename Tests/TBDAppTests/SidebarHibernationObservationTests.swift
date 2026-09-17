import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Records only evaluations made by the mounted SwiftUI body. This reference
/// is deliberately not observable: recording a render must not cause another.
@MainActor
private final class HibernationBodyRecord {
    private(set) var count = 0
    private(set) var hibernatedIDs = Set<UUID>()
    private(set) var workingIDs = Set<UUID>()

    func record(_ partition: SidebarHibernationPartition) {
        count += 1
        hibernatedIDs = partition.hibernatedWorktreeIDs
        workingIDs = Set(partition.workingRoots.map(\.id))
    }
}

private struct HibernationCacheProbe: View {
    let repoID: UUID?
    let record: HibernationBodyRecord
    @Environment(AppState.self) private var appState

    var body: some View {
        let partition = repoID.map { appState.sidebarHibernation(repoID: $0) }
            ?? appState.sidebarScratchHibernation
        let _ = record.record(partition)
        VStack(alignment: .leading) {
            // A tracked, unrelated property forces a measured warm-cache body
            // evaluation, just as in AppStateWarmCacheDependencySourceTests.
            Text(appState.alertMessage ?? "-")
            ForEach(partition.workingRoots) { row in
                Text("Working: \(row.displayName)")
            }
            ForEach(partition.hibernatedRoots) { row in
                Text("Hibernated: \(row.displayName)")
            }
        }
    }
}

@MainActor
@Suite("Hibernation getters preserve their warm-cache SwiftUI dependencies")
struct SidebarHibernationObservationTests {
    private enum Source {
        case repositoryTerminals, repositoryWorktrees
        case scratchTerminals, scratchRows, scratchDescendants

        var isScratch: Bool {
            switch self {
            case .repositoryTerminals, .repositoryWorktrees: false
            case .scratchTerminals, .scratchRows, .scratchDescendants: true
            }
        }
    }

    @Test func repositoryTerminalMutationReachesWarmBody() async throws {
        try await checkWarmDependency(.repositoryTerminals)
    }

    @Test func repositoryWorktreeMutationReachesWarmBody() async throws {
        try await checkWarmDependency(.repositoryWorktrees)
    }

    @Test func scratchTerminalMutationReachesWarmBody() async throws {
        try await checkWarmDependency(.scratchTerminals)
    }

    @Test func scratchRowMutationReachesWarmBody() async throws {
        try await checkWarmDependency(.scratchRows)
    }

    @Test func scratchDescendantMutationReachesWarmBody() async throws {
        try await checkWarmDependency(.scratchDescendants)
    }

    /// Cold fill -> forced warm-cache body -> change exactly one input. The
    /// probe must retain every dependency even though the cache hit itself
    /// needs none of those inputs to return its value. Removing the matching
    /// unconditional source read in either getter must fail its test here.
    private func checkWarmDependency(_ source: Source) async throws {
        let suite = "SidebarHibernationObservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(userDefaults: defaults)
        let repoID = UUID()
        let row = Worktree(
            repoID: source.isScratch ? nil : repoID,
            name: "acme-task", displayName: "Acme task", branch: "acme-task",
            path: "/tmp/acme-task", status: .active, tmuxServer: "acme")
        if source.isScratch {
            state.scratchWorktrees = [row]
        } else {
            state.worktrees = [repoID: [row]]
        }
        state.terminals[row.id] = [Terminal(
            worktreeID: row.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude,
            hibernatedAt: Date(timeIntervalSince1970: 1_800_000_000))]

        let record = HibernationBodyRecord()
        let host = OffscreenHost(
            root: HibernationCacheProbe(repoID: source.isScratch ? nil : repoID, record: record)
                .environment(state).defaultAppStorage(defaults),
            size: NSSize(width: 320, height: 200))
        defer { host.tearDown() }
        let initiallyRendered = await host.settle { record.count > 0 }
        try #require(initiallyRendered, "The probe never evaluated; the harness would be vacuous")
        await host.pump(times: 5)
        #expect(record.hibernatedIDs == [row.id])
        #expect(record.workingIDs.isEmpty)
        let owner: SidebarGroupID.Owner = source.isScratch ? .scratch : .repository(repoID)
        try #require(state.sidebarHibernationCache[owner] != nil, "The cold body did not fill the cache")

        let coldCount = record.count
        state.alertMessage = "Force a warm-cache render"
        let servedWarm = await host.settle { record.count > coldCount }
        try #require(servedWarm, "The forced warm-cache evaluation did not happen")
        await host.pump(times: 5)
        #expect(record.hibernatedIDs == [row.id])
        let warmCount = record.count

        switch source {
        case .repositoryTerminals, .scratchTerminals:
            state.terminals[row.id]?[0].hibernatedAt = nil
        case .repositoryWorktrees, .scratchDescendants:
            // An unloaded descendant keeps the repo subtree working. Any
            // descendant keeps Scratch working because its renderer is flat.
            let child = Worktree(
                repoID: repoID, name: "acme-child", displayName: "Acme child",
                branch: "acme-child", path: "/tmp/acme-child", status: .active,
                tmuxServer: "acme", parentWorktreeID: row.id)
            state.worktrees[repoID, default: []].append(child)
        case .scratchRows:
            state.scratchWorktrees = []
        }

        let mutationRendered = await host.settle {
            record.count > warmCount && record.hibernatedIDs.isEmpty
        }
        #expect(mutationRendered, "The source mutation did not reach the cache-served SwiftUI body")
        #expect(record.count > warmCount)
        #expect(record.hibernatedIDs.isEmpty)
        if case .scratchRows = source {
            #expect(record.workingIDs.isEmpty)
        } else {
            #expect(record.workingIDs == [row.id])
        }
    }
}
