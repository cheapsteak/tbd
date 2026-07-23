import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = String(bytes: data, encoding: .utf8) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "JSON-encoded data is not valid UTF-8"))
    }
    return string
}

private func decodeJSON<T: Decodable>(_ type: T.Type, from string: String) -> T? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

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

    init(from surface: WorkspaceTabSurface, position: Int, updatedAt: Date) throws {
        self.id = surface.id.uuidString
        self.worktreeID = surface.worktreeID.uuidString
        self.primaryContent = try encodeJSONString(surface.primary)
        self.label = surface.label
        self.position = position
        self.layout = try encodeJSONString(surface.layout)
        self.revision = Int64(surface.revision)
        self.updatedAt = updatedAt
    }

    /// Failable decode: skips (returns nil after a logged warning) rather than
    /// crashing when a required field fails to parse — copies `TabRecord.toModel()`.
    func toModel() -> WorkspaceTabSurface? {
        guard let uuid = UUID(uuidString: id) else {
            decodeLogger.warning("Skipping workspace_tab_surface row \(id, privacy: .public): malformed id")
            return nil
        }
        guard let wtID = UUID(uuidString: worktreeID) else {
            decodeLogger.warning("Skipping workspace_tab_surface row \(id, privacy: .public): malformed worktreeID")
            return nil
        }
        guard revision >= 0 else {
            decodeLogger.warning("Skipping workspace_tab_surface row \(id, privacy: .public): negative revision")
            return nil
        }
        guard let primary = decodeJSON(PrimaryContent.self, from: primaryContent) else {
            decodeLogger.warning("Skipping workspace_tab_surface row \(id, privacy: .public): malformed primaryContent")
            return nil
        }
        guard let layoutNode = decodeJSON(PanelLayoutNode.self, from: layout) else {
            decodeLogger.warning("Skipping workspace_tab_surface row \(id, privacy: .public): malformed layout")
            return nil
        }
        return WorkspaceTabSurface(
            id: uuid, worktreeID: wtID, label: label,
            primary: primary, layout: layoutNode, revision: UInt64(revision))
    }
}

/// GRDB Record type for the `panel_history` table: per-panel MRU history
/// (spec C §8), keyed by panel ID.
struct PanelHistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "panel_history"
    var panelID: String
    var tabID: String
    var history: String
    var updatedAt: Date

    init(panelID: PanelID, tabID: WorkspaceTabID, history: PanelHistory, updatedAt: Date) throws {
        self.panelID = panelID.uuidString
        self.tabID = tabID.uuidString
        self.history = try encodeJSONString(history)
        self.updatedAt = updatedAt
    }

    /// Failable decode of just the history payload: skips (logs) rather than
    /// crashes on a malformed panel ID or history blob.
    func toModel() -> (panelID: PanelID, history: PanelHistory)? {
        guard let panelUUID = UUID(uuidString: panelID) else {
            decodeLogger.warning("Skipping panel_history row: malformed panelID")
            return nil
        }
        guard let history = decodeJSON(PanelHistory.self, from: history) else {
            decodeLogger.warning("Skipping panel_history row \(panelID, privacy: .public): malformed history")
            return nil
        }
        return (panelUUID, history)
    }
}

/// GRDB Record type for the `panel_operation_receipt` table: bounded receipts
/// used for §7.4 idempotency of agent-originated panel operations. `public`
/// because `PanelSurfaceStore.commit(receipt:)` takes it directly — callers
/// (RPC handlers) construct the receipt themselves.
public struct PanelOperationReceiptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "panel_operation_receipt"
    public var operationID: String
    public var worktreeID: String
    public var tabID: String
    public var revision: Int64
    public var result: String
    public var appliedAt: Date

    public init(
        operationID: String, worktreeID: String, tabID: String,
        revision: Int64, result: String, appliedAt: Date
    ) {
        self.operationID = operationID
        self.worktreeID = worktreeID
        self.tabID = tabID
        self.revision = revision
        self.result = result
        self.appliedAt = appliedAt
    }
}

