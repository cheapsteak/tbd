import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")
private let panelSyncLogger = Logger(subsystem: "com.tbd.daemon", category: "panel.sync")

/// `value` as a JSON string, for a panel table's text column.
func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = String(bytes: data, encoding: .utf8) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "JSON-encoded data is not valid UTF-8"))
    }
    return string
}

/// A panel table's JSON text column decoded as `type`, or nil when it does
/// not decode.
func decodeJSON<T: Decodable>(_ type: T.Type, from string: String) -> T? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

/// The `layout` column's JSON: a workspace tab's side region without its
/// panels' histories, which live one row per panel in `panel_history` and are
/// joined back on read. A row in any other shape — spec C's layout tree among
/// them — does not decode and reads as no surface. `activePanelID` may name
/// one of the worktree's panels, which live in `worktree_panel`.
private struct StoredSideRegion: Codable {
    var panelIDs: [PanelID]
    var activePanelID: PanelID?
    var recency: [PanelID]
    var collapsed: Bool
    var width: Double

    init(_ side: SideRegion) {
        self.panelIDs = side.panels.map(\.id)
        self.activePanelID = side.activePanelID
        self.recency = side.recency
        self.collapsed = side.collapsed
        self.width = side.width
    }
}

/// GRDB Record type for the `workspace_tab_surface` table: one row per
/// workspace tab (primary, side region without histories, revision).
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
    /// True while the surface awaits its tab's first listing in a
    /// `panel.syncTabs` for its worktree, so a sync that omits the tab does
    /// not prune it until `PanelSurfaceStore.awaitingListingGrace` has passed
    /// since the row's last write. A scratch promote sets it on the surfaces
    /// it moves; the first sync that lists the tab clears it. Store-internal:
    /// the shared `WorkspaceTabSurface` does not carry it, and every write
    /// sets it.
    var awaitingListing: Bool

    init(from surface: WorkspaceTabSurface, position: Int, awaitingListing: Bool, updatedAt: Date) throws {
        self.id = surface.id.uuidString
        self.worktreeID = surface.worktreeID.uuidString
        self.primaryContent = try encodeJSONString(surface.primary)
        self.label = surface.label
        self.position = position
        self.layout = try encodeJSONString(StoredSideRegion(surface.side))
        self.revision = Int64(surface.revision)
        self.updatedAt = updatedAt
        self.awaitingListing = awaitingListing
    }

    /// Failable decode: returns nil after a logged warning, never traps, when
    /// a field fails to parse, a panel in the layout has no entry in
    /// `histories`, or the assembled surface fails `PanelSurfaceValidator`.
    /// `histories` must hold this tab's rows only. The surface takes
    /// `worktreePanels`, its worktree's stored list, through
    /// `PanelSurfaceReducer.adopting` before it is validated, so a front
    /// naming a panel the list no longer holds reads as repaired.
    func toModel(
        histories: [PanelID: PanelHistory], worktreePanels: [WorktreePanel]
    ) -> WorkspaceTabSurface? {
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
        guard let stored = decodeJSON(StoredSideRegion.self, from: layout) else {
            decodeLogger.warning("Skipping workspace_tab_surface row \(id, privacy: .public): malformed layout")
            return nil
        }
        var panels: [ViewerPanel] = []
        for panelID in stored.panelIDs {
            guard let history = histories[panelID] else {
                decodeLogger.warning(
                    "Skipping workspace_tab_surface row \(id, privacy: .public): panel \(panelID.uuidString, privacy: .public) has no readable history")
                return nil
            }
            panels.append(ViewerPanel(id: panelID, history: history))
        }
        let side = SideRegion(
            panels: panels, activePanelID: stored.activePanelID, recency: stored.recency,
            collapsed: stored.collapsed, width: stored.width)
        let surface = PanelSurfaceReducer.adopting(worktreePanels, into: WorkspaceTabSurface(
            id: uuid, worktreeID: wtID, label: label,
            primary: primary, side: side, revision: UInt64(revision)))
        let violations = PanelSurfaceValidator.violations(in: surface)
        guard violations.isEmpty else {
            let reason = violations.map { "\($0)" }.joined(separator: ", ")
            decodeLogger.warning(
                "Skipping workspace_tab_surface row \(id, privacy: .public): fails the panel model (\(reason, privacy: .public))")
            return nil
        }
        return surface
    }
}

