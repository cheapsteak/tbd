import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
import TBDShared

@Suite("PanelSurfaceStoreTests")
struct PanelSurfaceStoreTests {

    private struct ReduceMustNotRun: Error {}

    /// Builds a worktree row (via the real store, so FKs are satisfiable) and
    /// returns its ID.
    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/pss-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/pss-wt-\(UUID())", tmuxServer: "srv")
        return wt.id
    }

    private static func file(_ path: String) -> PanelContent {
        .file(FileReference(path: path))
    }

    /// A valid surface with one file panel per path, the first active.
    private func makeSurface(
        worktreeID: UUID, tabID: UUID = UUID(), label: String? = "tab",
        primary: PrimaryContent = .terminal(terminalID: UUID()),
        paths: [String] = ["/a.txt"], revision: UInt64 = 0
    ) -> WorkspaceTabSurface {
        let panels = paths.map { ViewerPanel(id: UUID(), content: Self.file($0)) }
        var side = SideRegion.empty
        if let first = panels.first {
            side = SideRegion(
                panels: panels, activePanelID: first.id, recency: panels.map(\.id),
                collapsed: false, width: 0.4)
        }
        return WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: label,
            primary: primary, side: side, revision: revision)
    }

    /// The entry the coordinator would build for a tab the app lists as-is.
    private func entry(for surface: WorkspaceTabSurface, position: Int) -> SyncTabEntry {
        SyncTabEntry(
            tabID: surface.id, position: position, label: surface.label,
            primary: surface.primary, importCandidate: surface)
    }

    /// Imports `surfaces` into `worktreeID` at positions 0, 1, … through the
    /// real sync path.
    private func seed(
        _ db: TBDDatabase, worktreeID: UUID, _ surfaces: [WorkspaceTabSurface], now: Date = Date()
    ) async throws {
        let entries = surfaces.enumerated().map { index, surface in entry(for: surface, position: index) }
        let outcome = try await db.panelSurface.syncTabs(worktreeID: worktreeID, entries: entries, now: now)
        #expect(outcome.imported == surfaces.map(\.id))
    }

    private func historyRowCount(_ db: TBDDatabase, tabID: UUID) async throws -> Int {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_history WHERE tabID = ?",
                arguments: [tabID.uuidString]) ?? -1
        }
    }

    /// The `layout` column's JSON for a one-panel side region, written by
    /// hand so a test can store a value the store itself would refuse.
    private static func storedLayout(panelKey: String, width: String) -> String {
        #"{"panelIDs":["\#(panelKey)"],"activePanelID":"\#(panelKey)","#
            + #""recency":["\#(panelKey)"],"collapsed":false,"width":\#(width)}"#
    }

    private func layoutColumn(_ db: TBDDatabase, tabID: UUID) async throws -> String? {
        try await db.writerForTests.read { dbc in
            try String.fetchOne(
                dbc, sql: "SELECT layout FROM workspace_tab_surface WHERE id = ?",
                arguments: [tabID.uuidString])
        }
    }

    // MARK: - Reading

    @Test func roundTripJoinsHistories() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)

        // Panel A: a two-entry history with the cursor moved back to /a.txt.
        var historyA = PanelHistory.seeded(with: Self.file("/a.txt"))
        historyA.recordReplacement(outgoing: Self.file("/a.txt"), incoming: Self.file("/a2.txt"))
        _ = historyA.goBack()
        let panelA = ViewerPanel(id: UUID(), history: historyA)
        let panelB = ViewerPanel(id: UUID(), content: .web(URL(string: "https://example.com")!))
        let surface = WorkspaceTabSurface(
            id: UUID(), worktreeID: wtID, label: "tab",
            primary: .note(noteID: UUID()),
            side: SideRegion(
                panels: [panelA, panelB], activePanelID: panelB.id,
                recency: [panelB.id, panelA.id], collapsed: true, width: 0.3),
            revision: 4)

        try await seed(db, worktreeID: wtID, [surface])

        #expect(try await db.panelSurface.surface(tabID: surface.id) == surface)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [surface])
        // One history row per panel, and the layout column carries no history.
        #expect(try await historyRowCount(db, tabID: surface.id) == 2)
        let layoutValue = try await layoutColumn(db, tabID: surface.id)
        let layout = try #require(layoutValue)
        #expect(!layout.contains("a2.txt"))
        #expect(!layout.contains("example.com"))
    }

    @Test func surfacesOrderedByPosition() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let a = makeSurface(worktreeID: wtID)
        let b = makeSurface(worktreeID: wtID)
        let c = makeSurface(worktreeID: wtID)

        _ = try await db.panelSurface.syncTabs(
            worktreeID: wtID,
            entries: [entry(for: a, position: 2), entry(for: b, position: 0), entry(for: c, position: 1)],
            now: Date())

        let ordered = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(ordered.map(\.id) == [b.id, c.id, a.id])
    }

    /// Every way a row can be unreadable — a malformed history blob, a
    /// missing history row, spec C's layout tree, a surface the validator
    /// rejects — reads as no surface, and never hides a readable sibling.
    @Test func malformedHistoryRowReadsAsNoSurface() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let badHistory = makeSurface(worktreeID: wtID)
        let missingHistory = makeSurface(worktreeID: wtID)
        let legacyLayout = makeSurface(worktreeID: wtID)
        let failsValidator = makeSurface(worktreeID: wtID)
        let intact = makeSurface(worktreeID: wtID)
        try await seed(db, worktreeID: wtID, [badHistory, missingHistory, legacyLayout, failsValidator, intact])

        let badPanelKey = badHistory.side.panels[0].id.uuidString
        let missingPanelKey = missingHistory.side.panels[0].id.uuidString
        // Hand-written layouts: out of range for one tab, and — as a control
        // that the hand-written shape decodes — the intact tab's own values.
        let outOfRangeLayout = Self.storedLayout(
            panelKey: failsValidator.side.panels[0].id.uuidString, width: "5")
        let controlLayout = Self.storedLayout(
            panelKey: intact.side.panels[0].id.uuidString, width: "0.4")
        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "UPDATE panel_history SET history = 'not json' WHERE panelID = ?",
                arguments: [badPanelKey])
            try dbc.execute(
                sql: "DELETE FROM panel_history WHERE panelID = ?",
                arguments: [missingPanelKey])
            try dbc.execute(
                sql: #"UPDATE workspace_tab_surface SET layout = '{"primary":{}}' WHERE id = ?"#,
                arguments: [legacyLayout.id.uuidString])
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = ? WHERE id = ?",
                arguments: [outOfRangeLayout, failsValidator.id.uuidString])
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = ? WHERE id = ?",
                arguments: [controlLayout, intact.id.uuidString])
        }

        #expect(try await db.panelSurface.surface(tabID: badHistory.id) == nil)
        #expect(try await db.panelSurface.surface(tabID: missingHistory.id) == nil)
        #expect(try await db.panelSurface.surface(tabID: legacyLayout.id) == nil)
        #expect(try await db.panelSurface.surface(tabID: failsValidator.id) == nil)
        #expect(try await db.panelSurface.surface(tabID: intact.id) == intact)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [intact])
    }

    // MARK: - applyReducing

    @Test func applyReducingPersistsAndRecordsReceipt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let first = makeSurface(worktreeID: wtID)
        let target = makeSurface(worktreeID: wtID)
        try await seed(db, worktreeID: wtID, [first, target])
        let panelID = target.side.panels[0].id
        let destination = Self.file("/b.txt")
        let operationID = UUID()

        let outcome = try await db.panelSurface.applyReducing(
            operationID: operationID, tabID: target.id, worktreeID: wtID, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.navigate(panelID: panelID, destination: destination), to: current)
        }

        let applied = try #require(outcome)
        guard case .applied(let result) = applied else {
            Issue.record("expected .applied, got \(applied)")
            return
        }
        #expect(result.replayed == false)
        #expect(result.tab.revision == 1)
        #expect(result.tab.side.panels[0].history.entries == [destination, Self.file("/a.txt")])
        #expect(try await db.panelSurface.surface(tabID: target.id) == result.tab)
        #expect(try await db.panelSurface.receipt(operationID: operationID) == result)
        // The row keeps its position.
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID).map(\.id) == [first.id, target.id])
    }

    @Test func applyReducingReplaysReceipt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let surface = makeSurface(worktreeID: wtID)
        try await seed(db, worktreeID: wtID, [surface])
        let operationID = UUID()

        let firstOutcome = try await db.panelSurface.applyReducing(
            operationID: operationID, tabID: surface.id, worktreeID: wtID, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.setCollapsed(true), to: current)
        }
        let first = try #require(firstOutcome)
        guard case .applied(let applied) = first else {
            Issue.record("expected .applied, got \(first)")
            return
        }

        // Same operationID again: the reducer must not run, nothing changes.
        let secondOutcome = try await db.panelSurface.applyReducing(
            operationID: operationID, tabID: surface.id, worktreeID: wtID, now: Date()
        ) { _ in
            throw ReduceMustNotRun()
        }
        #expect(secondOutcome == .replayed(applied))
        let stored = try await db.panelSurface.surface(tabID: surface.id)
        #expect(stored?.revision == 1)
        #expect(stored?.side.collapsed == true)
    }

    @Test func applyReducingReturnsNilForUnknownTabOrOtherWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let otherWtID = try await makeWorktree(db, name: "other")
        let surface = makeSurface(worktreeID: wtID)
        try await seed(db, worktreeID: wtID, [surface])

        let unknownTab = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: UUID(), worktreeID: wtID, now: Date()
        ) { _ in throw ReduceMustNotRun() }
        #expect(unknownTab == nil)

        let wrongWorktree = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: surface.id, worktreeID: otherWtID, now: Date()
        ) { _ in throw ReduceMustNotRun() }
        #expect(wrongWorktree == nil)
        #expect(try await db.panelSurface.surface(tabID: surface.id) == surface)
    }

    @Test func applyReducingDropsClosedPanelsHistory() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let surface = makeSurface(worktreeID: wtID, paths: ["/a.txt", "/b.txt"])
        try await seed(db, worktreeID: wtID, [surface])
        let closedID = surface.side.panels[1].id
        #expect(try await historyRowCount(db, tabID: surface.id) == 2)

        _ = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: surface.id, worktreeID: wtID, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.close(panelID: closedID), to: current)
        }

        #expect(try await historyRowCount(db, tabID: surface.id) == 1)
        let stored = try await db.panelSurface.surface(tabID: surface.id)
        #expect(stored?.side.panels.map(\.id) == [surface.side.panels[0].id])
    }

    /// `panel_history.panelID` is a table-wide key. A reduce that mints a
    /// panel ID another tab's history row already owns must throw rather than
    /// steal the row, and roll back everything — no surface change, no
    /// receipt.
    @Test func applyReducingRefusesAPanelIDOwnedByAnotherTab() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let owner = makeSurface(worktreeID: wtID)
        let target = makeSurface(worktreeID: wtID, paths: [])
        try await seed(db, worktreeID: wtID, [owner, target])
        let collisionID = owner.side.panels[0].id
        let operationID = UUID()

        await #expect(throws: PanelSurfaceStoreError.self) {
            _ = try await db.panelSurface.applyReducing(
                operationID: operationID, tabID: target.id, worktreeID: wtID, now: Date()
            ) { current in
                try PanelSurfaceReducer.apply(
                    .open(content: Self.file("/x.txt"), newPanel: true), to: current,
                    makeID: { collisionID })
            }
        }

        #expect(try await db.panelSurface.surface(tabID: target.id) == target)
        #expect(try await db.panelSurface.surface(tabID: owner.id) == owner)
        #expect(try await db.panelSurface.receipt(operationID: operationID) == nil)
        try await db.writerForTests.read { dbc in
            let ownerTabID = try String.fetchOne(
                dbc, sql: "SELECT tabID FROM panel_history WHERE panelID = ?",
                arguments: [collisionID.uuidString])
            #expect(ownerTabID == owner.id.uuidString)
        }
    }

    /// A surface the validator rejects would read back as no surface, so the
    /// store refuses to write one — from an apply, or from a sync, where the
    /// whole transaction rolls back.
    @Test func invalidSurfaceIsRefusedAndRollsBack() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let surface = makeSurface(worktreeID: wtID)
        try await seed(db, worktreeID: wtID, [surface])

        await #expect(throws: PanelSurfaceStoreError.self) {
            _ = try await db.panelSurface.applyReducing(
                operationID: UUID(), tabID: surface.id, worktreeID: wtID, now: Date()
            ) { current in
                var next = current
                next.side.width = 5
                next.revision += 1
                return next
            }
        }
        #expect(try await db.panelSurface.surface(tabID: surface.id) == surface)

        var invalid = makeSurface(worktreeID: wtID)
        invalid.side.activePanelID = nil
        let valid = makeSurface(worktreeID: wtID)
        // The valid import is written before the invalid one throws.
        let entries = [entry(for: surface, position: 0), entry(for: valid, position: 2),
                       entry(for: invalid, position: 1)]
        await #expect(throws: PanelSurfaceStoreError.self) {
            _ = try await db.panelSurface.syncTabs(worktreeID: wtID, entries: entries, now: Date())
        }
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [surface])
    }

    // MARK: - Actor-reentrancy lost update (production DatabasePool)

    /// Actor isolation does not span `await`, so a coordinator that loaded a
    /// surface, reduced, then awaited a separate write could have a
    /// concurrent same-tab apply read the stale revision (pool reads see a
    /// WAL snapshot) and silently clobber the first. Only reproduces under a
    /// real `DatabasePool` (temp-file db) — the in-memory `DatabaseQueue`
    /// serializes FIFO and hides it. `applyReducing` closes the window by
    /// doing load→reduce→persist in one write transaction; every concurrent
    /// apply rebases on the last committed surface, so all K increments and
    /// all K navigations survive.
    @Test func concurrentSameTabAppliesDoNotLoseUpdatesUnderPool() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pss-race-\(UUID()).sqlite")
        let db = try TBDDatabase(path: tmp.path)
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp.path + suffix)
            }
        }
        let wtID = try await makeWorktree(db)
        let surface = makeSurface(worktreeID: wtID, paths: ["/seed.txt"])
        try await seed(db, worktreeID: wtID, [surface])
        let tabID = surface.id
        let panelID = surface.side.panels[0].id
        let store = db.panelSurface

        // K concurrent navigates on the SAME panel, each a distinct
        // destination and operationID. Each bumps the revision by one and
        // pushes history; K + 1 entries stay under the history cap.
        let k = 6
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<k {
                group.addTask {
                    let destination = PanelContent.file(FileReference(path: "/f\(i).txt"))
                    _ = try await store.applyReducing(
                        operationID: UUID(), tabID: tabID, worktreeID: wtID, now: Date()
                    ) { current in
                        try PanelSurfaceReducer.apply(
                            .navigate(panelID: panelID, destination: destination), to: current)
                    }
                }
            }
            try await group.waitForAll()
        }

        let finalSurface = try await db.panelSurface.surface(tabID: tabID)
        let expectedRevision = UInt64(k)
        #expect(finalSurface?.revision == expectedRevision)
        let paths = Set((finalSurface?.side.panel(id: panelID)?.history.entries ?? []).compactMap {
            content -> String? in
            if case .file(let ref) = content { return ref.path }
            return nil
        })
        for i in 0..<k {
            #expect(paths.contains("/f\(i).txt"), "navigate to /f\(i).txt was lost")
        }
    }

    // MARK: - syncTabs

    @Test func syncImportsMissingTabs() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let a = makeSurface(worktreeID: wtID, paths: ["/a.txt", "/b.txt"])
        let b = makeSurface(worktreeID: wtID, paths: [])
        // A tab the converter skipped: listed, but with no candidate.
        let skippedID = UUID()
        let skipped = SyncTabEntry(
            tabID: skippedID, position: 1, label: "skipped",
            primary: .terminal(terminalID: UUID()), importCandidate: nil)

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID,
            entries: [entry(for: a, position: 0), skipped, entry(for: b, position: 2)],
            now: Date())

        #expect(outcome.imported == [a.id, b.id])
        #expect(outcome.changed == [a, b])
        #expect(outcome.reparented.isEmpty)
        #expect(outcome.removed.isEmpty)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [a, b])
        #expect(try await db.panelSurface.surface(tabID: skippedID) == nil)
        #expect(try await historyRowCount(db, tabID: a.id) == 2)
    }

    @Test func syncNeverOverwritesPanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let existing = makeSurface(worktreeID: wtID, paths: ["/a.txt"])
        try await seed(db, worktreeID: wtID, [existing])

        // The app lists the tab again with a freshly converted candidate whose
        // panels differ; the stored panels win.
        let candidate = makeSurface(
            worktreeID: wtID, tabID: existing.id, label: existing.label,
            primary: existing.primary, paths: ["/x.txt", "/y.txt"])
        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [entry(for: candidate, position: 0)], now: Date())

        #expect(outcome == SyncOutcome())
        #expect(try await db.panelSurface.surface(tabID: existing.id) == existing)
        #expect(try await historyRowCount(db, tabID: existing.id) == 1)
    }

    /// A listed tab whose row cannot be read still has a surface: the sync
    /// leaves it exactly as it is rather than replace data it could not read.
    @Test func syncNeverReplacesAnUnreadableRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let existing = makeSurface(worktreeID: wtID)
        try await seed(db, worktreeID: wtID, [existing])
        let unreadable = #"{"primary":{}}"#
        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = ? WHERE id = ?",
                arguments: [unreadable, existing.id.uuidString])
        }

        let candidate = makeSurface(
            worktreeID: wtID, tabID: existing.id, label: "renamed", paths: ["/x.txt"])
        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [entry(for: candidate, position: 3)], now: Date())

        #expect(outcome == SyncOutcome())
        #expect(try await layoutColumn(db, tabID: existing.id) == unreadable)
        #expect(try await historyRowCount(db, tabID: existing.id) == 1)
    }

    @Test func syncUpdatesPositionLabelPrimary() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let a = makeSurface(worktreeID: wtID, label: "a")
        let b = makeSurface(worktreeID: wtID, label: "b", paths: ["/b1.txt", "/b2.txt"])
        try await seed(db, worktreeID: wtID, [a, b])
        let newPrimary = PrimaryContent.file(FileReference(path: "/renamed.md"))

        // B moves to the front with a new label and primary; A moves back,
        // loses its label, and lists no primary, which keeps the stored one.
        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID,
            entries: [
                SyncTabEntry(tabID: b.id, position: 0, label: "renamed", primary: newPrimary, importCandidate: nil),
                SyncTabEntry(tabID: a.id, position: 1, label: nil, primary: nil, importCandidate: nil),
            ],
            now: Date())

        let expectedB = WorkspaceTabSurface(
            id: b.id, worktreeID: wtID, label: "renamed", primary: newPrimary,
            side: b.side, revision: b.revision + 1)
        let expectedA = WorkspaceTabSurface(
            id: a.id, worktreeID: wtID, label: nil, primary: a.primary,
            side: a.side, revision: a.revision + 1)
        #expect(outcome.changed == [expectedB, expectedA])
        #expect(outcome.imported.isEmpty)
        #expect(outcome.reparented.isEmpty)
        #expect(outcome.removed.isEmpty)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [expectedB, expectedA])
        #expect(try await historyRowCount(db, tabID: b.id) == 2)
    }

    @Test func syncReparentsSurfaceFromAnotherWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let scratchID = try await makeWorktree(db, name: "scratch")
        let mainID = try await makeWorktree(db, name: "main")
        let moved = makeSurface(worktreeID: scratchID, label: "t", paths: ["/a.txt", "/b.txt"])
        try await seed(db, worktreeID: scratchID, [moved])

        let candidate = makeSurface(worktreeID: mainID, tabID: moved.id, label: "t", paths: ["/x.txt"])
        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: mainID,
            entries: [SyncTabEntry(
                tabID: moved.id, position: 0, label: "t", primary: moved.primary,
                importCandidate: candidate)],
            now: Date())

        let expected = WorkspaceTabSurface(
            id: moved.id, worktreeID: mainID, label: "t", primary: moved.primary,
            side: moved.side, revision: moved.revision + 1)
        #expect(outcome.reparented == [moved.id])
        #expect(outcome.imported.isEmpty)
        #expect(outcome.changed == [expected])
        #expect(outcome.removed.isEmpty)
        #expect(try await db.panelSurface.surfaces(worktreeID: mainID) == [expected])
        #expect(try await db.panelSurface.surfaces(worktreeID: scratchID).isEmpty)
        #expect(try await historyRowCount(db, tabID: moved.id) == 2)

        // A later sync of the old worktree no longer owns the tab.
        let scratchOutcome = try await db.panelSurface.syncTabs(
            worktreeID: scratchID, entries: [], now: Date())
        #expect(scratchOutcome.removed.isEmpty)
        #expect(try await db.panelSurface.surface(tabID: moved.id) == expected)
    }

    @Test func syncDeletesUnlistedTabsWithHistories() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let otherWtID = try await makeWorktree(db, name: "other")
        let kept = makeSurface(worktreeID: wtID)
        let dropped = makeSurface(worktreeID: wtID, paths: ["/a.txt", "/b.txt"])
        let elsewhere = makeSurface(worktreeID: otherWtID)
        try await seed(db, worktreeID: wtID, [kept, dropped])
        try await seed(db, worktreeID: otherWtID, [elsewhere])

        // A receipt for the tab about to go; the sync leaves receipts alone.
        let operationID = UUID()
        _ = try await db.panelSurface.applyReducing(
            operationID: operationID, tabID: dropped.id, worktreeID: wtID, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.setCollapsed(true), to: current)
        }

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [entry(for: kept, position: 0)], now: Date())

        #expect(outcome.removed == [dropped.id])
        #expect(outcome.changed.isEmpty)
        #expect(try await db.panelSurface.surface(tabID: dropped.id) == nil)
        #expect(try await historyRowCount(db, tabID: dropped.id) == 0)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [kept])
        #expect(try await db.panelSurface.surfaces(worktreeID: otherWtID) == [elsewhere])
        #expect(try await historyRowCount(db, tabID: elsewhere.id) == 1)
        #expect(try await db.panelSurface.receipt(operationID: operationID) != nil)
    }

    @Test func syncReportsChangedSurfacesOnly() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let a = makeSurface(worktreeID: wtID, label: "a")
        let b = makeSurface(worktreeID: wtID, label: "b")
        let c = makeSurface(worktreeID: wtID, label: "c")
        try await seed(db, worktreeID: wtID, [a, b, c])

        // The same list again changes nothing.
        let unchanged = try await db.panelSurface.syncTabs(
            worktreeID: wtID,
            entries: [entry(for: a, position: 0), entry(for: b, position: 1), entry(for: c, position: 2)],
            now: Date())
        #expect(unchanged == SyncOutcome())

        // Only B's label differs.
        let relabelled = SyncTabEntry(
            tabID: b.id, position: 1, label: "b2", primary: b.primary, importCandidate: b)
        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID,
            entries: [entry(for: a, position: 0), relabelled, entry(for: c, position: 2)],
            now: Date())

        let expectedB = WorkspaceTabSurface(
            id: b.id, worktreeID: wtID, label: "b2", primary: b.primary,
            side: b.side, revision: b.revision + 1)
        #expect(outcome == SyncOutcome(changed: [expectedB]))
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [a, expectedB, c])
    }

    @Test func syncProcessesADuplicatedTabOnce() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let a = makeSurface(worktreeID: wtID)

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID,
            entries: [entry(for: a, position: 0), entry(for: a, position: 1)],
            now: Date())

        #expect(outcome == SyncOutcome(changed: [a], imported: [a.id]))
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [a])
    }

    // MARK: - commit and deleteSurfaces

    @Test func commitPositionNilKeepsExistingPosition() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let a = makeSurface(worktreeID: wtID)
        let b = makeSurface(worktreeID: wtID)

        try await db.panelSurface.commit(surface: a, position: 3, receipt: nil, now: Date())
        try await db.panelSurface.commit(surface: b, position: 1, receipt: nil, now: Date())
        // Recommit A with position: nil — must keep 3, not reset to 0.
        try await db.panelSurface.commit(surface: a, position: nil, receipt: nil, now: Date())

        let ordered = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(ordered.map(\.id) == [b.id, a.id])
    }

    /// Atomicity: a receipt whose `worktreeID` matches no `worktree` row
    /// violates the receipt table's FK, throwing AFTER the surface row and
    /// its history row were written in the same transaction. Nothing from
    /// the call may remain.
    @Test func commitRollsBackEntirelyWhenReceiptWriteFails() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let surface = makeSurface(worktreeID: wtID)
        let danglingReceipt = PanelOperationReceiptRecord(
            operationID: UUID().uuidString,
            worktreeID: UUID().uuidString,  // no such worktree row — FK violation
            tabID: surface.id.uuidString, revision: 1, result: "{}", appliedAt: Date())

        await #expect(throws: (any Error).self) {
            try await db.panelSurface.commit(
                surface: surface, position: 0, receipt: danglingReceipt, now: Date())
        }

        #expect(try await db.panelSurface.surface(tabID: surface.id) == nil)
        #expect(try await historyRowCount(db, tabID: surface.id) == 0)
        #expect(try await layoutColumn(db, tabID: surface.id) == nil)
    }

    @Test func deleteSurfacesRemovesSurfacesHistoriesAndReceipts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let a = makeSurface(worktreeID: wtID)
        let b = makeSurface(worktreeID: wtID)
        try await seed(db, worktreeID: wtID, [a, b])
        _ = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: a.id, worktreeID: wtID, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.setCollapsed(true), to: current)
        }

        try await db.panelSurface.deleteSurfaces(worktreeID: wtID)

        #expect(try await db.panelSurface.surfaces(worktreeID: wtID).isEmpty)
        #expect(try await db.panelSurface.surface(tabID: a.id) == nil)
        #expect(try await db.panelSurface.surface(tabID: b.id) == nil)
        try await db.writerForTests.read { dbc in
            let receiptCount = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?",
                arguments: [wtID.uuidString])
            #expect(receiptCount == 0)
            let historyCount = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM panel_history")
            #expect(historyCount == 0)
        }
    }

    // MARK: - Archive

    private func receiptCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString]) ?? -1
        }
    }

    /// An archived worktree keeps its row, so no FK cascade reclaims its
    /// panel rows; the archive itself must.
    @Test func archiveDeletesTheWorktreesPanelRowsAndNoOthers() async throws {
        let db = try TBDDatabase(inMemory: true)
        let archivedID = try await makeWorktree(db, name: "archived")
        let keptID = try await makeWorktree(db, name: "kept")
        let archivedTab = makeSurface(worktreeID: archivedID, paths: ["/a.txt", "/b.txt"])
        let keptTab = makeSurface(worktreeID: keptID, paths: ["/c.txt"])
        try await seed(db, worktreeID: archivedID, [archivedTab])
        try await seed(db, worktreeID: keptID, [keptTab])
        for (tabID, worktreeID) in [(archivedTab.id, archivedID), (keptTab.id, keptID)] {
            _ = try await db.panelSurface.applyReducing(
                operationID: UUID(), tabID: tabID, worktreeID: worktreeID, now: Date()
            ) { current in
                try PanelSurfaceReducer.apply(.setCollapsed(true), to: current)
            }
        }
        // Preconditions: each worktree has a surface, histories and a receipt.
        #expect(try await historyRowCount(db, tabID: archivedTab.id) == 2)
        #expect(try await receiptCount(db, worktreeID: archivedID) == 1)
        let keptBefore = try await db.panelSurface.surfaces(worktreeID: keptID)

        try await db.worktrees.archive(id: archivedID)

        #expect(try await db.panelSurface.surfaces(worktreeID: archivedID).isEmpty)
        #expect(try await historyRowCount(db, tabID: archivedTab.id) == 0)
        #expect(try await receiptCount(db, worktreeID: archivedID) == 0)
        #expect(try await db.panelSurface.surfaces(worktreeID: keptID) == keptBefore)
        #expect(try await historyRowCount(db, tabID: keptTab.id) == 1)
        #expect(try await receiptCount(db, worktreeID: keptID) == 1)
    }
}
