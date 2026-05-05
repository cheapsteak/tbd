import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `worktree` table.
struct WorktreeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "worktree"

    var id: String
    var repoID: String
    var name: String
    var displayName: String
    var branch: String
    var path: String
    var status: String
    var hasConflicts: Bool
    var createdAt: Date
    var archivedAt: Date?
    var tmuxServer: String
    var archivedClaudeSessions: String?
    var sortOrder: Int
    var archivedHeadSHA: String?

    init(from wt: Worktree) {
        self.id = wt.id.uuidString
        self.repoID = wt.repoID.uuidString
        self.name = wt.name
        self.displayName = wt.displayName
        self.branch = wt.branch
        self.path = wt.path
        self.status = wt.status.rawValue
        self.hasConflicts = wt.hasConflicts
        self.createdAt = wt.createdAt
        self.archivedAt = wt.archivedAt
        self.tmuxServer = wt.tmuxServer
        self.sortOrder = wt.sortOrder
        self.archivedHeadSHA = wt.archivedHeadSHA
        if let sessions = wt.archivedClaudeSessions {
            self.archivedClaudeSessions = try? String(
                data: JSONEncoder().encode(sessions), encoding: .utf8)
        }
    }

    func toModel() -> Worktree {
        var sessions: [String]?
        if let json = archivedClaudeSessions,
           let data = json.data(using: .utf8) {
            sessions = try? JSONDecoder().decode([String].self, from: data)
        }
        return Worktree(
            id: UUID(uuidString: id)!,
            repoID: UUID(uuidString: repoID)!,
            name: name,
            displayName: displayName,
            branch: branch,
            path: path,
            status: WorktreeStatus(rawValue: status)!,
            hasConflicts: hasConflicts,
            createdAt: createdAt,
            archivedAt: archivedAt,
            tmuxServer: tmuxServer,
            archivedClaudeSessions: sessions,
            sortOrder: sortOrder,
            archivedHeadSHA: archivedHeadSHA
        )
    }
}

