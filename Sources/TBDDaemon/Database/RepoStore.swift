import Foundation
import GRDB
import TBDShared

/// GRDB Record type for the `repo` table.
struct RepoRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "repo"

    var id: String
    var path: String
    var remoteURL: String?
    var displayName: String
    var defaultBranch: String
    var createdAt: Date
    var renamePrompt: String?
    var customInstructions: String?
    var claude_token_override_id: String?
    var worktree_slot: String?
    var worktree_root: String?
    var status: String

    init(from repo: Repo) {
        self.id = repo.id.uuidString
        self.path = repo.path
        self.remoteURL = repo.remoteURL
        self.displayName = repo.displayName
        self.defaultBranch = repo.defaultBranch
        self.createdAt = repo.createdAt
        self.renamePrompt = repo.renamePrompt
        self.customInstructions = repo.customInstructions
        self.claude_token_override_id = repo.claudeTokenOverrideID?.uuidString
        self.worktree_slot = repo.worktreeSlot
        self.worktree_root = repo.worktreeRoot
        self.status = repo.status.rawValue
    }

    func toModel() -> Repo {
        Repo(
            id: UUID(uuidString: id)!,
            path: path,
            remoteURL: remoteURL,
            displayName: displayName,
            defaultBranch: defaultBranch,
            createdAt: createdAt,
            renamePrompt: renamePrompt,
            customInstructions: customInstructions,
            claudeTokenOverrideID: claude_token_override_id.flatMap(UUID.init(uuidString:)),
            worktreeSlot: worktree_slot,
            worktreeRoot: worktree_root,
            status: RepoStatus(rawValue: status) ?? .ok
        )
    }
}

/// Provides CRUD operations for repos.
public struct RepoStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new repo and return it.
    public func create(
        path: String,
        displayName: String,
        defaultBranch: String,
        remoteURL: String? = nil
    ) async throws -> Repo {
        let slot = try await writer.write { db -> String in
            let existing = try String.fetchAll(
                db,
                sql: "SELECT worktree_slot FROM repo WHERE worktree_slot IS NOT NULL"
            )
            let assigned = Set(existing)
            var base = WorktreeLayout.sanitize(displayName)
            if base.isEmpty {
                let prefix = UUID().uuidString
                    .replacingOccurrences(of: "-", with: "")
                    .prefix(6)
                base = "repo-\(prefix)"
            }
            var slot = base
            var n = 2
            while assigned.contains(slot) {
                slot = "\(base)-\(n)"
                n += 1
            }
            return slot
        }
        var repo = Repo(
            path: path,
            remoteURL: remoteURL,
            displayName: displayName,
            defaultBranch: defaultBranch
        )
        repo.worktreeSlot = slot
        let record = RepoRecord(from: repo)
        try await writer.write { db in
            try record.insert(db)
        }
        return repo
    }

    /// List all repos, excluding the synthetic conductors pseudo-repo.
    public func list() async throws -> [Repo] {
        try await writer.read { db in
            try RepoRecord
                .filter(Column("id") != TBDConstants.conductorsRepoID.uuidString)
                .fetchAll(db)
                .map { $0.toModel() }
        }
    }

    /// Get a repo by ID.
    public func get(id: UUID) async throws -> Repo? {
        try await writer.read { db in
            try RepoRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// Remove a repo by ID.
    public func remove(id: UUID) async throws {
        _ = try await writer.write { db in
            try RepoRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// Update per-repo instruction fields.
    public func updateInstructions(id: UUID, renamePrompt: String?, customInstructions: String?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET renamePrompt = ?, customInstructions = ? WHERE id = ?",
                arguments: [renamePrompt, customInstructions, id.uuidString]
            )
        }
    }

    /// Set or clear the Claude token override for a repo.
    public func setClaudeTokenOverride(id: UUID, tokenID: UUID?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET claude_token_override_id = ? WHERE id = ?",
                arguments: [tokenID?.uuidString, id.uuidString]
            )
        }
    }

    /// Clear the Claude token override on every repo whose override matches the given token.
    public func clearClaudeTokenOverride(matching tokenID: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET claude_token_override_id = NULL WHERE claude_token_override_id = ?",
                arguments: [tokenID.uuidString]
            )
        }
    }

    /// Update a repo's health status.
    public func updateStatus(id: UUID, status: RepoStatus) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id.uuidString]
            )
        }
    }

    /// Update a repo's filesystem path. Used by `tbd repo relocate`.
    public func updatePath(id: UUID, path: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET path = ? WHERE id = ?",
                arguments: [path, id.uuidString]
            )
        }
    }

    /// Override the canonical worktree base directory for a repo. Pass `nil`
    /// to clear the override and fall back to `~/tbd/worktrees/<slot>`.
    /// Primarily used by tests to redirect a repo's worktrees into a tmp dir.
    public func updateWorktreeRoot(id: UUID, path: String?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET worktree_root = ? WHERE id = ?",
                arguments: [path, id.uuidString]
            )
        }
    }

    /// Find a repo by its filesystem path.
    public func findByPath(path: String) async throws -> Repo? {
        try await writer.read { db in
            try RepoRecord
                .filter(Column("path") == path)
                .fetchOne(db)?
                .toModel()
        }
    }
}
