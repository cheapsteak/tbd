import Foundation
import GRDB
import os

/// The `20261101170100_side_panel_notes` migration: notes leave the workspace
/// tab bar and the tabs' own side regions (side panel notes spec, "Daemon →
/// Migration"). It opens no worktree panel: a note shows in the side panel
/// when the user or an agent opens it there.
///
/// - The `worktree_panel` table and its index are created first when they
///   are missing, so the schema it leaves does not depend on
///   `20261101170000_worktree_panel` having run before it.
/// - Every worktree's `tabOrder` loses the ID of every note, and every note
///   loses its `tab` row. A worktree whose `activeTabID` names a note
///   selects the first tab its remaining `tabOrder` lists instead, or none
///   when it lists none or does not parse. Archived worktrees are cleaned
///   the same way.
/// - A surface whose primary is a note is deleted, with its panels'
///   histories.
/// - Every other surface loses its own panels whose history holds a note,
///   with their histories. One whose front was such a panel fronts its most
///   recent remaining own panel, else nothing. Collapse is never touched.
///
/// It inserts no `worktree_panel` row. Each surface it changes takes the
/// revision counter's next value. It works on raw SQL and private snapshots
/// of the JSON those columns hold, never on the live model types, so a later
/// change to them cannot change what it does. It throws only on SQL errors:
/// a throw here stops the daemon at every start, so a row whose JSON does not
/// parse is logged and left as it is. Running it again changes nothing: no
/// note is left in a tab order or a side region for it to remove.
enum SidePanelNotesMigration {
    static let identifier = "20261101170100_side_panel_notes"

    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "migrations")

    /// Runs the migration against an open write transaction. `now` is the
    /// `updatedAt` every surface it rewrites takes.
    static func run(_ db: GRDB.Database, now: Date = Date()) throws {
        try createWorktreePanelTableIfMissing(db)
        try removeNotesFromTabOrders(noteKeys: noteKeys(db), db: db)
        try db.execute(sql: "DELETE FROM tab WHERE id IN (SELECT id FROM note)")
        try repairSurfaces(db: db, now: now)
    }

    /// The `worktree_panel` table and its index, exactly as
    /// `20261101170000_worktree_panel.sql` creates them, when they are
    /// missing. Migrations can apply in a different order on different
    /// machines, so this one leaves the same schema whichever ran first.
    private static func createWorktreePanelTableIfMissing(_ db: GRDB.Database) throws {
        try db.createTableIfNotExists("worktree_panel") { t in
            t.primaryKey("id", .text).notNull()
            t.column("worktreeID", .text).notNull()
                .references("worktree", column: "id", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("content", .text).notNull()
        }
        try db.addIndexIfMissing(
            "worktree_panel_on_worktreeID", on: "worktree_panel", columns: ["worktreeID", "position"])
    }

    // MARK: - Notes and tab orders

    /// Every note row's ID as stored, uppercased.
    private static func noteKeys(_ db: GRDB.Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "SELECT id FROM note").compactMap { row -> String? in
            let key: String? = row["id"]
            return key?.uppercased()
        })
    }

    /// Removes every note's ID from every worktree's `tabOrder`, and moves
    /// an `activeTabID` naming a note to the first tab the remaining
    /// `tabOrder` lists. A `tabOrder` that is not a JSON array of strings is
    /// left as it is, and an `activeTabID` naming a note in such a worktree
    /// is cleared, since there is no list to take a tab from.
    private static func removeNotesFromTabOrders(noteKeys: Set<String>, db: GRDB.Database) throws {
        let worktrees = try Row.fetchAll(
            db, sql: "SELECT id, tabOrder, activeTabID FROM worktree ORDER BY id")
        for row in worktrees {
            guard let worktreeKey: String = row["id"] else { continue }
            let tabOrderText: String? = row["tabOrder"]
            let tabOrder = tabOrderText.flatMap { decodeJSON([String].self, from: $0) }
            let kept = tabOrder?.filter { !noteKeys.contains($0.uppercased()) }
            if let tabOrder, let kept {
                if kept.count != tabOrder.count {
                    try writeTabOrder(kept, worktreeKey: worktreeKey, db: db)
                }
            } else {
                logger.warning(
                    "migration \(Self.identifier, privacy: .public): leaving worktree \(worktreeKey, privacy: .public)'s tabOrder as it is: not a JSON array of strings")
            }
            let activeTabKey: String? = row["activeTabID"]
            if let activeTabKey, noteKeys.contains(activeTabKey.uppercased()) {
                try db.execute(
                    sql: "UPDATE worktree SET activeTabID = ? WHERE id = ?",
                    arguments: [kept?.first, worktreeKey])
            }
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

    // MARK: - Surfaces

    /// Deletes every surface whose primary is a note, and repairs every
    /// other: see `repairSurface`.
    private static func repairSurfaces(db: GRDB.Database, now: Date) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, primaryContent, layout FROM workspace_tab_surface
            ORDER BY worktreeID, position, id
            """)
        for row in rows {
            guard let tabKey: String = row["id"] else { continue }
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
            let layoutText: String? = row["layout"]
            try repairSurface(tabKey: tabKey, layoutText: layoutText, db: db, now: now)
        }
    }

    /// Deletes a surface row and its panels' histories. The migrator turns
    /// foreign keys off while a migration runs, so the cascade from the
    /// surface row would not reach them.
    private static func deleteSurface(tabKey: String, db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM panel_history WHERE tabID = ?", arguments: [tabKey])
        try db.execute(sql: "DELETE FROM workspace_tab_surface WHERE id = ?", arguments: [tabKey])
    }

    /// Drops the surface's own panels whose history holds a note, and their
    /// histories, and repairs its front (`repaired`). A surface whose layout
    /// does not parse, or names a panel with no readable history, is left as
    /// it is. One that comes out the same is not written.
    private static func repairSurface(
        tabKey: String, layoutText: String?, db: GRDB.Database, now: Date
    ) throws {
        guard let side = layoutText.flatMap({ decodeJSON(SideRegionSnapshot.self, from: $0) }) else {
            logger.warning(
                "migration \(Self.identifier, privacy: .public): leaving workspace_tab_surface row \(tabKey, privacy: .public) as it is: malformed layout")
            return
        }
        let histories = try panelHistoryRows(tabKey: tabKey, db: db)
        var removedKeys: [String] = []
        var removed: Set<UUID> = []
        for panelID in side.panelIDs {
            guard let stored = histories[panelID] else {
                logger.warning(
                    "migration \(Self.identifier, privacy: .public): leaving workspace_tab_surface row \(tabKey, privacy: .public) as it is: panel \(panelID.uuidString, privacy: .public) has no readable history")
                return
            }
            guard stored.history.isNote else { continue }
            removed.insert(panelID)
            removedKeys.append(stored.key)
        }

        let next = repaired(side, removing: removed)
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

    /// `side` without the panels in `removed`. A front that was one of them
    /// becomes the most recent remaining own panel, else nothing; any other
    /// front stays. Width and collapse are kept.
    private static func repaired(_ side: SideRegionSnapshot, removing removed: Set<UUID>) -> SideRegionSnapshot {
        var next = side
        next.panelIDs.removeAll { removed.contains($0) }
        next.recency.removeAll { removed.contains($0) }
        if let front = side.activePanelID, removed.contains(front) {
            next.activePanelID = next.recency.first
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

        /// True for a history that holds a note anywhere in it.
        var isNote: Bool { entries.contains { $0.isNote } }
    }

    /// A content value — a primary or a history entry — as an object whose
    /// one top-level key names its case. Only a note is told apart.
    private struct ContentSnapshot: Decodable {
        /// The top-level key is `note`.
        let isNote: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            isNote = container.contains(AnyKey("note"))
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
