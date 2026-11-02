import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+SelectionArchive")

/// Archiving the sidebar selection: the row menu's Archive Selection and the
/// archive shortcut. The decisions are `SelectionArchive`'s; this wires them
/// to live state. `selectedWorktreeIDs` is the one selection source: the
/// outline and the dock both sync into it, so it holds rows of both,
/// including rows a collapsed section hides.
extension AppState {
    // MARK: - Resolving the selection

    /// The selected IDs that resolve to a row (`findWorktree(id:)`), as rows.
    /// A stale ID, one whose row has gone, is left out.
    var selectedWorktreeRows: [Worktree] {
        selectedWorktreeIDs.compactMap { findWorktree(id: $0) }
    }

    /// Each selected row's facts for `SelectionArchive.archivableIDs`. They
    /// come from `RowActionMenuActions`, the same derivations each row's own
    /// menu reads.
    private func selectionArchiveCandidates() -> [SelectionArchive.Candidate] {
        selectedWorktreeRows.map {
            RowActionMenuActions(appState: self, worktree: $0, onRename: {}).archiveCandidate()
        }
    }

    /// Whether at least one selected row can be archived with the selection.
    /// It is all the row menu reads, when it is built, to enable Archive
    /// Selection. It judges the selected rows alone, so building the menu
    /// never walks the sidebar.
    func selectionHasArchivableRow() -> Bool {
        !SelectionArchive.archivableIDs(selectionArchiveCandidates()).isEmpty
    }

    /// Every worktree row in the order a selection's archive runs them: the
    /// Scratch section, then the sidebar's own walk (`sidebarWalk`) in its
    /// children-first order, which lists each row after its nested
    /// worktrees, so a parent is archived only once its selected children
    /// are. Taken from that walk rather than sorted apart from it, so the run
    /// order cannot drift from the order the sidebar shows.
    ///
    /// Rows the walk does not reach follow in sibling order, a failed row
    /// among them: each such row whose parent the walk did reach, or that has
    /// no parent, is walked children first from there, so the active
    /// worktrees nested under a failed row still come before it. A row whose
    /// parent links loop is reached from no such row and follows last, as
    /// does a row deeper than the walk's depth cap below one of them. A row
    /// deeper than the cap below a row the walk reached comes after its
    /// ancestors; the sidebar does not draw it either.
    ///
    /// It lists every row `findWorktree(id:)` resolves, each exactly once:
    /// `allWorktrees` is that same set of rows, and every row the walk leaves
    /// out is placed once after it. So every candidate
    /// `selectionArchiveTargets` builds is in it. It walks every row, so it
    /// is read when an archive starts, never when a menu is built.
    var selectionArchiveRunOrder: [UUID] {
        let walked = scratchWorktrees + sidebarWalk(.childrenFirst)
        let walkedIDs = Set(walked.map(\.id))
        let unwalked = allWorktrees
            .filter { !walkedIDs.contains($0.id) }
            .sorted(by: Worktree.precedesSibling)
        let unwalkedIDs = Set(unwalked.map(\.id))
        // A row whose parent the walk also left out is reached, if at all,
        // from that parent.
        let starts = unwalked.filter { row in
            guard let parentID = row.parentWorktreeID else { return true }
            return !unwalkedIDs.contains(parentID)
        }
        var rest: [Worktree] = []
        for row in starts {
            appendSubtree(row, depth: 0, order: .childrenFirst, into: &rest)
        }
        let placedIDs = Set(rest.map(\.id))
        rest += unwalked.filter { !placedIDs.contains($0.id) }
        return (walked + rest).map(\.id)
    }

    /// The selection's archivable rows, in run order
    /// (`selectionArchiveRunOrder`). An ID that resolves to no row is
    /// skipped, as is every row `SelectionArchive.archivableIDs` holds back.
    /// Read when an archive starts, since the run order walks every row.
    func selectionArchiveTargets() -> [UUID] {
        SelectionArchive.targets(selectionArchiveCandidates(), runOrder: selectionArchiveRunOrder)
    }

    // MARK: - Running an archive

    /// Archive Selection, picked from the row menu. The targets are resolved
    /// from the live selection when the item is picked, in run order
    /// (`selectionArchiveTargets`); the menu, when it was built, only judged
    /// whether any could go. They run by `SelectionArchive.route`: one row
    /// through `archiveWorktree(id:)`, several through the bulk run. A
    /// selection that changed under the open menu can leave none, and that
    /// is refused with `refusalBeep`.
    func archiveSelection() {
        startArchive(SelectionArchive.route(selectionArchiveTargets()))
    }

    /// Start `route` for a gesture, the row menu's Archive Selection or the
    /// archive shortcut: a refusal plays `refusalBeep` at once, an archive
    /// runs in a task of its own (`runArchive`), and `.nothing` does nothing.
    func startArchive(_ route: SelectionArchive.Route) {
        switch route {
        case .nothing:
            return
        case .refuse:
            refusalBeep()
        case .single, .bulk:
            Task { await runArchive(route) }
        }
    }

