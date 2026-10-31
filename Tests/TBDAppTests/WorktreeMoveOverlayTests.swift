import Foundation
import Observation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: deterministic, in-process state only. `worktree.moveMany` and
// `worktree.list` are stubbed and held on continuations, so each test decides
// when the daemon answers and in which order the reply, the delta and the
// fetches land. The code under test never sleeps; only `waitUntil`, which
// observes it, polls on a deadline. No `~/tbd`.

/// `AppState.moveWorktrees`: the rows move before the RPC returns, a pending
/// move is re-applied over every fetch and move delta until the daemon has
/// both replied and been seen, a fetch sent before the reply is fenced off,
/// and a failed move restores only the rows it touched.
@MainActor
@Suite("moving worktrees: pending-move overlay, fetch fence and failure")
struct WorktreeMoveOverlayTests {

    private func makeState() -> (AppState, TestDefaultsSuite) {
        let suite = TestDefaultsSuite("WorktreeMoveOverlayTests")
        let state = AppState(userDefaults: suite.defaults)
        // Long enough that a failure toast cannot dismiss itself before the
        // test reads it on a loaded runner.
        state.toastTickDuration = .seconds(600)
        return (state, suite)
    }

    private func wire(_ state: AppState, rpc: MoveRPCGate, fetch: FetchGate) {
        state.worktreeMoveManySender = { params in try await rpc.send(params) }
        state.worktreesFetcher = { repoID in try await fetch.fetch(repoID: repoID) }
    }

    // MARK: - Local first

