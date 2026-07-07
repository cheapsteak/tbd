import Testing
import Foundation
@testable import TBDApp
import TBDShared

// MARK: - Helpers

private func makeRepo(id: UUID = UUID(), displayName: String) -> Repo {
    Repo(id: id, path: "/tmp/\(displayName)", displayName: displayName)
}

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

@Suite("StatusBarView.focusLabel")
struct StatusBarFocusLabelTests {

    @Test("single selection with repo found shows repo/worktree label")
    func singleSelectionRepoFound() {
        let repoID = UUID()
        let wtID = UUID()
        let repo = makeRepo(id: repoID, displayName: "my-repo")
        let wt = makeWorktree(id: wtID, repoID: repoID, displayName: "feat-branch")

        let label = StatusBarView.focusLabel(
            selectedWorktreeIDs: [wtID],
            worktrees: [repoID: [wt]],
            scratchWorktrees: [],
            repos: [repo],
            selectedRepoID: nil
        )

        #expect(label == "my-repo / feat-branch")
    }

    @Test("single selection when repo lookup fails shows just worktree name")
    func singleSelectionRepoMissing() {
        let wtID = UUID()
        let unknownRepoID = UUID()
        let wt = makeWorktree(id: wtID, repoID: unknownRepoID, displayName: "feat-branch")

        let label = StatusBarView.focusLabel(
            selectedWorktreeIDs: [wtID],
            worktrees: [unknownRepoID: [wt]],
            scratchWorktrees: [],
            repos: [],  // no repos — lookup will fail
            selectedRepoID: nil
        )

        #expect(label == "feat-branch")
    }

    @Test("single scratch-space selection resolves via scratchWorktrees")
    func singleScratchSelection() {
        let wtID = UUID()
        let scratch = Worktree(
            id: wtID,
            repoID: nil,
            name: "scratch-1",
            displayName: "Scratch 1",
            branch: "main",
            path: "/tmp/scratch-1",
            tmuxServer: "tmux-\(wtID.uuidString)"
        )

        let label = StatusBarView.focusLabel(
            selectedWorktreeIDs: [wtID],
            worktrees: [:],
            scratchWorktrees: [scratch],
            repos: [],
            selectedRepoID: nil
        )

        #expect(label == "Scratch 1")
    }

    @Test("multi-selection shows count label")
    func multiSelectionShowsCount() {
        let repoID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let worktrees = ids.map { makeWorktree(id: $0, repoID: repoID, displayName: "wt-\($0.uuidString.prefix(4))") }

        let label = StatusBarView.focusLabel(
            selectedWorktreeIDs: Set(ids),
            worktrees: [repoID: worktrees],
            scratchWorktrees: [],
            repos: [],
            selectedRepoID: nil
        )

        #expect(label == "3 worktrees")
    }

    @Test("repo selected shows repo name")
    func repoSelectedShowsName() {
        let repoID = UUID()
        let repo = makeRepo(id: repoID, displayName: "acme")

        let label = StatusBarView.focusLabel(
            selectedWorktreeIDs: [],
            worktrees: [:],
            scratchWorktrees: [],
            repos: [repo],
            selectedRepoID: repoID
        )

        #expect(label == "acme")
    }

    @Test("nothing selected returns nil")
    func nothingSelectedReturnsNil() {
        let label = StatusBarView.focusLabel(
            selectedWorktreeIDs: [],
            worktrees: [:],
            scratchWorktrees: [],
            repos: [],
            selectedRepoID: nil
        )

        #expect(label == nil)
    }

    @Test("repo selected but repo not found returns nil")
    func repoSelectedButMissingReturnsNil() {
        let label = StatusBarView.focusLabel(
            selectedWorktreeIDs: [],
            worktrees: [:],
            scratchWorktrees: [],
            repos: [],
            selectedRepoID: UUID()  // unknown ID
        )

        #expect(label == nil)
    }
}

@Suite("StatusBarView.leftLabelBehavior")
struct StatusBarLeftLabelBehaviorTests {

    @Test("single worktree selected copies its path with path tooltip")
    func singleWorktreeCopiesPath() {
        let behavior = StatusBarView.leftLabelBehavior(selectedWorktreePath: "/tmp/feat-branch")

        #expect(behavior == .copyPath("/tmp/feat-branch"))
        #expect(behavior.tooltip == "/tmp/feat-branch")
    }

    @Test("no single worktree selected reveals in sidebar")
    func noSingleWorktreeReveals() {
        let behavior = StatusBarView.leftLabelBehavior(selectedWorktreePath: nil)

        #expect(behavior == .revealInSidebar)
        #expect(behavior.tooltip == "Reveal in sidebar")
    }
}
