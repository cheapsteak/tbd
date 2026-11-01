import Foundation
import GRDB
import TBDShared

@testable import TBDDaemonLib

extension TBDDatabase {
    /// Appends a worktree panel showing `content` to the worktree's list,
    /// unless one already does, and rewrites every readable surface of the
    /// worktree with the new list, in one write transaction. Returns the
    /// surfaces it rewrote, in position order; none when the list already
    /// showed `content` or the worktree has no surfaces.
    ///
    /// A fixture for a worktree whose panels are already open. It stores the
    /// list as `PanelSurfaceStore.applyReducing` does when an operation
    /// changes it (`writeWorktreePanels`, then `rewriteSurfaces`), without
    /// needing a tab to apply the operation to.
    @discardableResult
    func openWorktreePanelForTests(
        worktreeID: UUID, content: WorktreePanelContent, now: Date = Date()
    ) async throws -> [WorkspaceTabSurface] {
        try await writerForTests.write { dbc -> [WorkspaceTabSurface] in
            var panels = try PanelSurfaceStore.storedWorktreePanels(
                worktreeKey: worktreeID.uuidString, db: dbc)
            guard !panels.contains(where: { $0.content == content }) else { return [] }
            panels.append(WorktreePanel(id: UUID(), content: content))
            try PanelSurfaceStore.writeWorktreePanels(panels, worktreeID: worktreeID, db: dbc)
            return try PanelSurfaceStore.rewriteSurfaces(
                worktreeID: worktreeID, worktreePanels: panels, except: nil, db: dbc, now: now)
        }
    }
}