    @Test func appliesMoveLocallyBeforeRPCReturns() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)

        // Still inside the drop's main-actor turn: the task that sends the
        // RPC has not even run, and the rows have already moved.
        #expect(rpc.sent.isEmpty)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])
        #expect(topLevelSortOrders(state, repo: top.repo) == [0, 1, 2, 3])
        // The order the daemon will write, from the same placement.
        let daemonOrder = SiblingPlacement.place(
            group: top.rows.map(\.id), carried: [top.d.id], before: top.b.id)
        #expect(topLevelIDs(state, repo: top.repo) == daemonOrder)
        #expect(state.pendingWorktreeMoves == [PendingWorktreeMove(
            moveID: moveID, worktreeIDs: [top.d.id], newParentID: nil, before: top.b.id,
            fence: nil, rpcSucceeded: false, deltaApplied: false)])

        await rpc.succeed(moveID)
        #expect(rpc.sent.count == 1)
        #expect(rpc.sent.first?.moveID == moveID)
        #expect(rpc.sent.first?.worktreeIDs == [top.d.id])
        #expect(rpc.sent.first?.newParentID == nil)
        #expect(rpc.sent.first?.beforeWorktreeID == top.b.id)
        await waitUntil("the reply is recorded") { state.pendingWorktreeMoves.first?.rpcSucceeded == true }
    }

    // MARK: - Overlay

    @Test func stalePollDuringFlightLeavesRowsAndPublishesNothing() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        let moved = state.worktrees

        // The daemon has not committed: the poll answers with the rows as
        // they stood before the drop.
        let counter = ListWriteCounter(state)
        await state.refreshWorktrees()
        counter.stop()

        #expect(fetch.calls == 1)
        #expect(counter.count == 0)
        #expect(state.worktrees == moved)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])
        #expect(state.pendingWorktreeMoves.map(\.moveID) == [moveID])

        await rpc.succeed(moveID)
    }

    @Test func otherWritersDeltaDoesNotMoveCarriedRows() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        // Nest d under b.
        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: top.b.id, before: nil)
        #expect(childOrder(state, repo: top.repo, parent: top.b.id) == ["d"])

        // Meanwhile the CLI moves c to the front. The daemon has not committed
        // this app's move yet, so its group still holds d at the top level.
        let other = daemonDelta(
            group: top.rows.map(\.id), carried: [top.c.id], before: top.a.id,
            parent: nil, moveID: UUID())
        state.handleDelta(.worktreeSiblingsReordered(other))

        // The other writer's change lands; the carried row stays where the drop put it.
        #expect(row(state, top.d.id)?.parentWorktreeID == top.b.id)
        #expect(childOrder(state, repo: top.repo, parent: top.b.id) == ["d"])
        #expect(topLevelOrder(state, repo: top.repo) == ["c", "a", "b"])
        #expect(state.pendingWorktreeMoves.first?.deltaApplied == false)

        await rpc.succeed(moveID)
    }

    @Test func siblingsDeltaMakesSortOrdersEqualDaemons() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        // The daemon's group is a, x, b, c; x is archived, so the app does not
        // list it, and the rows it does list carry the daemon's numbers.
        let repo = UUID()
        let a = makeRow("a", repoID: repo, sortOrder: 0)
        let x = makeRow("x", repoID: repo, sortOrder: 1, status: .archived)
        let b = makeRow("b", repoID: repo, sortOrder: 2)
        let c = makeRow("c", repoID: repo, sortOrder: 3)
        state.worktrees = [repo: [a, b, c]]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: [a, b, c])
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [c.id], newParentID: nil, before: a.id)
        #expect(topLevelOrder(state, repo: repo) == ["c", "a", "b"])

        // The daemon commits and its delta arrives before the reply.
        let own = daemonDelta(
            group: [a.id, x.id, b.id, c.id], carried: [c.id], before: a.id,
            parent: nil, moveID: moveID)
        state.handleDelta(.worktreeSiblingsReordered(own))
        expectMatchesDaemon(state, own.entries)
        #expect(topLevelOrder(state, repo: repo) == ["c", "a", "b"])

        await rpc.succeed(moveID)
        await waitUntil("the move retires") { state.pendingWorktreeMoves.isEmpty }
        expectMatchesDaemon(state, own.entries)

        // A later group from another writer is taken as the daemon sent it.
        let later = daemonDelta(
            group: own.entries.map(\.worktreeID), carried: [b.id], before: c.id,
            parent: nil, moveID: nil)
        state.handleDelta(.worktreeSiblingsReordered(later))
        expectMatchesDaemon(state, later.entries)
        #expect(topLevelOrder(state, repo: repo) == ["b", "c", "a"])
    }

    @Test func otherWritersMovedDeltaDoesNotMoveCarriedRows() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        // Nest d under b.
        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: top.b.id, before: nil)

        // `worktree.move` from elsewhere puts d back at the top level, which
        // the daemon wrote before this app's move, and nests c under a.
        state.handleDelta(.worktreeMoved(
            WorktreeMovedDelta(worktreeID: top.d.id, newParentID: nil, newSortOrder: 9)))
        state.handleDelta(.worktreeMoved(
            WorktreeMovedDelta(worktreeID: top.c.id, newParentID: top.a.id, newSortOrder: 0)))

        #expect(row(state, top.d.id)?.parentWorktreeID == top.b.id)
        #expect(childOrder(state, repo: top.repo, parent: top.b.id) == ["d"])
        #expect(childOrder(state, repo: top.repo, parent: top.a.id) == ["c"])
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "b"])

        await rpc.succeed(moveID)
    }

    @Test func staleScopedPollPublishesNothing() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        let otherRepo = UUID()
        let f = makeRow("f", repoID: otherRepo, sortOrder: 0)
        state.worktrees = [top.repo: top.rows, otherRepo: [f]]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        let moved = state.worktrees

        // A fetch scoped to the moved rows' repo, answered before the commit.
        let counter = ListWriteCounter(state)
        await state.refreshWorktrees(repoID: top.repo)
        counter.stop()

        #expect(fetch.requests == [top.repo])
        #expect(counter.count == 0)
        #expect(state.worktrees == moved)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])

        await rpc.succeed(moveID)
    }

    @Test func movesAScratchRowAndKeepsTheListSorted() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let s0 = makeRow("s0", repoID: nil, sortOrder: 0)
        let s1 = makeRow("s1", repoID: nil, sortOrder: 1)
        let s2 = makeRow("s2", repoID: nil, sortOrder: 2)
        state.scratchWorktrees = [s0, s1, s2]
        // The daemon lists the rows in an order other than the sidebar's.
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: [s1, s2, s0])
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [s2.id], newParentID: nil, before: s0.id)

        // The scratch list is kept in `sortOrder` order, as a refresh leaves it.
        #expect(state.scratchWorktrees.map(\.name) == ["s2", "s0", "s1"])
        #expect(state.scratchWorktrees.map(\.sortOrder) == [0, 1, 2])
        #expect(state.worktrees.isEmpty)
        let moved = state.scratchWorktrees

        // A poll that predates the commit rebuilds the same list.
        let counter = ListWriteCounter(state)
        await state.refreshWorktrees()
        counter.stop()
        #expect(counter.count == 0)
        #expect(state.scratchWorktrees == moved)

        let own = daemonDelta(
            group: [s0.id, s1.id, s2.id], carried: [s2.id], before: s0.id,
            parent: nil, moveID: moveID)
        state.handleDelta(.worktreeSiblingsReordered(own))
        await rpc.succeed(moveID)
        await waitUntil("the move retires") { state.pendingWorktreeMoves.isEmpty }
        #expect(state.scratchWorktrees.map(\.name) == ["s2", "s0", "s1"])
    }

    // MARK: - Retiring

    @Test func retiresOnOwnDeltaEvenIfDeltaArrivesBeforeReply() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        let own = daemonDelta(
            group: top.rows.map(\.id), carried: [top.d.id], before: top.b.id,
            parent: nil, moveID: moveID)
        state.handleDelta(.worktreeSiblingsReordered(own))

        // Seen, but not answered: the move stays.
        #expect(state.pendingWorktreeMoves.count == 1)
        #expect(state.pendingWorktreeMoves.first?.deltaApplied == true)
        #expect(state.pendingWorktreeMoves.first?.rpcSucceeded == false)

        await rpc.succeed(moveID)
        await waitUntil("the move retires") { state.pendingWorktreeMoves.isEmpty }
        #expect(state.pendingWorktreeMoves.isEmpty)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])
    }

    @Test func doesNotRetireOnAnotherMovesDelta() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        let another = daemonDelta(
            group: top.rows.map(\.id), carried: [top.c.id], before: top.a.id,
            parent: nil, moveID: UUID())
        state.handleDelta(.worktreeSiblingsReordered(another))
        await rpc.succeed(moveID)
        await waitUntil("the reply is recorded") { state.pendingWorktreeMoves.first?.rpcSucceeded == true }

        #expect(state.pendingWorktreeMoves.map(\.moveID) == [moveID])
        #expect(state.pendingWorktreeMoves.first?.deltaApplied == false)

        // A group broadcast with no move ID retires nothing either.
        let anonymous = WorktreeSiblingsReorderedDelta(moveID: nil, entries: another.entries)
        state.handleDelta(.worktreeSiblingsReordered(anonymous))
        #expect(state.pendingWorktreeMoves.map(\.moveID) == [moveID])
    }

    @Test func retiresOnFetchAtOrAboveFence() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        let committed = applying(
            daemonDelta(
                group: top.rows.map(\.id), carried: [top.d.id], before: top.b.id,
                parent: nil, moveID: moveID
            ).entries,
            to: top.rows)

        // A poll sent before the reply.
        fetch.holdNext = true
        let early = Task { await state.refreshWorktrees() }
        await waitUntil("the early poll is sent") { fetch.heldCount == 1 }

        await rpc.succeed(moveID)
        await waitUntil("the reply is recorded") { state.pendingWorktreeMoves.first?.rpcSucceeded == true }
        let fence = state.pendingWorktreeMoves.first?.fence
        #expect(fence == 1)
        #expect(state.worktreeFetchFence == 1)

        // Even an answer that shows the commit cannot retire the move when the
        // fetch was sent below the fence.
        fetch.release(returning: committed)
        await early.value
        #expect(state.pendingWorktreeMoves.map(\.moveID) == [moveID])

        // A poll sent after the reply reads the commit.
        fetch.rows = committed
        await state.refreshWorktrees()
        #expect(state.pendingWorktreeMoves.isEmpty)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])
    }

    @Test func fetchBelowFenceIsDiscardedAfterRetire() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        let moved = state.worktrees

        // A poll goes out while the RPC is in flight and reads the daemon
        // before the commit.
        fetch.holdNext = true
        let poll = Task { await state.refreshWorktrees() }
        await waitUntil("the poll is sent") { fetch.heldCount == 1 }

        // The daemon commits, broadcasts and replies; the move retires.
        let own = daemonDelta(
            group: top.rows.map(\.id), carried: [top.d.id], before: top.b.id,
            parent: nil, moveID: moveID)
        state.handleDelta(.worktreeSiblingsReordered(own))
        await rpc.succeed(moveID)
        await waitUntil("the move retires") { state.pendingWorktreeMoves.isEmpty }

        // The poll's pre-commit answer arrives with no overlay left to absorb it.
        let counter = ListWriteCounter(state)
        fetch.release(returning: top.rows)
        await poll.value
        counter.stop()

        #expect(counter.count == 0)
        #expect(state.worktrees == moved)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])
    }

    /// Another writer may move a carried row after this move commits. The
    /// fetch at the fence carries that newer state, and the settled move must
    /// leave the overlay before the fetch is applied, not force its own
    /// placement back over it.
    @Test func fenceFetchKeepsALaterWritersPlacement() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        await rpc.succeed(moveID)
        await waitUntil("the reply is recorded") { state.pendingWorktreeMoves.first?.rpcSucceeded == true }

        // This move committed, then the CLI moved d to the end; its delta has
        // not arrived. The fetch at the fence reads both.
        let ours = daemonDelta(
            group: top.rows.map(\.id), carried: [top.d.id], before: top.b.id,
            parent: nil, moveID: moveID)
        let later = daemonDelta(
            group: ours.entries.map(\.worktreeID), carried: [top.d.id], before: nil,
            parent: nil, moveID: UUID())
        fetch.rows = applying(later.entries, to: applying(ours.entries, to: top.rows))
        await state.refreshWorktrees()

        #expect(state.pendingWorktreeMoves.isEmpty)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "b", "c", "d"])
        expectMatchesDaemon(state, later.entries)
    }

    // MARK: - Failure

    @Test func failureRestoresScopedSnapshotKeepsOtherChangesAndToasts() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        // Repo r: a and b at the top, c and d under a, e under b.
        // Repo s: f and g at the top.
        let r = UUID(), s = UUID()
        let a = makeRow("a", repoID: r, sortOrder: 0)
        let b = makeRow("b", repoID: r, sortOrder: 1)
        let c = makeRow("c", repoID: r, parent: a.id, sortOrder: 0)
        let d = makeRow("d", repoID: r, parent: a.id, sortOrder: 1)
        let e = makeRow("e", repoID: r, parent: b.id, sortOrder: 0)
        let f = makeRow("f", repoID: s, sortOrder: 0)
        let g = makeRow("g", repoID: s, sortOrder: 1)
        let before = [a, b, c, d, e, f, g]
        state.worktrees = [r: [a, b, c, d, e], s: [f, g]]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: before)
        wire(state, rpc: rpc, fetch: fetch)

        // Move c from under a to under b, ahead of e.
        let moveID = state.moveWorktrees(ids: [c.id], newParentID: b.id, before: e.id)
        #expect(childOrder(state, repo: r, parent: b.id) == ["c", "e"])

        // While the RPC is out, a poll brings two other changes: d (in the
        // group c left) is renamed, and g (in another repo) is reordered.
        var renamedD = d
        renamedD.displayName = "Row d, renamed"
        var reorderedG = g
        reorderedG.sortOrder = 5
        let meanwhile = [a, b, c, renamedD, e, f, reorderedG]
        fetch.rows = meanwhile
        await state.refreshWorktrees()
        #expect(childOrder(state, repo: r, parent: b.id) == ["c", "e"])
        #expect(row(state, d.id)?.displayName == "Row d, renamed")

        // The daemon refuses. Hold the refresh that follows, to see the state
        // the snapshot alone leaves, with the toast already up.
        fetch.holdNext = true
        await rpc.fail(moveID, with: MoveRefused())
        await waitUntil("the failure's refresh is sent") { fetch.heldCount == 1 }

        #expect(state.pendingWorktreeMoves.isEmpty)
        #expect(row(state, c.id)?.parentWorktreeID == a.id)
        #expect(row(state, c.id)?.sortOrder == 0)
        #expect(row(state, e.id)?.sortOrder == 0)
        #expect(childOrder(state, repo: r, parent: a.id) == ["c", "d"])
        #expect(childOrder(state, repo: r, parent: b.id) == ["e"])
        #expect(row(state, d.id)?.displayName == "Row d, renamed")
        #expect(row(state, g.id)?.sortOrder == 5)
        // Shown before the refresh, so a slow daemon cannot leave the rows
        // snapping back unexplained.
        #expect(state.activeToast?.message == "Couldn't move Row c: \(MoveRefused().localizedDescription)")
        #expect(state.activeToast?.style == .error)

        fetch.release(returning: meanwhile)
        state.dismissToast()
    }

    @Test func failureRestoresEvenWhenRefreshFails() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])

        // The daemon is gone: the RPC fails, and so does the refresh after it.
        let unreachable = DaemonClientError.daemonNotRunning
        fetch.error = unreachable
        await rpc.fail(moveID, with: unreachable)
        await waitUntil("the toast shows") { state.activeToast != nil }
        await waitUntil("the refresh is tried") { fetch.calls == 1 }

        #expect(fetch.calls == 1)
        #expect(state.pendingWorktreeMoves.isEmpty)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "b", "c", "d"])
        #expect(topLevelSortOrders(state, repo: top.repo) == [0, 1, 2, 3])
        #expect(state.worktrees == [top.repo: top.rows])
        #expect(state.activeToast?.message == "Couldn't move Row d: \(unreachable.localizedDescription)")
        #expect(state.activeToast?.style == .error)
        state.dismissToast()
    }

    /// The delta carrying this move's ID means the daemon committed it, so an
    /// error on the reply (a dropped connection) settles the move as a
    /// success: the rows stay, no toast, and the fence still fences.
    @Test func failureAfterOwnDeltaSettlesAsSuccess() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        state.worktrees = [top.repo: top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: top.rows)
        wire(state, rpc: rpc, fetch: fetch)

        let moveID = state.moveWorktrees(ids: [top.d.id], newParentID: nil, before: top.b.id)

        // A poll that reads the daemon before the commit.
        fetch.holdNext = true
        let poll = Task { await state.refreshWorktrees() }
        await waitUntil("the poll is sent") { fetch.heldCount == 1 }

        let own = daemonDelta(
            group: top.rows.map(\.id), carried: [top.d.id], before: top.b.id,
            parent: nil, moveID: moveID)
        state.handleDelta(.worktreeSiblingsReordered(own))
        await rpc.fail(moveID, with: DaemonClientError.receiveFailed("connection reset"))
        await waitUntil("the move settles") { state.pendingWorktreeMoves.isEmpty }

        #expect(state.activeToast == nil)
        #expect(state.worktreeFetchFence == 1)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])

        fetch.release(returning: top.rows)
        await poll.value
        #expect(fetch.calls == 1)
        #expect(state.activeToast == nil)
        #expect(topLevelOrder(state, repo: top.repo) == ["a", "d", "b", "c"])
    }

    @Test func refusesAnUnlistedOrMainParent() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let top = TopLevelFixture()
        let mainRow = makeRow("main", repoID: top.repo, sortOrder: 0, status: .main)
        state.worktrees = [top.repo: [mainRow] + top.rows]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: [mainRow] + top.rows)
        wire(state, rpc: rpc, fetch: fetch)
        let untouched = state.worktrees

        state.moveWorktrees(ids: [top.d.id], newParentID: UUID(), before: nil)
        state.moveWorktrees(ids: [top.d.id], newParentID: mainRow.id, before: nil)

        #expect(state.worktrees == untouched)
        #expect(state.pendingWorktreeMoves.isEmpty)

        // A valid move made afterwards is the only one the daemon hears about.
        let valid = state.moveWorktrees(ids: [top.d.id], newParentID: top.b.id, before: nil)
        await rpc.succeed(valid)
        #expect(rpc.sent.map(\.moveID) == [valid])
        #expect(childOrder(state, repo: top.repo, parent: top.b.id) == ["d"])
    }

    // MARK: - Two drops

    /// Review focus: the second drop lands while the first RPC is in flight.
    /// Both overlays compose in drop order, and once both settle the app holds
    /// the daemon's order and numbers.
    @Test func twoQuickDropsInOneGroupComposeAndSettle() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        // The daemon's group is a, x, b, c, d; x is archived and not listed.
        let repo = UUID()
        let a = makeRow("a", repoID: repo, sortOrder: 0)
        let x = makeRow("x", repoID: repo, sortOrder: 1, status: .archived)
        let b = makeRow("b", repoID: repo, sortOrder: 2)
        let c = makeRow("c", repoID: repo, sortOrder: 3)
        let d = makeRow("d", repoID: repo, sortOrder: 4)
        let listed = [a, b, c, d]
        state.worktrees = [repo: listed]
        let rpc = MoveRPCGate(), fetch = FetchGate(rows: listed)
        wire(state, rpc: rpc, fetch: fetch)

        // Drop d before b, then a at the end.
        let first = state.moveWorktrees(ids: [d.id], newParentID: nil, before: b.id)
        let second = state.moveWorktrees(ids: [a.id], newParentID: nil, before: nil)
        #expect(topLevelOrder(state, repo: repo) == ["d", "b", "c", "a"])
        #expect(state.pendingWorktreeMoves.map(\.moveID) == [first, second])
        let composed = state.worktrees

        // A poll that predates both commits rebuilds the same lists.
        let counter = ListWriteCounter(state)
        await state.refreshWorktrees()
        counter.stop()
        #expect(counter.count == 0)
        #expect(state.worktrees == composed)

        // The daemon commits the first drop; its delta, then its reply.
        let firstDelta = daemonDelta(
            group: [a.id, x.id, b.id, c.id, d.id], carried: [d.id], before: b.id,
            parent: nil, moveID: first)
        state.handleDelta(.worktreeSiblingsReordered(firstDelta))
        #expect(topLevelOrder(state, repo: repo) == ["d", "b", "c", "a"])
        await rpc.succeed(first)
        await waitUntil("the first move retires") { state.pendingWorktreeMoves.map(\.moveID) == [second] }
        #expect(topLevelOrder(state, repo: repo) == ["d", "b", "c", "a"])

        // Then the second.
        let secondDelta = daemonDelta(
            group: firstDelta.entries.map(\.worktreeID), carried: [a.id], before: nil,
            parent: nil, moveID: second)
        state.handleDelta(.worktreeSiblingsReordered(secondDelta))
        await rpc.succeed(second)
        await waitUntil("the second move retires") { state.pendingWorktreeMoves.isEmpty }

        #expect(rpc.sent.map(\.moveID) == [first, second])
        #expect(rpc.sent.map(\.worktreeIDs) == [[d.id], [a.id]])
        #expect(rpc.sent.map(\.beforeWorktreeID) == [b.id, nil])
        #expect(topLevelOrder(state, repo: repo) == ["d", "b", "c", "a"])
        expectMatchesDaemon(state, secondDelta.entries)

        // A poll after both commits finds the app already where the daemon is.
        fetch.rows = applying(secondDelta.entries, to: listed)
        let settled = ListWriteCounter(state)
        await state.refreshWorktrees()
        settled.stop()
        #expect(settled.count == 0)
    }
}

