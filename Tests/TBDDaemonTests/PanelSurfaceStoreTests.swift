import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
import TBDShared

@Suite("PanelSurfaceStoreTests")
struct PanelSurfaceStoreTests {

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

    private func makeState(
        worktreeID: UUID, tabID: UUID = UUID(), panelID: PanelID = UUID(),
        panelContent: PanelContent = .file(FileReference(path: "/a.txt"))
    ) -> PanelSurfaceState {
        let layout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: panelID, content: panelContent))],
            ratios: [0.5, 0.5]))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()), layout: layout, revision: 1)
        let history = PanelHistory.seeded(with: panelContent)
        return PanelSurfaceState(surface: surface, histories: [panelID: history])
    }

    @Test func commitRoundTripsSurfaceAndHistories() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let state = makeState(worktreeID: wtID)

        try await db.panelSurface.commit(state: state, position: 0, receipt: nil, now: Date())

        let fetched = try await db.panelSurface.state(tabID: state.surface.id)
        #expect(fetched == state)
    }

    @Test func positionNilKeepsExistingPositionOrderingUnaffected() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let stateA = makeState(worktreeID: wtID)
        let stateB = makeState(worktreeID: wtID)

        // A at position 3, B at position 1 — deliberately out of insertion order.
        try await db.panelSurface.commit(state: stateA, position: 3, receipt: nil, now: Date())
        try await db.panelSurface.commit(state: stateB, position: 1, receipt: nil, now: Date())

        // Recommit A with position: nil — must keep 3, not reset to 0/default.
        try await db.panelSurface.commit(state: stateA, position: nil, receipt: nil, now: Date())

        let ordered = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(ordered.map(\.id) == [stateB.surface.id, stateA.surface.id])
    }

    @Test func historiesFullyReplacedClosedPanelLosesRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tabID = UUID()
        let panelA = UUID()
        let panelB = UUID()
        let layout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [
                .primary,
                .panel(PanelSlot(id: panelA, content: .file(FileReference(path: "/a.txt")))),
                .panel(PanelSlot(id: panelB, content: .file(FileReference(path: "/b.txt")))),
            ],
            ratios: [0.34, 0.33, 0.33]))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: wtID, primary: .terminal(terminalID: UUID()),
            layout: layout, revision: 1)
        let bothHistories: [PanelID: PanelHistory] = [
            panelA: .seeded(with: .file(FileReference(path: "/a.txt"))),
            panelB: .seeded(with: .file(FileReference(path: "/b.txt"))),
        ]
        try await db.panelSurface.commit(
            state: PanelSurfaceState(surface: surface, histories: bothHistories),
            position: 0, receipt: nil, now: Date())

        // Panel B closed: second commit's layout/histories omit it entirely.
        let onlyA = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: panelA, content: .file(FileReference(path: "/a.txt"))))],
            ratios: [0.5, 0.5]))
        let narrowedSurface = WorkspaceTabSurface(
            id: tabID, worktreeID: wtID, primary: .terminal(terminalID: UUID()),
            layout: onlyA, revision: 2)
        try await db.panelSurface.commit(
            state: PanelSurfaceState(
                surface: narrowedSurface,
                histories: [panelA: .seeded(with: .file(FileReference(path: "/a.txt")))]),
            position: nil, receipt: nil, now: Date())

        let fetched = try await db.panelSurface.state(tabID: tabID)
        #expect(fetched?.histories.keys.sorted() == [panelA].sorted())
    }

    @Test func historyRecencyOnlyAdvancesChangedPanel() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tabID = UUID()
        let panelA = UUID()
        let panelB = UUID()
        let layout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [
                .panel(PanelSlot(id: panelA, content: .file(FileReference(path: "/a.txt")))),
                .panel(PanelSlot(id: panelB, content: .file(FileReference(path: "/b.txt")))),
            ],
            ratios: [0.5, 0.5]))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: wtID, primary: .terminal(terminalID: UUID()),
            layout: layout, revision: 1)
        let now1 = Date(timeIntervalSince1970: 1_700_000_000)
        let now2 = Date(timeIntervalSince1970: 1_700_000_500)

        try await db.panelSurface.commit(
            state: PanelSurfaceState(surface: surface, histories: [
                panelA: .seeded(with: .file(FileReference(path: "/a.txt"))),
                panelB: .seeded(with: .file(FileReference(path: "/b.txt"))),
            ]),
            position: 0, receipt: nil, now: now1)

        // Second commit: only panelA's history value changes.
        var changedA = PanelHistory.seeded(with: .file(FileReference(path: "/a.txt")))
        changedA.recordReplacement(
            outgoing: .file(FileReference(path: "/a.txt")), incoming: .file(FileReference(path: "/a2.txt")))
        try await db.panelSurface.commit(
            state: PanelSurfaceState(surface: surface, histories: [
                panelA: changedA,
                panelB: .seeded(with: .file(FileReference(path: "/b.txt"))),
            ]),
            position: nil, receipt: nil, now: now2)

        let recency = try await db.panelSurface.historyRecency(tabID: tabID)
        #expect(recency[panelA] == now2)
        #expect(recency[panelB] == now1)
    }

    @Test func deleteSurfacesRemovesSurfacesHistoriesAndReceipts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let stateA = makeState(worktreeID: wtID)
        let stateB = makeState(worktreeID: wtID)
        let receipt = PanelOperationReceiptRecord(
            operationID: UUID().uuidString, worktreeID: wtID.uuidString,
            tabID: stateA.surface.id.uuidString, revision: 1, result: "{}", appliedAt: Date())

        try await db.panelSurface.commit(state: stateA, position: 0, receipt: receipt, now: Date())
        try await db.panelSurface.commit(state: stateB, position: 1, receipt: nil, now: Date())

        try await db.panelSurface.deleteSurfaces(worktreeID: wtID)

        let remaining = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(remaining.isEmpty)
        #expect(try await db.panelSurface.state(tabID: stateA.surface.id) == nil)
        #expect(try await db.panelSurface.state(tabID: stateB.surface.id) == nil)
        try await db.writerForTests.read { dbc in
            let count = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?",
                arguments: [wtID.uuidString])
            #expect(count == 0)
            let historyCount = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_history")
            #expect(historyCount == 0)
        }
    }

    @Test func surfacesOrderedByPosition() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let stateA = makeState(worktreeID: wtID)
        let stateB = makeState(worktreeID: wtID)
        let stateC = makeState(worktreeID: wtID)

        try await db.panelSurface.commit(state: stateA, position: 2, receipt: nil, now: Date())
        try await db.panelSurface.commit(state: stateB, position: 0, receipt: nil, now: Date())
        try await db.panelSurface.commit(state: stateC, position: 1, receipt: nil, now: Date())

        let ordered = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(ordered.map(\.id) == [stateB.surface.id, stateC.surface.id, stateA.surface.id])
    }

    /// Atomicity: a receipt whose `worktreeID` doesn't match any real
    /// `worktree` row violates the FK constraint on `panel_operation_receipt`,
    /// throwing partway through the single write transaction — AFTER the
    /// surface row and history row have already been `save`d in the same
    /// closure. If the transaction weren't atomic, those earlier writes
    /// would still be visible. They must not be: everything rolls back.
    @Test func commitRollsBackEntirelyWhenReceiptWriteFails() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let state = makeState(worktreeID: wtID)
        let danglingReceipt = PanelOperationReceiptRecord(
            operationID: UUID().uuidString,
            worktreeID: UUID().uuidString,  // no such worktree row — FK violation
            tabID: state.surface.id.uuidString, revision: 1, result: "{}", appliedAt: Date())

        await #expect(throws: (any Error).self) {
            try await db.panelSurface.commit(
                state: state, position: 0, receipt: danglingReceipt, now: Date())
        }

        // Nothing from this call must be visible: surface AND its history
        // row, both written earlier in the same transaction, must be gone.
        let fetched = try await db.panelSurface.state(tabID: state.surface.id)
        #expect(fetched == nil)
        try await db.writerForTests.read { dbc in
            let historyCount = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_history WHERE tabID = ?",
                arguments: [state.surface.id.uuidString])
            #expect(historyCount == 0)
            let surfaceCount = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM workspace_tab_surface WHERE id = ?",
                arguments: [state.surface.id.uuidString])
            #expect(surfaceCount == 0)
        }
    }

    /// `panel_history.panelID` is a table-wide PK. Committing tab2 with a
    /// panelID already owned by tab1 must throw (not silently steal tab1's
    /// row via upsert), and tab1's row must survive untouched.
    @Test func commitRejectsPanelIDOwnedByAnotherTab() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let sharedPanel = UUID()
        let content = PanelContent.file(FileReference(path: "/a.txt"))

        let tab1 = makeState(worktreeID: wtID, panelID: sharedPanel, panelContent: content)
        try await db.panelSurface.commit(state: tab1, position: 0, receipt: nil, now: Date())

        // Tab2 (different tab id) carrying the SAME panelID.
        let tab2 = makeState(worktreeID: wtID, panelID: sharedPanel, panelContent: content)
        await #expect(throws: PanelSurfaceStoreError.self) {
            try await db.panelSurface.commit(state: tab2, position: 1, receipt: nil, now: Date())
        }

        // Tab1's history row is still owned by tab1 and its surface intact.
        try await db.writerForTests.read { dbc in
            let ownerTabID = try String.fetchOne(
                dbc, sql: "SELECT tabID FROM panel_history WHERE panelID = ?",
                arguments: [sharedPanel.uuidString])
            #expect(ownerTabID == tab1.surface.id.uuidString)
        }
        // Tab2 never landed.
        #expect(try await db.panelSurface.state(tabID: tab2.surface.id) == nil)
    }
}
