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
/// The same bug class hit the pinned-terminal dock — see the comment on
/// `PinnedTerminalCell.worktree` in `PinnedTerminalDock.swift`.
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

    // MARK: - allWorktrees (the flat scratch-inclusive accessor)

    @Test func allWorktreesIncludesRepoRowsAndScratch() {
        withState { state in
            let repoID = UUID()
            let repoWtID = UUID()
            let scratchID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: repoWtID, repoID: repoID)]]
            state.scratchWorktrees = [makeWorktree(id: scratchID, repoID: nil)]

            #expect(Set(state.allWorktrees.map(\.id)) == Set([repoWtID, scratchID]))
        }
    }
}

/// Cmd+Shift+A routing: scratch spaces must take the scratch-archive path —
/// the repo-worktree `worktree.archive` RPC rejects them with `repoNotFound`.
@MainActor
@Suite("archiveSelectedWorktree routes scratch to the scratch path")
struct ArchiveShortcutRouteTests {

    private func makeWorktree(id: UUID, repoID: UUID?, status: WorktreeStatus = .active) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "test-\(id.uuidString.prefix(8))",
            displayName: "Test \(id.uuidString.prefix(8))",
            branch: "main",
            path: "/tmp/test",
            status: status,
            tmuxServer: "test-server"
        )
    }

    @Test func scratchSelectionRoutesToScratchArchive() {
        let scratchID = UUID()
        let route = AppState.archiveShortcutRoute(
            selectedID: scratchID,
            worktrees: [:],
            scratchWorktrees: [makeWorktree(id: scratchID, repoID: nil)]
        )
        #expect(route == .scratch(scratchID))
    }

    @Test func repoWorktreeSelectionRoutesToWorktreeArchive() {
        let repoID = UUID()
        let wtID = UUID()
        let route = AppState.archiveShortcutRoute(
            selectedID: wtID,
            worktrees: [repoID: [makeWorktree(id: wtID, repoID: repoID)]],
            scratchWorktrees: []
        )
        #expect(route == .worktree(wtID))
    }

    @Test func mainAndCreatingRepoWorktreesRefuseArchive() {
        let repoID = UUID()
        for status: WorktreeStatus in [.main, .creating] {
            let wtID = UUID()
            let route = AppState.archiveShortcutRoute(
                selectedID: wtID,
                worktrees: [repoID: [makeWorktree(id: wtID, repoID: repoID, status: status)]],
                scratchWorktrees: []
            )
            #expect(route == nil)
        }
    }

    @Test func emptySelectionRoutesNowhere() {
        let route = AppState.archiveShortcutRoute(
            selectedID: nil,
            worktrees: [:],
            scratchWorktrees: []
        )
        #expect(route == nil)
    }
}

/// `renameWorktree`'s local update is owned by `applyLocalRename`, which must
/// cover both the repo-grouped dict and `scratchWorktrees` (previously the
/// scratch update was compensated caller-side in WorktreeRowView).
@MainActor
@Suite("Rename updates scratch spaces locally")
struct RenameScratchTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.RenameScratch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func makeWorktree(id: UUID, repoID: UUID?, status: WorktreeStatus = .active) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "test-\(id.uuidString.prefix(8))",
            displayName: "Test \(id.uuidString.prefix(8))",
            branch: "main",
            path: "/tmp/test",
            status: status,
            tmuxServer: "test-server"
        )
    }

    @Test func applyLocalRenameUpdatesScratchRow() {
        withState { state in
            let scratchID = UUID()
            state.scratchWorktrees = [makeWorktree(id: scratchID, repoID: nil)]

            state.applyLocalRename(id: scratchID, displayName: "Renamed Scratch")

            #expect(state.scratchWorktrees.first?.displayName == "Renamed Scratch")
        }
    }

    @Test func applyLocalRenameUpdatesRepoDictRow() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            state.applyLocalRename(id: wtID, displayName: "Renamed WT")

            #expect(state.worktrees[repoID]?.first?.displayName == "Renamed WT")
        }
    }

    @Test func renameCreatingWorktreeUpdatesLocallyWithoutRPC() async {
        // The .creating branch never hits the daemon, so the full async
        // method is exercisable without a connection.
        let suiteName = "TBDAppTests.RenameScratch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)

        let repoID = UUID()
        let wtID = UUID()
        state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID, status: .creating)]]

        await state.renameWorktree(id: wtID, displayName: "Renamed Creating")

        #expect(state.worktrees[repoID]?.first?.displayName == "Renamed Creating")
    }
}
