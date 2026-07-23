import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `workspace_tab_surface` table: one row per
/// workspace tab (layout tree + primary content + revision). See spec C §8.
struct WorkspaceTabSurfaceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "workspace_tab_surface"
    var id: String
    var worktreeID: String
    var primaryContent: String
    var label: String?
    var position: Int
    var layout: String
    var revision: Int64
    var updatedAt: Date
}

/// GRDB Record type for the `panel_history` table: per-panel MRU history
/// (spec C §8), keyed by panel ID.
struct PanelHistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "panel_history"
    var panelID: String
    var tabID: String
    var history: String
    var updatedAt: Date
}

/// GRDB Record type for the `panel_operation_receipt` table: bounded receipts
/// used for §7.4 idempotency of agent-originated panel operations.
struct PanelOperationReceiptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "panel_operation_receipt"
    var operationID: String
    var worktreeID: String
    var tabID: String
    var revision: Int64
    var result: String
    var appliedAt: Date
}

/// Store for the panel-surface schema (workspace tab layouts, panel history,
/// operation receipts). Skeleton for Task 5 — full CRUD API lands in Task 6.
public struct PanelSurfaceStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Whether a worktree has no persisted workspace-tab-surface rows yet
    /// (never imported / nothing saved).
    public func isEmpty(worktreeID: UUID) async throws -> Bool {
        try await writer.read { db in
            try WorkspaceTabSurfaceRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .fetchCount(db) == 0
        }
    }
}
