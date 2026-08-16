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

public enum PanelSurfaceStoreError: LocalizedError, Equatable, Sendable {
    /// A commit tried to write a panelID whose `panel_history` row already
    /// belongs to a different tab. `panel_history.panelID` is a table-wide
    /// primary key, so a blind upsert would silently steal the row (flip its
    /// tabID, overwrite its history) and lose the other tab's panel history.
    /// The invariant "panelID is globally unique across tabs" holds today
    /// (fresh UUIDs + importer cross-tab dedup), so this should never fire —
    /// it exists to turn a silent data-loss path into a loud failure.
    case panelHistoryOwnedByOtherTab(panelID: PanelID, existingTabID: WorkspaceTabID, incomingTabID: WorkspaceTabID)
    /// `commitImport` is create-if-absent: a worktree that already has a
    /// `panel_surface_imported_at` stamp OR any `workspace_tab_surface` row
    /// has already been imported (or is mid-import from a concurrent call),
    /// and must not be silently overwritten.
    case alreadyImported

    public var errorDescription: String? {
        switch self {
        case .panelHistoryOwnedByOtherTab(let panelID, let existingTabID, let incomingTabID):
            return "panel history for panel \(panelID.uuidString) already belongs to tab "
                + "\(existingTabID.uuidString); refusing a write from tab \(incomingTabID.uuidString)"
        case .alreadyImported:
            return "this worktree's panel surface was already imported"
        }
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

    /// Atomic §8 write for ONE tab: upsert the tab's surface row + its FULL
    /// history set + record the receipt, in one transaction (all-or-nothing —
    /// GRDB wraps a `write` closure in a SQLite transaction, so any thrown
    /// error rolls back everything written so far in this call, including
    /// the surface row and any history rows already saved).
    ///
    /// This is a PER-TAB upsert, NOT a worktree-level replace: it never
    /// removes surfaces for OTHER tabs of the worktree that aren't in this
    /// write. A caller wanting to replace a worktree's whole tab set must
    /// `deleteSurfaces(worktreeID:)` first (history then cascades), then
    /// commit each surviving tab. (Task 8's coordinator honors this contract.)
    ///
    /// `position: nil` keeps the row's existing position (or defaults to 0
    /// for a brand-new row). History rows for panels no longer in
    /// `state.histories` are deleted (full replace WITHIN this tab); a history
    /// row's `updatedAt` only advances to `now` when its decoded content
    /// actually changed — unchanged panels keep their prior `updatedAt`.
    ///
    /// Throws `PanelSurfaceStoreError.panelHistoryOwnedByOtherTab` if a
    /// panelID being written already has a `panel_history` row under a
    /// different tab (guards a silent cross-tab clobber — see the error doc).
    public func commit(
        state: PanelSurfaceState, position: Int?, receipt: PanelOperationReceiptRecord?,
        now: Date = Date()
    ) async throws {
        _ = try await writer.write { db in
            try Self.writeSurfaceAndHistory(state, position: position, db: db, now: now)
            if let receipt {
                try receipt.save(db)
                if let receiptWorktreeID = UUID(uuidString: receipt.worktreeID) {
                    try self.pruneReceipts(db: db, worktreeID: receiptWorktreeID, now: now)
                }
            }
        }
    }

    /// Writes ONE tab's surface row + its FULL history replace (drop-absent,
    /// cross-tab clobber guard, changed-only `updatedAt`) against an
    /// already-open write transaction. Shared by `commit` and the
    /// transactional `applyReducing` so both honor the identical per-tab
    /// contract (removed panels lose their row; no surface-row deletion needed
    /// because a single op only ever mutates one tab, never removes it).
    private static func writeSurfaceAndHistory(
        _ state: PanelSurfaceState, position: Int?, db: GRDB.Database, now: Date
    ) throws {
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

        // Loud-fail guard: `panel_history.panelID` is a table-wide PK, so a
        // blind `save` would silently steal a row owned by another tab. Any
        // panelID we're about to write that already exists under a DIFFERENT
        // tab is a violation of the global-uniqueness invariant — throw
        // instead of clobbering that tab's history.
        for panelID in state.histories.keys {
            if let owner = try PanelHistoryRecord.fetchOne(db, key: panelID.uuidString),
               owner.tabID != state.surface.id.uuidString {
                throw PanelSurfaceStoreError.panelHistoryOwnedByOtherTab(
                    panelID: panelID,
                    existingTabID: UUID(uuidString: owner.tabID) ?? UUID(),
                    incomingTabID: state.surface.id)
            }
        }

        for (panelID, history) in state.histories {
            let existingRow = existingByPanelID[panelID.uuidString]
            let unchanged = existingRow.flatMap { $0.toModel()?.history } == history
            let updatedAt = unchanged ? (existingRow?.updatedAt ?? now) : now
            let record = try PanelHistoryRecord(
                panelID: panelID, tabID: state.surface.id, history: history, updatedAt: updatedAt)
            try record.save(db)
        }
    }

    /// Outcome of a transactional `applyReducing` call.
    public enum ApplyOutcome: Sendable {
        /// A fresh commit — the reducer ran and its result was persisted.
        case applied(PanelApplyResult)
        /// `operationID` already had a receipt — the stored result is replayed
        /// (§7.4 idempotency), nothing was re-applied.
        case replayed(PanelApplyResult)
    }

    /// Transactional §7.2 apply: idempotency check, state load, reducer run,
    /// and persist ALL inside ONE write transaction, so concurrent same-tab
    /// applies under a production `DatabasePool` cannot lose an update.
    ///
    /// Actor isolation does NOT span `await`, and a pool `read` sees a
    /// pre-write WAL snapshot — so a coordinator that loaded state, reduced,
    /// then `await`ed a separate `commit` could have a second apply load the
    /// STALE pre-commit revision and clobber the first (silent lost update).
    /// Doing the load inside the write transaction means the reducer runs
    /// against the latest committed state — literally spec §7.4's "apply to
    /// the current authoritative tree" — and the pool's single-writer lock
    /// serializes the whole read-modify-write.
    ///
    /// `reduce` is the pure synchronous shared reducer (plus the caller's
    /// baseRevision→staleTarget error mapping and §6.1 `.automatic` recency
    /// rewrite). It runs fine inside the transaction. Returns `nil` when the
    /// tab has no surface row for `worktreeID` (caller maps to its
    /// not-found error).
    ///
    /// `reduce` also receives a `[PanelID: Date]` recency map (`panel_history
    /// .updatedAt`, keyed by panel) derived from the SAME `PanelHistoryRecord`
    /// rows used to build `current.histories` — one fetch inside this
    /// transaction feeds both. That is what keeps the coordinator's recency
    /// rewrite coherent with the tree the reducer applies it to: there is no
    /// separate pre-write recency query a concurrent commit could invalidate
    /// between read and reduce.
    public func applyReducing(
        operationID: UUID, tabID: UUID, worktreeID: UUID, now: Date,
        reduce: @Sendable (PanelSurfaceState, [PanelID: Date]) throws -> PanelSurfaceState
    ) async throws -> ApplyOutcome? {
        try await writer.write { db -> ApplyOutcome? in
            // Idempotency, authoritative under concurrency: a receipt committed
            // by a racing duplicate is visible here (same write lock), so the
            // second caller replays instead of double-applying.
            if let existing = try PanelOperationReceiptRecord.fetchOne(db, key: operationID.uuidString),
               let prior = decodeJSON(PanelApplyResult.self, from: existing.result) {
                return .replayed(prior)
            }

            // Load current committed state INSIDE the transaction.
            guard let surfaceRecord = try WorkspaceTabSurfaceRecord.fetchOne(db, key: tabID.uuidString),
                  let surface = surfaceRecord.toModel(),
                  surface.worktreeID == worktreeID else {
                return nil
            }
            let historyRows = try PanelHistoryRecord
                .filter(Column("tabID") == tabID.uuidString)
                .fetchAll(db)
            let histories = historyRows.compactMap { $0.toModel() }
            var recency: [PanelID: Date] = [:]
            for row in historyRows {
                guard let panelID = UUID(uuidString: row.panelID) else { continue }
                recency[panelID] = row.updatedAt
            }
            let current = PanelSurfaceState(
                surface: surface, histories: Dictionary(uniqueKeysWithValues: histories))

            let newState = try reduce(current, recency)

            try Self.writeSurfaceAndHistory(newState, position: surfaceRecord.position, db: db, now: now)

            let result = PanelApplyResult(tab: newState.surface, replayed: false)
            let receipt = PanelOperationReceiptRecord(
                operationID: operationID.uuidString, worktreeID: worktreeID.uuidString,
                tabID: tabID.uuidString, revision: Int64(newState.surface.revision),
                result: try encodeJSONString(result), appliedAt: now)
            try receipt.save(db)
            try self.pruneReceipts(db: db, worktreeID: worktreeID, now: now)
            return .applied(result)
        }
    }

    /// Keep at most this many receipts per worktree (spec C §7.4).
    private static let receiptRetentionLimit = 100
    /// Drop receipts older than this, regardless of count (spec C §7.4).
    private static let receiptMaxAge: TimeInterval = 24 * 60 * 60

    /// Shared prune body: runs INSIDE an already-open write transaction (used
    /// by `commit`) or wrapped in its own (the public `pruneReceipts` below,
    /// used directly by tests). Age-bound first, then count-bound — order
    /// doesn't affect the final surviving set, both are applied together.
    private func pruneReceipts(db: Database, worktreeID: UUID, now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.receiptMaxAge)
        try PanelOperationReceiptRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .filter(Column("appliedAt") < cutoff)
            .deleteAll(db)

        let keepIDs = try PanelOperationReceiptRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .order(Column("appliedAt").desc)
            .limit(Self.receiptRetentionLimit)
            .fetchAll(db)
            .map(\.operationID)
        try PanelOperationReceiptRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .filter(!keepIDs.contains(Column("operationID")))
            .deleteAll(db)
    }

