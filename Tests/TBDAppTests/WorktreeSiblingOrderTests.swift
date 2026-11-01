import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. Every row carries a fixed
// `createdAt`, and `worktree.moveMany` and `worktree.list` are stubs, so no
// test reaches a daemon or depends on when it ran. No `~/tbd`.

/// Siblings show in the daemon's order — `sortOrder`, then `createdAt`, then
/// ID — the order `worktree.moveMany` renumbers a group in. Rows that tie on
/// `sortOrder` (legacy rows at 0, creating placeholders) therefore show where
/// the first move into their group leaves them, and a drop never visibly
/// swaps two rows the user did not touch.
@MainActor
@Suite("Sibling order: ties break by createdAt, then ID")
struct WorktreeSiblingOrderTests {
    private func makeState() -> (AppState, TestDefaultsSuite) {
        let suite = TestDefaultsSuite("WorktreeSiblingOrderTests")
        let state = AppState(userDefaults: suite.defaults)
        return (state, suite)
    }

    @Test func comparatorBreaksTiesByCreatedAtThenID() {
        let repo = UUID()
        let low = Self.row("low", repoID: repo, sortOrder: 0, minute: 9, id: Self.id(1))
        let older = Self.row("older", repoID: repo, sortOrder: 1, minute: 0, id: Self.id(9))
        let newerSmallID = Self.row("newer small ID", repoID: repo, sortOrder: 1, minute: 5, id: Self.id(2))
        let newerLargeID = Self.row("newer large ID", repoID: repo, sortOrder: 1, minute: 5, id: Self.id(3))

        let sorted = [newerLargeID, newerSmallID, older, low].sorted(by: Worktree.precedesSibling)
        let names = sorted.map { $0.name }
        #expect(names == ["low", "older", "newer small ID", "newer large ID"])
    }

    /// The section's top level and a parent's children both follow it,
    /// whatever order the rows arrive in.
    @Test func topLevelAndChildrenShowTiesInDaemonOrder() {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let repo = UUID()
        let parent = Self.row("parent", repoID: repo, sortOrder: 0, minute: 0, id: Self.id(10))
        let first = Self.row("first", repoID: repo, sortOrder: 1, minute: 1, id: Self.id(19))
        let second = Self.row("second", repoID: repo, sortOrder: 1, minute: 2, id: Self.id(11))
        let childOlder = Self.row("child older", repoID: repo, parent: parent.id, sortOrder: 0, minute: 3,
                                  id: Self.id(29))
        let childNewer = Self.row("child newer", repoID: repo, parent: parent.id, sortOrder: 0, minute: 4,
                                  id: Self.id(21))
        // Arrival order is the reverse of the daemon's in both groups.
        state.worktrees = [repo: [second, childNewer, first, childOlder, parent]]

        let topLevel = state.sidebarTopLevelWorktrees(repoID: repo).map { $0.name }
        #expect(topLevel == ["parent", "first", "second"])
        let children = state.children(of: parent.id).map { $0.name }
        #expect(children == ["child older", "child newer"])
    }

    /// Scratch rows, which a refresh sorts as it lists them, follow the same
    /// order.
    @Test func refreshSortsTiedScratchRowsInDaemonOrder() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let older = Self.row("older", repoID: nil, sortOrder: 0, minute: 0, id: Self.id(39))
        let newer = Self.row("newer", repoID: nil, sortOrder: 0, minute: 1, id: Self.id(31))
        let listed = [newer, older]
        state.worktreesFetcher = { _ in listed }
        state.terminalsListFetcher = { [] }

        await state.refreshWorktrees()

        let names = state.scratchWorktrees.map { $0.name }
        #expect(names == ["older", "newer"])
    }

    /// The first drop into a group of tied rows renumbers the group. The rows
    /// the user did not touch keep the order they showed in before the drop.
    @Test func firstDropIntoATiedGroupMovesOnlyTheCarriedRow() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let repo = UUID()
        // All three at sortOrder 0, created x, then y, then z, and listed in
        // another order.
        let x = Self.row("x", repoID: repo, sortOrder: 0, minute: 0, id: Self.id(49))
        let y = Self.row("y", repoID: repo, sortOrder: 0, minute: 1, id: Self.id(48))
        let z = Self.row("z", repoID: repo, sortOrder: 0, minute: 2, id: Self.id(47))
        state.worktrees = [repo: [z, x, y]]
        let sent = SentMoves()
        state.worktreeMoveManySender = { params in sent.record(params) }

        let shownBefore = state.sidebarTopLevelWorktrees(repoID: repo).map { $0.name }
        #expect(shownBefore == ["x", "y", "z"])

        // Drop z between x and y.
        let moveID = state.moveWorktrees(ids: [z.id], newParentID: nil, before: y.id)
        #expect(moveID != nil)

        let shownAfter = state.sidebarTopLevelWorktrees(repoID: repo).map { $0.name }
        #expect(shownAfter == ["x", "z", "y"], "x and y must keep the order they showed in")
        let orders = state.sidebarTopLevelWorktrees(repoID: repo).map { $0.sortOrder }
        #expect(orders == [0, 1, 2])
        // The order the daemon will write, from its own tie-break.
        let daemonOrder = SiblingPlacement.place(group: [x.id, y.id, z.id], carried: [z.id], before: y.id)
        let shownIDs = state.sidebarTopLevelWorktrees(repoID: repo).map { $0.id }
        #expect(shownIDs == daemonOrder)

        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { sent.requests.count == 1 }
        }
        if outcome == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the move's RPC", observed: "\(sent.requests.count) sent", deadline: TestDeadlines.saturatedPass))
        }
        #expect(sent.requests.first?.beforeWorktreeID == y.id)
    }

    // MARK: Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", number))!
    }

    /// A row created `minute` minutes after a fixed instant.
    static func row(_ name: String, repoID: UUID?, parent: UUID? = nil, sortOrder: Int, minute: Int,
                    id: UUID) -> Worktree {
        Worktree(
            id: id, repoID: repoID, name: name, displayName: name, branch: name,
            path: "/acme/worktrees/\(name)", createdAt: epoch.addingTimeInterval(Double(minute) * 60),
            tmuxServer: "tbd-test", sortOrder: sortOrder, parentWorktreeID: parent)
    }
}

/// Stands in for `worktree.moveMany`: records each request and answers at
/// once.
@MainActor
private final class SentMoves {
    private(set) var requests: [WorktreeMoveManyParams] = []

    func record(_ params: WorktreeMoveManyParams) {
        requests.append(params)
    }
}
