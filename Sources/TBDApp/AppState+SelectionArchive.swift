import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+SelectionArchive")

/// Archiving the sidebar selection: the row menu's Archive Selection and the
/// archive shortcut. The decisions are `SelectionArchive`'s; this wires them
/// to live state. `selectedWorktreeIDs` is the one selection source: both
/// native tables sync into it, so it holds rows of both sidebars and both
/// docks, including rows a collapsed section hides.
extension AppState {
    /// Every worktree row in the order a selection's archive runs them:
    /// sidebar order (the Scratch section, then each repo's rows as
    /// `allWorktreesOrdered` walks them), with each row moved after its
    /// descendants so a parent is archived only once its selected children
    /// are. Rows the walk does not reach, such as a failed row, follow in
    /// sibling order and are placed among their relatives the same way.
    ///
    /// It lists every row `findWorktree(id:)` resolves, each exactly once:
    /// `allWorktrees` is that same set of rows, and `childrenFirst` returns
    /// every row it is given. So every candidate `selectionArchiveTargets`
    /// builds is in it.
    var selectionArchiveRunOrder: [UUID] {
        let walked = scratchWorktrees + allWorktreesOrdered
        let walkedIDs = Set(walked.map(\.id))
        let unwalked = allWorktrees
            .filter { !walkedIDs.contains($0.id) }
            .sorted(by: Worktree.precedesSibling)
        return SelectionArchive.childrenFirst(walked + unwalked)
    }

    /// The selection's archivable rows, in run order. An ID that resolves to
    /// no row is skipped, as is every row `SelectionArchive.archivableIDs`
    /// holds back. Each row's facts come from `RowActionMenuActions`, the same
    /// derivations its own menu reads.
    func selectionArchiveTargets() -> [UUID] {
        let candidates = selectedWorktreeIDs
            .compactMap { findWorktree(id: $0) }
            .map { RowActionMenuActions(appState: self, worktree: $0, onRename: {}).archiveCandidate() }
        return SelectionArchive.targets(candidates, runOrder: selectionArchiveRunOrder)
    }

    /// Archive Selection: archive `targetIDs`, resolved when the menu was
    /// built, by `SelectionArchive.route`.
    func archiveSelection(_ targetIDs: [UUID]) async {
        await runArchive(SelectionArchive.route(targetIDs))
    }

    /// Run a selection's archive. One row takes `archiveWorktree(id:)`
    /// unchanged, so it gets the same prompts and alert as the row's own
    /// Archive; several take `archiveInBulk`.
    func runArchive(_ route: SelectionArchive.Route) async {
        switch route {
        case .nothing:
            return
        case .single(let id):
            await archiveWorktree(id: id)
        case .bulk(let ids):
            await archiveInBulk(ids) { [daemonClient] worktree in
                // One call serves every row: the daemon takes a scratch row's
                // `worktree.archive` to the same body as `scratch.archive`
                // (see `archiveWorktree(id:)`).
                try await daemonClient.archiveWorktree(id: worktree.id)
            }
        }
    }

    /// Archive several rows in turn, in the order given, with no prompt and
    /// no per-row alert. `archive` makes one row's archive call: production
    /// passes the daemon's, tests a fake.
    ///
    /// One bulk run at a time: while one runs (`selectionArchiveInFlight`),
    /// another call returns at once and archives nothing, so the row menu and
    /// the shortcut, or the shortcut pressed twice, cannot start two runs
    /// over the same rows.
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
    /// stops the run, and the rows after it are counted as not attempted.
    /// When everything is done, and only if something failed, one alert sums
    /// it up (`SelectionArchive.summary`). A row that has left the state since
    /// the menu was built is not attempted and not counted.
    func archiveInBulk(
        _ targetIDs: [UUID],
        archive: @MainActor (Worktree) async throws -> Void
    ) async {
        guard !selectionArchiveInFlight else {
            logger.info("Ignored a selection archive while another is running")
            return
        }
        selectionArchiveInFlight = true
        defer { selectionArchiveInFlight = false }

        var archived = 0
        var total = 0
        var notAttempted = 0
        var archivedScratch = false
        var failures: [SelectionArchive.Failure] = []
        // A parent's ID → the display name of its first nested worktree that
        // was not archived.
        var heldBackBy: [UUID: String] = [:]
        for (index, id) in targetIDs.enumerated() {
            guard let worktree = findWorktree(id: id) else { continue }
            total += 1
            let reason: String
            var lostConnection = false
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
        if archivedScratch {
            await refreshArchivedScratch()
        }
        guard !failures.isEmpty else { return }
        showAlert(
            SelectionArchive.summary(
                archived: archived, total: total, failures: failures, notAttempted: notAttempted),
            isError: true)
    }
}