/// Store for the panel-surface schema (workspace tab layouts, panel history,
/// operation receipts). See spec C §8.
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

    /// All workspace-tab surfaces for a worktree, ordered by position.
    public func surfaces(worktreeID: UUID) async throws -> [WorkspaceTabSurface] {
        try await writer.read { db in
            try WorkspaceTabSurfaceRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .order(Column("position"))
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }

    /// A tab's surface plus its panels' navigation histories, or `nil` if
    /// the tab has no persisted surface row.
    public func state(tabID: UUID) async throws -> PanelSurfaceState? {
        try await writer.read { db in
            guard let surfaceRecord = try WorkspaceTabSurfaceRecord.fetchOne(db, key: tabID.uuidString),
                  let surface = surfaceRecord.toModel() else {
                return nil
            }
            let histories = try PanelHistoryRecord
                .filter(Column("tabID") == tabID.uuidString)
                .fetchAll(db)
                .compactMap { $0.toModel() }
            return PanelSurfaceState(
                surface: surface,
                histories: Dictionary(uniqueKeysWithValues: histories))
        }
    }

    /// Per-panel `updatedAt` for a tab's persisted histories — feeds the
    /// coordinator's §6.1 `.automatic` recency resolution.
    public func historyRecency(tabID: UUID) async throws -> [PanelID: Date] {
        try await writer.read { db in
            let rows = try PanelHistoryRecord
                .filter(Column("tabID") == tabID.uuidString)
                .fetchAll(db)
            var result: [PanelID: Date] = [:]
            for row in rows {
                guard let panelUUID = UUID(uuidString: row.panelID) else { continue }
                result[panelUUID] = row.updatedAt
            }
            return result
        }
    }

    /// Atomic §8 write: replace the tab's surface row + FULL history set for
    /// that tab + record the receipt, in one transaction (all-or-nothing —
    /// GRDB wraps a `write` closure in a SQLite transaction, so any thrown
    /// error rolls back everything written so far in this call, including
    /// the surface row and any history rows already saved). `position: nil`
    /// keeps the row's existing position (or defaults to 0 for a brand-new
    /// row). History rows for panels no longer in `state.histories` are
    /// deleted (full replace); a history row's `updatedAt` only advances to
    /// `now` when its decoded content actually changed — unchanged panels
    /// keep their prior `updatedAt`.
    public func commit(
        state: PanelSurfaceState, position: Int?, receipt: PanelOperationReceiptRecord?,
        now: Date = Date()
    ) async throws {
        _ = try await writer.write { db in
            let existingPosition = try WorkspaceTabSurfaceRecord.fetchOne(db, key: state.surface.id.uuidString)?.position
            let resolvedPosition = position ?? existingPosition ?? 0
            let surfaceRecord = try WorkspaceTabSurfaceRecord(
                from: state.surface, position: resolvedPosition, updatedAt: now)
            try surfaceRecord.save(db)

            let existingHistoryRows = try PanelHistoryRecord
                .filter(Column("tabID") == state.surface.id.uuidString)
                .fetchAll(db)
            let existingByPanelID = Dictionary(uniqueKeysWithValues: existingHistoryRows.map { ($0.panelID, $0) })

            // Full replace: drop rows for panels no longer present in the new state.
            let newPanelIDStrings = Set(state.histories.keys.map(\.uuidString))
            for row in existingHistoryRows where !newPanelIDStrings.contains(row.panelID) {
                try PanelHistoryRecord.deleteOne(db, key: row.panelID)
            }

            for (panelID, history) in state.histories {
                let existingRow = existingByPanelID[panelID.uuidString]
                let unchanged = existingRow.flatMap { $0.toModel()?.history } == history
                let updatedAt = unchanged ? (existingRow?.updatedAt ?? now) : now
                let record = try PanelHistoryRecord(
                    panelID: panelID, tabID: state.surface.id, history: history, updatedAt: updatedAt)
                try record.save(db)
            }

            if let receipt {
                try receipt.save(db)
            }
        }
    }

    /// Delete all surfaces (and, via `ON DELETE CASCADE`, their histories)
    /// plus any operation receipts for a worktree. History rows cascade
    /// automatically through the surface's FK; receipts reference the
    /// worktree directly (not the surface), so they're deleted explicitly
    /// here — used by callers re-writing a worktree's whole surface set so
    /// a prior write's rows never linger as stale leftovers.
    public func deleteSurfaces(worktreeID: UUID) async throws {
        _ = try await writer.write { db in
            try WorkspaceTabSurfaceRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
            try PanelOperationReceiptRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
        }
    }
}