    /// Public entry point for `pruneReceipts` — same bounds as the private
    /// helper `commit` runs automatically, exposed standalone for tests that
    /// want to drive pruning without going through a full commit.
    public func pruneReceipts(worktreeID: UUID, now: Date) async throws {
        _ = try await writer.write { db in
            try self.pruneReceipts(db: db, worktreeID: worktreeID, now: now)
        }
    }

    /// Persists a stand-alone receipt with NO surface/history write — used by
    /// `PanelCoordinator`'s `selectTab` handling, which is worktree-scoped and
    /// never mutates a `workspace_tab_surface`/`panel_history` row. Recording
    /// the receipt still lets the generic idempotency check in `apply` (which
    /// reads `receipt(operationID:)` before dispatching) replay a duplicate
    /// `selectTab` without re-touching `worktree.activeTabID` or re-broadcasting.
    public func saveReceipt(_ receipt: PanelOperationReceiptRecord, now: Date) async throws {
        _ = try await writer.write { db in
            try receipt.save(db)
            if let worktreeID = UUID(uuidString: receipt.worktreeID) {
                try self.pruneReceipts(db: db, worktreeID: worktreeID, now: now)
            }
        }
    }

    /// Idempotency lookup (spec C §7.4): the previously committed result for
    /// `operationID`, or `nil` if this operation never committed (or its
    /// receipt has since been pruned).
    public func receipt(operationID: UUID) async throws -> PanelApplyResult? {
        try await writer.read { db in
            guard let record = try PanelOperationReceiptRecord.fetchOne(db, key: operationID.uuidString) else {
                return nil
            }
            return decodeJSON(PanelApplyResult.self, from: record.result)
        }
    }