/// Provides CRUD operations for worktrees.
public struct WorktreeStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new worktree. The displayName defaults to the name.
    /// Automatically assigns sortOrder = max(sortOrder) + 1 for the repo.
    public func create(
        repoID: UUID,
        name: String,
        displayName: String? = nil,
        branch: String,
        path: String,
        tmuxServer: String,
        status: WorktreeStatus = .active
    ) async throws -> Worktree {
        try await writer.write { db in
            let maxOrder = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sortOrder) FROM worktree WHERE repoID = ?",
                arguments: [repoID.uuidString]
            ) ?? 0
            let wt = Worktree(
                repoID: repoID,
                name: name,
                displayName: displayName ?? name,
                branch: branch,
                path: path,
                status: status,
                tmuxServer: tmuxServer,
                sortOrder: maxOrder + 1
            )
            let record = WorktreeRecord(from: wt)
            try record.insert(db)
            return wt
        }
    }

    /// Update a worktree's status.
    public func updateStatus(id: UUID, status: WorktreeStatus) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.status = status.rawValue
            try record.update(db)
        }
    }

    /// Delete a worktree by ID.
    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try WorktreeRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// Create a synthetic "main" worktree entry pointing at the repo root.
    public func createMain(
        repoID: UUID,
        name: String,
        branch: String,
        path: String,
        tmuxServer: String
    ) async throws -> Worktree {
        let wt = Worktree(
            repoID: repoID,
            name: name,
            displayName: name,
            branch: branch,
            path: path,
            status: .main,
            tmuxServer: tmuxServer
        )
        let record = WorktreeRecord(from: wt)
        try await writer.write { db in
            try record.insert(db)
        }
        return wt
    }

    /// List worktrees, optionally filtered by repo and/or status.
    public func list(repoID: UUID? = nil, status: WorktreeStatus? = nil) async throws -> [Worktree] {
        try await writer.read { db in
            var request = WorktreeRecord.all()
            if let repoID {
                request = request.filter(Column("repoID") == repoID.uuidString)
            }
            if let status {
                request = request.filter(Column("status") == status.rawValue)
            } else {
                // Exclude conductor worktrees from default listing
                request = request.filter(Column("status") != WorktreeStatus.conductor.rawValue)
            }
            return try request.order(Column("sortOrder").asc).fetchAll(db).map { $0.toModel() }
        }
    }

    /// Get a worktree by ID.
    public func get(id: UUID) async throws -> Worktree? {
        try await writer.read { db in
            try WorktreeRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// Archive a worktree (set status to archived and record the timestamp).
    /// Optionally saves Claude session IDs and the captured HEAD SHA in the
    /// same transaction so they survive terminal deletion and crashes.
    /// Refuses to archive worktrees with `.main` status.
    public func archive(
        id: UUID,
        claudeSessionIDs: [String]? = nil,
        archivedHeadSHA: String? = nil
    ) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            if record.status == WorktreeStatus.main.rawValue {
                throw DatabaseError(message: "Cannot archive the main branch worktree")
            }
            if record.status == WorktreeStatus.creating.rawValue {
                throw DatabaseError(message: "Cannot archive a worktree that is still being created")
            }
            record.status = WorktreeStatus.archived.rawValue
            record.archivedAt = Date()
            if let sessions = claudeSessionIDs, !sessions.isEmpty {
                record.archivedClaudeSessions = try String(
                    data: JSONEncoder().encode(sessions), encoding: .utf8)
            }
            if let sha = archivedHeadSHA {
                record.archivedHeadSHA = sha
            }
            try record.update(db)
        }
    }

    /// Revive an archived worktree (set status back to active, clear archivedAt).
    /// When `clearSessions` is true (default), also clears archivedClaudeSessions.
    /// Pass false to preserve sessions when Claude wasn't restored (e.g. skipClaude).
    public func revive(id: UUID, clearSessions: Bool = true) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.status = WorktreeStatus.active.rawValue
            record.archivedAt = nil
            if clearSessions {
                record.archivedClaudeSessions = nil
            }
            try record.update(db)
        }
    }

    /// Replace the archivedClaudeSessions list with `sessions` (re-encoded as JSON).
    /// Used by the revive path when a `preferredSessionID` is supplied so the
    /// last-resumed-first ordering is persisted across re-archive.
    public func setArchivedClaudeSessions(id: UUID, sessions: [String]) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else { return }
            let json = try String(data: JSONEncoder().encode(sessions), encoding: .utf8) ?? "[]"
            record.archivedClaudeSessions = json
            try record.update(db)
        }
    }

    /// Rename a worktree's display name.
    public func rename(id: UUID, displayName: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.displayName = displayName
            try record.update(db)
        }
    }

    /// Update a worktree's hasConflicts flag.
    public func updateHasConflicts(id: UUID, hasConflicts: Bool) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.hasConflicts = hasConflicts
            try record.update(db)
        }
    }

    /// Update the filesystem path for a worktree.
    public func updatePath(id: UUID, path: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.path = path
            try record.update(db)
        }
    }

    /// Update the archived HEAD SHA for a worktree (captured at archive time).
    public func updateArchivedHeadSHA(id: UUID, sha: String?) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.archivedHeadSHA = sha
            try record.update(db)
        }
    }

    /// Update the branch name for a worktree.
    public func updateBranch(id: UUID, branch: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.branch = branch
            try record.update(db)
        }
    }

    /// Update the tmux server name for a worktree.
    public func updateTmuxServer(id: UUID, tmuxServer: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.tmuxServer = tmuxServer
            try record.update(db)
        }
    }

    /// Find a worktree by its filesystem path.
    public func findByPath(path: String) async throws -> Worktree? {
        try await writer.read { db in
            try WorktreeRecord
                .filter(Column("path") == path)
                .fetchOne(db)?
                .toModel()
        }
    }

    /// Reorder worktrees within a repo. The worktreeIDs array defines the new order.
    /// Worktrees not in the array are pushed to sortOrder values after the provided list.
    public func reorder(repoID: UUID, worktreeIDs: [UUID]) async throws {
        try await writer.write { db in
            for (index, wtID) in worktreeIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE worktree SET sortOrder = ? WHERE id = ? AND repoID = ?",
                    arguments: [index, wtID.uuidString, repoID.uuidString]
                )
            }
            // Push any worktrees not in the provided list to after the reordered ones
            let idStrings = worktreeIDs.map(\.uuidString)
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")
            let args: [any DatabaseValueConvertible] = [worktreeIDs.count, repoID.uuidString] + idStrings
            try db.execute(
                sql: """
                    UPDATE worktree SET sortOrder = ? + rowid
                    WHERE repoID = ? AND status IN ('active', 'creating') AND id NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(args)
            )
        }
    }

    /// Delete all worktrees for a given repo.
    public func deleteForRepo(repoID: UUID) async throws {
        _ = try await writer.write { db in
            try WorktreeRecord
                .filter(Column("repoID") == repoID.uuidString)
                .deleteAll(db)
        }
    }
}
