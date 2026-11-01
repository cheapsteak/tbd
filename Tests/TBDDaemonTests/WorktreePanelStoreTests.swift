import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
import TBDShared

/// The worktree's panels in `PanelSurfaceStore` (side panel notes spec,
/// "Daemon"): the `worktree_panel` rows, the list every surface of the
/// worktree reads, the surfaces a change to the list rewrites, and how
/// archive, promote, note deletion and a deleted worktree row reclaim them.
/// The operations that change the list from a tab are covered by
/// `PanelCoordinatorTests`.
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

    // MARK: - openWorktreePanel

    /// Worktree creation's path: the panel joins every surface, at a fresh
    /// revision, and selects nothing. A tab keeps its front and collapse; a
    /// tab with nothing in front brings the panel forward. Opening the same
    /// content again changes nothing.
    @Test func openWorktreePanelAppendsOnceAndSelectsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        let withPanel = try await seedTab(db, worktreeID: wtID, collapsed: true, position: 0)
        let empty = try await seedEmptyTab(db, worktreeID: wtID, position: 1)

        let rewritten = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: note.id), now: Date())

        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        try #require(panels.count == 1)
        let notePanel = panels[0]
        #expect(notePanel.content == .note(noteID: note.id))
        try #require(rewritten.map(\.id) == [withPanel.id, empty.id])
        let first = rewritten[0]
        let second = rewritten[1]
        #expect(first.worktreePanels == panels)
        #expect(second.worktreePanels == panels)
        #expect(first.side == withPanel.side, "a tab keeps its front and its collapse")
        #expect(first.revision > withPanel.revision)
        #expect(second.side.activePanelID == notePanel.id, "a tab with nothing in front shows the panel")
        #expect(second.side.collapsed == false)
        #expect(second.revision > first.revision)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == rewritten,
                "what the open returns is what a read returns")

        let again = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: note.id), now: Date())
        #expect(again.isEmpty)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: wtID) == panels)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == rewritten)
    }

    /// A worktree with no surfaces yet, as during creation, still stores the
    /// list, and a tab sync that imports a tab later joins it in.
    @Test func openWorktreePanelWithoutSurfacesStoresTheList() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)

        let rewritten = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .changes, now: Date())

        #expect(rewritten.isEmpty)
        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        let changesOnly: [WorktreePanelContent] = [.changes]
        #expect(panels.map(\.content) == changesOnly)
    }

    // MARK: - Writing

    /// A panel ID whose row belongs to another worktree is refused rather
    /// than moved out of that worktree's list.
    @Test func writeRefusesAPanelOwnedByAnotherWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, ownerID) = try await makeWorktree(db, name: "owner")
        let (_, otherID) = try await makeWorktree(db, name: "other")
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: ownerID, content: .changes, now: Date())
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

    // MARK: - Note deletion

    /// Deleting a note removes its panel from the worktree and from every
    /// surface, in one transaction, and names the surfaces it rewrote.
    @Test func noteDeleteRemovesItsPanelFromEverySurface() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        let tabA = try await seedTab(db, worktreeID: wtID, position: 0)
        let tabB = try await seedEmptyTab(db, worktreeID: wtID, position: 1)
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: wtID, content: .changes, now: Date())
        let opened = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: note.id), now: Date())
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
            _ = try await db.panelSurface.openWorktreePanel(worktreeID: worktreeID, content: .changes, now: Date())
        }
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: archivedID, content: .note(noteID: note.id), now: Date())
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
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: wtID, content: .changes, now: Date())
        #expect(try await panelRowCount(db, worktreeID: wtID) == 1, "precondition")

        try await db.worktrees.deleteForRepo(repoID: repoID)

        #expect(try await panelRowCount(db, worktreeID: wtID) == 0)
    }

    /// A scratch promote moves the scratch worktree's panels to the main
    /// worktree, after its own. A scratch Changes panel is dropped when the
    /// main worktree has one, and a moved tab that had it in front fronts the
    /// main worktree's. Every surface under the main worktree reads with the
    /// merged list, and the promote returns the main worktree's rewritten
    /// surface with the moved one.
    @Test func promoteMovesWorktreePanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/wps-promote-repo-\(UUID())", displayName: "r", defaultBranch: "main")
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/wps-scratch-\(UUID())", tmuxServer: "tbd-scratch")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/wps-main-\(UUID())", tmuxServer: "tbd-main")

        let resident = try await seedTab(db, worktreeID: main.id, position: 0)
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: main.id, content: .changes, now: Date())
        let mainChanges = try #require(try await db.panelSurface.worktreePanels(worktreeID: main.id).first)
        let residentBefore = try #require(try await db.panelSurface.surface(tabID: resident.id))

        let note = try await db.notes.create(worktreeID: scratch.id)
        let movedTab = try await seedEmptyTab(db, worktreeID: scratch.id, position: 0)
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: scratch.id, content: .note(noteID: note.id), now: Date())
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: scratch.id, content: .changes, now: Date())
        let scratchPanels = try await db.panelSurface.worktreePanels(worktreeID: scratch.id)
        let scratchContent: [WorktreePanelContent] = [.note(noteID: note.id), .changes]
        try #require(scratchPanels.map(\.content) == scratchContent)
        let scratchNote = scratchPanels[0]
        let scratchChanges = scratchPanels[1]
        _ = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: movedTab.id, worktreeID: scratch.id, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.select(panelID: scratchChanges.id), to: current)
        }

        let returned = try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: main.id, repoID: repo.id,
            tmuxServer: scratch.tmuxServer)

        let mainPanels = try await db.panelSurface.worktreePanels(worktreeID: main.id)
        #expect(mainPanels == [mainChanges, scratchNote], "the scratch panels follow the main worktree's")
        #expect(try await db.panelSurface.worktreePanels(worktreeID: scratch.id).isEmpty)
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 0)
        #expect(try await panelRowExists(db, panelID: scratchChanges.id) == false,
                "the scratch Changes panel is dropped and its row deleted")

        let surfaces = try await db.panelSurface.surfaces(worktreeID: main.id)
        try #require(surfaces.map(\.id) == [resident.id, movedTab.id])
        #expect(surfaces[0].worktreePanels == mainPanels)
        #expect(surfaces[1].worktreePanels == mainPanels)
        #expect(surfaces[0].side == residentBefore.side, "the main worktree's own tab keeps its front")
        #expect(surfaces[0].revision > residentBefore.revision)
        #expect(surfaces[1].side.activePanelID == mainChanges.id,
                "a moved tab fronting the dropped Changes panel fronts the main worktree's")
        #expect(returned == surfaces)
    }
}
