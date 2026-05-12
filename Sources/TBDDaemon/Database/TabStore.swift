import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `tab` table.
struct TabRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tab"

    var id: String
    var worktreeID: String
    var label: String?
    var createdAt: Date

    init(from state: TabState) {
        self.id = state.id.uuidString
        self.worktreeID = state.worktreeID.uuidString
        self.label = state.label
        self.createdAt = state.createdAt
    }

    func toModel() -> TabState {
        TabState(
            id: UUID(uuidString: id)!,
            worktreeID: UUID(uuidString: worktreeID)!,
            label: label,
            createdAt: createdAt
        )
    }
}

/// CRUD for tab metadata. Rows are sparse — only present when a tab has
/// user-set metadata (currently just a custom label).
///
/// NOTE: The `tab` table has no FK to `worktree`, so worktree-level
/// cleanups are explicit — see `deleteForWorktree(...)` and the call
/// sites in `WorktreeLifecycle+Archive.swift`, `WorktreeLifecycle+Reconcile.swift`,
/// and the per-row deletes in `handleTerminalDelete` / `handleNoteDelete`.
/// When adding a new code path that removes worktrees or their underlying
/// terminals/notes, mirror those deletes here too.
public struct TabStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert or update the label for a tab. Passing `nil` deletes the row.
    public func setLabel(tabID: UUID, worktreeID: UUID, label: String?) async throws {
        _ = try await writer.write { db in
            if let label {
                let record = TabRecord(from: TabState(
                    id: tabID,
                    worktreeID: worktreeID,
                    label: label,
                    createdAt: Date()
                ))
                // Preserve original createdAt if a row exists; INSERT OR REPLACE
                // would otherwise reset it. Use upsert semantics manually.
                if var existing = try TabRecord.fetchOne(db, key: tabID.uuidString) {
                    existing.label = label
                    try existing.update(db)
                } else {
                    try record.insert(db)
                }
            } else {
                try TabRecord.deleteOne(db, key: tabID.uuidString)
            }
        }
    }

    /// List all tab states for a worktree (only those with overrides).
    public func listForWorktree(worktreeID: UUID) async throws -> [TabState] {
        try await writer.read { db in
            try TabRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .fetchAll(db)
                .map { $0.toModel() }
        }
    }

    /// Delete a tab row by ID (used as cleanup when a terminal/note is deleted).
    public func delete(tabID: UUID) async throws {
        _ = try await writer.write { db in
            try TabRecord.deleteOne(db, key: tabID.uuidString)
        }
    }

    /// Delete all tab rows for a worktree (used when a worktree is removed).
    public func deleteForWorktree(worktreeID: UUID) async throws {
        _ = try await writer.write { db in
            try TabRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
        }
    }
}
