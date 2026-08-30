import Foundation
import TestSupport
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
    let defaultsSuite = TestDefaultsSuite("FindWorktreeScratch")
    defer { defaultsSuite.tearDown() }
    let defaults = defaultsSuite.defaults
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
/// The same bug class hit the pinned-terminal dock — see the comment in
/// `PinnedTerminalCell.body` in `PinnedTerminalDock.swift`.
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

/// Cmd+Shift+A routing: the route seam only decides refuse-vs-proceed.
/// `archiveWorktree(id:)` is scratch-aware and self-routes scratch rows to
/// the `scratch.archive` RPC; the daemon routes them too, so either door
/// reaches the same body. `archiveShortcutRoute` takes the
/// caller-resolved selection (`selectedWorktreeIDs.first.flatMap(findWorktree)`),
/// so a stale/unknown selected ID resolves to nil and routes nowhere.
@MainActor
@Suite("archiveSelectedWorktree refuse-vs-proceed routing")
struct ArchiveShortcutRouteTests {

    @Test func scratchSelectionProceeds() {
        // Scratch rows proceed through this seam: the daemon creates them
        // `.active`, never `.main`/`.creating`. The one repo-worktree refusal
        // that DOES apply to them, active children, is enforced daemon-side and
        // pre-disabled in the row menu rather than here.
        let scratchID = UUID()
        let target = AppState.archiveShortcutRoute(
            selectedWorktree: makeWorktree(id: scratchID, repoID: nil)
        )
        #expect(target == scratchID)
    }

    @Test func activeRepoWorktreeSelectionProceeds() {
        let wtID = UUID()
        let target = AppState.archiveShortcutRoute(
            selectedWorktree: makeWorktree(id: wtID, repoID: UUID())
        )
        #expect(target == wtID)
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
/// pre-apply. The local-only gate keys on `pendingWorktreeIDs` (client-side
/// creation placeholders the daemon has never heard of), NOT on `.creating`
/// status: a two-phase create leaves the daemon row `.creating` for as long
/// as its hooks run, and renames in that window must go through the RPC.
/// All RPC-path tests inject `renameRPCOverride` — never a live daemon.
@MainActor
@Suite("Rename gate, poll-race re-apply, and rollback")
struct RenameScratchTests {

    private func makeState() -> (AppState, () -> Void) {
        let suite = TestDefaultsSuite("RenameScratch")
        let state = AppState(userDefaults: suite.defaults)
        return (state, { suite.tearDown() })
    }

    @Test func pendingPlaceholderRenamesLocallyWithoutRPC() async {
        let (state, teardown) = makeState()
        defer { teardown() }

        let repoID = UUID()
        let placeholderID = UUID()
        state.worktrees = [repoID: [makeWorktree(id: placeholderID, repoID: repoID, status: .creating)]]
        state.pendingWorktreeIDs = [placeholderID]
        var rpcCalls = 0
        state.renameRPCOverride = { _, _ in rpcCalls += 1 }

        await state.renameWorktree(id: placeholderID, displayName: "Renamed Placeholder")

        #expect(state.worktrees[repoID]?.first?.displayName == "Renamed Placeholder")
        #expect(rpcCalls == 0)
    }

    @Test func daemonKnownCreatingRowTakesRPCPath() async {
        let (state, teardown) = makeState()
        defer { teardown() }

        // Daemon-known row, still `.creating` (hooks running) — NOT pending.
        let repoID = UUID()
        let wtID = UUID()
        state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID, status: .creating)]]
        var renamed: [(UUID, String)] = []
        state.renameRPCOverride = { id, name in renamed.append((id, name)) }

        await state.renameWorktree(id: wtID, displayName: "Renamed Creating")

