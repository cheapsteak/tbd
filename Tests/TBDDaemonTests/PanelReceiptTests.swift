import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
import TBDShared

@Suite("PanelReceiptTests")
struct PanelReceiptTests {

    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/pr-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/pr-wt-\(UUID())", tmuxServer: "srv")
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

    private func makeReceipt(
        operationID: UUID = UUID(), worktreeID: UUID, tabID: UUID, appliedAt: Date,
        result: PanelApplyResult
    ) throws -> PanelOperationReceiptRecord {
        let data = try JSONEncoder().encode(result)
        let json = String(data: data, encoding: .utf8)!
        return PanelOperationReceiptRecord(
            operationID: operationID.uuidString, worktreeID: worktreeID.uuidString,
            tabID: tabID.uuidString, revision: 1, result: json, appliedAt: appliedAt)
    }

    // MARK: - Idempotent replay

    @Test func receiptRoundTripsThroughCommit() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let state = makeState(worktreeID: wtID)
        let operationID = UUID()
        let expectedResult = PanelApplyResult(tab: state.surface, replayed: false)
        let receipt = try makeReceipt(
            operationID: operationID, worktreeID: wtID, tabID: state.surface.id,
            appliedAt: Date(), result: expectedResult)

        try await db.panelSurface.commit(state: state, position: 0, receipt: receipt, now: Date())

