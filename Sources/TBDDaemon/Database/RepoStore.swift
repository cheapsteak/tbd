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
            claudeTokenOverrideID: claude_token_override_id.flatMap(UUID.init(uuidString:))
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
        let repo = Repo(
            path: path,
            remoteURL: remoteURL,
            displayName: displayName,
            defaultBranch: defaultBranch
        )
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
