import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Shared row builder for every suite in this file. Pass `repoID: nil` for a
/// repo-less scratch space.
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

/// Construct `AppState(userDefaults:)` against a unique throwaway suite —
/// `UserDefaults.standard` on this unbundled executable is the developer's
/// real `TBDApp.plist`.
@MainActor
private func withState(_ body: (AppState) -> Void) {
    let suiteName = "TBDAppTests.FindWorktreeScratch.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(AppState(userDefaults: defaults))
}

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
@MainActor
@Suite("findWorktree resolves scratch spaces")
struct FindWorktreeScratchTests {

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
/// `archiveShortcutRoute` takes the caller-resolved selection
/// (`selectedWorktreeIDs.first.flatMap(findWorktree)`), so a stale/unknown
/// selected ID resolves to nil and routes nowhere.
@MainActor
@Suite("archiveSelectedWorktree routes scratch to the scratch path")
struct ArchiveShortcutRouteTests {

    @Test func scratchSelectionRoutesToScratchArchive() {
        let scratchID = UUID()
        let route = AppState.archiveShortcutRoute(
            selectedWorktree: makeWorktree(id: scratchID, repoID: nil)
        )
        #expect(route == .scratch(scratchID))
    }

    @Test func repoWorktreeSelectionRoutesToWorktreeArchive() {
        let wtID = UUID()
        let route = AppState.archiveShortcutRoute(
            selectedWorktree: makeWorktree(id: wtID, repoID: UUID())
        )
        #expect(route == .worktree(wtID))
    }

    @Test func mainAndCreatingRepoWorktreesRefuseArchive() {
        for status: WorktreeStatus in [.main, .creating] {
            let route = AppState.archiveShortcutRoute(
                selectedWorktree: makeWorktree(id: UUID(), repoID: UUID(), status: status)
            )
            #expect(route == nil)
        }
    }

    @Test func emptySelectionRoutesNowhere() {
        #expect(AppState.archiveShortcutRoute(selectedWorktree: nil) == nil)
    }

    @Test func staleSelectedIDRoutesNowhere() {
        withState { state in
            let repoID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: UUID(), repoID: repoID)]]
            state.scratchWorktrees = [makeWorktree(id: UUID(), repoID: nil)]
            // Selection points at a row that no longer exists anywhere.
            state.selectedWorktreeIDs = [UUID()]

            // Same resolution wiring archiveSelectedWorktree uses.
            let route = AppState.archiveShortcutRoute(
                selectedWorktree: state.selectedWorktreeIDs.first
                    .flatMap { state.findWorktree(id: $0) }
            )
            #expect(route == nil)
        }
    }
}

/// `renameWorktree` owns the single optimistic local update (scratch-aware,
/// applied before its RPC) — callers like `WorktreeRowView` must not
/// pre-apply. Exercised through the `.creating` branch, which returns before
/// the daemon RPC so no connection is needed.
@MainActor
@Suite("Rename updates scratch spaces locally")
struct RenameScratchTests {

    @Test func renameCreatingScratchRowUpdatesLocally() async {
        let suiteName = "TBDAppTests.RenameScratch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)

        let scratchID = UUID()
        state.scratchWorktrees = [makeWorktree(id: scratchID, repoID: nil, status: .creating)]

        await state.renameWorktree(id: scratchID, displayName: "Renamed Scratch")

        #expect(state.scratchWorktrees.first?.displayName == "Renamed Scratch")
    }

    @Test func renameCreatingWorktreeUpdatesLocallyWithoutRPC() async {
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

/// `createWorktree` replaces its optimistic placeholder with the daemon row
/// (a different UUID) via `replaceCreationPlaceholder`. A rename the user
/// typed while creation was in flight lives only on the placeholder, so the
/// swap must carry it onto the replacement row (and report it back so the
/// caller can persist it via the rename RPC).
@MainActor
@Suite("Rename typed during creation survives the placeholder swap")
struct CreationPlaceholderRenameTests {

    @Test func renamedPlaceholderCarriesNameOntoDaemonRow() async {
        let suiteName = "TBDAppTests.CreationPlaceholderRename.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)

        let repoID = UUID()
        let placeholderID = UUID()
        var placeholder = makeWorktree(id: placeholderID, repoID: repoID, status: .creating)
        placeholder.displayName = "delicate-coyote"
        state.worktrees = [repoID: [placeholder]]

        // User renames the row mid-creation (renameWorktree's .creating branch).
        await state.renameWorktree(id: placeholderID, displayName: "typed-name")

        let daemonRow = makeWorktree(id: UUID(), repoID: repoID, status: .creating)
        let typedName = state.replaceCreationPlaceholder(
            repoID: repoID,
            placeholderID: placeholderID,
            placeholderName: "delicate-coyote",
            with: daemonRow
        )

        #expect(typedName == "typed-name")
        #expect(state.worktrees[repoID]?.count == 1)
        #expect(state.worktrees[repoID]?.first?.id == daemonRow.id)
        #expect(state.worktrees[repoID]?.first?.displayName == "typed-name")
    }

    @Test func untouchedPlaceholderKeepsDaemonRowName() {
        withState { state in
            let repoID = UUID()
            let placeholderID = UUID()
            var placeholder = makeWorktree(id: placeholderID, repoID: repoID, status: .creating)
            placeholder.displayName = "delicate-coyote"
            state.worktrees = [repoID: [placeholder]]

            let daemonRow = makeWorktree(id: UUID(), repoID: repoID, status: .creating)
            let typedName = state.replaceCreationPlaceholder(
                repoID: repoID,
                placeholderID: placeholderID,
                placeholderName: "delicate-coyote",
                with: daemonRow
            )

            #expect(typedName == nil)
            #expect(state.worktrees[repoID]?.first?.id == daemonRow.id)
            #expect(state.worktrees[repoID]?.first?.displayName == daemonRow.displayName)
        }
    }

    @Test func missingPlaceholderIsANoOp() {
        withState { state in
            let repoID = UUID()
            state.worktrees = [repoID: []]

            let typedName = state.replaceCreationPlaceholder(
                repoID: repoID,
                placeholderID: UUID(),
                placeholderName: "delicate-coyote",
                with: makeWorktree(id: UUID(), repoID: repoID)
            )

            #expect(typedName == nil)
            #expect(state.worktrees[repoID]?.isEmpty == true)
        }
    }
}

/// `archiveScratch` runs the same synchronous cleanup as `archiveWorktree` —
/// `removeArchivedWorktreeFromState` — so the Cmd+Shift+A scratch path gets
/// selection cleanup and a tombstone, not just the daemon delta later. The
/// RPC itself needs a daemon; this verifies the cleanup helper covers scratch
/// rows (the piece `archiveScratch` relies on).
@MainActor
@Suite("Archive cleanup covers scratch spaces")
struct ScratchArchiveCleanupTests {

    @Test func removeArchivedWorktreeFromStateClearsScratchRowSelectionAndTombstones() {
        withState { state in
            let scratchID = UUID()
            state.scratchWorktrees = [makeWorktree(id: scratchID, repoID: nil)]
            state.selectedWorktreeIDs = [scratchID]

            state.removeArchivedWorktreeFromState(id: scratchID)

            #expect(state.scratchWorktrees.isEmpty)
            #expect(!state.selectedWorktreeIDs.contains(scratchID))
            // Synchronous tombstone so an in-flight poll can't re-append a
            // ghost row before the daemon delta lands.
            #expect(state.recentlyArchivedWorktreeIDs[scratchID] != nil)
        }
    }
}
