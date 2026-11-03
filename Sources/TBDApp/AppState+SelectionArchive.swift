import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+SelectionArchive")

/// One bulk-run archive call that has ended: the row as it was when the call
/// started, and the error, if the call failed.
private struct BulkArchiveCall: Sendable {
    let worktree: Worktree
    let error: (any Error)?
}

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
    /// Archive; several take `archiveInBulk`, which runs their calls side by
    /// side. `.nothing` and `.refuse` archive nothing: a refusal's beep is the
    /// gesture's, played before any task starts (`startArchive`).
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

    /// Archive several rows with no prompt and no per-row alert, up to
    /// `SelectionArchive.maxConcurrentArchives` calls at once. `targetIDs`
    /// come in run order (`selectionArchiveTargets`). `archive` makes one
    /// row's call: production passes `worktreeArchiver`, tests a fake. The
    /// calls overlap because each one gives up the main actor while it waits
    /// for the daemon.
    ///
    /// `SelectionArchive.BulkSchedule` decides what each row does and when,
    /// and a task group runs the calls: the run starts every row whose turn
    /// has come while a slot is free, waits for the next call to end, settles
    /// it, and then starts whatever that made ready. A row's turn comes once
    /// its selected children before it in run order are done, so a parent's
    /// call starts only after theirs end, and ready rows start in run order.
    ///
    /// One bulk run at a time: while one runs (`selectionArchiveInFlight`),
    /// another call archives nothing and plays `refusalBeep`, so the row menu
    /// and the shortcut, or the shortcut pressed twice, cannot start two runs
    /// over the same rows, and the second gesture is not dropped in silence.
    /// While a run goes, the rows it has yet to finish are in
    /// `selectionArchivePendingIDs`, and the single-row archives refuse them
    /// (`refuseArchiveOwnedBySelectionRun`), so no other path archives a row
    /// the run still owns. A row leaves the set when its own call ends, when
    /// it is skipped or found gone at its turn, or when the run gives up on
    /// it.
    ///
    /// Each success gets the single-row path's settlement,
    /// `removeArchivedWorktreeFromState`, as soon as its call returns, so rows
    /// leave the sidebar as their calls end, and the Scratch section's
    /// Archived tab is refreshed once at the end if a scratch row went. Each
    /// failure goes through `handleConnectionError`, as on the single-row
    /// path, and is collected; there is no bulk Archive anyway or discard
    /// offer. A row that was not archived holds back its parent: the parent
    /// is skipped without an RPC, since the daemon would refuse it for its
    /// active child, and collected with a reason naming that child
    /// (`SelectionArchive.nestedNotArchivedReason`), which in turn holds back
    /// the grandparent. A failure that is a lost connection to the daemon
    /// stops new rows from starting: the calls already in flight finish and
    /// are counted, archived or failed, the rows never started are counted as
    /// not attempted, and the Archived tab is not refreshed, since that call
    /// would fail too. When everything is done, and only if something failed,
    /// one alert sums it up (`SelectionArchive.summary`), listing the failures
    /// in run order rather than the order the calls ended in, so the same
    /// outcome always reads the same. A row that has left the state by its
    /// turn is not attempted and not counted.
    func archiveInBulk(
        _ targetIDs: [UUID],
        archive: @escaping @Sendable @MainActor (Worktree) async throws -> Void
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
            // Whatever the run did not settle row by row.
            selectionArchivePendingIDs.subtract(targetIDs)
        }

        var schedule = SelectionArchive.BulkSchedule(targetIDs.map { id in
            SelectionArchive.BulkSchedule.Target(id: id, parentID: findWorktree(id: id)?.parentWorktreeID)
        })
        var archived = 0
        var total = 0
        var notAttempted = 0
        var archivedScratch = false
        var lostConnection = false
        // Keyed by row, and listed in run order at the end.
        var failures: [UUID: SelectionArchive.Failure] = [:]

        await withTaskGroup(of: BulkArchiveCall.self) { group in
            while true {
                // Act on every row whose turn has come: start it while a slot
                // is free, or skip it if a nested worktree stayed.
                while !lostConnection, let turn = schedule.nextTurn() {
                    let id = turn.id
                    guard let worktree = findWorktree(id: id) else {
                        schedule.record(id, .vanished)
                        selectionArchivePendingIDs.remove(id)
                        continue
                    }
                    total += 1
                    switch turn {
                    case .start:
                        schedule.begin(id)
                        group.addTask {
                            do {
                                try await archive(worktree)
                                return BulkArchiveCall(worktree: worktree, error: nil)
                            } catch {
                                return BulkArchiveCall(worktree: worktree, error: error)
                            }
                        }
                    case .skip(_, let nestedName):
                        logger.info(
                            "Skipped \(worktree.displayName, privacy: .public) with the selection: \(nestedName, privacy: .public) was not archived")
                        failures[id] = SelectionArchive.Failure(
                            name: worktree.displayName,
                            reason: SelectionArchive.nestedNotArchivedReason(nestedName))
                        schedule.record(id, .notArchived(name: worktree.displayName))
                        selectionArchivePendingIDs.remove(id)
                    }
                }

                // Settle the next call to end.
                guard let call = await group.next() else { break }
                let worktree = call.worktree
                if let error = call.error {
                    logger.error(
                        "Failed to archive \(worktree.displayName, privacy: .public) with the selection: \(error, privacy: .public)")
                    handleConnectionError(error)
                    failures[worktree.id] = SelectionArchive.Failure(
                        name: worktree.displayName, reason: SelectionArchive.failureReason(error))
                    schedule.record(worktree.id, .notArchived(name: worktree.displayName))
                    if Self.isDisconnectError(error), !lostConnection {
                        // Start nothing more. The calls in flight still end
                        // here and count; the rows never started are given up.
                        lostConnection = true
                        let givenUp = schedule.unstarted
                        notAttempted = givenUp.filter { findWorktree(id: $0) != nil }.count
                        total += notAttempted
                        selectionArchivePendingIDs.subtract(givenUp)
                        logger.error(
                            "Stopped the selection archive: lost the connection to the daemon, \(notAttempted, privacy: .public) row(s) not attempted")
                    }
                } else {
                    removeArchivedWorktreeFromState(id: worktree.id)
                    archived += 1
                    if worktree.isScratch { archivedScratch = true }
                    schedule.record(worktree.id, .archived)
                    logger.info("Archived \(worktree.displayName, privacy: .public) with the selection")
                }
                selectionArchivePendingIDs.remove(worktree.id)
            }
        }

        if archivedScratch && !lostConnection {
            await refreshArchivedScratch()
        }
        let failuresInRunOrder = schedule.order.compactMap { failures[$0] }
        guard !failuresInRunOrder.isEmpty else { return }
        showAlert(
            SelectionArchive.summary(
                archived: archived, total: total, failures: failuresInRunOrder, notAttempted: notAttempted),
            isError: true)
    }
}
