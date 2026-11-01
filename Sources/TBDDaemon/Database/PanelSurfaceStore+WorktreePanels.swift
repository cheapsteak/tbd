import Foundation
import GRDB
import os
import TBDShared

private let worktreePanelLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// A tab whose surface `PanelSurfaceStore.openWorktreePanel(seeding:)`
/// writes open on the panel it opens, when the tab has no surface yet:
/// worktree creation's main tab, so the starter note shows beside the
/// primary terminal while a tab a sync imports later starts collapsed.
public struct SurfaceSeed: Sendable, Equatable {
    public let tabID: WorkspaceTabID
    public let primary: PrimaryContent
    /// The tab's index in the tab bar, stored in the `position` column.
    public let position: Int

    public init(tabID: WorkspaceTabID, primary: PrimaryContent, position: Int) {
        self.tabID = tabID
        self.primary = primary
        self.position = position
    }
}

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

    /// The worktree's readable surfaces and its panels, in one read, so the
    /// two always agree: `panel.get`'s answer. `tabID` present narrows the
    /// surfaces to that tab's, and to none when it has no readable surface
    /// under this worktree; absent returns every surface of the worktree,
    /// ordered by position. Unreadable rows are skipped as `surfaces` skips
    /// them, and the panels are returned either way.
    public func panelSnapshot(
        worktreeID: UUID, tabID: UUID?
    ) async throws -> (tabs: [WorkspaceTabSurface], worktreePanels: [WorktreePanel]) {
        try await writer.read { db -> (tabs: [WorkspaceTabSurface], worktreePanels: [WorktreePanel]) in
            let worktreeKey = worktreeID.uuidString
            let worktreePanels = try Self.storedWorktreePanels(worktreeKey: worktreeKey, db: db)
            var request = WorkspaceTabSurfaceRecord.filter(Column("worktreeID") == worktreeKey)
            if let tabID {
                request = request.filter(Column("id") == tabID.uuidString)
            }
            let records = try request.order(Column("position")).fetchAll(db)
            let historiesByTab = try Self.histories(tabKeys: records.map(\.id), db: db)
            let tabs = records.compactMap {
                $0.toModel(histories: historiesByTab[$0.id] ?? [:], worktreePanels: worktreePanels)
            }
            return (tabs: tabs, worktreePanels: worktreePanels)
        }
    }

    /// Appends a worktree panel showing `content` unless one already does,
    /// and rewrites every readable surface of the worktree with the new list,
    /// in one transaction. Returns the surfaces it rewrote, in position
    /// order, then the seeded surface when it wrote one. It rewrites none
    /// when the worktree already had the panel, or has no surfaces yet, in
    /// which case a tab sync joins the list in when it imports them.
    ///
    /// It selects nothing: each surface keeps the panel in front and its
    /// collapse state, except that one with nothing in front brings the
    /// new list's first panel forward (`PanelSurfaceReducer.adopting`).
    ///
    /// With `seed`, the same transaction then writes that tab's surface open,
    /// with this panel in front, when the tab has no row yet (see
    /// `SurfaceSeed`). Worktree creation opens the initial note this way, for
    /// the main tab, so no tab sync can import the tab collapsed between the
    /// open and the seed.
    public func openWorktreePanel(
        worktreeID: UUID, content: WorktreePanelContent, seeding seed: SurfaceSeed? = nil, now: Date
    ) async throws -> [WorkspaceTabSurface] {
        try await writer.write { db -> [WorkspaceTabSurface] in
            var panels = try Self.storedWorktreePanels(worktreeKey: worktreeID.uuidString, db: db)
            var written: [WorkspaceTabSurface] = []
            if !panels.contains(where: { $0.content == content }) {
                panels.append(WorktreePanel(id: UUID(), content: content))
                try Self.writeWorktreePanels(panels, worktreeID: worktreeID, db: db)
                written = try Self.rewriteSurfaces(
                    worktreeID: worktreeID, worktreePanels: panels, except: nil, db: db, now: now)
            }
            if let seed, let seeded = try Self.seedSurface(
                seed, worktreeID: worktreeID, showing: content, now: now, in: db) {
                written.append(seeded)
            }
            return written
        }
    }

    /// Writes `seed`'s tab a surface, open, with the worktree panel showing
    /// `content` in front, inside a caller's write transaction, and returns
    /// it. Writes nothing and returns nil when the tab already has a row,
    /// readable or not, or when no worktree panel shows `content`. Only
    /// `openWorktreePanel(seeding:)` runs it, right after it opens the panel.
    ///
    /// The surface has no panels of its own, no label, the default width
    /// and the revision counter's next value, and is stored at the seed's
    /// position. Its row is marked `awaitingListing`, as a promote's moved
    /// rows are: the app lists the tab only once it has loaded it, and a
    /// sync built before then must not prune the row. The first sync that
    /// lists the tab finds a readable row and changes only its position,
    /// label and primary, never its collapse state.
    static func seedSurface(
        _ seed: SurfaceSeed, worktreeID: UUID, showing content: WorktreePanelContent, now: Date,
        in db: GRDB.Database
    ) throws -> WorkspaceTabSurface? {
        guard try WorkspaceTabSurfaceRecord.fetchOne(db, key: seed.tabID.uuidString) == nil else { return nil }
        let worktreePanels = try storedWorktreePanels(worktreeKey: worktreeID.uuidString, db: db)
        guard let front = worktreePanels.first(where: { $0.content == content }) else { return nil }
        let surface = WorkspaceTabSurface(
            id: seed.tabID, worktreeID: worktreeID, primary: seed.primary,
            side: SideRegion(activePanelID: front.id, collapsed: false),
            worktreePanels: worktreePanels, revision: try nextRevision(db: db))
        try writeSurface(surface, position: seed.position, awaitingListing: true, db: db, now: now)
        return surface
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

    /// Appends a worktree panel for each of the worktree's notes that no
    /// panel shows, after the worktree's existing panels and ordered by the
    /// note's `createdAt`, inside a caller's write transaction, then
    /// rewrites every readable surface of the worktree with the new list.
    /// A note whose ID does not parse gets no panel. Returns the surfaces it
    /// rewrote, in position order; none when every note already had a
    /// panel.
    ///
    /// A revive runs it (side panel notes spec, "Daemon → Reclamation"):
    /// archiving deleted the worktree's panels and kept its notes, and
    /// `WorktreeStore` runs this in the transaction that takes the row out
    /// of `archived`. The archive also deleted the worktree's surfaces, so
    /// it usually rewrites none, and the next tab sync imports the tabs
    /// with this list.
    static func reopenNotePanels(
        worktreeID: UUID, now: Date, in db: GRDB.Database
    ) throws -> [WorkspaceTabSurface] {
        let worktreeKey = worktreeID.uuidString
        let noteIDs = try String.fetchAll(
            db, sql: "SELECT id FROM note WHERE worktreeID = ? ORDER BY createdAt, id",
            arguments: [worktreeKey]
        ).compactMap(UUID.init(uuidString:))
        var panels = try storedWorktreePanels(worktreeKey: worktreeKey, db: db)
        let storedCount = panels.count
        for noteID in noteIDs where !panels.contains(where: { $0.content == .note(noteID: noteID) }) {
            panels.append(WorktreePanel(id: UUID(), content: .note(noteID: noteID)))
        }
        guard panels.count != storedCount else { return [] }
        try writeWorktreePanels(panels, worktreeID: worktreeID, db: db)
        return try rewriteSurfaces(
            worktreeID: worktreeID, worktreePanels: panels, except: nil, db: db, now: now)
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
