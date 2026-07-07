import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Regression tests for `AppState.findWorktree(id:)` resolving repo-less
/// scratch spaces.
///
/// Scratch spaces are stored only in `AppState.scratchWorktrees`, never in the
/// repo-grouped `worktrees` dict. `createScratch()` appends the new row to
/// `scratchWorktrees` and immediately sets `selectedWorktreeIDs = [wt.id]`,
/// which routes the detail pane to `SingleWorktreeView`. That view (and
/// `ContentView.selectedWorktree`, and the PR toolbar) resolve the selected id
/// through `findWorktree`. Before the fix, `findWorktree` searched only
/// `worktrees`, so a freshly created scratch space resolved to nil and the
/// detail pane rendered "Worktree not found" on first run.
///
/// The same bug class hit a second call site: the pinned-terminal dock.
/// `PinnedTerminalCell` (PinnedTerminalDock.swift) previously hand-rolled a
/// worktrees-dict-only lookup, so pins from scratch spaces resolved to nil and
/// the cell rendered "Loading..." forever. It now resolves through
/// `findWorktree`, which this suite covers.
///
/// Constructs `AppState(userDefaults:)` against a unique throwaway suite —
/// `UserDefaults.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("findWorktree resolves scratch spaces")
struct FindWorktreeScratchTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.FindWorktreeScratch.\(UUID().uuidString)"
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

    @Test func findsScratchWorktreeNotInReposDict() {
        withState { state in
            let scratchID = UUID()
            state.scratchWorktrees = [makeWorktree(id: scratchID, repoID: nil)]

            let found = state.findWorktree(id: scratchID)

            #expect(found?.id == scratchID)
            #expect(found?.isScratch == true)
        }
    }

    @Test func stillFindsRepoScopedWorktree() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            #expect(state.findWorktree(id: wtID)?.id == wtID)
        }
    }

    @Test func findsScratchEvenWhenReposDictIsPopulated() {
        withState { state in
            let repoID = UUID()
            let repoWtID = UUID()
            let scratchID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: repoWtID, repoID: repoID)]]
            state.scratchWorktrees = [makeWorktree(id: scratchID, repoID: nil)]

            #expect(state.findWorktree(id: repoWtID)?.id == repoWtID)
            #expect(state.findWorktree(id: scratchID)?.id == scratchID)
        }
    }

    @Test func returnsNilForUnknownID() {
        withState { state in
            state.scratchWorktrees = [makeWorktree(id: UUID(), repoID: nil)]
            #expect(state.findWorktree(id: UUID()) == nil)
        }
    }
}