// MARK: - Fixtures

private let fixtureCreatedAt = Date(timeIntervalSince1970: 1_800_000_000)

private func makeRow(
    _ name: String, repoID: UUID?, parent: UUID? = nil, sortOrder: Int,
    status: WorktreeStatus = .active
) -> Worktree {
    Worktree(
        id: UUID(), repoID: repoID, name: name, displayName: "Row \(name)", branch: name,
        path: "/acme/worktrees/\(name)", status: status, createdAt: fixtureCreatedAt,
        tmuxServer: "tbd-test", sortOrder: sortOrder, parentWorktreeID: parent)
}

/// One repo whose top level is a, b, c, d, in that order.
private struct TopLevelFixture {
    let repo: UUID
    let a: Worktree, b: Worktree, c: Worktree, d: Worktree

    init() {
        let repo = UUID()
        self.repo = repo
        a = makeRow("a", repoID: repo, sortOrder: 0)
        b = makeRow("b", repoID: repo, sortOrder: 1)
        c = makeRow("c", repoID: repo, sortOrder: 2)
        d = makeRow("d", repoID: repo, sortOrder: 3)
    }

    var rows: [Worktree] { [a, b, c, d] }
}

private struct MoveRefused: LocalizedError {
    var errorDescription: String? { "the new parent is archived" }
}

