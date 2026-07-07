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
            scratchWorktrees: [],
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
            scratchWorktrees: [],
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
            scratchWorktrees: [],
            selectedRepoID: nil
        )
        let second = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: selectedSet,
            worktrees: worktrees,
            scratchWorktrees: [],
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
            scratchWorktrees: [],
            selectedRepoID: repoID
        )

        #expect(target == repoID)
    }

    @Test("nothing selected returns nil")
    func nothingSelectedReturnsNil() {
        let target = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: [],
            worktrees: [:],
            scratchWorktrees: [],
            selectedRepoID: nil
        )

        #expect(target == nil)
    }

    @Test("all-scratch multi-selection resolves via scratchWorktrees")
    func multiSelectionAllScratchReturnsCandidate() {
        // Scratch spaces live only in `scratchWorktrees`, never the repo dict;
        // a dict-only candidate filter made status-bar reveal a silent no-op
        // for all-scratch multi-selections.
        let scratchIDs = [UUID(), UUID()]
        let scratches = scratchIDs.map { id in
            Worktree(
                id: id,
                repoID: nil,
                name: "scratch-\(id.uuidString.prefix(4))",
                displayName: "Scratch \(id.uuidString.prefix(4))",
                branch: "main",
                path: "/tmp/scratch",
                tmuxServer: "tmux-\(id.uuidString)"
            )
        }

        let target = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: Set(scratchIDs),
            worktrees: [:],
            scratchWorktrees: scratches,
            selectedRepoID: nil
        )

        #expect(target == scratchIDs.min(by: { $0.uuidString < $1.uuidString }))
    }

    @Test("multi-selection with all stale IDs returns nil")
    func multiSelectionAllStaleReturnsNil() {
        let repoID = UUID()
        let staleID1 = UUID()
        let staleID2 = UUID()
        // worktrees dict has a different worktree — neither stale ID is present
        let otherID = UUID()
        let worktrees: [UUID: [Worktree]] = [
            repoID: [makeWorktree(id: otherID, repoID: repoID, displayName: "other")]
        ]

        let target = AppState.sidebarRevealTarget(
            selectedWorktreeIDs: [staleID1, staleID2],
            worktrees: worktrees,
            scratchWorktrees: [],
            selectedRepoID: nil
        )

        #expect(target == nil)
    }
}
