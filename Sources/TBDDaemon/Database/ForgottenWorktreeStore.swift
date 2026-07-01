import Foundation
import GRDB

/// GRDB Record type for the `forgotten_worktree` table.
///
/// A tombstone row records that the user explicitly ran `tbd worktree forget`
/// on a worktree at `path`. Reconcile consults these rows so a forgotten
/// worktree that still lives under a TBD-managed prefix (and is still
/// registered with git) is NOT re-adopted on the next sweep. The tombstone is
/// keyed by exact absolute path — the directory is the thing being ignored,
/// not any particular worktree row.
struct ForgottenWorktreeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "forgotten_worktree"

    var path: String
    var repoID: String
    var forgottenAt: Date
}

/// CRUD for worktree-forget tombstones. Daemon-internal — tombstones are not
/// exposed over RPC and have no mirror in `TBDShared.Models`.
public struct ForgottenWorktreeStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert (or refresh) a tombstone for `path`. Idempotent: re-forgetting
    /// the same path updates `forgottenAt` instead of throwing on the
    /// primary-key conflict.
    public func insert(path: String, repoID: UUID) async throws {
        let record = ForgottenWorktreeRecord(
            path: path,
            repoID: repoID.uuidString,
            forgottenAt: Date()
        )
        try await writer.write { db in
            try record.save(db)
        }
    }

    /// Whether a tombstone exists for the exact path.
    public func contains(path: String) async throws -> Bool {
        try await writer.read { db in
            try ForgottenWorktreeRecord.fetchOne(db, key: path) != nil
        }
    }

    /// All tombstoned paths, loaded as a set for O(1) membership checks in
    /// reconcile's re-adopt loop. Deliberately NOT scoped to a repo: the
    /// tombstone's semantic key is the directory path, and matching globally
    /// keeps forget sticky even if the repo row is ever deleted and re-added
    /// under a new UUID.
    public func allPaths() async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT path FROM forgotten_worktree"))
        }
    }

    /// Remove the tombstone for `path` (exact match). No-op when absent.
    /// Called when a worktree is deliberately re-added at a tombstoned path
    /// (adopt or create), so the ignore doesn't outlive the user's intent.
    public func delete(path: String) async throws {
        _ = try await writer.write { db in
            try ForgottenWorktreeRecord.deleteOne(db, key: path)
        }
    }
}
