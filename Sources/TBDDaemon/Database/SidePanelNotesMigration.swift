import Foundation
import GRDB
import os

/// The `20261101170100_side_panel_notes` migration: notes leave the workspace
/// tab bar and the tabs' own side regions, and show in worktree panels (side
/// panel notes spec, "Daemon → Migration").
///
/// - Every worktree's `tabOrder` loses the ID of every note, and every note
///   loses its `tab` row.
/// - Each note of a worktree that is not archived gets a worktree panel,
///   unless one already shows it: first the notes the worktree's tab order
///   lists, in that order, then the rest by creation, after any panel the
///   worktree already has.
/// - A surface whose primary is a note is deleted, with its panels'
///   histories.
/// - Every other surface loses its own panels on notes, with their
///   histories. One whose front was such a panel brings that note's worktree
///   panel forward, else its most recent own panel, else the worktree's first
///   panel.
/// - A surface whose side region had no panels, in a worktree that now has
///   worktree panels, fronts the first one and comes out collapsed, so the
///   migration narrows no terminal. One that had panels keeps its collapse.
///
/// Each surface it changes takes the revision counter's next value. It works
/// on raw SQL and private snapshots of the JSON those columns hold, never on
/// the live model types, so a later change to them cannot change what it
/// does. It throws only on SQL errors: a throw here stops the daemon at every
/// start, so a row whose JSON does not parse is logged and left as it is.
/// Running it again changes nothing.
enum SidePanelNotesMigration {
    static let identifier = "20261101170100_side_panel_notes"

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "migrations")

    /// Runs the migration against an open write transaction. `now` is the
    /// `updatedAt` every surface it rewrites takes.
    static func run(_ db: GRDB.Database, now: Date = Date()) throws {
        let notes = try noteRows(db)
        try moveNotesIntoWorktreePanels(notes, db: db)
        try db.execute(sql: "DELETE FROM tab WHERE id IN (SELECT id FROM note)")
        try repairSurfaces(db: db, now: now)
    }

    // MARK: - Notes and tab orders

    /// One `note` row: its ID as stored and parsed, and its worktree's ID as
    /// stored.
    private struct NoteRow {
        let key: String
        let id: UUID?
        let worktreeKey: String
    }

    /// Every note row, oldest first.
    private static func noteRows(_ db: GRDB.Database) throws -> [NoteRow] {
        try Row.fetchAll(db, sql: "SELECT id, worktreeID FROM note ORDER BY createdAt, id")
            .compactMap { row -> NoteRow? in
                guard let key: String = row["id"], let worktreeKey: String = row["worktreeID"] else {
                    return nil
                }
                return NoteRow(key: key, id: UUID(uuidString: key), worktreeKey: worktreeKey)
            }
    }

    /// Removes every note's ID from every worktree's `tabOrder`, and gives
    /// the notes of each worktree that is not archived their worktree panels.
    /// A `tabOrder` that is not a JSON array of strings is left as it is.
    private static func moveNotesIntoWorktreePanels(_ notes: [NoteRow], db: GRDB.Database) throws {
        let noteKeys = Set(notes.map { $0.key.uppercased() })
        let notesByWorktree = Dictionary(grouping: notes, by: \.worktreeKey)
        let worktrees = try Row.fetchAll(db, sql: "SELECT id, status, tabOrder FROM worktree ORDER BY id")
        for row in worktrees {
            guard let worktreeKey: String = row["id"] else { continue }
            let tabOrderText: String? = row["tabOrder"]
            let tabOrder = tabOrderText.flatMap { decodeJSON([String].self, from: $0) }
            if let tabOrder {
                let kept = tabOrder.filter { !noteKeys.contains($0.uppercased()) }
                if kept.count != tabOrder.count {
                    try writeTabOrder(kept, worktreeKey: worktreeKey, db: db)
                }
            } else {
                logger.warning(
                    "migration \(Self.identifier, privacy: .public): leaving worktree \(worktreeKey, privacy: .public)'s tabOrder as it is: not a JSON array of strings")
            }
            let status: String? = row["status"]
            guard status != "archived", let worktreeNotes = notesByWorktree[worktreeKey] else { continue }
            try insertWorktreePanels(
                for: worktreeNotes, listedIn: tabOrder ?? [], worktreeKey: worktreeKey, db: db)
        }
    }

    private static func writeTabOrder(_ tabOrder: [String], worktreeKey: String, db: GRDB.Database) throws {
        guard let json = try? encodeJSONString(tabOrder) else {
            logger.warning(
                "migration \(Self.identifier, privacy: .public): leaving worktree \(worktreeKey, privacy: .public)'s tabOrder as it is: it does not encode")
            return
        }
        try db.execute(sql: "UPDATE worktree SET tabOrder = ? WHERE id = ?", arguments: [json, worktreeKey])
    }

    /// Appends a worktree panel for each of the worktree's notes that no
    /// panel shows: first the notes `tabOrder` lists, in that order, then the
    /// rest in the order given, which is by creation.
    private static func insertWorktreePanels(
        for notes: [NoteRow], listedIn tabOrder: [String], worktreeKey: String, db: GRDB.Database
    ) throws {
        var noteIDs: [UUID] = []
        for note in notes {
            guard let id = note.id else {
                logger.warning(
                    "migration \(Self.identifier, privacy: .public): making no worktree panel for note \(note.key, privacy: .public): malformed id")
                continue
            }
            noteIDs.append(id)
        }
        var ordered: [UUID] = []
        for entry in tabOrder {
            guard let id = UUID(uuidString: entry), noteIDs.contains(id), !ordered.contains(id) else { continue }
            ordered.append(id)
        }
        for id in noteIDs where !ordered.contains(id) {
            ordered.append(id)
        }

        let shown = try Set(worktreePanelRows(worktreeKey: worktreeKey, db: db).compactMap(\.noteID))
        let lastPosition = try Int.fetchOne(
            db, sql: "SELECT MAX(position) FROM worktree_panel WHERE worktreeID = ?", arguments: [worktreeKey])
        var position = (lastPosition ?? -1) + 1
        for noteID in ordered where !shown.contains(noteID) {
            try db.execute(
                sql: "INSERT INTO worktree_panel (id, worktreeID, position, content) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, worktreeKey, position, noteContentJSON(noteID)])
            position += 1
        }
    }

    /// A note's worktree panel content, as `JSONEncoder` spells it.
    private static func noteContentJSON(_ noteID: UUID) -> String {
        #"{"note":{"noteID":"\#(noteID.uuidString)"}}"#
    }

    // MARK: - Worktree panels

    /// One worktree panel as `worktree_panel` holds it.
    private struct WorktreePanelRow {
        let id: UUID
        /// The note it shows; nil for the Changes panel.
        let noteID: UUID?
    }

    /// The worktree's readable panels, in strip order. As the store reads
    /// them, a row whose ID or content does not parse is left out, and so is
    /// one showing what an earlier row shows.
    private static func worktreePanelRows(worktreeKey: String, db: GRDB.Database) throws -> [WorktreePanelRow] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, content FROM worktree_panel WHERE worktreeID = ? ORDER BY position, id",
            arguments: [worktreeKey])
        var panels: [WorktreePanelRow] = []
        var showsChanges = false
        for row in rows {
            guard let idText: String = row["id"], let id = UUID(uuidString: idText),
                  let contentText: String = row["content"],
                  let content = decodeJSON(ContentSnapshot.self, from: contentText) else { continue }
            if content.isNote {
                guard let noteID = content.noteID, !panels.contains(where: { $0.noteID == noteID }) else { continue }
                panels.append(WorktreePanelRow(id: id, noteID: noteID))
            } else if content.isChanges, !showsChanges {
                showsChanges = true
                panels.append(WorktreePanelRow(id: id, noteID: nil))
            }
        }
        return panels
    }

    // MARK: - Surfaces

    /// Deletes every surface whose primary is a note, and repairs every
    /// other: see `repairSurface`.
    private static func repairSurfaces(db: GRDB.Database, now: Date) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, worktreeID, primaryContent, layout FROM workspace_tab_surface
            ORDER BY worktreeID, position, id
            """)
        var panelsByWorktree: [String: [WorktreePanelRow]] = [:]
        for row in rows {
            guard let tabKey: String = row["id"], let worktreeKey: String = row["worktreeID"] else { continue }
            let primaryText: String? = row["primaryContent"]
            guard let primary = primaryText.flatMap({ decodeJSON(ContentSnapshot.self, from: $0) }) else {
                logger.warning(
                    "migration \(Self.identifier, privacy: .public): leaving workspace_tab_surface row \(tabKey, privacy: .public) as it is: malformed primaryContent")
                continue
            }
            if primary.isNote {
                try deleteSurface(tabKey: tabKey, db: db)
                continue
            }
            let panels: [WorktreePanelRow]
            if let cached = panelsByWorktree[worktreeKey] {
                panels = cached
            } else {
                panels = try worktreePanelRows(worktreeKey: worktreeKey, db: db)
                panelsByWorktree[worktreeKey] = panels
            }
            let layoutText: String? = row["layout"]
            try repairSurface(tabKey: tabKey, layoutText: layoutText, worktreePanels: panels, db: db, now: now)
        }
    }

    /// Deletes a surface row and its panels' histories. The migrator turns
    /// foreign keys off while a migration runs, so the cascade from the
    /// surface row would not reach them.
    private static func deleteSurface(tabKey: String, db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM panel_history WHERE tabID = ?", arguments: [tabKey])
        try db.execute(sql: "DELETE FROM workspace_tab_surface WHERE id = ?", arguments: [tabKey])
    }

    /// Drops the surface's own panels on notes and their histories, and
    /// repairs its front and collapse (`repaired`). A surface whose layout
    /// does not parse, or names a panel with no readable history, is left as
    /// it is. One that comes out the same is not written.
    private static func repairSurface(
        tabKey: String, layoutText: String?, worktreePanels: [WorktreePanelRow],
        db: GRDB.Database, now: Date
    ) throws {
        guard let side = layoutText.flatMap({ decodeJSON(SideRegionSnapshot.self, from: $0) }) else {
            logger.warning(
                "migration \(Self.identifier, privacy: .public): leaving workspace_tab_surface row \(tabKey, privacy: .public) as it is: malformed layout")
            return
        }
        let histories = try panelHistoryRows(tabKey: tabKey, db: db)
        var removedKeys: [String] = []
        var removed: Set<UUID> = []
        var frontNoteID: UUID?
        for panelID in side.panelIDs {
            guard let stored = histories[panelID] else {
                logger.warning(
                    "migration \(Self.identifier, privacy: .public): leaving workspace_tab_surface row \(tabKey, privacy: .public) as it is: panel \(panelID.uuidString, privacy: .public) has no readable history")
                return
            }
            guard stored.history.isNote else { continue }
            removed.insert(panelID)
            removedKeys.append(stored.key)
            if panelID == side.activePanelID {
                frontNoteID = stored.history.shownNoteID
            }
        }

        let next = repaired(side, removing: removed, frontNoteID: frontNoteID, worktreePanels: worktreePanels)
        guard next != side else { return }
        guard let layout = try? encodeJSONString(next) else {
            logger.warning(
                "migration \(Self.identifier, privacy: .public): leaving workspace_tab_surface row \(tabKey, privacy: .public) as it is: its repaired layout does not encode")
            return
        }
        guard let revision = try nextRevision(db) else {
            logger.warning(
                "migration \(Self.identifier, privacy: .public): leaving workspace_tab_surface row \(tabKey, privacy: .public) as it is: the panel_revision_counter row is missing")
            return
        }
        try db.execute(
            sql: "UPDATE workspace_tab_surface SET layout = ?, revision = ?, updatedAt = ? WHERE id = ?",
            arguments: [layout, revision, now, tabKey])
        for key in removedKeys {
            try db.execute(
                sql: "DELETE FROM panel_history WHERE panelID = ? AND tabID = ?", arguments: [key, tabKey])
        }
    }

    /// `side` without the panels in `removed`, with its front and collapse
    /// repaired:
    ///
    /// - A front that is still one of its own panels or a worktree panel
    ///   stays.
    /// - Otherwise the front is the worktree panel on `frontNoteID`, the note
    ///   the removed front panel showed, else the most recent remaining own
    ///   panel, else the worktree's first panel, else none.
    /// - A side region that had no panels comes out collapsed when the
    ///   worktree has panels; one that had panels keeps its collapse.
    private static func repaired(
        _ side: SideRegionSnapshot, removing removed: Set<UUID>, frontNoteID: UUID?,
        worktreePanels: [WorktreePanelRow]
    ) -> SideRegionSnapshot {
        var next = side
        next.panelIDs.removeAll { removed.contains($0) }
        next.recency.removeAll { removed.contains($0) }
        let worktreePanelIDs = worktreePanels.map(\.id)
        if let front = side.activePanelID,
           next.panelIDs.contains(front) || worktreePanelIDs.contains(front) {
            next.activePanelID = front
        } else if let frontNoteID,
                  let notePanel = worktreePanels.first(where: { $0.noteID == frontNoteID }) {
            next.activePanelID = notePanel.id
        } else {
            next.activePanelID = next.recency.first ?? worktreePanelIDs.first
        }
        if side.panelIDs.isEmpty, !worktreePanels.isEmpty {
            next.collapsed = true
        }
        return next
    }

    /// The tab's readable panel histories, keyed by panel ID, each with its
    /// row's `panelID` as stored. A row whose ID or history does not parse is
    /// left out.
    private static func panelHistoryRows(
        tabKey: String, db: GRDB.Database
    ) throws -> [UUID: (key: String, history: HistorySnapshot)] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT panelID, history FROM panel_history WHERE tabID = ?", arguments: [tabKey])
        var histories: [UUID: (key: String, history: HistorySnapshot)] = [:]
        for row in rows {
            guard let key: String = row["panelID"], let panelID = UUID(uuidString: key),
                  let text: String = row["history"],
                  let history = decodeJSON(HistorySnapshot.self, from: text) else { continue }
            histories[panelID] = (key: key, history: history)
        }
        return histories
    }

    /// The revision counter's next value, incremented in the open
    /// transaction; nil when its row is missing.
    private static func nextRevision(_ db: GRDB.Database) throws -> Int64? {
        try db.execute(sql: "UPDATE panel_revision_counter SET value = value + 1 WHERE id = 1")
        return try Int64.fetchOne(db, sql: "SELECT value FROM panel_revision_counter WHERE id = 1")
    }

    // MARK: - JSON snapshots

    /// The `layout` column: a tab's side region without its panels'
    /// histories.
    private struct SideRegionSnapshot: Codable, Equatable {
        var panelIDs: [UUID]
        var activePanelID: UUID?
        var recency: [UUID]
        var collapsed: Bool
        var width: Double
    }

    /// A `panel_history` row's history: the panel's entries, and the index
    /// of the one it shows.
    private struct HistorySnapshot: Decodable {
        let entries: [ContentSnapshot]
        let cursor: Int

        /// True for a note panel's history. A history holds content of one
        /// kind, so one note entry makes it a note panel's.
        var isNote: Bool { entries.contains { $0.isNote } }

        /// The note the panel shows: the one the cursor's entry names.
        var shownNoteID: UUID? {
            entries.indices.contains(cursor) ? entries[cursor].noteID : nil
        }
    }

    /// A content value — a primary, a history entry or a worktree panel's
    /// content — as an object whose one top-level key names its case. Only
    /// the cases this migration acts on are told apart.
    private struct ContentSnapshot: Decodable {
        /// The top-level key is `note`.
        let isNote: Bool
        /// The top-level key is `changes`.
        let isChanges: Bool
        /// The note a `note` value names; nil for any other value, and for a
        /// note whose ID does not parse.
        let noteID: UUID?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            isNote = container.contains(AnyKey("note"))
            isChanges = container.contains(AnyKey("changes"))
            if isNote, let payload = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("note")) {
                noteID = try? payload.decode(UUID.self, forKey: AnyKey("noteID"))
            } else {
                noteID = nil
            }
        }
    }

    /// A coding key for whatever name a JSON object carries.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }
}