    /// Atomic §11.2 import: writes every converted surface + its histories +
    /// stamps `worktree.panel_surface_imported_at`, all in one transaction.
    /// Create-if-absent — throws `.alreadyImported` when the worktree already
    /// has a stamp OR any existing surface row (covers a prior successful
    /// import and a prior partial write alike).
    ///
    /// `conversion.histories` is keyed by `PanelID` across ALL tabs; each
    /// surface's own subset is recovered via `surface.layout.allPanelIDs` —
    /// the importer's cross-tab dedup guarantees those IDs are globally
    /// unique, so the same `panelHistoryOwnedByOtherTab` guard `commit` uses
    /// composes cleanly across this multi-tab write.
    public func commitImport(
        worktreeID: UUID, conversion: LegacySurfaceImporter.Conversion, now: Date
    ) async throws {
        _ = try await writer.write { db in
            let alreadyStamped = try WorktreeRecord
                .fetchOne(db, key: worktreeID.uuidString)?.panel_surface_imported_at != nil
            let hasExistingSurfaces = try WorkspaceTabSurfaceRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .fetchCount(db) > 0
            guard !alreadyStamped, !hasExistingSurfaces else {
                throw PanelSurfaceStoreError.alreadyImported
            }

            for (index, surface) in conversion.surfaces.enumerated() {
                let surfaceRecord = try WorkspaceTabSurfaceRecord(from: surface, position: index, updatedAt: now)
                try surfaceRecord.save(db)

                for panelID in surface.layout.allPanelIDs {
                    guard let history = conversion.histories[panelID] else { continue }
                    if let owner = try PanelHistoryRecord.fetchOne(db, key: panelID.uuidString),
                       owner.tabID != surface.id.uuidString {
                        throw PanelSurfaceStoreError.panelHistoryOwnedByOtherTab(
                            panelID: panelID,
                            existingTabID: UUID(uuidString: owner.tabID) ?? UUID(),
                            incomingTabID: surface.id)
                    }
                    let historyRecord = try PanelHistoryRecord(
                        panelID: panelID, tabID: surface.id, history: history, updatedAt: now)
                    try historyRecord.save(db)
                }
            }

            try db.execute(
                sql: "UPDATE worktree SET panel_surface_imported_at = ? WHERE id = ?",
                arguments: [now, worktreeID.uuidString])
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
