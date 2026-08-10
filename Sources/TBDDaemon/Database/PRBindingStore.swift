import Foundation
import GRDB
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "prBinding")

/// GRDB Record type for the `worktree_pull_request` table.
struct PRBindingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "worktree_pull_request"

    var id: String
    var worktreeID: String
    var host: String
    var owner: String
    var repo: String
    var number: Int
    var url: String
    var headBranch: String?
    var baseRef: String?
    var prStatus: String?
    var source: String
    var detached: Bool
    var boundAt: Date

    init(from binding: PRBinding) {
        self.id = binding.id.uuidString
        self.worktreeID = binding.worktreeID.uuidString
        self.host = binding.host.lowercased()
        self.owner = binding.owner.lowercased()
        self.repo = binding.repo.lowercased()
        self.number = binding.number
        self.url = binding.url
        self.headBranch = binding.headBranch
        self.baseRef = binding.baseRef
        self.prStatus = binding.status.flatMap { status in
            (try? JSONEncoder().encode(status)).flatMap { String(data: $0, encoding: .utf8) }
        }
        self.source = binding.source.rawValue
        self.detached = binding.detached
        self.boundAt = binding.boundAt
    }

    /// Failable decode: skip a malformed row after a logged warning rather than
    /// crashing the daemon on one bad record.
    func toModel() -> PRBinding? {
        guard let uuid = UUID(uuidString: id) else {
            logger.warning("Skipping worktree_pull_request row \(id, privacy: .public): malformed id")
            return nil
        }
        guard let wtID = UUID(uuidString: worktreeID) else {
            logger.warning("Skipping worktree_pull_request row \(id, privacy: .public): malformed worktreeID \(worktreeID, privacy: .public)")
            return nil
        }
        guard let bindingSource = PRBindingSource(rawValue: source) else {
            logger.warning("Skipping worktree_pull_request row \(id, privacy: .public): unknown source \(source, privacy: .public)")
            return nil
        }
        let status = prStatus
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(PRStatus.self, from: $0) }
        return PRBinding(id: uuid, worktreeID: wtID, host: host, owner: owner,
                         repo: repo, number: number, url: url,
                         headBranch: headBranch, baseRef: baseRef, status: status,
                         source: bindingSource, detached: detached, boundAt: boundAt)
    }
}

/// Persistence for PR bindings. Enforces first-source-wins deduplication,
/// tombstone semantics, and the per-worktree cap.
public struct PRBindingStore: Sendable {
    /// Bounds the per-poll GraphQL cost of a long-lived worktree. A worktree
    /// that has genuinely opened twenty live PRs is already pathological; the
    /// cap keeps one runaway session from unbounded polling.
    static let maxBindingsPerWorktree = 20

    let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert a binding, or return the existing row unchanged if this PR is
    /// already bound (first source wins). Returns nil when the cap is full and
    /// nothing is evictable.
    ///
    /// A tombstoned row is returned as-is — still detached. Reviving it is
    /// policy, not persistence, and belongs to the caller (`setDetached`).
    @discardableResult
    public func upsert(_ binding: PRBinding) async throws -> PRBinding? {
        try await writer.write { db in
            let record = PRBindingRecord(from: binding)
            if let existing = try Self.fetchIdentity(db, record: record) {
                return existing.toModel()   // already bound (possibly tombstoned)
            }
            let liveCount = try PRBindingRecord
                .filter(Column("worktreeID") == record.worktreeID)
                .filter(Column("detached") == false)
                .fetchCount(db)
            if liveCount >= Self.maxBindingsPerWorktree {
                guard let evictable = try Self.oldestTerminal(db, worktreeID: record.worktreeID) else {
                    logger.warning("dropping PR #\(record.number, privacy: .public) for worktree \(record.worktreeID, privacy: .public): binding cap reached and no terminal binding to evict")
                    return nil
                }
                try PRBindingRecord.filter(key: evictable.id).deleteAll(db)
            }
            try record.insert(db)
            // Re-read rather than returning `record.toModel()`: SQLite stores
            // dates at millisecond precision, so the caller's `boundAt` would
            // otherwise not equal what a later `list` returns.
            return try Self.fetchIdentity(db, record: record)?.toModel()
        }
    }

    public func list(worktreeID: UUID, includeDetached: Bool = false) async throws -> [PRBinding] {
        try await writer.read { db in
            var request = PRBindingRecord.filter(Column("worktreeID") == worktreeID.uuidString)
            if !includeDetached { request = request.filter(Column("detached") == false) }
            return try request
                .order(Column("boundAt").asc, Column("rowid").asc)
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }

    /// Every live binding across all worktrees — the poll's input set.
    public func listAll() async throws -> [PRBinding] {
        try await writer.read { db in
            try PRBindingRecord
                .filter(Column("detached") == false)
                .order(Column("boundAt").asc, Column("rowid").asc)
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }

    /// Set or clear a tombstone. Returns false when no such binding exists.
    @discardableResult
    public func setDetached(worktreeID: UUID, identityKey: String,
                            detached: Bool) async throws -> Bool {
        let parts = identityKey.split(separator: "\u{1}", omittingEmptySubsequences: false)
        guard parts.count == 4, let number = Int(parts[3]) else { return false }
        return try await writer.write { db in
            let updated = try PRBindingRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .filter(Column("host") == String(parts[0]).lowercased())
                .filter(Column("owner") == String(parts[1]).lowercased())
                .filter(Column("repo") == String(parts[2]).lowercased())
                .filter(Column("number") == number)
                .updateAll(db, Column("detached").set(to: detached))
            return updated > 0
        }
    }

    public func updateStatus(bindingID: UUID, status: PRStatus?) async throws {
        let encoded = status.flatMap { value in
            (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        _ = try await writer.write { db in
            try PRBindingRecord
                .filter(key: bindingID.uuidString)
                .updateAll(db, Column("prStatus").set(to: encoded))
        }
    }

    // MARK: - Helpers

    private static func fetchIdentity(_ db: GRDB.Database,
                                      record: PRBindingRecord) throws -> PRBindingRecord? {
        try PRBindingRecord
            .filter(Column("worktreeID") == record.worktreeID)
            .filter(Column("host") == record.host)
            .filter(Column("owner") == record.owner)
            .filter(Column("repo") == record.repo)
            .filter(Column("number") == record.number)
            .fetchOne(db)
    }

    /// The oldest binding in a terminal state — the eviction candidate when the
    /// cap is reached. A live PR is never evicted.
    private static func oldestTerminal(_ db: GRDB.Database,
                                       worktreeID: String) throws -> PRBindingRecord? {
        try PRBindingRecord
            .filter(Column("worktreeID") == worktreeID)
            .filter(Column("detached") == false)
            .order(Column("boundAt").asc, Column("rowid").asc)
            .fetchAll(db)
            .first { $0.toModel()?.status?.state.isTerminal == true }
    }
}
