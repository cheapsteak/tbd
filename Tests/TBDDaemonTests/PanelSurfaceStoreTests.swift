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
    /// real sync path, and returns them as stored, in the same order. Each
    /// import takes its revision from the daemon-wide counter, not from the
    /// surface the test built.
    @discardableResult
    private func seed(
        _ db: TBDDatabase, worktreeID: UUID, _ surfaces: [WorkspaceTabSurface], now: Date = Date()
    ) async throws -> [WorkspaceTabSurface] {
        let entries = surfaces.enumerated().map { index, surface in entry(for: surface, position: index) }
        let outcome = try await db.panelSurface.syncTabs(worktreeID: worktreeID, entries: entries, now: now)
        #expect(outcome.imported == surfaces.map(\.id))
        try #require(outcome.changed.map(\.id) == surfaces.map(\.id))
        return outcome.changed
    }

    /// `surface` at `revision`. A store write takes the counter's next value,
    /// so a test compares everything but the revision against the surface it
    /// built, and the revision on its own.
    private static func revised(_ surface: WorkspaceTabSurface, _ revision: UInt64) -> WorkspaceTabSurface {
        var copy = surface
        copy.revision = revision
        return copy
    }

    /// Each revision is higher than the one before it.
    private static func strictlyIncreasing(_ revisions: [UInt64]) -> Bool {
        zip(revisions, revisions.dropFirst()).allSatisfy { $0 < $1 }
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

        let stored = try await seed(db, worktreeID: wtID, [surface])[0]

        #expect(stored == Self.revised(surface, stored.revision))
        #expect(try await db.panelSurface.surface(tabID: surface.id) == stored)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [stored])
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
        let built = makeSurface(worktreeID: wtID)
        let seeded = try await seed(
            db, worktreeID: wtID, [badHistory, missingHistory, legacyLayout, failsValidator, built])
        let intact = seeded[4]

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
        let target = try await seed(db, worktreeID: wtID, [first, makeSurface(worktreeID: wtID)])[1]
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
        #expect(result.tab.revision > target.revision)
        #expect(result.tab.side.panels[0].history.entries == [destination, Self.file("/a.txt")])
        #expect(try await db.panelSurface.surface(tabID: target.id) == result.tab)
        #expect(try await db.panelSurface.receipt(operationID: operationID) == result)
        // The row keeps its position.
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID).map(\.id) == [first.id, target.id])
    }

    @Test func applyReducingReplaysReceipt() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let surface = try await seed(db, worktreeID: wtID, [makeSurface(worktreeID: wtID)])[0]
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
        #expect(applied.tab.revision > surface.revision)
        #expect(stored?.revision == applied.tab.revision, "the replay took no new revision")
        #expect(stored?.side.collapsed == true)
    }

    @Test func applyReducingReturnsNilForUnknownTabOrOtherWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let otherWtID = try await makeWorktree(db, name: "other")
        let surface = try await seed(db, worktreeID: wtID, [makeSurface(worktreeID: wtID)])[0]

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
        let seeded = try await seed(
            db, worktreeID: wtID, [makeSurface(worktreeID: wtID), makeSurface(worktreeID: wtID, paths: [])])
        let owner = seeded[0]
        let target = seeded[1]
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
        let surface = try await seed(db, worktreeID: wtID, [makeSurface(worktreeID: wtID)])[0]

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
        let surface = try await seed(
            db, worktreeID: wtID, [makeSurface(worktreeID: wtID, paths: ["/seed.txt"])])[0]
        let tabID = surface.id
        let panelID = surface.side.panels[0].id
        let store = db.panelSurface

        // K concurrent navigates on the SAME panel, each a distinct
        // destination and operationID. Each takes a new revision and pushes
        // history; K + 1 entries stay under the history cap.
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
        #expect((finalSurface?.revision ?? 0) > surface.revision)
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
        let revisions = outcome.changed.map(\.revision)
        #expect(outcome.changed == zip([a, b], revisions).map { Self.revised($0, $1) })
        #expect(Self.strictlyIncreasing([0] + revisions), "each import takes the counter's next value")
        #expect(outcome.reparented.isEmpty)
        #expect(outcome.removed.isEmpty)
        #expect(outcome.skipped == [skippedID], "a tab left without a surface is reported")
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == outcome.changed)
        #expect(try await db.panelSurface.surface(tabID: skippedID) == nil)
        #expect(try await historyRowCount(db, tabID: a.id) == 2)
    }

    @Test func syncNeverOverwritesPanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let existing = try await seed(
            db, worktreeID: wtID, [makeSurface(worktreeID: wtID, paths: ["/a.txt"])])[0]

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

    /// A listed tab whose row cannot be read, with an import candidate, gets
    /// the candidate in its place — row and histories — at a fresh revision,
    /// reported as imported; otherwise no later sync could read it either and
    /// the tab would stay on legacy for good.
    @Test func syncReplacesUnreadableSurface() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let existing = try await seed(
            db, worktreeID: wtID, [makeSurface(worktreeID: wtID, paths: ["/a.txt", "/b.txt"])])[0]
        let unreadable = #"{"primary":{}}"#
        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = ? WHERE id = ?",
                arguments: [unreadable, existing.id.uuidString])
        }
        #expect(try await db.panelSurface.surface(tabID: existing.id) == nil, "precondition: unreadable")

        let candidate = makeSurface(
            worktreeID: wtID, tabID: existing.id, label: "renamed", paths: ["/x.txt"])
        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID, entries: [entry(for: candidate, position: 3)], now: Date())

        let replaced = try #require(outcome.changed.first)
        #expect(outcome.changed == [Self.revised(candidate, replaced.revision)])
        #expect(replaced.revision > existing.revision, "the replacement takes the counter's next value")
        #expect(outcome.imported == [existing.id])
        #expect(outcome.skipped.isEmpty)
        #expect(outcome.reparented.isEmpty)
        #expect(outcome.removed.isEmpty)
        #expect(try await db.panelSurface.surface(tabID: existing.id) == replaced)
        #expect(try await layoutColumn(db, tabID: existing.id) != unreadable)
        // The old panels' history rows went with the row; the candidate's one stands.
        #expect(try await historyRowCount(db, tabID: existing.id) == 1)
        let oldPanelKeys = existing.side.panels.map(\.id.uuidString)
        let oldRows = try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_history WHERE panelID IN (?, ?)",
                arguments: [oldPanelKeys[0], oldPanelKeys[1]])
        }
        #expect(oldRows == 0)
    }

    /// A listed tab whose row cannot be read and whose legacy layout the
    /// converter skips keeps its row, and is reported skipped, so the app
    /// stops asking for a surface no load would find.
    @Test func syncReportsUnreadableUnconvertibleTabAsSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let existing = try await seed(db, worktreeID: wtID, [makeSurface(worktreeID: wtID)])[0]
        let unreadable = #"{"primary":{}}"#
        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "UPDATE workspace_tab_surface SET layout = ? WHERE id = ?",
                arguments: [unreadable, existing.id.uuidString])
        }

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: wtID,
            entries: [SyncTabEntry(
                tabID: existing.id, position: 3, label: "renamed",
                primary: existing.primary, importCandidate: nil)],
            now: Date())

        #expect(outcome == SyncOutcome(skipped: [existing.id]))
        #expect(try await layoutColumn(db, tabID: existing.id) == unreadable)
        #expect(try await historyRowCount(db, tabID: existing.id) == 1)
    }

    @Test func syncUpdatesPositionLabelPrimary() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let seeded = try await seed(db, worktreeID: wtID, [
            makeSurface(worktreeID: wtID, label: "a"),
            makeSurface(worktreeID: wtID, label: "b", paths: ["/b1.txt", "/b2.txt"]),
        ])
        let a = seeded[0]
        let b = seeded[1]
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

        try #require(outcome.changed.map(\.id) == [b.id, a.id])
        let expectedB = WorkspaceTabSurface(
            id: b.id, worktreeID: wtID, label: "renamed", primary: newPrimary,
            side: b.side, revision: outcome.changed[0].revision)
        let expectedA = WorkspaceTabSurface(
            id: a.id, worktreeID: wtID, label: nil, primary: a.primary,
            side: a.side, revision: outcome.changed[1].revision)
        #expect(outcome.changed == [expectedB, expectedA])
        #expect(Self.strictlyIncreasing([a.revision, b.revision, expectedB.revision, expectedA.revision]),
                "an update takes the counter's next value, above every earlier write")
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
        let moved = try await seed(
            db, worktreeID: scratchID,
            [makeSurface(worktreeID: scratchID, label: "t", paths: ["/a.txt", "/b.txt"])])[0]

        let candidate = makeSurface(worktreeID: mainID, tabID: moved.id, label: "t", paths: ["/x.txt"])
        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: mainID,
            entries: [SyncTabEntry(
                tabID: moved.id, position: 0, label: "t", primary: moved.primary,
                importCandidate: candidate)],
            now: Date())

        let revision = try #require(outcome.changed.first).revision
        let expected = WorkspaceTabSurface(
            id: moved.id, worktreeID: mainID, label: "t", primary: moved.primary,
            side: moved.side, revision: revision)
        #expect(revision > moved.revision)
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
        let seeded = try await seed(db, worktreeID: wtID, [
            makeSurface(worktreeID: wtID), makeSurface(worktreeID: wtID, paths: ["/a.txt", "/b.txt"]),
        ])
        let kept = seeded[0]
        let dropped = seeded[1]
        let elsewhere = try await seed(db, worktreeID: otherWtID, [makeSurface(worktreeID: otherWtID)])[0]

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
        let seeded = try await seed(db, worktreeID: wtID, [
            makeSurface(worktreeID: wtID, label: "a"),
            makeSurface(worktreeID: wtID, label: "b"),
            makeSurface(worktreeID: wtID, label: "c"),
        ])
        let a = seeded[0]
        let b = seeded[1]
        let c = seeded[2]

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

        let revision = try #require(outcome.changed.first).revision
        let expectedB = WorkspaceTabSurface(
            id: b.id, worktreeID: wtID, label: "b2", primary: b.primary,
            side: b.side, revision: revision)
        #expect(revision > c.revision)
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

        let stored = Self.revised(a, try #require(outcome.changed.first).revision)
        #expect(outcome == SyncOutcome(changed: [stored], imported: [a.id]))
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == [stored])
    }

    /// Revisions are daemon-wide: a tab whose surface is deleted and imported
    /// again comes back above every revision it had, so the app's revision
    /// guard, which compares snapshots of one tab, never refuses it.
    @Test func reimportAfterDeleteGetsAHigherRevision() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let built = makeSurface(worktreeID: wtID)
        let imported = try await seed(db, worktreeID: wtID, [built])[0]
        let outcome = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: built.id, worktreeID: wtID, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.setCollapsed(true), to: current)
        }
        guard case .applied(let applied)? = outcome else {
            Issue.record("expected .applied, got \(String(describing: outcome))")
            return
        }
        #expect(applied.tab.revision > imported.revision)

        let deleted = try await db.panelSurface.syncTabs(worktreeID: wtID, entries: [], now: Date())
        #expect(deleted.removed == [built.id])
        #expect(try await db.panelSurface.surface(tabID: built.id) == nil)

        let reimported = try await seed(db, worktreeID: wtID, [built])[0]
        #expect(reimported.revision > applied.tab.revision,
                "the re-import restarts nothing: its revision exceeds the deleted surface's last one")
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

        let removed = try await db.worktrees.archive(id: archivedID)

        #expect(removed == [archivedTab.id], "the archive names the tabs it deleted, for the delta")
        #expect(try await db.panelSurface.surfaces(worktreeID: archivedID).isEmpty)
        #expect(try await historyRowCount(db, tabID: archivedTab.id) == 0)
        #expect(try await receiptCount(db, worktreeID: archivedID) == 0)
        #expect(try await db.panelSurface.surfaces(worktreeID: keptID) == keptBefore)
        #expect(try await historyRowCount(db, tabID: keptTab.id) == 1)
        #expect(try await receiptCount(db, worktreeID: keptID) == 1)
    }

    /// Every panel row that names `worktreeID`: its surfaces, the histories
    /// of those surfaces, and its operation receipts.
    private func panelRowCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
        let key = worktreeID.uuidString
        return try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc,
                sql: """
                    SELECT (SELECT COUNT(*) FROM workspace_tab_surface WHERE worktreeID = ?)
                         + (SELECT COUNT(*) FROM panel_history h
                              JOIN workspace_tab_surface s ON s.id = h.tabID
                              WHERE s.worktreeID = ?)
                         + (SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?)
                    """,
                arguments: [key, key, key]) ?? -1
        }
    }

    /// A scratch promote archives the scratch row without going through
    /// `archive`, and moves its tabs to the main worktree. Their panels and
    /// receipts move with them, and no panel row stays on the archived row,
    /// which no reconciler covers.
    @Test func promoteScratchReparentsPanelSurfaces() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/pss-promote-repo-\(UUID())", displayName: "r", defaultBranch: "main")
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/pss-scratch-\(UUID())", tmuxServer: "tbd-scratch")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/pss-main-\(UUID())", tmuxServer: "tbd-main")
        let first = makeSurface(worktreeID: scratch.id, paths: ["/a.txt", "/b.txt"])
        let second = makeSurface(worktreeID: scratch.id, paths: ["/c.txt"])
        try await seed(db, worktreeID: scratch.id, [first, second])
        _ = try await db.panelSurface.applyReducing(
            operationID: UUID(), tabID: first.id, worktreeID: scratch.id, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.setCollapsed(true), to: current)
        }
        let before = try await db.panelSurface.surfaces(worktreeID: scratch.id)
        // Preconditions: two surfaces, three histories and a receipt.
        #expect(before.map(\.id) == [first.id, second.id])
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 6)

        let moved = try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: main.id, repoID: repo.id,
            tmuxServer: scratch.tmuxServer)

        let after = try await db.panelSurface.surfaces(worktreeID: main.id)
        #expect(after == moved, "the promote returns the moved surfaces as stored, for its delta")
        #expect(after.map(\.id) == [first.id, second.id])
        for (old, new) in zip(before, after) {
            #expect(new.worktreeID == main.id)
            #expect(new.side == old.side, "the panels move with their histories")
            #expect(new.primary == old.primary)
            #expect(new.label == old.label)
        }
        let highestBefore = try #require(before.map(\.revision).max())
        #expect(after.allSatisfy { $0.revision > highestBefore },
                "the move takes fresh revisions, so the app's guard adopts it over any copy it holds")
        #expect(Self.strictlyIncreasing(after.map(\.revision)))
        #expect(try await historyRowCount(db, tabID: first.id) == 2)
        #expect(try await historyRowCount(db, tabID: second.id) == 1)
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 0,
                "no surface, history or receipt references the archived scratch worktree")
        #expect(try await receiptCount(db, worktreeID: main.id) == 1,
                "the scratch worktree's receipt moves to the main worktree rather than vanishing")
    }

    /// A `panel.apply` retried across a scratch promote, say because its
    /// reply was lost to the reconnect, still names the scratch worktree. Its
    /// receipt moved with the tab, so it replays the stored result instead of
    /// looking for the tab under a worktree that no longer holds it.
    @Test func retriedApplyAfterPromoteReplays() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/pss-retry-repo-\(UUID())", displayName: "r", defaultBranch: "main")
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/pss-retry-scratch-\(UUID())", tmuxServer: "tbd-scratch")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/pss-retry-main-\(UUID())", tmuxServer: "tbd-main")
        let tab = try await seed(db, worktreeID: scratch.id, [makeSurface(worktreeID: scratch.id)])[0]
        let operationID = UUID()
        let firstOutcome = try await db.panelSurface.applyReducing(
            operationID: operationID, tabID: tab.id, worktreeID: scratch.id, now: Date()
        ) { current in
            try PanelSurfaceReducer.apply(.setCollapsed(true), to: current)
        }
        let first = try #require(firstOutcome)
        guard case .applied(let applied) = first else {
            Issue.record("expected .applied, got \(first)")
            return
        }

        try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: main.id, repoID: repo.id,
            tmuxServer: scratch.tmuxServer)
        let moved = try #require(try await db.panelSurface.surface(tabID: tab.id))

        let retried = try await db.panelSurface.applyReducing(
            operationID: operationID, tabID: tab.id, worktreeID: scratch.id, now: Date()
        ) { _ in
            throw ReduceMustNotRun()
        }

        #expect(retried == .replayed(applied),
                "the retry replays its receipt; nil means the receipt was lost with the scratch worktree")
        #expect(try await db.panelSurface.receipt(operationID: operationID) == applied)
        #expect(try await db.panelSurface.surface(tabID: tab.id) == moved, "the replay changed nothing")
    }

    /// A sync that lands after the archive must not import the archived
    /// worktree's tabs again, nor move a tab it lists from another worktree:
    /// it changes nothing and reports nothing.
    @Test func syncTabsIgnoresArchivedWorktree() async throws {
        let db = try TBDDatabase(inMemory: true)
        let archivedID = try await makeWorktree(db, name: "archived")
        let otherID = try await makeWorktree(db, name: "other")
        let archivedTab = makeSurface(worktreeID: archivedID)
        try await seed(db, worktreeID: archivedID, [archivedTab])
        let elsewhere = try await seed(db, worktreeID: otherID, [makeSurface(worktreeID: otherID)])[0]
        try await db.worktrees.archive(id: archivedID)

        let outcome = try await db.panelSurface.syncTabs(
            worktreeID: archivedID,
            entries: [entry(for: archivedTab, position: 0), entry(for: elsewhere, position: 1)],
            now: Date())

        #expect(outcome == SyncOutcome())
        #expect(try await db.panelSurface.surfaces(worktreeID: archivedID).isEmpty)
        #expect(try await historyRowCount(db, tabID: archivedTab.id) == 0)
        #expect(try await db.panelSurface.surface(tabID: elsewhere.id) == elsewhere)
    }
}