    /// Run a selection's archive. One row takes `archiveWorktree(id:)`
    /// unchanged, so it gets the same prompts and alert as the row's own
    /// Archive; several take `archiveInBulk`. `.nothing` and `.refuse`
    /// archive nothing: a refusal's beep is the gesture's, played before any
    /// task starts (`startArchive`).
    func runArchive(_ route: SelectionArchive.Route) async {
        switch route {
        case .nothing, .refuse:
            return
        case .single(let id):
            await archiveWorktree(id: id)
        case .bulk(let ids):
            await archiveInBulk(ids) { worktree in
                // One call serves every row: the daemon takes a scratch row's
                // `worktree.archive` to the same body as `scratch.archive`
                // (see `archiveWorktree(id:)`).
                try await self.worktreeArchiver(worktree.id, false, false)
            }
        }
    }

    /// Whether a running bulk archive still owns `id`
    /// (`selectionArchivePendingIDs`), so a single-row archive must leave it
    /// to the run. When it does, this plays `refusalBeep` and the caller
    /// sends nothing; the run archives the row, or says why not, in its own
    /// turn.
    func refuseArchiveOwnedBySelectionRun(_ id: UUID) -> Bool {
        guard selectionArchivePendingIDs.contains(id) else { return false }
        logger.info("Refused archiving \(id, privacy: .public): a selection archive has yet to finish it")
        refusalBeep()
        return true
    }

    /// Archive several rows in turn, in the order given, with no prompt and
    /// no per-row alert. `archive` makes one row's archive call: production
    /// passes `worktreeArchiver`, tests a fake.
    ///
    /// One bulk run at a time: while one runs (`selectionArchiveInFlight`),
    /// another call archives nothing and plays `refusalBeep`, so the row menu
    /// and the shortcut, or the shortcut pressed twice, cannot start two runs
    /// over the same rows, and the second gesture is not dropped in silence.
    /// While a run goes, the rows it has yet to finish are in
    /// `selectionArchivePendingIDs`, and the single-row archives refuse them
    /// (`refuseArchiveOwnedBySelectionRun`), so no other path archives a row
    /// the run still owns.
    ///
    /// Each success gets the single-row path's settlement,
    /// `removeArchivedWorktreeFromState`, and the Scratch section's Archived
    /// tab is refreshed once at the end if a scratch row went. Each failure
    /// goes through `handleConnectionError`, as on the single-row path, and is
    /// collected; there is no bulk Archive anyway or discard offer. A row
    /// that was not archived holds back its parent: when the parent's turn
    /// comes it is skipped without an RPC, since the daemon would refuse it
    /// for its active child, and collected with a reason naming that child
    /// (`SelectionArchive.nestedNotArchivedReason`), which in turn holds back
    /// the grandparent. A failure that is a lost connection to the daemon
    /// stops the run: the rows after it are counted as not attempted, and the
    /// Archived tab is not refreshed, since that call would fail too. When
    /// everything is done, and only if something failed, one alert sums it up
    /// (`SelectionArchive.summary`). A row that has left the state since the
    /// run's targets were resolved is not attempted and not counted.
    func archiveInBulk(
        _ targetIDs: [UUID],
        archive: @MainActor (Worktree) async throws -> Void
    ) async {
        guard !selectionArchiveInFlight else {
            logger.info("Refused a selection archive while another is running")
            refusalBeep()
            return
        }
        selectionArchiveInFlight = true
        selectionArchivePendingIDs.formUnion(targetIDs)
        defer {
            selectionArchiveInFlight = false
            // The rows a lost connection left unattempted.
            selectionArchivePendingIDs.subtract(targetIDs)
        }

        var archived = 0
        var total = 0
        var notAttempted = 0
        var archivedScratch = false
        var lostConnection = false
        var failures: [SelectionArchive.Failure] = []
        // A parent's ID → the display name of its first nested worktree that
        // was not archived.
        var heldBackBy: [UUID: String] = [:]
        for (index, id) in targetIDs.enumerated() {
            // The row's turn is over when this pass ends, however it ends.
            defer { selectionArchivePendingIDs.remove(id) }
            guard let worktree = findWorktree(id: id) else { continue }
            total += 1
            let reason: String
            if let nestedName = heldBackBy[id] {
                reason = SelectionArchive.nestedNotArchivedReason(nestedName)
                logger.info(
                    "Skipped \(worktree.displayName, privacy: .public) with the selection: \(nestedName, privacy: .public) was not archived")
            } else {
                do {
                    try await archive(worktree)
                    removeArchivedWorktreeFromState(id: id)
                    archived += 1
                    if worktree.isScratch { archivedScratch = true }
                    logger.info("Archived \(worktree.displayName, privacy: .public) with the selection")
                    continue
                } catch {
                    logger.error(
                        "Failed to archive \(worktree.displayName, privacy: .public) with the selection: \(error, privacy: .public)")
                    handleConnectionError(error)
                    reason = SelectionArchive.failureReason(error)
                    lostConnection = Self.isDisconnectError(error)
                }
            }
            failures.append(SelectionArchive.Failure(name: worktree.displayName, reason: reason))
            if let parentID = worktree.parentWorktreeID, heldBackBy[parentID] == nil {
                heldBackBy[parentID] = worktree.displayName
            }
            if lostConnection {
                notAttempted = targetIDs[(index + 1)...].filter { findWorktree(id: $0) != nil }.count
                total += notAttempted
                break
            }
        }
        if archivedScratch && !lostConnection {
            await refreshArchivedScratch()
        }
        guard !failures.isEmpty else { return }
        showAlert(
            SelectionArchive.summary(
                archived: archived, total: total, failures: failures, notAttempted: notAttempted),
            isError: true)
    }
}