/// The delta the daemon broadcasts for a committed move: the destination
/// group, archived rows included, in `SiblingPlacement` order and numbered
/// from zero.
private func daemonDelta(
    group: [UUID], carried: [UUID], before: UUID?, parent: UUID?, moveID: UUID?
) -> WorktreeSiblingsReorderedDelta {
    let ordered = SiblingPlacement.place(group: group, carried: carried, before: before)
    return WorktreeSiblingsReorderedDelta(
        moveID: moveID,
        entries: ordered.enumerated().map { sortOrder, worktreeID in
            WorktreeOrderEntry(worktreeID: worktreeID, parentWorktreeID: parent, sortOrder: sortOrder)
        })
}

/// `rows` as `worktree.list` returns them once `entries` are committed.
private func applying(_ entries: [WorktreeOrderEntry], to rows: [Worktree]) -> [Worktree] {
    let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.worktreeID, $0) })
    return rows.map { original in
        guard let entry = byID[original.id] else { return original }
        var committed = original
        committed.parentWorktreeID = entry.parentWorktreeID
        committed.sortOrder = entry.sortOrder
        return committed
    }
}

// MARK: - Reading the state

@MainActor
private func row(_ state: AppState, _ id: UUID) -> Worktree? {
    state.worktrees.values.joined().first { $0.id == id }
}

