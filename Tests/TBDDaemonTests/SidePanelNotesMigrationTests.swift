import Foundation
import GRDB
import Testing
import TBDShared

@testable import TBDDaemonLib

/// The `20261101170100_side_panel_notes` migration
/// (docs/specs/2026-11-01-side-panel-notes-and-changes-design.md, "Daemon →
/// Migration"): notes leave the workspace tab bar and the tabs' own side
/// regions, and show in worktree panels.
///
/// Each test migrates a database to just before the migration, seeds rows as
/// the daemon wrote them before it, and runs the rest of the chain. JSON that
/// names a note is written out literally, since that is the shape the
/// migration recognizes; other content is encoded by the live types, so the
/// store can read the surfaces back.
@Suite("SidePanelNotesMigration")
struct SidePanelNotesMigrationTests {

    /// The migration identifier immediately before this one. Migrating only
    /// this far reproduces the schema the migration runs on.
    private static let lastIdentifierBefore = "20261101170000_worktree_panel"

    /// The revision counter's value when the migration starts, above every
    /// seeded surface's revision, as the store keeps it.
    private static let counterBefore: Int64 = 40

    // MARK: - Fixture

    /// A database migrated to just before the migration and seeded by
    /// `seed`, then migrated the rest of the way. Returns the database and
    /// what `seed` returned.
    private static func migrate<T>(
        seed: (GRDB.Database) throws -> T
    ) throws -> (queue: DatabaseQueue, seeded: T) {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: lastIdentifierBefore)
        let seeded: T = try queue.write { db -> T in
            try db.execute(
                sql: "UPDATE panel_revision_counter SET value = ? WHERE id = 1", arguments: [Self.counterBefore])
            return try seed(db)
        }
        try migrator.migrate(queue)
        return (queue, seeded)
    }

    /// The `layout` column's JSON as the daemon writes it.
    private struct Layout: Codable, Equatable {
        var panelIDs: [UUID]
        var activePanelID: UUID?
        var recency: [UUID]
        var collapsed: Bool = false
        var width: Double = 0.5
    }

    /// One `worktree_panel` row.
    private struct PanelRow {
        let id: UUID?
        let position: Int
        let content: String
    }

    // MARK: - Seeding

    /// A repo and a worktree row; returns the worktree's ID.
    private static func insertWorktree(
        _ db: GRDB.Database, status: String = "active", tabOrder: String = "[]"
    ) throws -> UUID {
        let repoID = UUID()
        let worktreeID = UUID()
        let now = Date()
        try db.execute(sql: """
            INSERT INTO repo (id, path, displayName, defaultBranch, createdAt)
            VALUES (?, ?, 'SidePanelNotes', 'main', ?)
            """, arguments: [repoID.uuidString, "/tmp/side-panel-notes-repo-\(repoID.uuidString)", now])
        try db.execute(sql: """
            INSERT INTO worktree (id, repoID, name, displayName, branch, path, status, createdAt, tmuxServer, tabOrder)
            VALUES (?, ?, 'w', 'w', 'main', ?, ?, ?, 'tbd-side-panel-notes', ?)
            """, arguments: [
                worktreeID.uuidString, repoID.uuidString,
                "/tmp/side-panel-notes-wt-\(worktreeID.uuidString)", status, now, tabOrder,
            ])
        return worktreeID
    }

    private static func setTabOrder(_ db: GRDB.Database, worktreeID: UUID, _ tabIDs: [UUID]) throws {
        let json = try encodeJSONString(tabIDs.map(\.uuidString))
        try db.execute(
            sql: "UPDATE worktree SET tabOrder = ? WHERE id = ?", arguments: [json, worktreeID.uuidString])
    }

    private static func setActiveTabID(_ db: GRDB.Database, worktreeID: UUID, _ tabID: UUID) throws {
        try db.execute(
            sql: "UPDATE worktree SET activeTabID = ? WHERE id = ?",
            arguments: [tabID.uuidString, worktreeID.uuidString])
    }

    private static func insertNote(
        _ db: GRDB.Database, worktreeID: UUID,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws -> UUID {
        let noteID = UUID()
        try db.execute(sql: """
            INSERT INTO note (id, worktreeID, title, content, createdAt, updatedAt)
            VALUES (?, ?, 'Notes', '', ?, ?)
            """, arguments: [noteID.uuidString, worktreeID.uuidString, createdAt, createdAt])
        return noteID
    }

    private static func insertTabRow(_ db: GRDB.Database, id: UUID, worktreeID: UUID) throws {
        try db.execute(
            sql: "INSERT INTO tab (id, worktreeID, label, createdAt) VALUES (?, ?, NULL, ?)",
            arguments: [id.uuidString, worktreeID.uuidString, Date()])
    }

    private static func insertSurface(
        _ db: GRDB.Database, worktreeID: UUID, primary: String, layout: String,
        position: Int = 0, revision: Int64 = 1
    ) throws -> UUID {
        let tabID = UUID()
        try db.execute(sql: """
            INSERT INTO workspace_tab_surface
                (id, worktreeID, primaryContent, position, layout, revision, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                tabID.uuidString, worktreeID.uuidString, primary, position, layout, revision, Date(),
            ])
        return tabID
    }

    private static func insertHistory(_ db: GRDB.Database, panelID: UUID, tabID: UUID, history: String) throws {
        try db.execute(
            sql: "INSERT INTO panel_history (panelID, tabID, history, updatedAt) VALUES (?, ?, ?, ?)",
            arguments: [panelID.uuidString, tabID.uuidString, history, Date()])
    }

    private static func terminalPrimary() throws -> String {
        try encodeJSONString(PrimaryContent.terminal(terminalID: UUID()))
    }

    private static func notePrimary(_ noteID: UUID) -> String {
        #"{"note":{"noteID":"\#(noteID.uuidString)"}}"#
    }

    private static func fileHistory(_ path: String = "/a.txt") throws -> String {
        try encodeJSONString(PanelHistory.seeded(with: .file(FileReference(path: path))))
    }

    private static func noteHistory(_ noteID: UUID) -> String {
        #"{"entries":[{"note":{"noteID":"\#(noteID.uuidString)"}}],"cursor":0}"#
    }

    /// A note's worktree panel content, as `JSONEncoder` spells
    /// `WorktreePanelContent.note`.
    private static func noteContent(_ noteID: UUID) -> String {
        #"{"note":{"noteID":"\#(noteID.uuidString)"}}"#
    }

    // MARK: - Reading back

    private static func tabOrderText(_ queue: DatabaseQueue, worktreeID: UUID) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT tabOrder FROM worktree WHERE id = ?", arguments: [worktreeID.uuidString])
        }
    }

    private static func tabOrder(_ queue: DatabaseQueue, worktreeID: UUID) throws -> [String]? {
        try tabOrderText(queue, worktreeID: worktreeID).flatMap { decodeJSON([String].self, from: $0) }
    }

    private static func activeTabID(_ queue: DatabaseQueue, worktreeID: UUID) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT activeTabID FROM worktree WHERE id = ?", arguments: [worktreeID.uuidString])
        }
    }

    private static func tabRowIDs(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM tab ORDER BY id")
        }
    }

    /// The worktree's `worktree_panel` rows in position order.
    private static func panelRows(_ queue: DatabaseQueue, worktreeID: UUID) throws -> [PanelRow] {
        try queue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, position, content FROM worktree_panel WHERE worktreeID = ? ORDER BY position",
                arguments: [worktreeID.uuidString]
            ).map { row in
                PanelRow(id: UUID(uuidString: row["id"]), position: row["position"], content: row["content"])
            }
        }
    }

    private static func layoutText(_ queue: DatabaseQueue, tabID: UUID) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT layout FROM workspace_tab_surface WHERE id = ?", arguments: [tabID.uuidString])
        }
    }

    private static func layout(_ queue: DatabaseQueue, tabID: UUID) throws -> Layout? {
        try layoutText(queue, tabID: tabID).flatMap { decodeJSON(Layout.self, from: $0) }
    }

    private static func revision(_ queue: DatabaseQueue, tabID: UUID) throws -> Int64? {
        try queue.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT revision FROM workspace_tab_surface WHERE id = ?", arguments: [tabID.uuidString])
        }
    }

    private static func counter(_ queue: DatabaseQueue) throws -> Int64? {
        try queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM panel_revision_counter WHERE id = 1")
        }
    }

    /// The panel IDs of the tab's `panel_history` rows, sorted.
    private static func historyPanelIDs(_ queue: DatabaseQueue, tabID: UUID) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(
                db, sql: "SELECT panelID FROM panel_history WHERE tabID = ? ORDER BY panelID",
                arguments: [tabID.uuidString])
        }
    }

    /// `worktree_panel`'s columns, foreign keys and index as SQLite reports
    /// them, one line each, so two ways of creating the table compare equal
    /// only when they make the same table.
    private struct WorktreePanelSchema: Equatable {
        /// `name TYPE notnull=N pk=N`, in column order.
        var columns: [String]
        /// `from -> table.to on delete ACTION`.
        var foreignKeys: [String]
        /// `worktree_panel_on_worktreeID`'s columns, in index order.
        var indexColumns: [String]
    }

    /// The table `20261101170000_worktree_panel.sql` creates.
    private static let expectedWorktreePanelSchema = WorktreePanelSchema(
        columns: [
            "id TEXT notnull=1 pk=1",
            "worktreeID TEXT notnull=1 pk=0",
            "position INTEGER notnull=1 pk=0",
            "content TEXT notnull=1 pk=0",
        ],
        foreignKeys: ["worktreeID -> worktree.id on delete CASCADE"],
        indexColumns: ["worktreeID", "position"])

    private static func worktreePanelSchema(_ queue: DatabaseQueue) throws -> WorktreePanelSchema {
        try queue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(worktree_panel)").map { row -> String in
                let name: String = row["name"]
                let type: String = row["type"]
                let notNull: Int = row["notnull"]
                let primaryKey: Int = row["pk"]
                return "\(name) \(type.uppercased()) notnull=\(notNull) pk=\(primaryKey)"
            }
            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(worktree_panel)").map {
                row -> String in
                let from: String = row["from"]
                let table: String = row["table"]
                let to: String? = row["to"]
                let onDelete: String = row["on_delete"]
                return "\(from) -> \(table).\(to ?? "<primary key>") on delete \(onDelete)"
            }
            let indexColumns = try Row.fetchAll(db, sql: "PRAGMA index_info(worktree_panel_on_worktreeID)")
                .map { row -> String in row["name"] }
            return WorktreePanelSchema(columns: columns, foreignKeys: foreignKeys, indexColumns: indexColumns)
        }
    }

    private static func surfaceExists(_ queue: DatabaseQueue, tabID: UUID) throws -> Bool {
        try queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM workspace_tab_surface WHERE id = ?",
                arguments: [tabID.uuidString]) == 1
        }
    }

    // MARK: - Notes leave the tab bar

    /// A note's ID leaves its worktree's tab order, it gets one worktree
    /// panel, and its tab row goes while the terminal tab's stays.
    @Test func movesNoteOutOfTabOrderIntoWorktreePanel() throws {
        let terminalTabID = UUID()
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, noteID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            try Self.setTabOrder(db, worktreeID: worktreeID, [terminalTabID, noteID])
            try Self.insertTabRow(db, id: terminalTabID, worktreeID: worktreeID)
            try Self.insertTabRow(db, id: noteID, worktreeID: worktreeID)
            return (worktreeID, noteID)
        }

        let tabOrder = try Self.tabOrder(queue, worktreeID: seeded.worktreeID)
        #expect(tabOrder == [terminalTabID.uuidString])
        let panels = try Self.panelRows(queue, worktreeID: seeded.worktreeID)
        let contents = panels.map(\.content)
        #expect(contents == [Self.noteContent(seeded.noteID)])
        #expect(panels.first?.id != nil)
        let tabRows = try Self.tabRowIDs(queue)
        #expect(tabRows == [terminalTabID.uuidString])
    }

    /// The panels follow the tab order's notes, in its order, then the notes
    /// it does not list, by creation rather than by insertion.
    @Test func ordersPanelsByTabOrderThenCreation() throws {
        let terminalTabID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, notes: [UUID]) in
            let worktreeID = try Self.insertWorktree(db)
            let first = try Self.insertNote(db, worktreeID: worktreeID, createdAt: base)
            let fourth = try Self.insertNote(db, worktreeID: worktreeID, createdAt: base.addingTimeInterval(180))
            let second = try Self.insertNote(db, worktreeID: worktreeID, createdAt: base.addingTimeInterval(60))
            let third = try Self.insertNote(db, worktreeID: worktreeID, createdAt: base.addingTimeInterval(120))
            try Self.setTabOrder(db, worktreeID: worktreeID, [terminalTabID, third, first])
            return (worktreeID, [first, second, third, fourth])
        }

        let notes = seeded.notes
        let expected: [String] = [notes[2], notes[0], notes[1], notes[3]].map { Self.noteContent($0) }
        let panels = try Self.panelRows(queue, worktreeID: seeded.worktreeID)
        let contents = panels.map(\.content)
        let positions = panels.map(\.position)
        #expect(contents == expected)
        #expect(positions == [0, 1, 2, 3])
    }

    /// An archived worktree's tab order loses its notes' IDs, and its notes
    /// get no worktree panels.
    @Test func archivedWorktreeGetsNoPanels() throws {
        let terminalTabID = UUID()
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, noteID: UUID) in
            let worktreeID = try Self.insertWorktree(db, status: "archived")
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            try Self.setTabOrder(db, worktreeID: worktreeID, [terminalTabID, noteID])
            try Self.insertTabRow(db, id: noteID, worktreeID: worktreeID)
            return (worktreeID, noteID)
        }

        let tabOrder = try Self.tabOrder(queue, worktreeID: seeded.worktreeID)
        #expect(tabOrder == [terminalTabID.uuidString])
        let panels = try Self.panelRows(queue, worktreeID: seeded.worktreeID)
        #expect(panels.isEmpty)
        let tabRows = try Self.tabRowIDs(queue)
        #expect(tabRows.isEmpty)
    }

    /// A note's ID leaves every tab order that lists it, not only its own
    /// worktree's: a scratch promote copies the scratch worktree's tab order
    /// to the main worktree, while the notes stay behind with the scratch.
    @Test func removesNoteIDsFromEveryWorktreesTabOrder() throws {
        let terminalTabID = UUID()
        let (queue, seeded) = try Self.migrate { db -> (scratchID: UUID, mainID: UUID) in
            let scratchID = try Self.insertWorktree(db, status: "archived")
            let noteID = try Self.insertNote(db, worktreeID: scratchID)
            let mainID = try Self.insertWorktree(db, status: "main")
            try Self.setTabOrder(db, worktreeID: mainID, [terminalTabID, noteID])
            return (scratchID, mainID)
        }

        let tabOrder = try Self.tabOrder(queue, worktreeID: seeded.mainID)
        #expect(tabOrder == [terminalTabID.uuidString])
        let mainPanels = try Self.panelRows(queue, worktreeID: seeded.mainID)
        #expect(mainPanels.isEmpty)
        let scratchPanels = try Self.panelRows(queue, worktreeID: seeded.scratchID)
        #expect(scratchPanels.isEmpty)
    }

    /// A worktree whose selected tab was a note selects the first tab its
    /// remaining tab order lists, or none when it lists none; one whose
    /// selected tab is a terminal keeps it, though its tab order lost a note.
    @Test func activeNoteTabMovesToFirstRemainingTab() throws {
        let firstTerminalTabID = UUID()
        let secondTerminalTabID = UUID()
        let selectedTerminalTabID = UUID()
        let (queue, seeded) = try Self.migrate {
            db -> (noteSelectedID: UUID, terminalSelectedID: UUID, onlyNoteID: UUID) in
            let noteSelectedID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: noteSelectedID)
            try Self.setTabOrder(db, worktreeID: noteSelectedID, [noteID, firstTerminalTabID, secondTerminalTabID])
            try Self.setActiveTabID(db, worktreeID: noteSelectedID, noteID)

            let terminalSelectedID = try Self.insertWorktree(db)
            let otherNoteID = try Self.insertNote(db, worktreeID: terminalSelectedID)
            try Self.setTabOrder(db, worktreeID: terminalSelectedID, [otherNoteID, selectedTerminalTabID])
            try Self.setActiveTabID(db, worktreeID: terminalSelectedID, selectedTerminalTabID)

            let onlyNoteID = try Self.insertWorktree(db)
            let loneNoteID = try Self.insertNote(db, worktreeID: onlyNoteID)
            try Self.setTabOrder(db, worktreeID: onlyNoteID, [loneNoteID])
            try Self.setActiveTabID(db, worktreeID: onlyNoteID, loneNoteID)
            return (noteSelectedID, terminalSelectedID, onlyNoteID)
        }

        let repaired = try Self.activeTabID(queue, worktreeID: seeded.noteSelectedID)
        #expect(repaired == firstTerminalTabID.uuidString)
        let kept = try Self.activeTabID(queue, worktreeID: seeded.terminalSelectedID)
        #expect(kept == selectedTerminalTabID.uuidString)
        let cleared = try Self.activeTabID(queue, worktreeID: seeded.onlyNoteID)
        #expect(cleared == nil)
    }

    // MARK: - Order independence

    /// The identifier before `20261101170000_worktree_panel`, the migration
    /// that creates the `worktree_panel` table.
    private static let lastIdentifierBeforeWorktreePanelTable = "20261030194425_panel_tabs"

    /// Run on a database where `20261101170000_worktree_panel` has not run,
    /// as a machine that applies the two in another order would, the
    /// migration creates the table that file creates, then moves the notes
    /// into it. The rest of the chain still applies afterwards and adds no
    /// second panel.
    @Test func createsWorktreePanelTableWhenMissing() throws {
        let queue = try DatabaseQueue()
        let migrator = TBDDatabase.buildMigratorForTests()
        try migrator.migrate(queue, upTo: Self.lastIdentifierBeforeWorktreePanelTable)
        let tableBefore = try queue.read { db in try db.tableExists("worktree_panel") }
        #expect(!tableBefore)

        let seeded = try queue.write { db -> (worktreeID: UUID, noteID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            try Self.setTabOrder(db, worktreeID: worktreeID, [noteID])
            try SidePanelNotesMigration.run(db)
            return (worktreeID, noteID)
        }

        let schema = try Self.worktreePanelSchema(queue)
        #expect(schema == Self.expectedWorktreePanelSchema)
        let contents = try Self.panelRows(queue, worktreeID: seeded.worktreeID).map(\.content)
        let expectedContents: [String] = [Self.noteContent(seeded.noteID)]
        #expect(contents == expectedContents)
        let tabOrder = try Self.tabOrder(queue, worktreeID: seeded.worktreeID)
        let expectedTabOrder: [String] = []
        #expect(tabOrder == expectedTabOrder)

        try migrator.migrate(queue)
        let contentsAfterChain = try Self.panelRows(queue, worktreeID: seeded.worktreeID).map(\.content)
        #expect(contentsAfterChain == expectedContents)
    }

    /// The table `20261101170000_worktree_panel.sql` creates on the usual
    /// order has the shape the migration's own creation is held to.
    @Test func sqlFileCreatesTheSameWorktreePanelTable() throws {
        let queue = try DatabaseQueue()
        try TBDDatabase.buildMigratorForTests().migrate(queue)
        let schema = try Self.worktreePanelSchema(queue)
        #expect(schema == Self.expectedWorktreePanelSchema)
    }

    // MARK: - A tab's own note panels

    /// A tab's own panel on a note, in front, gives way to the note's
    /// worktree panel, in front: its history row goes, the file panel stays,
    /// and the row takes a revision above every earlier one.
    @Test func replacesTabsOwnNotePanelInFront() async throws {
        let filePanelID = UUID()
        let notePanelID = UUID()
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, noteID: UUID, tabID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            let tabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(
                    panelIDs: [filePanelID, notePanelID], activePanelID: notePanelID,
                    recency: [notePanelID, filePanelID])),
                revision: Self.counterBefore)
            try Self.insertHistory(db, panelID: filePanelID, tabID: tabID, history: Self.fileHistory())
            try Self.insertHistory(db, panelID: notePanelID, tabID: tabID, history: Self.noteHistory(noteID))
            return (worktreeID, noteID, tabID)
        }

        let panels = try Self.panelRows(queue, worktreeID: seeded.worktreeID)
        let notePanelRowID = try #require(panels.first?.id)
        let layout = try #require(try Self.layout(queue, tabID: seeded.tabID))
        #expect(layout == Layout(panelIDs: [filePanelID], activePanelID: notePanelRowID, recency: [filePanelID]))
        let historyIDs = try Self.historyPanelIDs(queue, tabID: seeded.tabID)
        #expect(historyIDs == [filePanelID.uuidString])
        let revision = try #require(try Self.revision(queue, tabID: seeded.tabID))
        #expect(revision > Self.counterBefore)

        let surfaces = try await PanelSurfaceStore(writer: queue).surfaces(worktreeID: seeded.worktreeID)
        let surface = try #require(surfaces.first)
        let ownPanelIDs = surface.side.panels.map(\.id)
        #expect(ownPanelIDs == [filePanelID])
        #expect(surface.side.activePanelID == notePanelRowID)
        let expectedPanels = [WorktreePanel(id: notePanelRowID, content: .note(noteID: seeded.noteID))]
        #expect(surface.worktreePanels == expectedPanels)
        #expect(surface.revision == UInt64(revision))
    }

    /// A file panel in front stays in front when the tab's note panel was
    /// behind it.
    @Test func keepsFrontWhenNotePanelWasBehind() throws {
        let filePanelID = UUID()
        let notePanelID = UUID()
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, tabID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            let tabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(
                    panelIDs: [filePanelID, notePanelID], activePanelID: filePanelID,
                    recency: [filePanelID, notePanelID])))
            try Self.insertHistory(db, panelID: filePanelID, tabID: tabID, history: Self.fileHistory())
            try Self.insertHistory(db, panelID: notePanelID, tabID: tabID, history: Self.noteHistory(noteID))
            return (worktreeID, tabID)
        }

        let layout = try #require(try Self.layout(queue, tabID: seeded.tabID))
        #expect(layout == Layout(panelIDs: [filePanelID], activePanelID: filePanelID, recency: [filePanelID]))
        let historyIDs = try Self.historyPanelIDs(queue, tabID: seeded.tabID)
        #expect(historyIDs == [filePanelID.uuidString])
    }

    /// A tab's own panel on a note that has no row goes too. With another
    /// own panel left, the front falls back to the most recent one rather
    /// than to the worktree's panel; with none left, to the worktree's first
    /// panel, keeping the region's collapse state.
    @Test func removesOwnPanelOfDeletedNote() throws {
        let filePanelID = UUID()
        let deletedNotePanelID = UUID()
        let loneDeletedNotePanelID = UUID()
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, withFileID: UUID, aloneID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            _ = try Self.insertNote(db, worktreeID: worktreeID)
            let deletedNoteID = UUID()
            let withFileID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(
                    panelIDs: [filePanelID, deletedNotePanelID], activePanelID: deletedNotePanelID,
                    recency: [deletedNotePanelID, filePanelID])))
            try Self.insertHistory(db, panelID: filePanelID, tabID: withFileID, history: Self.fileHistory())
            try Self.insertHistory(
                db, panelID: deletedNotePanelID, tabID: withFileID, history: Self.noteHistory(deletedNoteID))
            let aloneID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(
                    panelIDs: [loneDeletedNotePanelID], activePanelID: loneDeletedNotePanelID,
                    recency: [loneDeletedNotePanelID])),
                position: 1)
            try Self.insertHistory(
                db, panelID: loneDeletedNotePanelID, tabID: aloneID, history: Self.noteHistory(deletedNoteID))
            return (worktreeID, withFileID, aloneID)
        }

        let withFile = try #require(try Self.layout(queue, tabID: seeded.withFileID))
        #expect(withFile == Layout(panelIDs: [filePanelID], activePanelID: filePanelID, recency: [filePanelID]))
        let withFileHistories = try Self.historyPanelIDs(queue, tabID: seeded.withFileID)
        #expect(withFileHistories == [filePanelID.uuidString])

        let worktreePanelID = try #require(try Self.panelRows(queue, worktreeID: seeded.worktreeID).first?.id)
        let alone = try #require(try Self.layout(queue, tabID: seeded.aloneID))
        #expect(alone == Layout(panelIDs: [], activePanelID: worktreePanelID, recency: [], collapsed: false))
        let aloneHistories = try Self.historyPanelIDs(queue, tabID: seeded.aloneID)
        #expect(aloneHistories.isEmpty)
    }

    /// Every surface whose primary is a note is deleted with its panels'
    /// histories, whether or not the note still has a row; a terminal's
    /// surface stays.
    @Test func deletesNotePrimarySurfaces() throws {
        let sidePanelID = UUID()
        let (queue, seeded) = try Self.migrate { db -> (noteTabID: UUID, deletedNoteTabID: UUID, terminalTabID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            let noteTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.notePrimary(noteID),
                layout: encodeJSONString(Layout(
                    panelIDs: [sidePanelID], activePanelID: sidePanelID, recency: [sidePanelID])))
            try Self.insertHistory(db, panelID: sidePanelID, tabID: noteTabID, history: Self.fileHistory())
            let deletedNoteTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.notePrimary(UUID()),
                layout: encodeJSONString(Layout(panelIDs: [], activePanelID: nil, recency: [])),
                position: 1)
            let terminalTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(panelIDs: [], activePanelID: nil, recency: [])),
                position: 2)
            return (noteTabID, deletedNoteTabID, terminalTabID)
        }

        #expect(try !Self.surfaceExists(queue, tabID: seeded.noteTabID))
        #expect(try !Self.surfaceExists(queue, tabID: seeded.deletedNoteTabID))
        #expect(try Self.surfaceExists(queue, tabID: seeded.terminalTabID))
        let noteTabHistories = try Self.historyPanelIDs(queue, tabID: seeded.noteTabID)
        #expect(noteTabHistories.isEmpty)
    }

    // MARK: - Front and collapse

    /// A tab whose side region had no panels fronts the worktree's first
    /// panel and comes out collapsed, so the update narrows no terminal; the
    /// store reads it back, and it passes the validator.
    @Test func emptyRegionComesOutCollapsed() async throws {
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, noteID: UUID, tabID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            let tabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(panelIDs: [], activePanelID: nil, recency: [])))
            return (worktreeID, noteID, tabID)
        }

        let worktreePanelID = try #require(try Self.panelRows(queue, worktreeID: seeded.worktreeID).first?.id)
        let layout = try #require(try Self.layout(queue, tabID: seeded.tabID))
        #expect(layout == Layout(panelIDs: [], activePanelID: worktreePanelID, recency: [], collapsed: true))
        let revision = try #require(try Self.revision(queue, tabID: seeded.tabID))
        #expect(revision > Self.counterBefore)

        let surfaces = try await PanelSurfaceStore(writer: queue).surfaces(worktreeID: seeded.worktreeID)
        let surface = try #require(surfaces.first)
        #expect(surface.side.collapsed)
        #expect(surface.side.activePanelID == worktreePanelID)
        let worktreePanelContents = surface.worktreePanels.map(\.content)
        let expectedContents: [WorktreePanelContent] = [.note(noteID: seeded.noteID)]
        #expect(worktreePanelContents == expectedContents)
        let violations = PanelSurfaceValidator.violations(in: surface)
        #expect(violations.isEmpty)
        #expect(!surface.isSideVisible)
    }

    /// A tab whose side region had panels keeps its front and its collapse
    /// state, and its row is not rewritten; its strip gains the worktree
    /// panel when the store joins it in.
    @Test(arguments: [false, true])
    func tabWithPanelsKeepsCollapseAndFront(collapsed: Bool) async throws {
        let filePanelID = UUID()
        let seededLayout = Layout(
            panelIDs: [filePanelID], activePanelID: filePanelID, recency: [filePanelID], collapsed: collapsed)
        let (queue, seeded) = try Self.migrate { db -> (worktreeID: UUID, noteID: UUID, tabID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            let tabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(seededLayout), revision: 7)
            try Self.insertHistory(db, panelID: filePanelID, tabID: tabID, history: Self.fileHistory())
            return (worktreeID, noteID, tabID)
        }

        let layout = try #require(try Self.layout(queue, tabID: seeded.tabID))
        #expect(layout == seededLayout)
        let revision = try Self.revision(queue, tabID: seeded.tabID)
        #expect(revision == 7)

        let surfaces = try await PanelSurfaceStore(writer: queue).surfaces(worktreeID: seeded.worktreeID)
        let surface = try #require(surfaces.first)
        #expect(surface.side.activePanelID == filePanelID)
        #expect(surface.side.collapsed == collapsed)
        let worktreePanelContents = surface.worktreePanels.map(\.content)
        let expectedContents: [WorktreePanelContent] = [.note(noteID: seeded.noteID)]
        #expect(worktreePanelContents == expectedContents)
    }

    /// A worktree with no notes keeps its tab order, its surfaces' layouts
    /// and their revisions byte for byte, an empty side region included, and
    /// gets no worktree panels, while another worktree's notes move.
    @Test func leavesWorktreeWithoutNotesUntouched() throws {
        let filePanelID = UUID()
        let terminalTabIDs = [UUID(), UUID()]
        // Spaced as no JSONEncoder writes them, so a rewrite would show.
        let quietTabOrder = "[ \"\(terminalTabIDs[0].uuidString)\", \"\(terminalTabIDs[1].uuidString)\" ]"
        let panelLayoutText = """
            { "panelIDs": ["\(filePanelID.uuidString)"], "activePanelID": "\(filePanelID.uuidString)", \
            "recency": ["\(filePanelID.uuidString)"], "collapsed": false, "width": 0.4 }
            """
        let emptyLayoutText = #"{ "panelIDs": [], "recency": [], "collapsed": false, "width": 0.5 }"#
        let (queue, seeded) = try Self.migrate { db -> (otherID: UUID, quietID: UUID, panelTabID: UUID, emptyTabID: UUID) in
            let otherID = try Self.insertWorktree(db)
            _ = try Self.insertNote(db, worktreeID: otherID)
            _ = try Self.insertSurface(
                db, worktreeID: otherID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(panelIDs: [], activePanelID: nil, recency: [])))
            let quietID = try Self.insertWorktree(db, tabOrder: quietTabOrder)
            let panelTabID = try Self.insertSurface(
                db, worktreeID: quietID, primary: Self.terminalPrimary(), layout: panelLayoutText, revision: 3)
            try Self.insertHistory(db, panelID: filePanelID, tabID: panelTabID, history: Self.fileHistory())
            let emptyTabID = try Self.insertSurface(
                db, worktreeID: quietID, primary: Self.terminalPrimary(), layout: emptyLayoutText,
                position: 1, revision: 4)
            return (otherID, quietID, panelTabID, emptyTabID)
        }

        let otherPanels = try Self.panelRows(queue, worktreeID: seeded.otherID)
        #expect(otherPanels.count == 1)

        #expect(try Self.tabOrderText(queue, worktreeID: seeded.quietID) == quietTabOrder)
        #expect(try Self.layoutText(queue, tabID: seeded.panelTabID) == panelLayoutText)
        #expect(try Self.layoutText(queue, tabID: seeded.emptyTabID) == emptyLayoutText)
        #expect(try Self.revision(queue, tabID: seeded.panelTabID) == 3)
        #expect(try Self.revision(queue, tabID: seeded.emptyTabID) == 4)
        let quietPanels = try Self.panelRows(queue, worktreeID: seeded.quietID)
        #expect(quietPanels.isEmpty)
    }

    // MARK: - Robustness

    /// A layout that does not parse, a panel with no history row, a tab order
    /// that is not JSON and a primary that is not JSON are each logged and
    /// left as they are, the migration finishes without throwing, and the
    /// rows around them move. The surfaces left alone are ones the migration
    /// would otherwise rewrite: the orphan's tab shows a note panel in front,
    /// and the bad primary's side region is empty.
    @Test func skipsMalformedRowsWithoutThrowing() throws {
        let orphanPanelID = UUID()
        let orphanNotePanelID = UUID()
        let filePanelID = UUID()
        let notePanelID = UUID()
        let badLayoutText = "{not json"
        let orphanLayoutText = try encodeJSONString(Layout(
            panelIDs: [orphanNotePanelID, orphanPanelID], activePanelID: orphanNotePanelID,
            recency: [orphanNotePanelID, orphanPanelID]))
        let emptyLayoutText = try encodeJSONString(Layout(panelIDs: [], activePanelID: nil, recency: []))
        // `migrate` runs the whole chain, so returning from it is the
        // migration returning.
        let (queue, seeded) = try Self.migrate {
            db -> (worktreeID: UUID, badTabID: UUID, orphanTabID: UUID, badPrimaryTabID: UUID, goodTabID: UUID) in
            let worktreeID = try Self.insertWorktree(db, tabOrder: "not json")
            let noteID = try Self.insertNote(db, worktreeID: worktreeID)
            let badTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(), layout: badLayoutText, revision: 5)
            let orphanTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(), layout: orphanLayoutText,
                position: 1, revision: 6)
            try Self.insertHistory(
                db, panelID: orphanNotePanelID, tabID: orphanTabID, history: Self.noteHistory(noteID))
            let badPrimaryTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: "{not json", layout: emptyLayoutText,
                position: 2, revision: 7)
            let goodTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(
                    panelIDs: [filePanelID, notePanelID], activePanelID: notePanelID,
                    recency: [notePanelID, filePanelID])),
                position: 3)
            try Self.insertHistory(db, panelID: filePanelID, tabID: goodTabID, history: Self.fileHistory())
            try Self.insertHistory(db, panelID: notePanelID, tabID: goodTabID, history: Self.noteHistory(noteID))
            return (worktreeID, badTabID, orphanTabID, badPrimaryTabID, goodTabID)
        }

        #expect(try Self.tabOrderText(queue, worktreeID: seeded.worktreeID) == "not json")
        #expect(try Self.layoutText(queue, tabID: seeded.badTabID) == badLayoutText)
        #expect(try Self.revision(queue, tabID: seeded.badTabID) == 5)
        #expect(try Self.layoutText(queue, tabID: seeded.orphanTabID) == orphanLayoutText)
        #expect(try Self.revision(queue, tabID: seeded.orphanTabID) == 6)
        let orphanHistories = try Self.historyPanelIDs(queue, tabID: seeded.orphanTabID)
        #expect(orphanHistories == [orphanNotePanelID.uuidString])
        #expect(try Self.layoutText(queue, tabID: seeded.badPrimaryTabID) == emptyLayoutText)
        #expect(try Self.revision(queue, tabID: seeded.badPrimaryTabID) == 7)

        let panels = try Self.panelRows(queue, worktreeID: seeded.worktreeID)
        let worktreePanelID = try #require(panels.first?.id)
        #expect(panels.count == 1)
        let good = try #require(try Self.layout(queue, tabID: seeded.goodTabID))
        #expect(good == Layout(panelIDs: [filePanelID], activePanelID: worktreePanelID, recency: [filePanelID]))
    }

    /// Running the migration a second time makes no second panel for a note
    /// and changes no surface, so it takes no revision: a tab the first run
    /// collapsed stays collapsed, and one the user has expanded since stays
    /// expanded.
    @Test func runningTwiceMakesOnePanelPerNote() throws {
        let filePanelID = UUID()
        let notePanelID = UUID()
        let (queue, seeded) = try Self.migrate {
            db -> (worktreeID: UUID, panelTabID: UUID, emptyTabID: UUID, collapsedTabID: UUID) in
            let worktreeID = try Self.insertWorktree(db)
            let first = try Self.insertNote(db, worktreeID: worktreeID)
            let second = try Self.insertNote(
                db, worktreeID: worktreeID, createdAt: Date(timeIntervalSince1970: 1_800_000_060))
            try Self.setTabOrder(db, worktreeID: worktreeID, [first, second])
            let panelTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(
                    panelIDs: [filePanelID, notePanelID], activePanelID: notePanelID,
                    recency: [notePanelID, filePanelID])))
            try Self.insertHistory(db, panelID: filePanelID, tabID: panelTabID, history: Self.fileHistory())
            try Self.insertHistory(db, panelID: notePanelID, tabID: panelTabID, history: Self.noteHistory(second))
            let emptyTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(panelIDs: [], activePanelID: nil, recency: [])),
                position: 1)
            let collapsedTabID = try Self.insertSurface(
                db, worktreeID: worktreeID, primary: Self.terminalPrimary(),
                layout: encodeJSONString(Layout(panelIDs: [], activePanelID: nil, recency: [])),
                position: 2)
            return (worktreeID, panelTabID, emptyTabID, collapsedTabID)
        }
        let panelsAfterFirst = try Self.panelRows(queue, worktreeID: seeded.worktreeID)
        let panelLayoutAfterFirst = try Self.layoutText(queue, tabID: seeded.panelTabID)
        let collapsedLayoutAfterFirst = try Self.layoutText(queue, tabID: seeded.collapsedTabID)
        let collapsedAfterFirst = try #require(try Self.layout(queue, tabID: seeded.collapsedTabID))
        #expect(collapsedAfterFirst.collapsed)

        // The user expands one of the tabs the first run collapsed.
        var expanded = try #require(try Self.layout(queue, tabID: seeded.emptyTabID))
        #expect(expanded.collapsed)
        expanded.collapsed = false
        let expandedLayoutText = try encodeJSONString(expanded)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE workspace_tab_surface SET layout = ? WHERE id = ?",
                arguments: [expandedLayoutText, seeded.emptyTabID.uuidString])
        }
        let expandedRevision = try Self.revision(queue, tabID: seeded.emptyTabID)
        let counterAfterFirst = try Self.counter(queue)

        try queue.write { db in try SidePanelNotesMigration.run(db) }

        let panels = try Self.panelRows(queue, worktreeID: seeded.worktreeID)
        #expect(panels.count == 2)
        let ids = panels.map(\.id)
        let idsAfterFirst = panelsAfterFirst.map(\.id)
        #expect(ids == idsAfterFirst)
        let contents = panels.map(\.content)
        let contentsAfterFirst = panelsAfterFirst.map(\.content)
        #expect(contents == contentsAfterFirst)
        #expect(try Self.layoutText(queue, tabID: seeded.panelTabID) == panelLayoutAfterFirst)
        #expect(try Self.layoutText(queue, tabID: seeded.collapsedTabID) == collapsedLayoutAfterFirst)
        #expect(try Self.layoutText(queue, tabID: seeded.emptyTabID) == expandedLayoutText)
        let afterRerun = try #require(try Self.layout(queue, tabID: seeded.emptyTabID))
        #expect(!afterRerun.collapsed)
        #expect(try Self.revision(queue, tabID: seeded.emptyTabID) == expandedRevision)
        #expect(try Self.counter(queue) == counterAfterFirst)
    }
}
