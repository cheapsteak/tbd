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
    var tabOrder: String  // JSON array of UUID strings, e.g. "[]" or "[\"...\",\"...\"]"
    var activeTabID: String?
    var parentWorktreeID: String?

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
        self.tabOrder = "[]"  // overwritten by GRDB when fetched; only "new worktree" path uses this initializer
        self.activeTabID = nil  // new worktrees start with no stored selection
        self.parentWorktreeID = wt.parentWorktreeID?.uuidString
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
            archivedHeadSHA: archivedHeadSHA,
            parentWorktreeID: parentWorktreeID.flatMap { UUID(uuidString: $0) }
        )
    }
}

public enum WorktreeMoveError: Error, CustomStringConvertible {
    case selfReference
    case cycle
    case parentNotFound
    case parentIsMain
    case worktreeNotFound

    public var description: String {
        switch self {
        case .selfReference: return "A worktree cannot be its own parent."
        case .cycle: return "This move would create a cycle in the worktree tree."
        case .parentNotFound: return "Parent worktree not found."
        case .parentIsMain: return "Cannot nest under the main worktree."
        case .worktreeNotFound: return "Worktree not found."
        }
    }
}

public enum WorktreeArchiveError: Error, CustomStringConvertible {
    case hasActiveChildren

    public var description: String {
        "Archive nested worktrees first."
    }
}