        #expect(state.worktrees[repoID]?.first?.displayName == "Renamed Creating")
        #expect(renamed.count == 1)
        #expect(renamed.first?.0 == wtID)
        #expect(renamed.first?.1 == "Renamed Creating")
    }

    @Test func renameScratchRowAppliesLocallyAndSendsRPC() async {
        let (state, teardown) = makeState()
        defer { teardown() }

        let scratchID = UUID()
        state.scratchWorktrees = [makeWorktree(id: scratchID, repoID: nil)]
        var rpcCalls = 0
        state.renameRPCOverride = { _, _ in rpcCalls += 1 }

        await state.renameWorktree(id: scratchID, displayName: "Renamed Scratch")

        #expect(state.scratchWorktrees.first?.displayName == "Renamed Scratch")
        #expect(rpcCalls == 1)
    }

    @Test func reappliesAfterRPCSuccessToBeatInterleavedPollRevert() async {
        let (state, teardown) = makeState()
        defer { teardown() }

        let repoID = UUID()
        let wtID = UUID()
        let original = makeWorktree(id: wtID, repoID: repoID)
        state.worktrees = [repoID: [original]]
        // Simulate a poll snapshot captured pre-rename landing while the RPC
        // is in flight: it reverts the optimistic name, then the RPC succeeds.
        state.renameRPCOverride = { _, _ in
            state.worktrees[repoID]?[0].displayName = original.displayName
        }

        await state.renameWorktree(id: wtID, displayName: "New Name")

        #expect(state.worktrees[repoID]?.first?.displayName == "New Name")
    }

    @Test func rollsBackAndAlertsOnRPCFailure() async {
        let (state, teardown) = makeState()
        defer { teardown() }

        struct RenameError: Error {}
        let repoID = UUID()
        let wtID = UUID()
        let original = makeWorktree(id: wtID, repoID: repoID)
        state.worktrees = [repoID: [original]]
        state.renameRPCOverride = { _, _ in throw RenameError() }

        await state.renameWorktree(id: wtID, displayName: "Doomed Name")

        #expect(state.worktrees[repoID]?.first?.displayName == original.displayName)
        #expect(state.alertMessage?.hasPrefix("Rename failed:") == true)
        #expect(state.alertIsError == true)
    }

    @Test func unresolvableIDIsANoOpWithoutRPC() async {
        let (state, teardown) = makeState()
        defer { teardown() }

        // The id resolves nowhere and is not a pending placeholder — e.g.
        // the placeholder was just swapped away. No doomed RPC, no alert.
        state.worktrees = [UUID(): [makeWorktree(id: UUID(), repoID: UUID())]]
        var rpcCalls = 0
        state.renameRPCOverride = { _, _ in rpcCalls += 1 }

        await state.renameWorktree(id: UUID(), displayName: "Ghost")

        #expect(rpcCalls == 0)
        #expect(state.alertMessage == nil)
    }
}

/// `createWorktree` replaces its optimistic placeholder with the daemon row
/// (a different UUID) via `replaceCreationPlaceholder`. A rename the user
/// typed while creation was in flight lives only on the placeholder, so the
/// swap must carry it onto the replacement row (and report it back so the
/// caller can persist it via the rename RPC). The swap also dedupes against
/// a poll that merged the daemon row alongside the preserved placeholder,
/// and returns nil — no row inserted, caller must not select/edit — when
/// both rows are gone (e.g. the repo was removed mid-create).
@MainActor
@Suite("Rename typed during creation survives the placeholder swap")
struct CreationPlaceholderRenameTests {

    @Test func renamedPlaceholderCarriesNameOntoDaemonRow() async {
        let defaultsSuite = TestDefaultsSuite("CreationPlaceholderRename")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        let state = AppState(userDefaults: defaults)

        let repoID = UUID()
        let placeholderID = UUID()
        var placeholder = makeWorktree(id: placeholderID, repoID: repoID, status: .creating)
        placeholder.displayName = "delicate-coyote"
        state.worktrees = [repoID: [placeholder]]
        state.pendingWorktreeIDs = [placeholderID]

        // User renames the row mid-creation (renameWorktree's placeholder
        // branch — pending id, applied locally only).
        await state.renameWorktree(id: placeholderID, displayName: "typed-name")

        let daemonRow = makeWorktree(id: UUID(), repoID: repoID, status: .creating)
        let swap = state.replaceCreationPlaceholder(
            repoID: repoID,
            placeholderID: placeholderID,
            placeholderName: "delicate-coyote",
            with: daemonRow
        )

        #expect(swap?.typedName == "typed-name")
        #expect(state.worktrees[repoID]?.count == 1)
        #expect(state.worktrees[repoID]?.first?.id == daemonRow.id)
        #expect(state.worktrees[repoID]?.first?.displayName == "typed-name")
    }

    /// After the swap carries the typed name onto the daemon row,
    /// `createWorktree` persists it through `renameWorktree(id:displayName:)`
    /// (wt.id is daemon-known and non-pending, so it takes the full RPC path).
    /// A failed persist must surface via the "Rename failed:" alert — the old
    /// inline `daemonClient.renameWorktree` call's catch only logged, so a
    /// non-connection RPC failure silently lost the name. Drives the persist
    /// sub-sequence the create path runs post-swap; the full `createWorktree`
    /// isn't wired to a seam (its `daemonClient.createWorktree` has no
    /// override), so this reproduces the post-swap state directly.
    @Test func createPathPersistRollsBackAndAlertsWhenRenameRPCFails() async {
        let defaultsSuite = TestDefaultsSuite("CreationPlaceholderRename")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        let state = AppState(userDefaults: defaults)

        struct RenameError: Error {}
        let repoID = UUID()
        let placeholderID = UUID()
        var placeholder = makeWorktree(id: placeholderID, repoID: repoID, status: .creating)
        placeholder.displayName = "delicate-coyote"
        state.worktrees = [repoID: [placeholder]]
        state.pendingWorktreeIDs = [placeholderID]

        // User renames the row mid-creation (local-only placeholder branch).
        await state.renameWorktree(id: placeholderID, displayName: "typed-name")

        // Daemon confirms creation: swap carries the typed name onto the real
        // daemon row and the placeholder leaves `pendingWorktreeIDs` (as
        // createWorktree's `defer` does).
        let daemonRow = makeWorktree(id: UUID(), repoID: repoID, status: .creating)
        state.pendingWorktreeIDs.remove(placeholderID)
        let swap = state.replaceCreationPlaceholder(
            repoID: repoID,
            placeholderID: placeholderID,
            placeholderName: "delicate-coyote",
            with: daemonRow
        )
        #expect(swap?.typedName == "typed-name")

        // createWorktree now persists the carried rename through renameWorktree.
        // A failed RPC must alert, not silently log like the old inline call.
        state.renameRPCOverride = { _, _ in throw RenameError() }
        if let typedName = swap?.typedName {
            await state.renameWorktree(id: daemonRow.id, displayName: typedName)
        }

        #expect(state.alertMessage?.hasPrefix("Rename failed:") == true)
        #expect(state.alertIsError == true)
    }

