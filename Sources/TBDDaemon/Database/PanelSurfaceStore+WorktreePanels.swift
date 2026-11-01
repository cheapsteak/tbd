import Foundation
import GRDB
import os
import TBDShared

private let worktreePanelLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// The worktree's panels (side panel notes spec, "The model" and "Daemon"):
/// one ordered list per worktree in `worktree_panel`, which every workspace
/// tab surface of the worktree carries. A change to the list rewrites every
/// readable surface of the worktree in the transaction that makes it.
extension PanelSurfaceStore {

    /// The worktree's panels, in strip order. A malformed row is skipped
    /// with a logged warning.
    public func worktreePanels(worktreeID: UUID) async throws -> [WorktreePanel] {
        try await writer.read { db in
            try Self.storedWorktreePanels(worktreeKey: worktreeID.uuidString, db: db)
        }
    }

    /// Appends a worktree panel showing `content` unless one already does,
    /// and rewrites every readable surface of the worktree with the new list,
    /// in one transaction. Returns the surfaces it rewrote, in position
    /// order; none when the worktree already had the panel, or has no
    /// surfaces yet, in which case a tab sync joins the list in when it
    /// imports them.
    ///
    /// It selects nothing: each surface keeps the panel in front and its
    /// collapse state, except that one with nothing in front brings the
    /// new list's first panel forward (`PanelSurfaceReducer.adopting`).
    /// Worktree creation opens the initial note this way.
    public func openWorktreePanel(
        worktreeID: UUID, content: WorktreePanelContent, now: Date
    ) async throws -> [WorkspaceTabSurface] {
        try await writer.write { db -> [WorkspaceTabSurface] in
            var panels = try Self.storedWorktreePanels(worktreeKey: worktreeID.uuidString, db: db)
            guard !panels.contains(where: { $0.content == content }) else { return [] }
            panels.append(WorktreePanel(id: UUID(), content: content))
            try Self.writeWorktreePanels(panels, worktreeID: worktreeID, db: db)
            return try Self.rewriteSurfaces(
                worktreeID: worktreeID, worktreePanels: panels, except: nil, db: db, now: now)
        }
    }

    /// Removes the worktree panel showing `content`, inside a caller's write
    /// transaction, and rewrites every readable surface of the worktree with
    /// the remaining list; a surface that had it in front brings its most
    /// recent own panel forward, else the first remaining worktree panel.
    /// Returns the surfaces it rewrote, in position order; none when no
    /// panel showed `content`. `NoteStore.delete` runs it in the transaction
    /// that deletes the note.
    static func removeWorktreePanels(
        showing content: WorktreePanelContent, worktreeID: UUID, now: Date, in db: GRDB.Database
    ) throws -> [WorkspaceTabSurface] {
        let panels = try storedWorktreePanels(worktreeKey: worktreeID.uuidString, db: db)
        let remaining = panels.filter { $0.content != content }
        guard remaining.count != panels.count else { return [] }
        try writeWorktreePanels(remaining, worktreeID: worktreeID, db: db)
        return try rewriteSurfaces(
            worktreeID: worktreeID, worktreePanels: remaining, except: nil, db: db, now: now)
    }

    /// The panels of the worktree whose ID is `worktreeKey`, ordered by
    /// position, against an open transaction. A malformed row is skipped
    /// with a logged warning, and so is a row repeating an earlier row's
    /// content, since a list showing one note twice fails the validator and
    /// would make every surface of the worktree unreadable.
    static func storedWorktreePanels(worktreeKey: String, db: GRDB.Database) throws -> [WorktreePanel] {
        let records = try WorktreePanelRecord
            .filter(Column("worktreeID") == worktreeKey)
            .order(Column("position"), Column("id"))
            .fetchAll(db)
        var panels: [WorktreePanel] = []
        for record in records {
            guard let panel = record.toModel() else { continue }
            guard !panels.contains(where: { $0.content == panel.content }) else {
                worktreePanelLogger.warning(
                    "Skipping worktree_panel row \(record.id, privacy: .public): another panel of its worktree shows the same content")
                continue
            }
            panels.append(panel)
        }
        return panels
    }

    /// Replaces the worktree's `worktree_panel` rows with `panels`, against
    /// an open write transaction: deletes the worktree's rows that `panels`
    /// does not name, and stores each panel with `position` set to its index.
    /// Throws `worktreePanelOwnedByOtherWorktree`, before writing that panel,
    /// when a panel's row belongs to another worktree.
    static func writeWorktreePanels(_ panels: [WorktreePanel], worktreeID: UUID, db: GRDB.Database) throws {
        let worktreeKey = worktreeID.uuidString
        let panelKeys = panels.map(\.id.uuidString)
        try WorktreePanelRecord
            .filter(Column("worktreeID") == worktreeKey)
            .filter(!panelKeys.contains(Column("id")))
            .deleteAll(db)
        for (position, panel) in panels.enumerated() {
            if let owner = try WorktreePanelRecord.fetchOne(db, key: panel.id.uuidString),
               owner.worktreeID != worktreeKey {
                throw PanelSurfaceStoreError.worktreePanelOwnedByOtherWorktree(
                    panelID: panel.id,
                    existingWorktreeID: UUID(uuidString: owner.worktreeID) ?? UUID(),
                    incomingWorktreeID: worktreeID)
            }
            try WorktreePanelRecord(from: panel, worktreeID: worktreeID, position: position).save(db)
        }
    }

    /// Rewrites every readable surface of the worktree but `exceptTabID`'s
    /// with `worktreePanels`, the worktree's new list, against an open write
    /// transaction. Each surface adopts the list
    /// (`PanelSurfaceReducer.adopting`), takes the revision counter's next
    /// value, and keeps its position and `awaitingListing` marker. A row that
    /// cannot be read with the new list is left exactly as it is. Returns the
    /// rewritten surfaces, in position order.
    static func rewriteSurfaces(
        worktreeID: UUID, worktreePanels: [WorktreePanel], except exceptTabID: UUID?,
        db: GRDB.Database, now: Date
    ) throws -> [WorkspaceTabSurface] {
        let records = try WorkspaceTabSurfaceRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .order(Column("position"))
            .fetchAll(db)
            .filter { $0.id != exceptTabID?.uuidString }
        let historiesByTab = try histories(tabKeys: records.map(\.id), db: db)
        var rewritten: [WorkspaceTabSurface] = []
        for record in records {
            guard var surface = record.toModel(
                histories: historiesByTab[record.id] ?? [:], worktreePanels: worktreePanels) else {
                continue
            }
            surface.revision = try nextRevision(db: db)
            try writeSurface(
                surface, position: record.position, awaitingListing: record.awaitingListing,
                db: db, now: now)
            rewritten.append(surface)
        }
        return rewritten
    }
}