/// Provides CRUD operations for worktrees.
public struct WorktreeStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new worktree. The displayName defaults to the name.
    /// Automatically assigns sortOrder = max(sortOrder) + 1 scoped to the
    /// new worktree's sibling group (same parentWorktreeID), so nested
    /// children get their own contiguous ordering separate from top-level
    /// worktrees in the same repo.
    public func create(
        repoID: UUID,
        name: String,
        displayName: String? = nil,
        branch: String,
        path: String,
        tmuxServer: String,
        status: WorktreeStatus = .active,
        parentWorktreeID: UUID? = nil
    ) async throws -> Worktree {
        try await writer.write { db in
            let maxOrder: Int
            if let pid = parentWorktreeID {
                maxOrder = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(sortOrder) FROM worktree WHERE parentWorktreeID = ?",
                    arguments: [pid.uuidString]
                ) ?? 0
            } else {
                maxOrder = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(sortOrder) FROM worktree WHERE repoID = ? AND parentWorktreeID IS NULL",
                    arguments: [repoID.uuidString]
                ) ?? 0
            }
            let wt = Worktree(
                repoID: repoID,
                name: name,
                displayName: displayName ?? name,
                branch: branch,
                path: path,
                status: status,
                tmuxServer: tmuxServer,
                sortOrder: maxOrder + 1,
                parentWorktreeID: parentWorktreeID
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

    /// NULL out any `parentWorktreeID` that references a row no longer in the
    /// table (e.g. the parent was deleted out-of-band by a manual sqlite edit
    /// or a future regression). Safe to call on every reconcile — a single
    /// `UPDATE … NOT IN (SELECT id FROM worktree)`.
    public func nullOrphanedParents() async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE worktree
                SET parentWorktreeID = NULL
                WHERE parentWorktreeID IS NOT NULL
                  AND parentWorktreeID NOT IN (SELECT id FROM worktree)
            """)
        }
    }

    /// Walk every row with a non-null `parentWorktreeID` and break any cycles
    /// found (A.parent=B, B.parent=A) by NULLing the parent on the row we
    /// started from. `WorktreeStore.move()`'s cycle guard prevents new cycles
    /// through normal operations, so this only catches DB damage from manual
    /// sqlite edits or regressions — call it at daemon startup, NOT on every
    /// reconcile. (Reconcile fires from cleanup RPCs and periodic git sweeps;
    /// running this O(N) walk every time is wasted work for the common case
    /// of a healthy DB.)
    public func breakCyclicParents() async throws {
        try await writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, parentWorktreeID FROM worktree
                WHERE parentWorktreeID IS NOT NULL
            """)
            for row in rows {
                guard let rowID = row["id"] as String? else { continue }
                var cursor: String? = row["parentWorktreeID"] as String?
                var visited: Set<String> = [rowID]
                while let curID = cursor {
                    if !visited.insert(curID).inserted {
                        try db.execute(
                            sql: "UPDATE worktree SET parentWorktreeID = NULL WHERE id = ?",
                            arguments: [rowID]
                        )
                        break
                    }
                    cursor = try Row.fetchOne(
                        db,
                        sql: "SELECT parentWorktreeID FROM worktree WHERE id = ?",
                        arguments: [curID]
                    )?["parentWorktreeID"] as String?
                }
            }
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

    /// Throws `WorktreeArchiveError.hasActiveChildren` if the worktree has any
    /// direct children with status `.active` or `.creating`. Used as a precheck
    /// by the archive RPC handler so app and CLI surface the same error.
    public func assertArchivable(id: UUID) async throws {
        try await writer.read { db in
            let activeRaw = WorktreeStatus.active.rawValue
            let creatingRaw = WorktreeStatus.creating.rawValue
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM worktree
                WHERE parentWorktreeID = ?
                  AND status IN (?, ?)
                """,
                arguments: [id.uuidString, activeRaw, creatingRaw]
            ) ?? 0
            if count > 0 {
                throw WorktreeArchiveError.hasActiveChildren
            }
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

    /// Move a worktree to a new parent (or top-level) and a new sort-order
    /// position within its destination sibling group.
    /// Validates: not-self, parent exists, parent is not `main`, no cycle.
    /// Renumbers siblings in the destination group so the moved row lands at
    /// the requested sortOrder.
    public func move(worktreeID: UUID, newParentID: UUID?, newSortOrder: Int) async throws {
        try await writer.write { db in
            guard let movingRecord = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString) else {
                throw WorktreeMoveError.worktreeNotFound
            }

            if let pid = newParentID {
                if pid == worktreeID {
                    throw WorktreeMoveError.selfReference
                }
                guard let parent = try WorktreeRecord.fetchOne(db, key: pid.uuidString) else {
                    throw WorktreeMoveError.parentNotFound
                }
                if parent.status == WorktreeStatus.main.rawValue {
                    throw WorktreeMoveError.parentIsMain
                }
                // Cycle check: walk up from parent; if we ever hit `worktreeID`, cycle.
                // The `visited` set defends against a pre-existing cycle in the DB
                // (manual edit or future regression) by treating any revisit as a
                // cycle too — otherwise the loop would spin forever inside the
                // write transaction and block the database.
                var cursor: String? = parent.parentWorktreeID
                var visited: Set<String> = [pid.uuidString]
                while let curID = cursor {
                    if curID == worktreeID.uuidString {
                        throw WorktreeMoveError.cycle
                    }
                    if !visited.insert(curID).inserted {
                        throw WorktreeMoveError.cycle
                    }
                    cursor = try WorktreeRecord.fetchOne(db, key: curID)?.parentWorktreeID
                }
            }

            // Renumber destination siblings: shift sortOrder of siblings >= newSortOrder by +1,
            // then set moving to newSortOrder.
            let parentArg = newParentID?.uuidString
            if let p = parentArg {
                try db.execute(
                    sql: "UPDATE worktree SET sortOrder = sortOrder + 1 WHERE parentWorktreeID = ? AND sortOrder >= ? AND id != ?",
                    arguments: [p, newSortOrder, worktreeID.uuidString]
                )
            } else {
                // Top-level siblings = same repo, parent null, NOT main. The UI
                // renders main via a status-filtered path (so an updated sortOrder
                // on a main row is invisible), but excluding it here keeps the
                // sibling group consistent with how the UI orders top-level rows.
                try db.execute(
                    sql: "UPDATE worktree SET sortOrder = sortOrder + 1 WHERE repoID = ? AND parentWorktreeID IS NULL AND status != 'main' AND sortOrder >= ? AND id != ?",
                    arguments: [movingRecord.repoID, newSortOrder, worktreeID.uuidString]
                )
            }

            try db.execute(
                sql: "UPDATE worktree SET parentWorktreeID = ?, sortOrder = ? WHERE id = ?",
                arguments: [parentArg, newSortOrder, worktreeID.uuidString]
            )
        }
    }

    /// Reorder worktrees within a repo. The worktreeIDs array defines the new order.
    /// Only affects worktrees in the provided list (typically top-level). Any other
    /// top-level worktrees not in the list are pushed to sortOrder values after the
    /// reordered ones. Nested children (parentWorktreeID IS NOT NULL) are left alone
    /// — their sortOrder is scoped to their parent group.
    public func reorder(repoID: UUID, worktreeIDs: [UUID]) async throws {
        try await writer.write { db in
            for (index, wtID) in worktreeIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE worktree SET sortOrder = ? WHERE id = ? AND repoID = ?",
                    arguments: [index, wtID.uuidString, repoID.uuidString]
                )
            }
            // Push any TOP-LEVEL worktrees not in the provided list to after the
            // reordered ones. Children are scoped per parent and untouched.
            let idStrings = worktreeIDs.map(\.uuidString)
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")
            let args: [any DatabaseValueConvertible] = [worktreeIDs.count, repoID.uuidString] + idStrings
            try db.execute(
                sql: """
                    UPDATE worktree SET sortOrder = ? + rowid
                    WHERE repoID = ?
                      AND status IN ('active', 'creating')
                      AND parentWorktreeID IS NULL
                      AND id NOT IN (\(placeholders))
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

    /// Read the `tabOrder` JSON column for a worktree, decoded into UUIDs.
    /// Returns an empty array if the worktree has no stored order yet.
    public func getTabOrder(worktreeID: UUID) async throws -> [UUID] {
        try await writer.read { db in
            guard let record = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString) else {
                return []
            }
            return Self.decodeTabOrder(record.tabOrder)
        }
    }

    /// Replace the `tabOrder` JSON column for a worktree.
    public func setTabOrder(worktreeID: UUID, tabIDs: [UUID]) async throws {
        let json = Self.encodeTabOrder(tabIDs)
        _ = try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET tabOrder = ? WHERE id = ?",
                arguments: [json, worktreeID.uuidString]
            )
        }
    }

    /// Read the `activeTabID` column for a worktree. Returns nil for missing
    /// worktrees, NULL columns, or strings that don't decode as a UUID.
    public func getActiveTabID(worktreeID: UUID) async throws -> UUID? {
        try await writer.read { db in
            guard let record = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString),
                  let raw = record.activeTabID else {
                return nil
            }
            return UUID(uuidString: raw)
        }
    }

    /// Set or clear (`nil`) the persisted active tab UUID for a worktree.
    public func setActiveTabID(worktreeID: UUID, tabID: UUID?) async throws {
        _ = try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET activeTabID = ? WHERE id = ?",
                arguments: [tabID?.uuidString, worktreeID.uuidString]
            )
        }
    }

    private static func decodeTabOrder(_ json: String) -> [UUID] {
        guard let data = json.data(using: .utf8) else { return [] }
        guard let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap(UUID.init(uuidString:))
    }

    private static func encodeTabOrder(_ ids: [UUID]) -> String {
        let strings = ids.map(\.uuidString)
        guard let data = try? JSONEncoder().encode(strings),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}