        let fetched = try await db.panelSurface.receipt(operationID: operationID)
        #expect(fetched == expectedResult)
    }

    @Test func unknownOperationIDReturnsNil() async throws {
        let db = try TBDDatabase(inMemory: true)
        let fetched = try await db.panelSurface.receipt(operationID: UUID())
        #expect(fetched == nil)
    }

    // MARK: - Bounded pruning

    @Test func pruneByCountKeepsNewest100Of105() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tabID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let operationIDs: [UUID] = (0..<105).map { _ in UUID() }

        try await db.writerForTests.write { dbc in
            for i in 0..<105 {
                let opID = operationIDs[i]
                let result = PanelApplyResult(
                    tab: WorkspaceTabSurface(
                        id: tabID, worktreeID: wtID, primary: .terminal(terminalID: UUID()),
                        layout: .primary, revision: 0),
                    replayed: false)
                let data = try JSONEncoder().encode(result)
                let record = PanelOperationReceiptRecord(
                    operationID: opID.uuidString, worktreeID: wtID.uuidString, tabID: tabID.uuidString,
                    revision: 1, result: String(data: data, encoding: .utf8)!,
                    appliedAt: base.addingTimeInterval(TimeInterval(i)))
                try record.save(dbc)
            }
        }

        // now is right after the last receipt — no receipt is 24h+ old yet.
        try await db.panelSurface.pruneReceipts(worktreeID: wtID, now: base.addingTimeInterval(105))

        let remainingCount = try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?",
                arguments: [wtID.uuidString])
        }
        #expect(remainingCount == 100)

        // The oldest 5 (indices 0..<5) must be gone; the newest 100 remain.
        for opID in operationIDs[0..<5] {
            #expect(try await db.panelSurface.receipt(operationID: opID) == nil)
        }
        for opID in operationIDs[5...] {
            #expect(try await db.panelSurface.receipt(operationID: opID) != nil)
        }
    }

    @Test func pruneByAgeDropsReceiptsOlderThan24Hours() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tabID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let operationIDs: [UUID] = (0..<3).map { _ in UUID() }

        try await db.writerForTests.write { dbc in
            for i in 0..<3 {
                let opID = operationIDs[i]
                let result = PanelApplyResult(
                    tab: WorkspaceTabSurface(
                        id: tabID, worktreeID: wtID, primary: .terminal(terminalID: UUID()),
                        layout: .primary, revision: 0),
                    replayed: false)
                let data = try JSONEncoder().encode(result)
                let record = PanelOperationReceiptRecord(
                    operationID: opID.uuidString, worktreeID: wtID.uuidString, tabID: tabID.uuidString,
                    revision: 1, result: String(data: data, encoding: .utf8)!,
                    appliedAt: base.addingTimeInterval(TimeInterval(i)))
                try record.save(dbc)
            }
        }

        // 25h after the base — all 3 receipts (spanning only 2s) are older than 24h.
        try await db.panelSurface.pruneReceipts(worktreeID: wtID, now: base.addingTimeInterval(25 * 60 * 60))

        for opID in operationIDs {
            #expect(try await db.panelSurface.receipt(operationID: opID) == nil)
        }
    }

    // MARK: - Atomic import commit

    private func makeConversion(worktreeID: UUID, tabID: UUID = UUID(), panelID: PanelID = UUID())
        -> LegacySurfaceImporter.Conversion
    {
        let layout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: panelID, content: .file(FileReference(path: "/a.txt"))))],
            ratios: [0.5, 0.5]))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, primary: .terminal(terminalID: UUID()),
            layout: layout, revision: 0)
        return LegacySurfaceImporter.Conversion(
            surfaces: [surface],
            histories: [panelID: .seeded(with: .file(FileReference(path: "/a.txt")))])
    }

    @Test func commitImportWritesSurfacesHistoriesAndStampAtomically() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let conversion = makeConversion(worktreeID: wtID)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await db.panelSurface.commitImport(worktreeID: wtID, conversion: conversion, now: now)

        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces == conversion.surfaces)
        let state = try await db.panelSurface.state(tabID: conversion.surfaces[0].id)
        #expect(state?.histories == conversion.histories)
        let stampedAt = try await db.worktrees.panelSurfaceImportedAt(worktreeID: wtID)
        #expect(stampedAt == now)
    }

    @Test func commitImportSecondCallIsNoOpAlreadyImportedGuard() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let conversion = makeConversion(worktreeID: wtID)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await db.panelSurface.commitImport(worktreeID: wtID, conversion: conversion, now: now)

        // Second import call (e.g. a lost-response retry) must throw, never double-write.
        let secondConversion = makeConversion(worktreeID: wtID)
        await #expect(throws: PanelSurfaceStoreError.alreadyImported) {
            try await db.panelSurface.commitImport(
                worktreeID: wtID, conversion: secondConversion, now: now.addingTimeInterval(60))
        }

        // Only the FIRST import's surface must be present — no double-write.
        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces.map(\.id) == [conversion.surfaces[0].id])
    }

    @Test func commitImportThrowsAlreadyImportedWhenSurfaceRowExistsButNoStamp() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        // A surface row exists (e.g. from an unrelated commit) but the
        // worktree was never stamped as imported — must still guard.
        let state = makeState(worktreeID: wtID)
        try await db.panelSurface.commit(state: state, position: 0, receipt: nil, now: Date())
        #expect(try await db.worktrees.panelSurfaceImportedAt(worktreeID: wtID) == nil)

        let conversion = makeConversion(worktreeID: wtID)
        await #expect(throws: PanelSurfaceStoreError.alreadyImported) {
            try await db.panelSurface.commitImport(worktreeID: wtID, conversion: conversion, now: Date())
        }
    }

    /// Atomicity: a conversion whose SECOND surface reuses a panelID already
    /// owned by an unrelated tab (some other worktree's tab) trips the
    /// `panelHistoryOwnedByOtherTab` guard partway through the write loop —
    /// AFTER the first surface has already been `save`d in the same
    /// transaction. Nothing from this failed import may land: not the first
    /// surface, not its history, not the `panel_surface_imported_at` stamp.
    @Test func commitImportRollsBackEntirelyOnMidLoopFailure() async throws {
        let db = try TBDDatabase(inMemory: true)
        let otherWtID = try await makeWorktree(db, name: "other")
        let clobberedPanelID = UUID()
        let ownerState = makeState(worktreeID: otherWtID, panelID: clobberedPanelID)
        try await db.panelSurface.commit(state: ownerState, position: 0, receipt: nil, now: Date())

        let wtID = try await makeWorktree(db)
        let tab1 = makeConversion(worktreeID: wtID).surfaces[0]
        // Second surface's panel reuses `clobberedPanelID`, which belongs to
        // `ownerState`'s tab under a DIFFERENT worktree.
        let tab2ID = UUID()
        let layout2 = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: clobberedPanelID, content: .file(FileReference(path: "/b.txt"))))],
            ratios: [0.5, 0.5]))
        let tab2 = WorkspaceTabSurface(
            id: tab2ID, worktreeID: wtID, primary: .terminal(terminalID: UUID()),
            layout: layout2, revision: 0)
        let conversion = LegacySurfaceImporter.Conversion(
            surfaces: [tab1, tab2],
            histories: [
                tab1.layout.allPanelIDs[0]: .seeded(with: .file(FileReference(path: "/a.txt"))),
                clobberedPanelID: .seeded(with: .file(FileReference(path: "/b.txt"))),
            ])

        await #expect(throws: PanelSurfaceStoreError.self) {
            try await db.panelSurface.commitImport(worktreeID: wtID, conversion: conversion, now: Date())
        }

        // Nothing from the failed import landed for the target worktree.
        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces.isEmpty)
        #expect(try await db.worktrees.panelSurfaceImportedAt(worktreeID: wtID) == nil)
        // The other worktree's tab still owns the panel untouched.
        try await db.writerForTests.read { dbc in
            let ownerTabID = try String.fetchOne(
                dbc, sql: "SELECT tabID FROM panel_history WHERE panelID = ?",
                arguments: [clobberedPanelID.uuidString])
            #expect(ownerTabID == ownerState.surface.id.uuidString)
        }
    }

    /// Multi-tab import: the importer's cross-tab dedup guarantees distinct
    /// panelIDs across tabs, so `commitImport` writing MULTIPLE tabs' worth
    /// of history in one transaction must never trip the
    /// `panelHistoryOwnedByOtherTab` guard on its own legitimate writes.
    @Test func commitImportMultiTabComposesWithCrossTabHistoryGuard() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab1ID = UUID()
        let tab2ID = UUID()
        let term1 = UUID()
        let term2 = UUID()
        let viewer1 = UUID()
        let viewer2 = UUID()
        let legacyHistory1 = MRUHistory<PaneContent>.seeded(with: .codeViewer(id: viewer1, path: "/one"))
        let legacyHistory2 = MRUHistory<PaneContent>.seeded(with: .codeViewer(id: viewer2, path: "/two"))
        // Each tab's primary is its terminal; the codeViewer is a SEPARATE
        // leaf so it survives conversion as a panel (with history), not the
        // tab's `.primary` — mirrors LegacySurfaceImporterTests's split shape.
        let layout1 = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [.pane(.terminal(terminalID: term1)), .pane(.codeViewer(id: viewer1, path: "/one"))],
            ratios: [0.5, 0.5])
        let layout2 = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [.pane(.terminal(terminalID: term2)), .pane(.codeViewer(id: viewer2, path: "/two"))],
            ratios: [0.5, 0.5])
        let payload1 = LegacyTabPayload(
            tabID: tab1ID, label: "one", content: .terminal(terminalID: term1), layout: layout1)
        let payload2 = LegacyTabPayload(
            tabID: tab2ID, label: "two", content: .terminal(terminalID: term2), layout: layout2)

        let conversion = LegacySurfaceImporter.convert(
            worktreeID: wtID, tabs: [payload1, payload2], tabOrder: [tab1ID, tab2ID],
            paneHistories: [viewer1: legacyHistory1, viewer2: legacyHistory2])
        #expect(conversion.skipped.isEmpty)
        #expect(conversion.surfaces.count == 2)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.panelSurface.commitImport(worktreeID: wtID, conversion: conversion, now: now)

        let surfaces = try await db.panelSurface.surfaces(worktreeID: wtID)
        #expect(surfaces.map(\.id) == [tab1ID, tab2ID])
        let state1 = try await db.panelSurface.state(tabID: tab1ID)
        let state2 = try await db.panelSurface.state(tabID: tab2ID)
        #expect(state1?.histories.keys.first == viewer1)
        #expect(state2?.histories.keys.first == viewer2)
        let stampedAt = try await db.worktrees.panelSurfaceImportedAt(worktreeID: wtID)
        #expect(stampedAt == now)
    }
}