/// GRDB Record type for the `panel_history` table: one row per viewer panel,
/// keyed by panel ID, holding that panel's navigation history.
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
/// used for idempotent replay of panel operations. `public` because
/// `PanelSurfaceStore.commit(surface:position:receipt:now:)` takes it
/// directly — callers construct the receipt themselves.
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
    /// A write tried to store a panelID whose `panel_history` row already
    /// belongs to a different tab. `panel_history.panelID` is a table-wide
    /// primary key, so a blind upsert would silently steal the row (flip its
    /// tabID, overwrite its history) and lose the other tab's panel history.
    /// Panel IDs are freshly minted — by the reducer for a new panel and by
    /// the legacy converter for an imported one — so this should never fire;
    /// it turns a silent data-loss path into a loud failure.
    case panelHistoryOwnedByOtherTab(panelID: PanelID, existingTabID: WorkspaceTabID, incomingTabID: WorkspaceTabID)
    /// A write tried to store a worktree panel whose `worktree_panel` row
    /// already belongs to another worktree. The row's `id` is a table-wide
    /// key, so a blind upsert would move the panel out of the other
    /// worktree's list; the write is refused instead. Only a scratch promote
    /// moves worktree panels between worktrees, and it re-points them
    /// explicitly.
    case worktreePanelOwnedByOtherWorktree(panelID: PanelID, existingWorktreeID: UUID, incomingWorktreeID: UUID)
    /// A write tried to store a surface that fails `PanelSurfaceValidator`.
    /// Such a row would read back as no surface, and a tab sync never
    /// replaces a row it cannot read, so the tab would be stranded; the write
    /// is refused instead.
    case invalidSurface(tabID: WorkspaceTabID, violations: [PanelSurfaceViolation])
    /// The one `panel_revision_counter` row the `panel_tabs` migration seeds
    /// is gone, so no write can take a revision; the write is refused rather
    /// than given one that could fall below a stored revision.
    case revisionCounterMissing

    public var errorDescription: String? {
        switch self {
        case .panelHistoryOwnedByOtherTab(let panelID, let existingTabID, let incomingTabID):
            return "panel history for panel \(panelID.uuidString) already belongs to tab "
                + "\(existingTabID.uuidString); refusing a write from tab \(incomingTabID.uuidString)"
        case .worktreePanelOwnedByOtherWorktree(let panelID, let existingWorktreeID, let incomingWorktreeID):
            return "worktree panel \(panelID.uuidString) already belongs to worktree "
                + "\(existingWorktreeID.uuidString); refusing a write from worktree \(incomingWorktreeID.uuidString)"
        case .invalidSurface(let tabID, let violations):
            let reason = violations.map { "\($0)" }.joined(separator: ", ")
            return "refusing to store tab \(tabID.uuidString)'s panel surface: it breaks the panel model (\(reason))"
        case .revisionCounterMissing:
            return "refusing to store a panel surface: the panel_revision_counter row is missing"
        }
    }
}

/// One workspace tab as a `panel.syncTabs` call lists it.
public struct SyncTabEntry: Sendable {
    public let tabID: UUID
    /// The tab's index in the tab bar; stored in the `position` column.
    public let position: Int
    public let label: String?
    /// The tab's primary as the app knows it; nil keeps the stored one.
    public let primary: PrimaryContent?
    /// The surface to insert when the tab has no row yet — the legacy
    /// converter's output, or nil when the converter skipped the tab.
    public let importCandidate: WorkspaceTabSurface?

    public init(tabID: UUID, position: Int, label: String?, primary: PrimaryContent?,
                importCandidate: WorkspaceTabSurface?) {
        self.tabID = tabID
        self.position = position
        self.label = label
        self.primary = primary
        self.importCandidate = importCandidate
    }
}

/// What one `syncTabs` call changed, all lists in the order they were
/// processed.
public struct SyncOutcome: Sendable, Equatable {
    /// Every surface the call inserted or updated, as stored.
    public var changed: [WorkspaceTabSurface]
    /// Listed tabs that had no readable row and now have one: imported where
    /// there was no row, or replacing a row that could not be read.
    public var imported: [UUID]
    /// Listed tabs whose row moved here from another worktree.
    public var reparented: [UUID]
    /// This worktree's tabs whose rows were deleted because they were not
    /// listed.
    public var removed: [UUID]
    /// Listed tabs with no readable row and no import candidate, because the
    /// converter skipped them: the sync left them without a surface.
    public var skipped: [UUID]

    public init(changed: [WorkspaceTabSurface] = [], imported: [UUID] = [],
                reparented: [UUID] = [], removed: [UUID] = [], skipped: [UUID] = []) {
        self.changed = changed
        self.imported = imported
        self.reparented = reparented
        self.removed = removed
        self.skipped = skipped
    }
}

