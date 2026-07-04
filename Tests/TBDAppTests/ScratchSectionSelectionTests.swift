import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for `AppState.selectScratchSection()` and its mutual exclusivity with
/// `selectedRepoID` / `selectedWorktreeIDs`. Selecting the "Scratch" sidebar
/// section header is a third, parallel selection concept alongside the
/// existing two (`selectedWorktreeIDs` for `List`'s native selection,
/// `selectedRepoID` for repo headers) — an inconsistent combination (e.g.
/// both `selectedRepoID` and `selectedScratchSection` true at once) would
/// make `ContentView`'s if/else detail-pane chain pick the wrong pane.
///
/// Constructs `AppState(userDefaults:)` against a unique throwaway suite per
/// `ArchiveNavigateBackTests`' convention — `UserDefaults.standard` on this
/// unbundled executable is the developer's real `TBDApp.plist`.
@MainActor
@Suite("Scratch section selection")
struct ScratchSectionSelectionTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.ScratchSectionSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func makeWorktree(id: UUID, repoID: UUID?) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "test-\(id.uuidString.prefix(8))",
            displayName: "Test \(id.uuidString.prefix(8))",
            branch: "main",
            path: "/tmp/test",
            status: .active,
            tmuxServer: "test-server"
        )
    }

    @Test func selectScratchSectionSetsFlagAndClearsOtherSelections() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.selectedWorktreeIDs = [wtID]

            state.selectScratchSection()

            #expect(state.selectedScratchSection == true)
            #expect(state.selectedRepoID == nil)
            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }

    @Test func selectingRepoClearsScratchSection() {
        withState { state in
            let repoID = UUID()
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]

            state.selectScratchSection()
            #expect(state.selectedScratchSection == true)

            state.selectRepo(id: repoID)

            #expect(state.selectedScratchSection == false)
            #expect(state.selectedRepoID == repoID)
        }
    }

    @Test func selectingWorktreeClearsScratchSection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            state.selectScratchSection()
            #expect(state.selectedScratchSection == true)

            state.selectedWorktreeIDs = [wtID]

            #expect(state.selectedScratchSection == false)
            #expect(state.selectedWorktreeIDs == [wtID])
        }
    }

    @Test func scratchSectionDefaultsToFalse() {
        withState { state in
            #expect(state.selectedScratchSection == false)
        }
    }

    /// Back/forward navigation entries never encode `.scratchSection` (a
    /// documented scope cut for v1), but applying a `.repo` or `.worktrees`
    /// history entry must still clear a lingering scratch selection so the
    /// two flags never end up simultaneously true.
    @Test func navigatingBackToARepoEntryClearsScratchSection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            // History: [.repo(repoID)] (index 0), [.worktrees([wtID])] (index 1, current).
            state.selectRepo(id: repoID)
            state.selectedWorktreeIDs = [wtID]

            // Scratch section is selected without going through recordNavigation
            // (documented scope cut) — history still points at index 1.
            state.selectScratchSection()
            #expect(state.selectedScratchSection == true)
            #expect(state.canGoBack == true)

            state.navigateBack()

            #expect(state.selectedScratchSection == false)
            #expect(state.selectedRepoID == repoID)
        }
    }

    @Test func navigatingBackToAWorktreesEntryClearsScratchSection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]

            // History: [.worktrees([wtID])] (index 0), [.repo(repoID)] (index 1, current).
            state.selectedWorktreeIDs = [wtID]
            state.selectRepo(id: repoID)

            state.selectScratchSection()
            #expect(state.selectedScratchSection == true)
            #expect(state.canGoBack == true)

            state.navigateBack()

            #expect(state.selectedScratchSection == false)
            #expect(state.selectedWorktreeIDs == [wtID])
        }
    }
}