    @Test func untouchedPlaceholderKeepsDaemonRowName() {
        withState { state in
            let repoID = UUID()
            let placeholderID = UUID()
            var placeholder = makeWorktree(id: placeholderID, repoID: repoID, status: .creating)
            placeholder.displayName = "delicate-coyote"
            state.worktrees = [repoID: [placeholder]]

            let daemonRow = makeWorktree(id: UUID(), repoID: repoID, status: .creating)
            let swap = state.replaceCreationPlaceholder(
                repoID: repoID,
                placeholderID: placeholderID,
                placeholderName: "delicate-coyote",
                with: daemonRow
            )

            #expect(swap != nil)
            #expect(swap?.typedName == nil)
            #expect(state.worktrees[repoID]?.first?.id == daemonRow.id)
            #expect(state.worktrees[repoID]?.first?.displayName == daemonRow.displayName)
        }
    }

    @Test func dedupesPollMergedDaemonRowAgainstPreservedPlaceholder() {
        withState { state in
            let repoID = UUID()
            let placeholderID = UUID()
            var placeholder = makeWorktree(id: placeholderID, repoID: repoID, status: .creating)
            placeholder.displayName = "typed-name" // renamed mid-creation
            let other = makeWorktree(id: UUID(), repoID: repoID)
            let daemonRow = makeWorktree(id: UUID(), repoID: repoID, status: .creating)
            // A poll merged the daemon row alongside the preserved placeholder.
            state.worktrees = [repoID: [placeholder, other, daemonRow]]

            let swap = state.replaceCreationPlaceholder(
                repoID: repoID,
                placeholderID: placeholderID,
                placeholderName: "delicate-coyote",
                with: daemonRow
            )

            #expect(swap?.typedName == "typed-name")
            // Exactly one final row, at the placeholder's position.
            let rows = state.worktrees[repoID] ?? []
            #expect(rows.count == 2)
            #expect(rows.first?.id == daemonRow.id)
            #expect(rows.first?.displayName == "typed-name")
            #expect(rows.last?.id == other.id)
        }
    }

    @Test func placeholderGoneButPollMergedRowPresentUpdatesInPlace() {
        withState { state in
            let repoID = UUID()
            let other = makeWorktree(id: UUID(), repoID: repoID)
            var daemonRow = makeWorktree(id: UUID(), repoID: repoID, status: .creating)
            state.worktrees = [repoID: [other, daemonRow]]

            // The RPC result carries fresher fields than the poll-merged row.
            daemonRow.displayName = "fresher-name"
            let swap = state.replaceCreationPlaceholder(
                repoID: repoID,
                placeholderID: UUID(),
                placeholderName: "delicate-coyote",
                with: daemonRow
            )

            #expect(swap != nil)
            #expect(swap?.typedName == nil)
            let rows = state.worktrees[repoID] ?? []
            #expect(rows.count == 2)
            #expect(rows.last?.id == daemonRow.id)
            #expect(rows.last?.displayName == "fresher-name")
        }
    }

    @Test func bothRowsAbsentReturnsNilAndResurrectsNothing() {
        withState { state in
            let repoID = UUID()
            state.worktrees = [repoID: []]

            let swap = state.replaceCreationPlaceholder(
                repoID: repoID,
                placeholderID: UUID(),
                placeholderName: "delicate-coyote",
                with: makeWorktree(id: UUID(), repoID: repoID)
            )

            // nil tells createWorktree not to arm selection/editing for the
            // vanished row.
            #expect(swap == nil)
            #expect(state.worktrees[repoID]?.isEmpty == true)
        }
    }

    @Test func removedRepoReturnsNilAndResurrectsNothing() {
        withState { state in
            let repoID = UUID()
            // Repo removed mid-create: no entry in the dict at all.
            let swap = state.replaceCreationPlaceholder(
                repoID: repoID,
                placeholderID: UUID(),
                placeholderName: "delicate-coyote",
                with: makeWorktree(id: UUID(), repoID: repoID)
            )

            #expect(swap == nil)
            #expect(state.worktrees[repoID] == nil)
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
