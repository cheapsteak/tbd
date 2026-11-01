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
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: wtID, content: .changes, now: Date())
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

    /// A tab the app lists for the first time, after an update or for a new
    /// terminal, has nothing of its own to show: in a worktree with panels it
    /// fronts the first one, collapsed, so no terminal narrows on its own.
    /// That holds for a missing row and for an unreadable row replaced by its
    /// import, and a later update of the row keeps the collapse.
    @Test func importWithNoOwnPanelsComesOutCollapsedWhenWorktreeHasPanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: wtID, content: .changes, now: Date())
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: note.id), now: Date())
        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        try #require(panels.count == 2)
        let unreadable = try await seedEmptyTab(db, worktreeID: wtID, position: 1)
        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = 'not a layout' WHERE id = ?",
                arguments: [unreadable.id.uuidString])
        }
        let fresh = terminalEntry(worktreeID: wtID, position: 0)
        let replaced = terminalEntry(tabID: unreadable.id, worktreeID: wtID, position: 1)

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [fresh, replaced], now: Date())

        #expect(outcome.imported == [fresh.tabID, replaced.tabID])
        try #require(outcome.changed.count == 2)
        for imported in outcome.changed {
            #expect(imported.side.panels.isEmpty)
            #expect(imported.side.collapsed == true)
            #expect(imported.side.activePanelID == panels[0].id)
            #expect(imported.worktreePanels == panels)
            #expect(try await db.panelSurface.surface(tabID: imported.id) == imported, "it reads back valid")
        }

        let relabelled = terminalEntry(tabID: fresh.tabID, worktreeID: wtID, position: 0, label: "renamed")
        let update = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [relabelled, replaced], now: Date())
        let updated = try #require(update.changed.first)
        #expect(update.imported.isEmpty)
        #expect(updated.label == "renamed")
        #expect(updated.side.collapsed == true, "an update never changes the collapse")
    }

    /// An import with panels of its own keeps the collapse the app gave it,
    /// even in a worktree with panels.
    @Test func importWithOwnPanelsKeepsItsCollapse() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: wtID, content: .changes, now: Date())
        func sideWithAFile(collapsed: Bool) -> SideRegion {
            let panelID = UUID()
            return SideRegion(
                panels: [ViewerPanel(id: panelID, content: .file(FileReference(path: "/a.txt")))],
                activePanelID: panelID, recency: [panelID], collapsed: collapsed, width: 0.4)
        }
        let open = terminalEntry(worktreeID: wtID, position: 0, side: sideWithAFile(collapsed: false))
        let collapsed = terminalEntry(worktreeID: wtID, position: 1, side: sideWithAFile(collapsed: true))

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [open, collapsed], now: Date())

        try #require(outcome.changed.map(\.id) == [open.tabID, collapsed.tabID])
        #expect(outcome.changed[0].side.collapsed == false)
        #expect(outcome.changed[0].side == open.importCandidate?.side, "it keeps its own front")
        #expect(outcome.changed[1].side.collapsed == true)
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

    // MARK: - Seeding the main tab

    /// The awaiting-listing marker of a tab's row, or nil when it has none.
    private func awaitingListing(_ db: TBDDatabase, tabID: UUID) async throws -> Bool? {
        try await db.writerForTests.read { dbc in
            try Bool.fetchOne(
                dbc, sql: "SELECT awaitingListing FROM workspace_tab_surface WHERE id = ?",
                arguments: [tabID.uuidString])
        }
    }

    /// `openWorktreePanel(seeding:)` writes the seed's tab a surface, open,
    /// with the new panel in front and marked as awaiting its listing, in the
    /// open's transaction. The siblings the open rewrites keep their collapse
    /// state, and a tab that already has a row is never overwritten.
    @Test func openWorktreePanelSeedsAnOpenSurfaceOnlyForATabWithoutOne() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (_, wtID) = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: wtID, content: .changes, now: Date())
        let openSibling = try await seedEmptyTab(db, worktreeID: wtID, position: 0)
        let collapsedSibling = try await seedTab(db, worktreeID: wtID, collapsed: true, position: 1)
        let tabID = UUID()
        let seed = SurfaceSeed(tabID: tabID, primary: .terminal(terminalID: tabID), position: 2)

        let written = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: note.id), seeding: seed, now: Date())

        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        let notePanel = try #require(panels.last)
        #expect(notePanel.content == .note(noteID: note.id))
        try #require(written.map(\.id) == [openSibling.id, collapsedSibling.id, tabID])
        #expect(written[0].side.collapsed == false)
        #expect(written[1].side.collapsed == true, "a sibling keeps its collapse")
        #expect(written[1].side.activePanelID == collapsedSibling.side.activePanelID)
        let seeded = written[2]
        #expect(seeded.primary == .terminal(terminalID: tabID))
        #expect(seeded.side.panels.isEmpty)
        #expect(seeded.side.activePanelID == notePanel.id)
        #expect(seeded.side.collapsed == false)
        #expect(seeded.side.width == SideRegion.defaultWidth)
        #expect(seeded.label == nil)
        #expect(seeded.worktreePanels == panels)
        #expect(try await db.panelSurface.surface(tabID: tabID) == seeded)
        #expect(try await awaitingListing(db, tabID: tabID) == true)
        let positions = try await db.writerForTests.read { dbc in
            try Int.fetchAll(
                dbc, sql: "SELECT position FROM workspace_tab_surface WHERE worktreeID = ? ORDER BY position",
                arguments: [wtID.uuidString])
        }
        #expect(positions == [0, 1, 2])

        // The same open again changes nothing, and seeds nothing over the row.
        let again = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: note.id), seeding: seed, now: Date())
        #expect(again.isEmpty)
        #expect(try await db.panelSurface.surface(tabID: tabID) == seeded)

        // A new panel seeded on a tab that has a row rewrites it with the
        // others, and leaves it collapsed.
        let other = try await db.notes.create(worktreeID: wtID)
        let onExisting = SurfaceSeed(
            tabID: collapsedSibling.id, primary: collapsedSibling.primary, position: 1)
        let rewritten = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: other.id), seeding: onExisting, now: Date())
        #expect(rewritten.map(\.id) == [openSibling.id, collapsedSibling.id, tabID])
        let stillCollapsed = try #require(try await db.panelSurface.surface(tabID: collapsedSibling.id))
        #expect(stillCollapsed.side.collapsed == true)
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
    /// worktree. A moved tab that had a note panel in front brings its most
    /// recent own panel forward, else the merged list's first panel. The main
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
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: scratch.id, content: .note(noteID: note.id), now: Date())
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: scratch.id, content: .changes, now: Date())
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
    }

    /// When the main worktree already has a Changes panel, the scratch
    /// worktree's is deleted, and a moved tab that had it in front fronts the
    /// main worktree's. The scratch note panels are deleted all the same, and
    /// the main worktree's list is unchanged, so its own tab is not
    /// rewritten and the promote returns only the moved tab.
    @Test func promoteDropsTheScratchChangesPanelWhenMainHasOne() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (repoID, scratch, mainID) = try await makePromotePair(db)
        let resident = try await seedTab(db, worktreeID: mainID, position: 0)
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: mainID, content: .changes, now: Date())
        let mainChanges = try #require(try await db.panelSurface.worktreePanels(worktreeID: mainID).first)
        let residentBefore = try #require(try await db.panelSurface.surface(tabID: resident.id))

        let note = try await db.notes.create(worktreeID: scratch.id)
        let movedTab = try await seedEmptyTab(db, worktreeID: scratch.id, position: 0)
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: scratch.id, content: .note(noteID: note.id), now: Date())
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: scratch.id, content: .changes, now: Date())
        let scratchChanges = try #require(
            try await db.panelSurface.worktreePanels(worktreeID: scratch.id).last)
        _ = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: movedTab.id, worktreeID: scratch.id, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.select(panelID: scratchChanges.id), to: current)
        }

        let returned = try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: mainID, repoID: repoID,
            tmuxServer: scratch.tmuxServer)

        #expect(try await db.panelSurface.worktreePanels(worktreeID: mainID) == [mainChanges])
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 0)
        #expect(try await panelRowExists(db, panelID: scratchChanges.id) == false,
                "the scratch Changes panel is dropped and its row deleted")
        #expect(try await notePanelRowCount(db, noteID: note.id) == 0, "no note panel survives anywhere")

        let surfaces = try await db.panelSurface.surfaces(worktreeID: mainID)
        try #require(surfaces.map(\.id) == [resident.id, movedTab.id])
        #expect(surfaces[0] == residentBefore, "the main worktree's list did not change")
        #expect(surfaces[1].worktreePanels == [mainChanges])
        #expect(surfaces[1].side.activePanelID == mainChanges.id,
                "a moved tab fronting the dropped Changes panel fronts the main worktree's")
        #expect(returned == [surfaces[1]])
    }
}