/// Store for the panel-surface tables (workspace tab surfaces, per-panel
/// histories, worktree panels, operation receipts). See the panel tabs spec,
/// "Daemon → Store", and the side panel notes spec, "Daemon".
///
/// A surface is written as one `workspace_tab_surface` row plus one
/// `panel_history` row per panel, and read back by joining the two, and its
/// worktree's `worktree_panel` rows, inside one transaction. A row that fails
/// to decode, lacks a panel's history, or fails the validator reads as no
/// surface.
///
/// The worktree's panels are one list per worktree, which every surface of
/// the worktree carries. A change to the list rewrites every other readable
/// surface of the worktree in the same transaction, each at a fresh revision,
/// so every snapshot the app holds of the worktree's tabs agrees on it.
///
/// Revisions are daemon-wide: every write that creates or changes a surface
/// takes its revision from the one-row `panel_revision_counter`, incremented
/// inside the same transaction, and the counter never decreases. So a tab's
/// revision keeps rising even when its surface is deleted and re-imported —
/// by a sync, or by an archive and revive — and the app's revision guard can
/// compare any two snapshots of a tab.
public struct PanelSurfaceStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// All readable workspace-tab surfaces for a worktree, ordered by
    /// position, with their panels' histories and the worktree's panels
    /// joined in. Unreadable rows are skipped with a logged warning.
    public func surfaces(worktreeID: UUID) async throws -> [WorkspaceTabSurface] {
        try await writer.read { db in
            let records = try WorkspaceTabSurfaceRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .order(Column("position"))
                .fetchAll(db)
            let historiesByTab = try Self.histories(tabKeys: records.map(\.id), db: db)
            let worktreePanels = try Self.storedWorktreePanels(worktreeKey: worktreeID.uuidString, db: db)
            return records.compactMap {
                $0.toModel(histories: historiesByTab[$0.id] ?? [:], worktreePanels: worktreePanels)
            }
        }
    }

    /// A tab's surface with its panels' histories and its worktree's panels
    /// joined in, or nil when the tab has no row or its row cannot be read.
    public func surface(tabID: UUID) async throws -> WorkspaceTabSurface? {
        try await writer.read { db in
            guard let record = try WorkspaceTabSurfaceRecord.fetchOne(db, key: tabID.uuidString) else {
                return nil
            }
            return try Self.loadSurface(record, db: db)
        }
    }

    /// Writes one tab's whole surface — the row plus its full history set —
    /// and, when given, a receipt, in one transaction. A per-tab upsert, never
    /// a worktree-level replace: other tabs' rows are untouched. Operations go
    /// through `applyReducing` and tab-set changes through `syncTabs`; this is
    /// for callers that own a whole surface, such as test seeding.
    ///
    /// `position: nil` keeps the row's existing position (0 for a new row).
    /// Throws `invalidSurface` or `panelHistoryOwnedByOtherTab` before
    /// anything lands. A commit lists no tab, so the row keeps its
    /// `awaitingListing` marker (none for a new row).
    ///
    /// The surface is stored at the revision it carries, since its caller
    /// owns it whole; the revision counter is raised to at least that
    /// revision, so every later write still takes a higher one.
    ///
    /// The surface's `worktreePanels` are validated with it but not stored:
    /// the list is the worktree's, written only by an operation that changes
    /// it, and a read joins in the stored list.
    public func commit(
        surface: WorkspaceTabSurface, position: Int?, receipt: PanelOperationReceiptRecord?,
        now: Date = Date()
    ) async throws {
        _ = try await writer.write { db in
            try Self.writeSurface(surface, position: position, awaitingListing: nil, db: db, now: now)
            try Self.raiseRevisionCounter(toAtLeast: surface.revision, db: db)
            if let receipt {
                try receipt.save(db)
                if let receiptWorktreeID = UUID(uuidString: receipt.worktreeID) {
                    try self.pruneReceipts(db: db, worktreeID: receiptWorktreeID, now: now)
                }
            }
        }
    }

    /// Each listed tab's readable panel histories, keyed by tab ID string,
    /// then panel ID. A malformed history row is left out (and logged), so the
    /// surface that names its panel reads as no surface.
    static func histories(
        tabKeys: [String], db: GRDB.Database
    ) throws -> [String: [PanelID: PanelHistory]] {
        guard !tabKeys.isEmpty else { return [:] }
        var byTab: [String: [PanelID: PanelHistory]] = [:]
        let rows = try PanelHistoryRecord
            .filter(tabKeys.contains(Column("tabID")))
            .fetchAll(db)
        for row in rows {
            guard let decoded = row.toModel() else { continue }
            byTab[row.tabID, default: [:]][decoded.panelID] = decoded.history
        }
        return byTab
    }

    /// The daemon-wide revision counter's next value, against an
    /// already-open write transaction: it is incremented and read in the
    /// caller's transaction, so a write that rolls back takes nothing.
    static func nextRevision(db: GRDB.Database) throws -> UInt64 {
        try db.execute(sql: "UPDATE panel_revision_counter SET value = value + 1 WHERE id = 1")
        guard let value = try Int64.fetchOne(
            db, sql: "SELECT value FROM panel_revision_counter WHERE id = 1"
        ) else {
            throw PanelSurfaceStoreError.revisionCounterMissing
        }
        return UInt64(value)
    }

    /// Raises the revision counter to at least `revision`, never lowering
    /// it, for a write that stores a revision it did not take from the
    /// counter.
    private static func raiseRevisionCounter(toAtLeast revision: UInt64, db: GRDB.Database) throws {
        try db.execute(
            sql: "UPDATE panel_revision_counter SET value = MAX(value, ?) WHERE id = 1",
            arguments: [Int64(revision)])
        guard db.changesCount > 0 else {
            throw PanelSurfaceStoreError.revisionCounterMissing
        }
    }

    /// Clears one row's `awaitingListing` marker, and nothing else, against an
    /// already-open write transaction: a sync listed its tab. The marker is
    /// store-internal, so the surface the app sees is unchanged and takes no
    /// revision.
    private static func clearAwaitingListing(tabKey: String, db: GRDB.Database) throws {
        try db.execute(
            sql: "UPDATE workspace_tab_surface SET awaitingListing = 0 WHERE id = ?",
            arguments: [tabKey])
    }

    /// One row's surface with its own histories and the panels of the
    /// worktree it names joined in, or nil when the row cannot be read.
    static func loadSurface(
        _ record: WorkspaceTabSurfaceRecord, db: GRDB.Database
    ) throws -> WorkspaceTabSurface? {
        let historiesByTab = try Self.histories(tabKeys: [record.id], db: db)
        let worktreePanels = try Self.storedWorktreePanels(worktreeKey: record.worktreeID, db: db)
        return record.toModel(histories: historiesByTab[record.id] ?? [:], worktreePanels: worktreePanels)
    }

    /// Writes ONE tab's surface row and its full history set against an
    /// already-open write transaction:
    ///
    /// - refuses a surface that fails the validator (`invalidSurface`);
    /// - drops this tab's history rows for panels it no longer has;
    /// - refuses a panel whose history row belongs to another tab
    ///   (`panelHistoryOwnedByOtherTab`);
    /// - writes a panel's history row only when its history changed, so an
    ///   untouched panel keeps its row's `updatedAt`.
    ///
    /// `position: nil` keeps the row's existing position (0 for a new row),
    /// and `awaitingListing: nil` keeps its marker (false for a new row).
    /// The surface's `worktreePanels` are validated with it and not written:
    /// `writeWorktreePanels` stores the worktree's list.
    static func writeSurface(
        _ surface: WorkspaceTabSurface, position: Int?, awaitingListing: Bool?,
        db: GRDB.Database, now: Date
    ) throws {
        let violations = PanelSurfaceValidator.violations(in: surface)
        guard violations.isEmpty else {
            throw PanelSurfaceStoreError.invalidSurface(tabID: surface.id, violations: violations)
        }
        let tabKey = surface.id.uuidString

        var existing: WorkspaceTabSurfaceRecord?
        if position == nil || awaitingListing == nil {
            existing = try WorkspaceTabSurfaceRecord.fetchOne(db, key: tabKey)
        }
        try WorkspaceTabSurfaceRecord(
            from: surface,
            position: position ?? existing?.position ?? 0,
            awaitingListing: awaitingListing ?? existing?.awaitingListing ?? false,
            updatedAt: now
        ).save(db)

        let existingRows = try PanelHistoryRecord
            .filter(Column("tabID") == tabKey)
            .fetchAll(db)
        let existingByPanelKey = Dictionary(
            existingRows.map { ($0.panelID, $0) }, uniquingKeysWith: { first, _ in first })

        // Full replace within this tab: a closed panel loses its row.
        let panelKeys = Set(surface.side.panels.map(\.id.uuidString))
        for row in existingRows where !panelKeys.contains(row.panelID) {
            try PanelHistoryRecord.deleteOne(db, key: row.panelID)
        }

        // `panel_history.panelID` is a table-wide key, so a blind `save` would
        // steal a row owned by another tab. Throw instead.
        for panel in surface.side.panels {
            if let owner = try PanelHistoryRecord.fetchOne(db, key: panel.id.uuidString),
               owner.tabID != tabKey {
                throw PanelSurfaceStoreError.panelHistoryOwnedByOtherTab(
                    panelID: panel.id,
                    existingTabID: UUID(uuidString: owner.tabID) ?? UUID(),
                    incomingTabID: surface.id)
            }
        }

        for panel in surface.side.panels {
            if existingByPanelKey[panel.id.uuidString]?.toModel()?.history == panel.history {
                continue
            }
            try PanelHistoryRecord(
                panelID: panel.id, tabID: surface.id, history: panel.history, updatedAt: now
            ).save(db)
        }
    }

    /// Outcome of a transactional `applyReducing` call.
    public enum ApplyOutcome: Sendable, Equatable {
        /// A fresh commit — the reducer ran and its result was persisted.
        /// `siblings` are the worktree's other surfaces the commit rewrote,
        /// in position order, because the operation changed the worktree's
        /// panel list; empty when it did not.
        case applied(PanelApplyResult, siblings: [WorkspaceTabSurface])
        /// `operationID` already had a receipt for this tab — the stored
        /// result is replayed, nothing was re-applied.
        case replayed(PanelApplyResult)
        /// `operationID` already had a receipt for another tab: the caller
        /// reused an operation ID. Nothing was applied, and the other tab's
        /// receipt is untouched.
        case operationIDReused
    }

    /// What `operationID`'s receipt decides for an operation on `tabID`,
    /// against an open transaction: `.replayed` with the stored result when
    /// the receipt is this tab's, `.operationIDReused` when it is another
    /// tab's, and nil when there is no receipt, or this tab's receipt holds a
    /// result that cannot be read, which the operation then replaces by
    /// applying anew. Never `.applied`.
    ///
    /// Only the tab is compared, not the worktree. Tab IDs are global, and a
    /// tab's receipts move with it when a sync re-parents it or a scratch
    /// promote moves it, so a retry that still names the worktree the tab
    /// left replays that tab's own result.
    private static func replayOutcome(
        operationID: UUID, tabID: UUID, in db: GRDB.Database
    ) throws -> ApplyOutcome? {
        guard let existing = try PanelOperationReceiptRecord.fetchOne(db, key: operationID.uuidString) else {
            return nil
        }
        guard UUID(uuidString: existing.tabID) == tabID else {
            return .operationIDReused
        }
        guard let prior = decodeJSON(PanelApplyResult.self, from: existing.result) else {
            return nil
        }
        return .replayed(prior)
    }

    /// The idempotency check `applyReducing` makes first, as a read on its
    /// own, for a caller's fast path: `.replayed`, `.operationIDReused`, or
    /// nil when the operation would apply. Never `.applied`.
    public func replayOutcome(operationID: UUID, tabID: UUID) async throws -> ApplyOutcome? {
        try await writer.read { db in
            try Self.replayOutcome(operationID: operationID, tabID: tabID, in: db)
        }
    }

    /// Transactional apply: idempotency check, surface load, reducer run, and
    /// persist ALL inside ONE write transaction, so concurrent same-tab
    /// applies under a production `DatabasePool` cannot lose an update.
    ///
    /// Actor isolation does not span `await`, and a pool `read` sees a
    /// pre-write WAL snapshot — so a coordinator that loaded the surface,
    /// reduced, then `await`ed a separate write could have a second apply
    /// load the stale pre-write revision and clobber the first. Loading
    /// inside the write transaction means the reducer always runs against
    /// the latest committed surface, and the pool's single-writer lock
    /// serializes the whole read-modify-write.
    ///
    /// `reduce` is the pure synchronous shared reducer plus whatever error
    /// mapping the caller needs. Returns nil when the tab has no readable
    /// surface under `worktreeID` (the caller maps that to its not-found
    /// error), and `.operationIDReused` without running `reduce` when
    /// `operationID`'s receipt is another tab's. The reduced surface is
    /// stored at the revision counter's next value, whatever revision the
    /// reducer gave it. The row keeps its position and its `awaitingListing`
    /// marker, since an operation lists no tab; the receipt stores the
    /// result.
    ///
    /// When the reduced surface's `worktreePanels` differ from the stored
    /// list, the same transaction stores the new list and rewrites every
    /// other readable surface of the worktree with it
    /// (`rewriteSurfaces`), and the outcome carries them in `siblings`. A
    /// sibling row that cannot be read is left as it is.
    public func applyReducing(
        operationID: UUID, tabID: UUID, worktreeID: UUID, now: Date,
        reduce: @Sendable (WorkspaceTabSurface) throws -> WorkspaceTabSurface
    ) async throws -> ApplyOutcome? {
        try await writer.write { db -> ApplyOutcome? in
            // Idempotency, authoritative under concurrency: a receipt committed
            // by a racing duplicate is visible here (same write lock), so the
            // second caller replays instead of double-applying, and a reused
            // ID for another tab is refused here too.
            if let prior = try Self.replayOutcome(operationID: operationID, tabID: tabID, in: db) {
                return prior
            }

            guard let record = try WorkspaceTabSurfaceRecord.fetchOne(db, key: tabID.uuidString),
                  let current = try Self.loadSurface(record, db: db),
                  current.worktreeID == worktreeID else {
                return nil
            }

            var next = try reduce(current)
            next.revision = try Self.nextRevision(db: db)

            try Self.writeSurface(
                next, position: record.position, awaitingListing: record.awaitingListing, db: db, now: now)

            var siblings: [WorkspaceTabSurface] = []
            if next.worktreePanels != current.worktreePanels {
                try Self.writeWorktreePanels(next.worktreePanels, worktreeID: worktreeID, db: db)
                siblings = try Self.rewriteSurfaces(
                    worktreeID: worktreeID, worktreePanels: next.worktreePanels, except: tabID,
                    db: db, now: now)
            }

            let result = PanelApplyResult(tab: next, replayed: false)
            let receipt = PanelOperationReceiptRecord(
                operationID: operationID.uuidString, worktreeID: worktreeID.uuidString,
                tabID: tabID.uuidString, revision: Int64(next.revision),
                result: try encodeJSONString(result), appliedAt: now)
            try receipt.save(db)
            try self.pruneReceipts(db: db, worktreeID: worktreeID, now: now)
            return .applied(result, siblings: siblings)
        }
    }

    /// `panel.syncTabs` (panel tabs spec, "Tab sync"), in one write
    /// transaction. For each listed tab, first occurrence only:
    ///
    /// - **No row** – inserts `importCandidate` under this worktree with the
    ///   entry's position, label and (when given) primary, at the revision
    ///   counter's next value, and reports it in `imported` and `changed`;
    ///   nothing when the candidate is nil, because the converter skipped the
    ///   tab, which is then reported in `skipped`.
    /// - **Unreadable row** – one that fails to decode or validate is
    ///   replaced, with its histories, by `importCandidate`, exactly as a
    ///   missing row is imported, with a logged warning: otherwise the tab
    ///   would stay on legacy for good, since no later sync could read it
    ///   either. With no candidate the row is left as it is and the tab is
    ///   reported in `skipped`, so the app stops asking for a surface it
    ///   cannot get.
    /// - **Readable row** – never overwritten. Re-points it to this worktree
    ///   when it sits under another, with the tab's operation receipts, so
    ///   they are pruned and archived with the worktree that now holds the
    ///   tab; and applies the entry's position, label and primary (primary
    ///   only when non-nil). When any of those changed, the surface takes the
    ///   revision counter's next value and is reported in `changed`. Panels
    ///   and histories are never touched.
    ///
    /// Every surface the sync inserts or reports carries this worktree's
    /// panels: an import adopts the list before it is written
    /// (`PanelSurfaceReducer.adopting`), so a tab with no panel of its own
    /// shows the first worktree panel in front, and an updated surface
    /// carries the list a read of it joins in.
    ///
    /// Listing a tab clears its row's `awaitingListing` marker, whichever
    /// case applies. Clearing it alone changes nothing the app sees, so it
    /// takes no revision and is not reported.
    ///
    /// This worktree's rows for tabs not listed are deleted first, except a
    /// row awaiting its tab's first listing that was last written within
    /// `awaitingListingGrace` of `now`; their histories cascade. A scratch
    /// promote moves surfaces here before the app's tab list names them, and
    /// a sync built from the earlier list can land after the move, so such a
    /// row survives until a sync lists its tab or the grace runs out. Other
    /// worktrees' rows, and every receipt but a re-parented tab's, are left
    /// alone.
    ///
    /// An archived worktree changes nothing and gets an empty outcome:
    /// archiving deleted its surfaces (`WorktreeStore.archive`), and a sync
    /// that lands after it must not import them again. A revive makes the
    /// worktree syncable again.
    public func syncTabs(
        worktreeID: UUID, entries: [SyncTabEntry], now: Date
    ) async throws -> SyncOutcome {
        try await writer.write { db -> SyncOutcome in
            var outcome = SyncOutcome()

            let status = try String.fetchOne(
                db, sql: "SELECT status FROM worktree WHERE id = ?", arguments: [worktreeID.uuidString])
            guard status != WorktreeStatus.archived.rawValue else { return outcome }
            let worktreePanels = try Self.storedWorktreePanels(worktreeKey: worktreeID.uuidString, db: db)

            let listedKeys = entries.map(\.tabID.uuidString)
            let graceCutoff = now.addingTimeInterval(-Self.awaitingListingGrace)
            let unlisted = try WorkspaceTabSurfaceRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .filter(!listedKeys.contains(Column("id")))
                .filter(Column("awaitingListing") == false || Column("updatedAt") < graceCutoff)
                .order(Column("position"))
                .fetchAll(db)
            for row in unlisted {
                try WorkspaceTabSurfaceRecord.deleteOne(db, key: row.id)
                if let removedID = UUID(uuidString: row.id) {
                    outcome.removed.append(removedID)
                }
            }

            var seen = Set<UUID>()
            for entry in entries {
                guard seen.insert(entry.tabID).inserted else { continue }

                let record = try WorkspaceTabSurfaceRecord.fetchOne(db, key: entry.tabID.uuidString)
                let current = try record.flatMap { try Self.loadSurface($0, db: db) }
                guard let record, let current else {
                    guard let candidate = entry.importCandidate else {
                        if let record, record.awaitingListing {
                            try Self.clearAwaitingListing(tabKey: record.id, db: db)
                        }
                        outcome.skipped.append(entry.tabID)
                        continue
                    }
                    if let record {
                        panelSyncLogger.warning("""
                            panel.syncTabs worktree=\(worktreeID, privacy: .public) \
                            replacing tab \(entry.tabID, privacy: .public)'s unreadable surface \
                            (stored under worktree \(record.worktreeID, privacy: .public)) \
                            with its legacy import
                            """)
                        // Its histories cascade.
                        try WorkspaceTabSurfaceRecord.deleteOne(db, key: record.id)
                    }
                    let imported = PanelSurfaceReducer.adopting(worktreePanels, into: WorkspaceTabSurface(
                        id: entry.tabID, worktreeID: worktreeID, label: entry.label,
                        primary: entry.primary ?? candidate.primary, side: candidate.side,
                        revision: try Self.nextRevision(db: db)))
                    try Self.writeSurface(
                        imported, position: entry.position, awaitingListing: false, db: db, now: now)
                    outcome.imported.append(entry.tabID)
                    outcome.changed.append(imported)
                    continue
                }

                let primary = entry.primary ?? current.primary
                let reparented = current.worktreeID != worktreeID
                guard reparented || record.position != entry.position
                        || current.label != entry.label || current.primary != primary else {
                    if record.awaitingListing {
                        try Self.clearAwaitingListing(tabKey: record.id, db: db)
                    }
                    continue
                }
                // This worktree's list, which a read of the row joins in. It
                // differs from `current`'s only when the tab moves here from
                // another worktree.
                let updated = PanelSurfaceReducer.adopting(worktreePanels, into: WorkspaceTabSurface(
                    id: current.id, worktreeID: worktreeID, label: entry.label,
                    primary: primary, side: current.side, revision: try Self.nextRevision(db: db)))

                // Only the row's own columns; `layout` and `panel_history`
                // stay as they are.
                var row = record
                row.worktreeID = worktreeID.uuidString
                row.label = entry.label
                row.primaryContent = try encodeJSONString(primary)
                row.position = entry.position
                row.revision = Int64(updated.revision)
                row.updatedAt = now
                row.awaitingListing = false
                try row.update(db)

                if reparented {
                    // The tab's receipts follow it, as a scratch promote's do.
                    try db.execute(
                        sql: "UPDATE panel_operation_receipt SET worktreeID = ? WHERE tabID = ?",
                        arguments: [worktreeID.uuidString, record.id])
                    outcome.reparented.append(entry.tabID)
                }
                outcome.changed.append(updated)
            }
            return outcome
        }
    }

    /// Keep at most this many receipts per worktree.
    private static let receiptRetentionLimit = 100
    /// Drop receipts older than this, regardless of count.
    private static let receiptMaxAge: TimeInterval = 24 * 60 * 60
    /// An unlisting sync prunes a row awaiting its listing once this long has
    /// passed since the row's last write. The race it guards lasts seconds;
    /// minutes of margin keep a slow or reconnecting app from losing a moved tab.
    static let awaitingListingGrace: TimeInterval = 10 * 60

    /// Shared prune body: runs INSIDE an already-open write transaction (used
    /// by `commit` and `applyReducing`) or wrapped in its own (the public
    /// `pruneReceipts` below, used directly by tests). Age-bound first, then
    /// count-bound — order doesn't affect the final surviving set.
    private func pruneReceipts(db: GRDB.Database, worktreeID: UUID, now: Date) throws {
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

    /// Public entry point for `pruneReceipts` — same bounds the private
    /// helper applies automatically, exposed standalone for tests that want
    /// to drive pruning without going through a write.
    public func pruneReceipts(worktreeID: UUID, now: Date) async throws {
        _ = try await writer.write { db in
            try self.pruneReceipts(db: db, worktreeID: worktreeID, now: now)
        }
    }

    /// Idempotency lookup: the previously committed result for
    /// `operationID`, or nil if this operation never committed (or its
    /// receipt has since been pruned).
    public func receipt(operationID: UUID) async throws -> PanelApplyResult? {
        try await writer.read { db in
            guard let record = try PanelOperationReceiptRecord.fetchOne(db, key: operationID.uuidString) else {
                return nil
            }
            return decodeJSON(PanelApplyResult.self, from: record.result)
        }
    }

    /// Delete all surfaces (and, via `ON DELETE CASCADE`, their histories)
    /// plus the worktree's panels and any operation receipts for a worktree.
    /// History rows cascade through the surface's FK; worktree panels and
    /// receipts reference the worktree directly (not the surface), so they're
    /// deleted explicitly here.
    public func deleteSurfaces(worktreeID: UUID) async throws {
        try await writer.write { db in
            try Self.deleteSurfaces(worktreeID: worktreeID, in: db)
        }
    }

    /// `deleteSurfaces(worktreeID:)` inside a caller's write transaction,
    /// returning the IDs of the tabs whose surfaces it deleted, so the caller
    /// can name them in a delta's `removedTabIDs`. `WorktreeStore.archive`
    /// runs it in the transaction that archives the worktree: an archived
    /// worktree keeps its row, so the cascade from that row never fires, and
    /// this is what reclaims its panel rows, its worktree panels among them.
    /// A row awaiting its tab's first listing goes too.
    @discardableResult
    static func deleteSurfaces(worktreeID: UUID, in db: Database) throws -> [UUID] {
        let tabKeys = try String.fetchAll(
            db, sql: "SELECT id FROM workspace_tab_surface WHERE worktreeID = ? ORDER BY position",
            arguments: [worktreeID.uuidString])
        try WorkspaceTabSurfaceRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .deleteAll(db)
        try WorktreePanelRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .deleteAll(db)
        try PanelOperationReceiptRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .deleteAll(db)
        return tabKeys.compactMap(UUID.init(uuidString:))
    }

    /// Moves every surface of `fromWorktreeID` to `toWorktreeID` inside a
    /// caller's write transaction, with `fromWorktreeID`'s worktree panels
    /// and operation receipts. Histories go with their surfaces, because they
    /// key on the tab, which keeps its ID. Each moved row takes the counter's
    /// next revision, as a sync's re-parent does, and a position after every
    /// surface `toWorktreeID` already holds, in the order the rows had, so
    /// no two of its surfaces share a position before the next sync sets
    /// them. The receipts move rather than go, so a `panel.apply` retried
    /// across the move still replays.
    ///
    /// The worktree panels join `toWorktreeID`'s after its own, in their
    /// order. One showing content `toWorktreeID` already shows, such as a
    /// second Changes panel, is dropped and its row deleted, and a moved tab
    /// that had it in front fronts `toWorktreeID`'s panel on that content
    /// instead. Every surface under `toWorktreeID` then carries the merged
    /// list: when it differs from `toWorktreeID`'s own, its readable surfaces
    /// are rewritten with it (`rewriteSurfaces`).
    ///
    /// Each moved row is marked `awaitingListing`. The app learns of the
    /// main worktree before this move, so a `panel.syncTabs` it built from
    /// its earlier tab list, which does not name the moved tabs, can land
    /// after it; the marker keeps that sync from pruning them, until a sync
    /// lists the tab or `awaitingListingGrace` passes. `WorktreeStore.archive`
    /// still deletes a marked row.
    ///
    /// Returns, for a delta's `tabs`, `toWorktreeID`'s own surfaces that the
    /// merged list rewrote, then the moved surfaces, each group ordered by
    /// position and as stored; a moved row that cannot be read still moves
    /// but is not returned. `WorktreeStore.promoteScratchMigration` runs it
    /// in the transaction that retires a promoted scratch worktree, which
    /// archives that row without going through `WorktreeStore.archive`: the
    /// tabs move to the main worktree, and their panels move with them.
    static func reparentSurfaces(
        from fromWorktreeID: UUID, to toWorktreeID: UUID, now: Date, in db: GRDB.Database
    ) throws -> [WorkspaceTabSurface] {
        let ownPanels = try Self.storedWorktreePanels(worktreeKey: toWorktreeID.uuidString, db: db)
        var merged = ownPanels
        // A dropped panel's ID, mapped to the kept panel on its content.
        var replacements: [PanelID: PanelID] = [:]
        for panel in try Self.storedWorktreePanels(worktreeKey: fromWorktreeID.uuidString, db: db) {
            if let kept = merged.first(where: { $0.content == panel.content }) {
                replacements[panel.id] = kept.id
            } else {
                merged.append(panel)
            }
        }
        let droppedKeys = replacements.keys.map(\.uuidString)
        try WorktreePanelRecord.filter(droppedKeys.contains(Column("id"))).deleteAll(db)

        // Before the moved rows arrive, so only `toWorktreeID`'s own
        // surfaces are rewritten here.
        var rewritten: [WorkspaceTabSurface] = []
        if merged != ownPanels {
            rewritten = try Self.rewriteSurfaces(
                worktreeID: toWorktreeID, worktreePanels: merged, except: nil, db: db, now: now)
        }

        var rows = try WorkspaceTabSurfaceRecord
            .filter(Column("worktreeID") == fromWorktreeID.uuidString)
            .order(Column("position"))
            .fetchAll(db)
        let firstFreePosition = try Int.fetchOne(
            db, sql: "SELECT MAX(position) + 1 FROM workspace_tab_surface WHERE worktreeID = ?",
            arguments: [toWorktreeID.uuidString]) ?? 0
        for index in rows.indices {
            rows[index].worktreeID = toWorktreeID.uuidString
            rows[index].position = firstFreePosition + index
            rows[index].layout = Self.layout(rows[index].layout, replacingFront: replacements)
            rows[index].revision = Int64(try Self.nextRevision(db: db))
            rows[index].updatedAt = now
            rows[index].awaitingListing = true
            try rows[index].update(db)
        }
        try db.execute(
            sql: "UPDATE worktree_panel SET worktreeID = ? WHERE worktreeID = ?",
            arguments: [toWorktreeID.uuidString, fromWorktreeID.uuidString])
        try Self.writeWorktreePanels(merged, worktreeID: toWorktreeID, db: db)
        try db.execute(
            sql: "UPDATE panel_operation_receipt SET worktreeID = ? WHERE worktreeID = ?",
            arguments: [toWorktreeID.uuidString, fromWorktreeID.uuidString])
        let historiesByTab = try Self.histories(tabKeys: rows.map(\.id), db: db)
        let moved = rows.compactMap {
            $0.toModel(histories: historiesByTab[$0.id] ?? [:], worktreePanels: merged)
        }
        return rewritten + moved
    }

    /// `layout` with the panel in front replaced by `replacements[front]`
    /// when that names one; unchanged otherwise, or when it does not decode.
    private static func layout(_ layout: String, replacingFront replacements: [PanelID: PanelID]) -> String {
        guard !replacements.isEmpty,
              var stored = decodeJSON(StoredSideRegion.self, from: layout),
              let front = stored.activePanelID,
              let replacement = replacements[front] else {
            return layout
        }
        stored.activePanelID = replacement
        return (try? encodeJSONString(stored)) ?? layout
    }
}
