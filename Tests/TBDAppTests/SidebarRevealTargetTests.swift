import Testing
import Foundation
@testable import TBDApp
import TBDShared

// MARK: - Helpers

private func makeWorktree(id: UUID = UUID(), repoID: UUID, displayName: String) -> Worktree {
    Worktree(
        id: id,
        repoID: repoID,
        name: displayName.lowercased().replacingOccurrences(of: " ", with: "-"),
        displayName: displayName,
        branch: "tbd/\(displayName)",
        path: "/tmp/\(displayName)",
        tmuxServer: "tmux-\(id.uuidString)"
    )
}

// MARK: - Tests

@Suite("AppState.sidebarRevealTarget")
struct SidebarRevealTargetTests {

    @Test("single selection returns that worktree's ID")
    func singleSelectionReturnsWorktreeID() {
        let repoID = UUID()
        let wtID = UUID()
        let wt = makeWorktree(id: wtID, repoID: repoID, displayName: "feat")

        let target = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: [wtID],
            worktrees: [repoID: [wt]],
            selectedRepoID: nil
        )

        #expect(target == wtID)
    }

    @Test("multi-selection returns the UUID-string-sorted-first candidate deterministically")
    func multiSelectionReturnsDeterministicID() {
        let repoID = UUID()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let worktrees: [UUID: [Worktree]] = [
            repoID: [
                makeWorktree(id: id1, repoID: repoID, displayName: "wt1"),
                makeWorktree(id: id2, repoID: repoID, displayName: "wt2"),
                makeWorktree(id: id3, repoID: repoID, displayName: "wt3"),
            ]
        ]

        let target = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: [id1, id2, id3],
            worktrees: worktrees,
            selectedRepoID: nil
        )

        // Expected: the ID whose uuidString sorts first alphabetically.
        let expected = [id1, id2, id3].min(by: { $0.uuidString < $1.uuidString })
        #expect(target == expected)
    }

    @Test("multi-selection is deterministic across calls with same inputs")
    func multiSelectionIsDeterministic() {
        let repoID = UUID()
        let ids = (0..<5).map { _ in UUID() }
        let worktrees: [UUID: [Worktree]] = [
            repoID: ids.map { makeWorktree(id: $0, repoID: repoID, displayName: "wt-\($0.uuidString.prefix(4))") }
        ]
        let selectedSet = Set(ids)

        let first = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: selectedSet,
            worktrees: worktrees,
            selectedRepoID: nil
        )
        let second = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: selectedSet,
            worktrees: worktrees,
            selectedRepoID: nil
        )

        #expect(first == second)
    }

    @Test("no worktree selected but repo selected returns repo ID")
    func repoOnlySelectionReturnsRepoID() {
        let repoID = UUID()

        let target = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: [],
            worktrees: [:],
            selectedRepoID: repoID
        )

        #expect(target == repoID)
    }

    @Test("nothing selected returns nil")
    func nothingSelectedReturnsNil() {
        let target = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: [],
            worktrees: [:],
            selectedRepoID: nil
        )

        #expect(target == nil)
    }
}
