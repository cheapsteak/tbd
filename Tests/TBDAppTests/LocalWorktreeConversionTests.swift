import Testing
import Foundation
import TestSupport
@testable import TBDApp
@testable import TBDShared

/// Tier 1: the app-side end of the local/remote boundary. `selectedLocalWorktree`
/// is what every directory-reading view binds to, so these pin that a selection
/// with no checkout on this disk resolves to nil rather than to an empty path.
@Suite @MainActor struct LocalWorktreeConversionTests {

    private func makeWorktree(location: WorktreeLocation, path: String) -> Worktree {
        Worktree(repoID: UUID(), name: "n", displayName: "n", branch: "b",
                 path: path, tmuxServer: "s", location: location)
    }

    /// `UserDefaults.standard` on this unbundled executable is the developer's
    /// real `TBDApp.plist`, so every case gets its own named suite and tears it
    /// down.
    private func withState(_ label: String, _ body: (AppState) -> Void) {
        let suite = TestDefaultsSuite(label)
        defer { suite.tearDown() }
        body(AppState(userDefaults: suite.defaults))
    }

    @Test func selectedLocalWorktreeIsNilForARemoteSelection() {
        withState("LocalWorktreeConversionTests.remote") { state in
            let remote = makeWorktree(
                location: .remote(provider: "agentbox", sessionID: "s-1"), path: "")
            state.worktrees[remote.repoID!] = [remote]
            state.selectedWorktreeIDs = [remote.id]
            #expect(state.selectedLocalWorktree == nil)
        }
    }

    /// The optimistic creation placeholder is local but has no directory yet.
    /// It is the only empty-path row today, and it must not reach a view that
    /// reads a directory.
    @Test func selectedLocalWorktreeIsNilForAnEmptyPathPlaceholder() {
        withState("LocalWorktreeConversionTests.creating") { state in
            let placeholder = makeWorktree(location: .local, path: "")
            state.worktrees[placeholder.repoID!] = [placeholder]
            state.selectedWorktreeIDs = [placeholder.id]
            #expect(state.selectedLocalWorktree == nil)
        }
    }

    @Test func selectedLocalWorktreeWrapsALocalSelection() {
        withState("LocalWorktreeConversionTests.local") { state in
            let local = makeWorktree(location: .local, path: "/tmp/w")
            state.worktrees[local.repoID!] = [local]
            state.selectedWorktreeIDs = [local.id]
            #expect(state.selectedLocalWorktree?.path == "/tmp/w")
            #expect(state.selectedLocalWorktree?.worktree == local)
        }
    }

    /// `RowActionMenu.Context.pathIsEmpty` now reads off the wrapper, so the
    /// row menu hides the path actions for exactly the rows the wrapper
    /// refuses.
    @Test func rowActionContextReportsPathIsEmptyForAnEmptyPathRow() {
        withState("LocalWorktreeConversionTests.rowMenu") { state in
            let placeholder = makeWorktree(location: .local, path: "")
            let actions = RowActionMenuActions(
                appState: state, worktree: placeholder, onRename: {})
            #expect(actions.context().pathIsEmpty)

            let local = makeWorktree(location: .local, path: "/tmp/w")
            let localActions = RowActionMenuActions(
                appState: state, worktree: local, onRename: {})
            #expect(!localActions.context().pathIsEmpty)
        }
    }
}
