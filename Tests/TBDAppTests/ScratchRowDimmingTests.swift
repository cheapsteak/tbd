import Testing
import Foundation
@testable import TBDApp
@testable import TBDShared

/// Direct, falsifiable proof of `WorktreeRowView`'s scratch-row dimming rule,
/// mirroring `ScratchSectionVisibleTests`'s pattern of testing the extracted
/// pure function instead of live view behavior. Exercises
/// `AppState.scratchRowIsDimmed` in isolation — no SwiftUI render, no
/// `FileManager` I/O — so a regression in the promoted/missing-dir interplay
/// fails this test immediately instead of surfacing as a silently-wrong
/// opacity in the sidebar.
@MainActor
@Suite("scratchRowIsDimmed gate")
struct ScratchRowDimmingTests {
    private func makeWorktree(
        repoID: UUID?,
        promotedToRepoID: UUID? = nil
    ) -> Worktree {
        Worktree(
            repoID: repoID, name: "s", displayName: "s", branch: "",
            path: "/tmp/scratch-\(UUID().uuidString)", tmuxServer: "tbd-scratch",
            promotedToRepoID: promotedToRepoID)
    }

    @Test("un-promoted scratch with a missing directory dims")
    func unpromotedScratchMissingDirDims() {
        let worktree = makeWorktree(repoID: nil)
        #expect(AppState.scratchRowIsDimmed(worktree, directoryExists: false))
    }

    @Test("promoted scratch with a missing directory does NOT dim")
    func promotedScratchMissingDirDoesNotDim() {
        let worktree = makeWorktree(repoID: nil, promotedToRepoID: UUID())
        #expect(!AppState.scratchRowIsDimmed(worktree, directoryExists: false))
    }

    @Test("un-promoted scratch with its directory present does NOT dim")
    func unpromotedScratchDirPresentDoesNotDim() {
        let worktree = makeWorktree(repoID: nil)
        #expect(!AppState.scratchRowIsDimmed(worktree, directoryExists: true))
    }

    @Test("non-scratch worktree never dims, regardless of promoted/dir state")
    func nonScratchWorktreeNeverDims() {
        let worktree = makeWorktree(repoID: UUID(), promotedToRepoID: nil)
        #expect(!AppState.scratchRowIsDimmed(worktree, directoryExists: false))
        #expect(!AppState.scratchRowIsDimmed(worktree, directoryExists: true))

        let promotedButNonScratch = makeWorktree(repoID: UUID(), promotedToRepoID: UUID())
        #expect(!AppState.scratchRowIsDimmed(promotedButNonScratch, directoryExists: false))
    }
}
