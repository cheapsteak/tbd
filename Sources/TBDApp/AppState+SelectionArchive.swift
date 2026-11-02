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
    /// are. Rows the walk does not reach, such as a child of a scratch space,
    /// follow in sibling order and are placed among their relatives the same
    /// way.
    var selectionArchiveRunOrder: [UUID] {
        let walked = scratchWorktrees + allWorktreesOrdered
        let walkedIDs = Set(walked.map(\.id))
        let unwalked = allWorktrees
            .filter { !walkedIDs.contains($0.id) }
            .sorted(by: Worktree.precedesSibling)
        return SelectionArchive.childrenFirst(walked + unwalked)
    }

    /// The selection's archivable rows, in run order. An ID that resolves to
    /// no row is skipped, as is every row `SelectionArchive.isArchivable`
    /// refuses. Each row's facts come from `RowActionMenuActions`, the same
    /// derivations its own menu reads.
    func selectionArchiveTargets() -> [UUID] {
        let selectedIDs = selectedWorktreeIDs
        let candidates = selectedIDs
            .compactMap { findWorktree(id: $0) }
            .map { RowActionMenuActions(appState: self, worktree: $0, onRename: {}).archiveCandidate() }
        return SelectionArchive.targets(candidates, selectedIDs: selectedIDs, runOrder: selectionArchiveRunOrder)
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
                // A scratch row takes the scratch RPC, as `archiveScratch(id:)`
                // does, though the daemon would route it either way.
                if worktree.isScratch {
                    try await daemonClient.archiveScratch(worktreeID: worktree.id)
                } else {
                    try await daemonClient.archiveWorktree(id: worktree.id)
                }
            }
        }
    }

    /// Archive several rows in turn, in the order given, with no prompt and
    /// no per-row alert. `archive` makes one row's archive call: production
    /// passes the daemon's, tests a fake.
    ///
    /// Each success gets the single-row path's settlement,
    /// `removeArchivedWorktreeFromState`, and the Scratch section's Archived
    /// tab is refreshed once at the end if a scratch row went. Each failure
    /// goes through `handleConnectionError`, as on the single-row path, and is
    /// collected; there is no bulk Archive anyway or discard offer. When
    /// everything is done, and only if something failed, one alert sums it
    /// up (`SelectionArchive.summary`). A row that has left the state since
    /// the menu was built is not attempted.
    func archiveInBulk(
        _ targetIDs: [UUID],
        archive: @MainActor (Worktree) async throws -> Void
    ) async {
        var archived = 0
        var attempted = 0
        var archivedScratch = false
        var failures: [SelectionArchive.Failure] = []
        for id in targetIDs {
            guard let worktree = findWorktree(id: id) else { continue }
            attempted += 1
            do {
                try await archive(worktree)
                removeArchivedWorktreeFromState(id: id)
                archived += 1
                if worktree.isScratch { archivedScratch = true }
                logger.info("Archived \(worktree.displayName, privacy: .public) with the selection")
            } catch {
                logger.error(
                    "Failed to archive \(worktree.displayName, privacy: .public) with the selection: \(error, privacy: .public)")
                handleConnectionError(error)
                failures.append(SelectionArchive.Failure(
                    name: worktree.displayName, reason: SelectionArchive.failureReason(error)))
            }
        }
        if archivedScratch {
            await refreshArchivedScratch()
        }
        guard !failures.isEmpty else { return }
        showAlert(
            SelectionArchive.summary(archived: archived, attempted: attempted, failures: failures),
            isError: true)
    }
}
