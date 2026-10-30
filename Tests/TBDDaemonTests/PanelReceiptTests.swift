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

    private func makeSurface(worktreeID: UUID, tabID: UUID = UUID()) -> WorkspaceTabSurface {
        let panel = ViewerPanel(id: UUID(), content: .file(FileReference(path: "/a.txt")))
        return WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()),
            side: SideRegion(panels: [panel], activePanelID: panel.id, recency: [panel.id]),
            revision: 1)
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
        let surface = makeSurface(worktreeID: wtID)
        let operationID = UUID()
        let expectedResult = PanelApplyResult(tab: surface, replayed: false)
        let receipt = try makeReceipt(
            operationID: operationID, worktreeID: wtID, tabID: surface.id,
            appliedAt: Date(), result: expectedResult)

        try await db.panelSurface.commit(surface: surface, position: 0, receipt: receipt, now: Date())

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
                        revision: 0),
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
                        revision: 0),
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

    /// Exact-boundary: a receipt whose `appliedAt` is EXACTLY `now - 24h`
    /// (`appliedAt == cutoff`) is KEPT — prune uses strict `appliedAt < cutoff`,
    /// so "older than 24h" excludes exactly-24h-old. Pins the direction so a
    /// future refactor to `<=` can't silently prune a receipt one tick early
    /// (a retry would then re-apply it — idempotency break).
    @Test func pruneKeepsReceiptExactlyAtAgeBoundary() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tabID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let operationID = UUID()
        let result = PanelApplyResult(
            tab: WorkspaceTabSurface(
                id: tabID, worktreeID: wtID, primary: .terminal(terminalID: UUID()),
                revision: 0),
            replayed: false)

        try await db.writerForTests.write { dbc in
            let data = try JSONEncoder().encode(result)
            let record = PanelOperationReceiptRecord(
                operationID: operationID.uuidString, worktreeID: wtID.uuidString, tabID: tabID.uuidString,
                revision: 1, result: String(data: data, encoding: .utf8)!,
                appliedAt: now.addingTimeInterval(-24 * 60 * 60))  // exactly the cutoff
            try record.save(dbc)
        }

        try await db.panelSurface.pruneReceipts(worktreeID: wtID, now: now)

        #expect(try await db.panelSurface.receipt(operationID: operationID) != nil)
    }
}
