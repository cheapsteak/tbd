import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for back-navigation on archive: when the archived worktree is the
/// *only* selected worktree, `removeArchivedWorktreeFromState` walks back
/// through navigation history to the most recent entry that neither
/// references the archived worktree nor points at gone worktrees. All other
/// cases (not selected, multi-select, no usable history) keep the plain
/// remove-from-selection behavior.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite — TBDApp ships as an unbundled SPM executable, so `UserDefaults.standard`
/// is the running developer's real `TBDApp.plist`. Using it from tests would
/// clobber live UI preferences.
@MainActor
@Suite("Archive navigates back")
struct ArchiveNavigateBackTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.ArchiveNavigateBack.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func makeWorktree(id: UUID, repoID: UUID) -> Worktree {
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

    // MARK: - Sole selection: navigate back to previous entry

    @Test func archivingSolelyFocusedWorktree_navigatesToPreviousEntry() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID)]]

            // History: [A], [B]; B is the current sole selection.
            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [b]

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.selectionOrder == [a])
            #expect(state.navigationEntries[state.navigationIndex] == .worktrees([a]))
        }
    }

    // MARK: - Not selected: behavior unchanged, no navigation

    @Test func archivingNonSelectedWorktree_leavesSelectionUntouched() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID)]]

            state.selectedWorktreeIDs = [a]
            let indexBefore = state.navigationIndex
            let entriesBefore = state.navigationEntries

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.selectionOrder == [a])
            #expect(state.navigationIndex == indexBefore)
            #expect(state.navigationEntries == entriesBefore)
        }
    }

    // MARK: - Multi-select: drop the archived ID, keep the rest, no back-nav

    @Test func archivingWorktreeInMultiSelect_keepsRemainingSelection() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID)]]

            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [a, b]

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.selectionOrder == [a])
            // No back-navigation: the head entry reflects the reduced
            // selection, not an earlier history entry re-applied.
            #expect(state.navigationEntries[state.navigationIndex] == .worktrees([a]))
            #expect(state.navigationIndex == state.navigationEntries.count - 1)
        }
    }

    // MARK: - Skips history entries that reference the archived worktree

    @Test func walkBack_skipsEntriesReferencingArchivedWorktree() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            let c = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID),
                                        makeWorktree(id: c, repoID: repoID)]]

            // History: [A], [B, C] (contains B — must be skipped), [B].
            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [b, c]
            state.selectedWorktreeIDs = [b]

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.selectionOrder == [a])
        }
    }

    // MARK: - Skips history entries whose worktrees no longer exist

    @Test func walkBack_skipsEntriesForGoneWorktrees() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            let gone = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID),
                                        makeWorktree(id: gone, repoID: repoID)]]

            // History: [A], [gone], [B] — then `gone` disappears (e.g. archived
            // earlier from another client).
            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [gone]
            state.selectedWorktreeIDs = [b]
            state.worktrees[repoID]?.removeAll { $0.id == gone }

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.selectionOrder == [a])
        }
    }

    // MARK: - No usable history: selection ends up empty, no crash

    @Test func noUsableHistory_fallsBackToEmptySelection() {
        withState { state in
            let repoID = UUID()
            let b = UUID()
            state.worktrees = [repoID: [makeWorktree(id: b, repoID: repoID)]]

            // Only history entry is the archived worktree itself.
            state.selectedWorktreeIDs = [b]

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.selectionOrder.isEmpty)
        }
    }

    // MARK: - Forward after archive-back must not re-select the archived ID

    @Test func forwardAfterArchiveBack_doesNotReselectArchivedWorktree() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID)]]

            // History: [A], [B]; archive B auto-navigates back to [A] and
            // leaves [B] as (stale) forward history.
            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [b]
            state.removeArchivedWorktreeFromState(id: b)
            #expect(state.selectedWorktreeIDs == [a])
            // The only forward entry is the dead [B] — the toolbar forward
            // button must render disabled, not as an enabled no-op.
            #expect(state.canGoForward == false)

            state.navigateForward()

            // Forward skips the dead [B] entry — selection must not become
            // the archived (now nonexistent) worktree or go empty.
            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.selectionOrder == [a])
        }
    }

    // MARK: - Back flag false when every prior entry is stale

    @Test func archiveBackNav_withOnlyStaleEntriesBehind_disablesBack() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            let gone = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID),
                                        makeWorktree(id: gone, repoID: repoID)]]

            // History: [gone], [A], [B] — then `gone` disappears and B is
            // archived. Back-nav lands on [A]; the only entry behind it is
            // the stale [gone], so canGoBack must be false.
            state.selectedWorktreeIDs = [gone]
            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [b]
            state.worktrees[repoID]?.removeAll { $0.id == gone }

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.canGoBack == false)
        }
    }

    // MARK: - Stale-flag dead button disables itself on first click

    @Test func navigateBack_withFlagsGoneStale_noOpsAndDisablesBack() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let gone = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: gone, repoID: repoID)]]

            // History: [gone], [A]; then `gone` vanishes with no navigation
            // event (e.g. daemon poll), leaving canGoBack stale-true.
            state.selectedWorktreeIDs = [gone]
            state.selectedWorktreeIDs = [a]
            #expect(state.canGoBack == true)
            state.worktrees[repoID]?.removeAll { $0.id == gone }

            state.navigateBack()

            // No usable prior entry: selection untouched, and the dead
            // button disables itself on the first click.
            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.canGoBack == false)
        }
    }

    // MARK: - navigateBack skips stale entries

    @Test func navigateBack_skipsStaleEntries() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let b = UUID()
            let gone = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: b, repoID: repoID),
                                        makeWorktree(id: gone, repoID: repoID)]]

            // History: [A], [gone], [B] — then `gone` disappears.
            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [gone]
            state.selectedWorktreeIDs = [b]
            state.worktrees[repoID]?.removeAll { $0.id == gone }

            state.navigateBack()

            #expect(state.selectedWorktreeIDs == [a])
            #expect(state.selectionOrder == [a])
        }
    }

    // MARK: - navigateForward skips stale entries

    @Test func navigateForward_skipsStaleEntries() {
        withState { state in
            let repoID = UUID()
            let a = UUID()
            let c = UUID()
            let gone = UUID()
            state.worktrees = [repoID: [makeWorktree(id: a, repoID: repoID),
                                        makeWorktree(id: c, repoID: repoID),
                                        makeWorktree(id: gone, repoID: repoID)]]

            // History: [A], [gone], [C] — then `gone` disappears.
            state.selectedWorktreeIDs = [a]
            state.selectedWorktreeIDs = [gone]
            state.selectedWorktreeIDs = [c]
            state.worktrees[repoID]?.removeAll { $0.id == gone }

            state.navigateBack()    // lands on [A], skipping [gone]
            #expect(state.selectedWorktreeIDs == [a])

            state.navigateForward() // skips [gone], lands on [C]

            #expect(state.selectedWorktreeIDs == [c])
            #expect(state.selectionOrder == [c])
        }
    }

    // MARK: - Empty history: no crash

    @Test func emptyHistory_fallsBackToEmptySelection() {
        withState { state in
            let repoID = UUID()
            let b = UUID()
            state.worktrees = [repoID: [makeWorktree(id: b, repoID: repoID)]]

            // Selection seeded without going through didSet recording.
            state.isNavigating = true
            state.selectedWorktreeIDs = [b]
            state.isNavigating = false

            state.removeArchivedWorktreeFromState(id: b)

            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }
}
