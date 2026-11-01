import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
import TBDShared

/// The worktree's panels in `PanelSurfaceStore` (side panel notes spec,
/// "Daemon"): the `worktree_panel` rows, the list every surface of the
/// worktree reads, the surfaces a change to the list rewrites, and how
/// archive, promote, note deletion and a deleted worktree row reclaim them,
/// and `applyReducing`'s refusal of a note panel for a note not in the
/// worktree. The operations that change the list from a tab are otherwise
/// covered by `PanelCoordinatorTests`.
@Suite("WorktreePanelStoreTests")
struct WorktreePanelStoreTests {

    /// A worktree row (via the real store, so FKs are satisfiable).
    private func makeWorktree(
        _ db: TBDDatabase, name: String = "w"
    ) async throws -> (repoID: UUID, worktreeID: UUID) {
        let repo = try await db.repos.create(
            path: "/tmp/wps-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/wps-wt-\(UUID())", tmuxServer: "srv")
        return (repo.id, wt.id)
    }

    /// Seeds a tab with one file panel in front.
    @discardableResult
    private func seedTab(
        _ db: TBDDatabase, worktreeID: UUID, panelID: PanelID = UUID(),
        collapsed: Bool = false, position: Int
    ) async throws -> WorkspaceTabSurface {
        let surface = WorkspaceTabSurface(
            id: UUID(), worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()),
            side: SideRegion(
                panels: [ViewerPanel(id: panelID, content: .file(FileReference(path: "/a.txt")))],
                activePanelID: panelID, recency: [panelID], collapsed: collapsed, width: 0.4))
        try await db.panelSurface.commit(surface: surface, position: position, receipt: nil, now: Date())
        return surface
    }

    /// Seeds a tab whose side region has no panels.
    @discardableResult
    private func seedEmptyTab(
        _ db: TBDDatabase, worktreeID: UUID, position: Int
    ) async throws -> WorkspaceTabSurface {
        let surface = WorkspaceTabSurface(
            id: UUID(), worktreeID: worktreeID, label: "empty",
            primary: .terminal(terminalID: UUID()), side: .empty)
        try await db.panelSurface.commit(surface: surface, position: position, receipt: nil, now: Date())
        return surface
    }

    private func panelRowCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM worktree_panel WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString]) ?? -1
        }
    }

    private func panelRowExists(_ db: TBDDatabase, panelID: PanelID) async throws -> Bool {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM worktree_panel WHERE id = ?",
                arguments: [panelID.uuidString]) == 1
        }
    }

    // MARK: - Reading

    /// Rows read back in position order, whatever order they were written
    /// in, and a row whose ID or content does not parse, or that repeats an
    /// earlier row's content, is skipped rather than failing the read.
    @Test func readSkipsMalformedAndRepeatedRowsInPositionOrder() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let noteID = UUID()
        let notePanel = WorktreePanel(id: UUID(), content: .note(noteID: noteID))
        let changesPanel = WorktreePanel(id: UUID(), content: .changes)
        let repeatedNote = WorktreePanel(id: UUID(), content: .note(noteID: noteID))
        try await db.writerForTests.write { dbc in
            try WorktreePanelRecord(from: changesPanel, worktreeID: wtID, position: 1).insert(dbc)
            try WorktreePanelRecord(from: notePanel, worktreeID: wtID, position: 0).insert(dbc)
            try WorktreePanelRecord(from: repeatedNote, worktreeID: wtID, position: 2).insert(dbc)
            try dbc.execute(
                sql: "INSERT INTO worktree_panel (id, worktreeID, position, content) VALUES (?, ?, ?, ?)",
                arguments: ["not-a-uuid", wtID.uuidString, 3, #"{"changes":{}}"#])
            try dbc.execute(
                sql: "INSERT INTO worktree_panel (id, worktreeID, position, content) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, wtID.uuidString, 4, "not json"])
        }

        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)

        #expect(panels == [notePanel, changesPanel])
        #expect(try await panelRowCount(db, worktreeID: wtID) == 5, "a read deletes nothing")
    }

    /// `panel.get`'s read: the surfaces and the panels come back from one
    /// read, whole or narrowed to one tab, and a tab of another worktree
    /// narrows to no tab while the panels still come back.
    @Test func panelSnapshotReadsTabsAndPanelsTogether() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let (_, otherID) = try await makeWorktree(db, name: "other")
        let first = try await seedTab(db, worktreeID: wtID, position: 0)
        let second = try await seedEmptyTab(db, worktreeID: wtID, position: 1)
        let foreign = try await seedTab(db, worktreeID: otherID, position: 0)
        try await db.openWorktreePanelForTests(worktreeID: wtID, content: .changes)
        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        try #require(panels.count == 1)

        let whole = try await db.panelSurface.panelSnapshot(worktreeID: wtID, tabID: nil)
        #expect(whole.tabs.map(\.id) == [first.id, second.id])
        #expect(whole.worktreePanels == panels)
        let listsPerTab = whole.tabs.map(\.worktreePanels)
        let expectedLists: [[WorktreePanel]] = [panels, panels]
        #expect(listsPerTab == expectedLists)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == whole.tabs)

        let scoped = try await db.panelSurface.panelSnapshot(worktreeID: wtID, tabID: second.id)
        #expect(scoped.tabs.map(\.id) == [second.id])
        #expect(scoped.worktreePanels == panels)

        let misattributed = try await db.panelSurface.panelSnapshot(worktreeID: wtID, tabID: foreign.id)
        #expect(misattributed.tabs.isEmpty)
        #expect(misattributed.worktreePanels == panels)
    }

    @Test func recordRoundTripsBothKindsOfContent() throws {
        let worktreeID = UUID()
        for content in [WorktreePanelContent.note(noteID: UUID()), .changes] {
            let panel = WorktreePanel(id: UUID(), content: content)
            let record = try WorktreePanelRecord(from: panel, worktreeID: worktreeID, position: 3)
            #expect(record.worktreeID == worktreeID.uuidString)
            #expect(record.position == 3)
            #expect(record.toModel() == panel)
        }
    }

    // MARK: - Tab sync imports

    /// The entry the coordinator builds for a terminal tab, importing `side`
    /// when the tab has no readable surface.
    private func terminalEntry(
        tabID: UUID = UUID(), worktreeID: UUID, position: Int, label: String? = nil,
        side: SideRegion = .empty
    ) -> SyncTabEntry {
        let primary = PrimaryContent.terminal(terminalID: tabID)
        return SyncTabEntry(
            tabID: tabID, position: position, label: label, primary: primary,
            importCandidate: WorkspaceTabSurface(
                id: tabID, worktreeID: worktreeID, primary: primary, side: side))
    }

    /// In a worktree with panels, an import keeps the collapse state the app
    /// gave it, open or collapsed: for a missing row and for an unreadable
    /// row replaced by its import, a tab with no panel of its own fronting
    /// the first worktree panel, and for a tab with a panel of its own,
    /// which keeps its own front.
    @Test(arguments: [false, true])
    func importKeepsTheCandidatesCollapse(collapsed: Bool) async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        try await db.openWorktreePanelForTests(worktreeID: wtID, content: .changes)
        try await db.openWorktreePanelForTests(worktreeID: wtID, content: .note(noteID: note.id))
        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        try #require(panels.count == 2)
        let unreadable = try await seedEmptyTab(db, worktreeID: wtID, position: 1)
        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = 'not a layout' WHERE id = ?",
                arguments: [unreadable.id.uuidString])
        }
        let emptySide = SideRegion(collapsed: collapsed)
        let filePanelID = UUID()
        let fileSide = SideRegion(
            panels: [ViewerPanel(id: filePanelID, content: .file(FileReference(path: "/a.txt")))],
            activePanelID: filePanelID, recency: [filePanelID], collapsed: collapsed, width: 0.4)
        let fresh = terminalEntry(worktreeID: wtID, position: 0, side: emptySide)
        let replaced = terminalEntry(tabID: unreadable.id, worktreeID: wtID, position: 1, side: emptySide)
        let withOwnPanel = terminalEntry(worktreeID: wtID, position: 2, side: fileSide)

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [fresh, replaced, withOwnPanel], now: Date())

        #expect(outcome.imported == [fresh.tabID, replaced.tabID, withOwnPanel.tabID])
        try #require(outcome.changed.count == 3)
        for imported in outcome.changed {
            #expect(imported.side.collapsed == collapsed)
            #expect(imported.worktreePanels == panels)
            #expect(try await db.panelSurface.surface(tabID: imported.id) == imported, "it reads back valid")
        }
        for imported in outcome.changed.prefix(2) {
            #expect(imported.side.panels.isEmpty)
            #expect(imported.side.activePanelID == panels[0].id)
        }
        #expect(outcome.changed[2].side == fileSide, "it keeps its own front")
    }

    /// In a worktree without panels an import is written as the app gave it.
    @Test func importInWorktreeWithoutPanelsIsUnchanged() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let entry = terminalEntry(worktreeID: wtID, position: 0)

        let outcome = try await db.panelSurface.syncTabs(worktreeID: wtID, entries: [entry], now: Date())

        let imported = try #require(outcome.changed.first)
        #expect(imported.side.collapsed == false)
        #expect(imported.side.activePanelID == nil)
        #expect(imported.worktreePanels.isEmpty)
        #expect(try await db.panelSurface.surface(tabID: entry.tabID) == imported)
    }

    // MARK: - Writing

    /// A panel ID whose row belongs to another worktree is refused rather
    /// than moved out of that worktree's list.
    @Test func writeRefusesAPanelOwnedByAnotherWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, ownerID) = try await makeWorktree(db, name: "owner")
        let (_, otherID) = try await makeWorktree(db, name: "other")
        try await db.openWorktreePanelForTests(worktreeID: ownerID, content: .changes)
        let owned = try #require(try await db.panelSurface.worktreePanels(worktreeID: ownerID).first)

        await #expect(throws: PanelSurfaceStoreError.worktreePanelOwnedByOtherWorktree(
            panelID: owned.id, existingWorktreeID: ownerID, incomingWorktreeID: otherID)) {
            try await db.writerForTests.write { dbc in
                try PanelSurfaceStore.writeWorktreePanels([owned], worktreeID: otherID, db: dbc)
            }
        }

        #expect(try await db.panelSurface.worktreePanels(worktreeID: ownerID) == [owned])
        #expect(try await db.panelSurface.worktreePanels(worktreeID: otherID).isEmpty)
    }

    // MARK: - Opening a note from a tab

    /// The daemon-wide revision counter's value.
    private func revisionCounter(_ db: TBDDatabase) async throws -> Int64? {
        try await db.writerForTests.read { dbc in
            try Int64.fetchOne(dbc, sql: "SELECT value FROM panel_revision_counter WHERE id = 1")
        }
    }

    /// `applyReducing` checks, inside its transaction, that a note panel the
    /// operation adds shows a note of the worktree. A note with no row, as
    /// after a `note.delete` that committed between the caller's own check
    /// and the operation, and another worktree's note are both refused, and
    /// nothing is written: no panel, no change to the surface, no receipt
    /// and no revision taken. The worktree's own note still opens.
    @Test func applyRefusesANotePanelForANoteNotInTheWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let (_, otherID) = try await makeWorktree(db, name: "other")
        let ownNote = try await db.notes.create(worktreeID: wtID)
        let foreignNote = try await db.notes.create(worktreeID: otherID)
        let tab = try await seedTab(db, worktreeID: wtID, position: 0)
        let before = try #require(try await db.panelSurface.surface(tabID: tab.id))
        let counterBefore = try await revisionCounter(db)

        for noteID in [UUID(), foreignNote.id] {
            let operationID = UUID()
            await #expect(throws: PanelSurfaceStoreError.noteNotInWorktree(noteID: noteID, worktreeID: wtID)) {
                _ = try await db.panelSurface.applyReducing(
                    operationID: operationID, tabID: tab.id, worktreeID: wtID, now: Date()
                ) { current in
                    try PanelSurfaceReducer.apply(
                        .open(content: .note(noteID: noteID), newPanel: false), to: current)
                }
            }
            #expect(try await db.panelSurface.receipt(operationID: operationID) == nil)
        }

        #expect(try await db.panelSurface.surface(tabID: tab.id) == before)
        #expect(try await panelRowCount(db, worktreeID: wtID) == 0)
        #expect(try await panelRowCount(db, worktreeID: otherID) == 0)
        #expect(try await revisionCounter(db) == counterBefore)

        let outcome = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: tab.id, worktreeID: wtID, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.open(content: .note(noteID: ownNote.id), newPanel: false), to: current)
        }
        guard case .applied(let applied, _)? = outcome else {
            Issue.record("expected .applied, got \(String(describing: outcome))")
            return
        }
        #expect(applied.tab.worktreePanel(showing: .note(noteID: ownNote.id)) != nil)
        #expect(try await panelRowCount(db, worktreeID: wtID) == 1)
    }

    // MARK: - Note deletion

    /// Deleting a note removes its panel from the worktree and from every
    /// surface, in one transaction, and names the surfaces it rewrote.
    @Test func noteDeleteRemovesItsPanelFromEverySurface() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        let tabA = try await seedTab(db, worktreeID: wtID, position: 0)
        let tabB = try await seedEmptyTab(db, worktreeID: wtID, position: 1)
        try await db.openWorktreePanelForTests(worktreeID: wtID, content: .changes)
        let opened = try await db.openWorktreePanelForTests(worktreeID: wtID, content: .note(noteID: note.id))
        let changesPanel = try #require(try await db.panelSurface.worktreePanels(worktreeID: wtID).first)
        let revisionsBefore = opened.map(\.revision)

        let deletion = try #require(try await db.notes.delete(id: note.id))

        #expect(deletion.worktreeID == wtID)
        #expect(deletion.changedSurfaces.map(\.id) == [tabA.id, tabB.id])
        #expect(try await db.notes.get(id: note.id) == nil)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: wtID) == [changesPanel])
        let stored = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(stored == deletion.changedSurfaces)
        let noteShown = stored.contains { $0.worktreePanel(showing: .note(noteID: note.id)) != nil }
        #expect(!noteShown)
        let revisionsAfter = stored.map(\.revision)
        let everyRevisionFresh = revisionsAfter.count == revisionsBefore.count
            && zip(revisionsBefore, revisionsAfter).allSatisfy { $0 < $1 }
        #expect(everyRevisionFresh, "each rewritten surface takes a fresh revision")
        #expect(stored.first?.side.activePanelID == tabA.side.activePanelID)
    }

    /// No row, no panel: nil. A note with no panel deletes and rewrites
    /// nothing.
    @Test func noteDeleteWithoutAPanelRewritesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        let tab = try await seedTab(db, worktreeID: wtID, position: 0)

        #expect(try await db.notes.delete(id: UUID()) == nil, "no row existed")
        let deletion = try await db.notes.delete(id: note.id)

        #expect(deletion == NoteDeletion(worktreeID: wtID, changedSurfaces: []))
        #expect(try await db.panelSurface.surface(tabID: tab.id) == tab)
    }

    // MARK: - Reclamation

    /// An archived worktree keeps its row, so no cascade reclaims its
    /// panels; the archive itself must, and leaves other worktrees' alone.
    @Test func archiveDeletesWorktreePanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, archivedID) = try await makeWorktree(db, name: "archived")
        let (_, keptID) = try await makeWorktree(db, name: "kept")
        let note = try await db.notes.create(worktreeID: archivedID)
        try await seedEmptyTab(db, worktreeID: archivedID, position: 0)
        for worktreeID in [archivedID, keptID] {
            try await db.openWorktreePanelForTests(worktreeID: worktreeID, content: .changes)
        }
        try await db.openWorktreePanelForTests(worktreeID: archivedID, content: .note(noteID: note.id))
        #expect(try await panelRowCount(db, worktreeID: archivedID) == 2, "precondition")
        let keptBefore = try await db.panelSurface.worktreePanels(worktreeID: keptID)

        try await db.worktrees.archive(id: archivedID)

        #expect(try await panelRowCount(db, worktreeID: archivedID) == 0)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: archivedID).isEmpty)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: keptID) == keptBefore)
        #expect(try await db.notes.get(id: note.id) != nil, "archiving deletes no note")
    }

    /// Deleting the worktree row deletes its panels through the cascade.
    @Test func deletingTheWorktreeRowCascadesToItsPanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (repoID, wtID) = try await makeWorktree(db)
        try await db.openWorktreePanelForTests(worktreeID: wtID, content: .changes)
        #expect(try await panelRowCount(db, worktreeID: wtID) == 1, "precondition")

        try await db.worktrees.deleteForRepo(repoID: repoID)

        #expect(try await panelRowCount(db, worktreeID: wtID) == 0)
    }

    /// A repo with a main worktree and a scratch worktree to promote into it.
    private func makePromotePair(
        _ db: TBDDatabase
    ) async throws -> (repoID: UUID, scratch: Worktree, mainID: UUID) {
        let repo = try await db.repos.create(
            path: "/tmp/wps-promote-repo-\(UUID())", displayName: "r", defaultBranch: "main")
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/wps-scratch-\(UUID())", tmuxServer: "tbd-scratch")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/wps-main-\(UUID())", tmuxServer: "tbd-main")
        return (repo.id, scratch, main.id)
    }

    /// The part of a `layout` column these tests read: the tab's own panels
    /// and the panel in front.
    private struct StoredLayoutColumn: Decodable {
        let panelIDs: [PanelID]
        let activePanelID: PanelID?
    }

    /// A tab's `layout` column as stored, decoded from the raw text rather
    /// than through a read, which would repair a front naming a missing
    /// panel.
    private func storedLayout(_ db: TBDDatabase, tabID: UUID) async throws -> StoredLayoutColumn {
        let json = try await db.writerForTests.read { dbc in
            try String.fetchOne(
                dbc, sql: "SELECT layout FROM workspace_tab_surface WHERE id = ?",
                arguments: [tabID.uuidString])
        }
        return try JSONDecoder().decode(StoredLayoutColumn.self, from: Data(try #require(json).utf8))
    }

    /// Every `worktree_panel` row that shows `noteID`, in any worktree.
    private func notePanelRowCount(_ db: TBDDatabase, noteID: UUID) async throws -> Int {
        let content = try encodeJSONString(WorktreePanelContent.note(noteID: noteID))
        return try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM worktree_panel WHERE content = ?",
                arguments: [content]) ?? -1
        }
    }

    /// A scratch promote moves the scratch worktree's Changes panel to a
    /// main worktree that has none, after the main worktree's own panels,
    /// and deletes its note panels: the notes stay with the archived scratch
    /// worktree. A moved tab that had a note panel in front is stored
    /// fronting its most recent own panel, else the merged list's first
    /// panel, so its `layout` column never names the deleted panel. The main
    /// worktree's own tab takes the merged list at a fresh revision, keeping
    /// its front, and the promote returns it with the moved tabs.
    @Test func promoteMovesTheChangesPanelAndDeletesNotePanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (repoID, scratch, mainID) = try await makePromotePair(db)
        let resident = try await seedTab(db, worktreeID: mainID, position: 0)
        let residentBefore = try #require(try await db.panelSurface.surface(tabID: resident.id))

        let note = try await db.notes.create(worktreeID: scratch.id)
        let ownPanelID = UUID()
        let withOwnPanel = try await seedTab(db, worktreeID: scratch.id, panelID: ownPanelID, position: 0)
        let withoutPanels = try await seedEmptyTab(db, worktreeID: scratch.id, position: 1)
        try await db.openWorktreePanelForTests(worktreeID: scratch.id, content: .note(noteID: note.id))
        try await db.openWorktreePanelForTests(worktreeID: scratch.id, content: .changes)
        let scratchPanels = try await db.panelSurface.worktreePanels(worktreeID: scratch.id)
        let scratchContent: [WorktreePanelContent] = [.note(noteID: note.id), .changes]
        try #require(scratchPanels.map(\.content) == scratchContent)
        let scratchNote = scratchPanels[0]
        let scratchChanges = scratchPanels[1]
        _ = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: withOwnPanel.id, worktreeID: scratch.id, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.select(panelID: scratchNote.id), to: current)
        }
        // Preconditions: both scratch tabs show the note panel.
        let scratchSurfaces = try await db.panelSurface.surfaces(worktreeID: scratch.id)
        let frontsBefore: [PanelID?] = [scratchNote.id, scratchNote.id]
        try #require(scratchSurfaces.map(\.side.activePanelID) == frontsBefore)

        let returned = try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: mainID, repoID: repoID,
            tmuxServer: scratch.tmuxServer)

        #expect(try await db.panelSurface.worktreePanels(worktreeID: mainID) == [scratchChanges],
                "the Changes panel moves, keeping its ID")
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 0)
        #expect(try await notePanelRowCount(db, noteID: note.id) == 0, "no note panel survives anywhere")
        #expect(try await db.notes.get(id: note.id)?.worktreeID == scratch.id,
                "the note itself stays with the scratch worktree")

        let surfaces = try await db.panelSurface.surfaces(worktreeID: mainID)
        try #require(surfaces.map(\.id) == [resident.id, withOwnPanel.id, withoutPanels.id])
        let shownLists = surfaces.map(\.worktreePanels)
        let mergedForEach: [[WorktreePanel]] = [[scratchChanges], [scratchChanges], [scratchChanges]]
        #expect(shownLists == mergedForEach)
        #expect(surfaces[0].side == residentBefore.side, "the main worktree's own tab keeps its front")
        #expect(surfaces[0].revision > residentBefore.revision)
        #expect(surfaces[1].side.activePanelID == ownPanelID,
                "a moved tab that fronted a note panel fronts its most recent own panel")
        #expect(surfaces[2].side.activePanelID == scratchChanges.id,
                "with no own panel, it fronts the merged list's first panel")
        #expect(returned == surfaces)

        // The stored rows, not only the reads, name panels that exist.
        let mainPanels = try await db.panelSurface.worktreePanels(worktreeID: mainID)
        let mainPanelIDs = Set(mainPanels.map(\.id))
        for tab in [withOwnPanel, withoutPanels] {
            let stored = try await storedLayout(db, tabID: tab.id)
            let front = try #require(stored.activePanelID)
            let frontExists = stored.panelIDs.contains(front) || mainPanelIDs.contains(front)
            #expect(frontExists, "tab \(tab.id)'s stored front \(front) names no panel")
        }
        #expect(try await storedLayout(db, tabID: withOwnPanel.id).activePanelID == ownPanelID)
        #expect(try await storedLayout(db, tabID: withoutPanels.id).activePanelID == scratchChanges.id)
    }

    /// When the main worktree already has a Changes panel, the scratch
    /// worktree's is deleted, and a moved tab that had it in front is stored
    /// fronting the main worktree's Changes panel — not its most recent own
    /// panel, and not the merged list's first panel, here the main
    /// worktree's note panel. The scratch note panels are deleted all the
    /// same, and the main worktree's list is unchanged, so its own tab is not
    /// rewritten and the promote returns only the moved tabs.
    @Test func promoteDropsTheScratchChangesPanelWhenMainHasOne() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (repoID, scratch, mainID) = try await makePromotePair(db)
        let resident = try await seedTab(db, worktreeID: mainID, position: 0)
        let mainNote = try await db.notes.create(worktreeID: mainID)
        try await db.openWorktreePanelForTests(worktreeID: mainID, content: .note(noteID: mainNote.id))
        try await db.openWorktreePanelForTests(worktreeID: mainID, content: .changes)
        let mainPanels = try await db.panelSurface.worktreePanels(worktreeID: mainID)
        let mainContent: [WorktreePanelContent] = [.note(noteID: mainNote.id), .changes]
        try #require(mainPanels.map(\.content) == mainContent,
                     "precondition: the merged list's first panel is not Changes")
        let mainChanges = mainPanels[1]
        let residentBefore = try #require(try await db.panelSurface.surface(tabID: resident.id))

        let note = try await db.notes.create(worktreeID: scratch.id)
        let ownPanelID = UUID()
        let withOwnPanel = try await seedTab(db, worktreeID: scratch.id, panelID: ownPanelID, position: 0)
        let withoutPanels = try await seedEmptyTab(db, worktreeID: scratch.id, position: 1)
        try await db.openWorktreePanelForTests(worktreeID: scratch.id, content: .note(noteID: note.id))
        try await db.openWorktreePanelForTests(worktreeID: scratch.id, content: .changes)
        let scratchChanges = try #require(
            try await db.panelSurface.worktreePanels(worktreeID: scratch.id).last)
        for tab in [withOwnPanel, withoutPanels] {
            _ = try await db.panelSurface.applyReducing(
                operationID: UUID(), tabID: tab.id, worktreeID: scratch.id, now: Date()
            ) { current in
                try PanelSurfaceReducer.apply(.select(panelID: scratchChanges.id), to: current)
            }
        }
        // Precondition: both scratch tabs show the scratch Changes panel.
        let scratchSurfaces = try await db.panelSurface.surfaces(worktreeID: scratch.id)
        let frontsBefore: [PanelID?] = [scratchChanges.id, scratchChanges.id]
        try #require(scratchSurfaces.map(\.side.activePanelID) == frontsBefore)

        let returned = try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: mainID, repoID: repoID,
            tmuxServer: scratch.tmuxServer)

        #expect(try await db.panelSurface.worktreePanels(worktreeID: mainID) == mainPanels)
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 0)
        #expect(try await panelRowExists(db, panelID: scratchChanges.id) == false,
                "the scratch Changes panel is dropped and its row deleted")
        #expect(try await notePanelRowCount(db, noteID: note.id) == 0, "no note panel survives anywhere")

        let surfaces = try await db.panelSurface.surfaces(worktreeID: mainID)
        try #require(surfaces.map(\.id) == [resident.id, withOwnPanel.id, withoutPanels.id])
        #expect(surfaces[0] == residentBefore, "the main worktree's list did not change")
        let movedFronts = surfaces.dropFirst().map(\.side.activePanelID)
        let expectedFronts: [PanelID?] = [mainChanges.id, mainChanges.id]
        #expect(movedFronts == expectedFronts,
                "a moved tab fronting the dropped Changes panel fronts the main worktree's")
        for moved in surfaces.dropFirst() {
            #expect(moved.worktreePanels == mainPanels)
        }
        let keptOwnPanels: [PanelID] = surfaces[1].side.panels.map(\.id)
        let expectedOwnPanels: [PanelID] = [ownPanelID]
        #expect(keptOwnPanels == expectedOwnPanels, "the moved tab keeps its own panel")
        #expect(returned == Array(surfaces.dropFirst()))
        for tab in [withOwnPanel, withoutPanels] {
            #expect(try await storedLayout(db, tabID: tab.id).activePanelID == mainChanges.id,
                    "the stored row, not only the read, names the kept Changes panel")
        }
    }

    /// A moved row that cannot be read still moves: re-pointed to the main
    /// worktree after its own surfaces and marked awaiting its listing, with
    /// its `layout` as it was. The promote does not return it.
    @Test func promoteMovesAnUnreadableRowAsItIs() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (repoID, scratch, mainID) = try await makePromotePair(db)
        try await seedTab(db, worktreeID: mainID, position: 0)
        let unreadable = try await seedTab(db, worktreeID: scratch.id, position: 0)
        let brokenLayout = "not a layout"
        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = ? WHERE id = ?",
                arguments: [brokenLayout, unreadable.id.uuidString])
        }

        let returned = try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: mainID, repoID: repoID,
            tmuxServer: scratch.tmuxServer)

        #expect(returned.isEmpty)
        typealias MovedColumns = (worktreeID: String, position: Int, layout: String, awaitingListing: Bool)
        let stored = try await db.writerForTests.read { dbc -> MovedColumns? in
            guard let row = try Row.fetchOne(
                dbc, sql: "SELECT worktreeID, position, layout, awaitingListing FROM workspace_tab_surface WHERE id = ?",
                arguments: [unreadable.id.uuidString]) else { return nil }
            let worktreeKey: String = row["worktreeID"]
            let position: Int = row["position"]
            let layout: String = row["layout"]
            let awaiting: Bool = row["awaitingListing"]
            return (worktreeKey, position, layout, awaiting)
        }
        let moved = try #require(stored)
        #expect(moved.worktreeID == mainID.uuidString)
        #expect(moved.position == 1)
        #expect(moved.layout == brokenLayout)
        #expect(moved.awaitingListing == true)
    }
}