@MainActor
private func siblings(_ state: AppState, repo: UUID, parent: UUID?) -> [Worktree] {
    (state.worktrees[repo] ?? [])
        .filter { $0.parentWorktreeID == parent }
        .sorted { $0.sortOrder < $1.sortOrder }
}

@MainActor
private func topLevelOrder(_ state: AppState, repo: UUID) -> [String] {
    siblings(state, repo: repo, parent: nil).map(\.name)
}

@MainActor
private func topLevelIDs(_ state: AppState, repo: UUID) -> [UUID] {
    siblings(state, repo: repo, parent: nil).map(\.id)
}

@MainActor
private func topLevelSortOrders(_ state: AppState, repo: UUID) -> [Int] {
    siblings(state, repo: repo, parent: nil).map(\.sortOrder)
}

@MainActor
private func childOrder(_ state: AppState, repo: UUID, parent: UUID) -> [String] {
    siblings(state, repo: repo, parent: parent).map(\.name)
}

/// Every row the app lists from `entries` carries the daemon's parent and
/// `sortOrder`; rows the app does not list (archived ones) are skipped.
@MainActor
private func expectMatchesDaemon(
    _ state: AppState, _ entries: [WorktreeOrderEntry],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for entry in entries {
        guard let listed = row(state, entry.worktreeID) else { continue }
        #expect(listed.sortOrder == entry.sortOrder, "\(listed.name)", sourceLocation: sourceLocation)
        #expect(listed.parentWorktreeID == entry.parentWorktreeID, "\(listed.name)", sourceLocation: sourceLocation)
    }
}

// MARK: - Gates

/// Waits on the main actor until `condition` holds, so the tasks the code
/// under test started get to run, and records the timeout instead of hanging.
/// The deadline is the saturated-pass budget: some of these waits cross the
/// cooperative pool (the refresh's terminal fetch), and in the parallel pass a
/// single scheduling hop can cost tens of seconds (`Tests/CLAUDE.md`,
/// "Population is the scheduler").
@MainActor
private func waitUntil(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let start = clock.now
    while !condition() {
        if clock.now - start > TestDeadlines.saturatedPass {
            Issue.record(
                BoundedWaitTimeout(what: what, observed: nil, deadline: TestDeadlines.saturatedPass),
                sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Stands in for `worktree.moveMany`: records each request and holds it
/// until the test answers it.
@MainActor
private final class MoveRPCGate {
    private(set) var sent: [WorktreeMoveManyParams] = []
    private var held: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func send(_ params: WorktreeMoveManyParams) async throws {
        sent.append(params)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            held[params.moveID] = continuation
        }
    }

    func succeed(_ moveID: UUID) async {
        await waitUntil("the move's RPC is sent") { self.held[moveID] != nil }
        held.removeValue(forKey: moveID)?.resume()
    }

    func fail(_ moveID: UUID, with error: any Error) async {
        await waitUntil("the move's RPC is sent") { self.held[moveID] != nil }
        held.removeValue(forKey: moveID)?.resume(throwing: error)
    }
}

/// Stands in for `worktree.list`: answers with `rows` (or throws `error`) at
/// once, or, after `holdNext` is set, holds the next fetch until `release`.
@MainActor
private final class FetchGate {
    var rows: [Worktree]
    var error: (any Error)?
    var holdNext = false
    /// The `repoID` scope of each fetch, in order.
    private(set) var requests: [UUID?] = []
    var calls: Int { requests.count }
    private var held: [CheckedContinuation<[Worktree], any Error>] = []

    init(rows: [Worktree]) {
        self.rows = rows
    }

    var heldCount: Int { held.count }

    func fetch(repoID: UUID?) async throws -> [Worktree] {
        requests.append(repoID)
        if holdNext {
            holdNext = false
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Worktree], any Error>) in
                held.append(continuation)
            }
        }
        if let error { throw error }
        return rows
    }

    func release(returning answer: [Worktree]) {
        guard !held.isEmpty else {
            Issue.record("no fetch is held")
            return
        }
        held.removeFirst().resume(returning: answer)
    }
}

/// Counts writes to `worktrees` and `scratchWorktrees`, the two lists the
/// sidebar renders, while it is live. Re-arms after each one, since
/// `withObservationTracking`'s `onChange` fires once.
@MainActor
private final class ListWriteCounter {
    private let state: AppState
    private var isLive = true
    private(set) var count = 0

    init(_ state: AppState) {
        self.state = state
        arm()
    }

    func stop() {
        isLive = false
    }

    private func arm() {
        withObservationTracking {
            _ = state.worktrees
            _ = state.scratchWorktrees
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isLive else { return }
                self.count += 1
                self.arm()
            }
        }
    }
}
