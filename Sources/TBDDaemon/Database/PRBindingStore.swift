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

    /// Set or clear a tombstone. Returns true only when a row's state actually
    /// **changed** — false both when no such binding exists and when it was
    /// already in the requested state.
    ///
    /// `updateAll` counts MATCHED rows, not modified ones, so the natural
    /// `updated > 0` reported success for a no-op and `tbd pr detach` on an
    /// already-detached PR printed "Detached." The predicate carries the
    /// current-state check instead, which makes the count mean what the caller
    /// reads it as.
    @discardableResult
    public func setDetached(worktreeID: UUID, identityKey: String,
                            detached: Bool) async throws -> Bool {
        guard let identity = Self.identity(from: identityKey) else { return false }
        return try await writer.write { db in
            let updated = try Self.matching(worktreeID: worktreeID, identity: identity)
                .filter(Column("detached") == !detached)
                .updateAll(db, Column("detached").set(to: detached))
            return updated > 0
        }
    }

    /// Hard-delete a `branch`-sourced binding — the poll's heal path.
    ///
    /// A **delete, not a tombstone**, and only for `branch`. A tombstone records
    /// a user's decision and nothing but an explicit `tbd pr attach` clears it;
    /// a heal is an inference from branch facts that can themselves be wrong (a
    /// stale `repo.defaultBranch`, a momentarily narrower candidate list, a
    /// remote pointed away and back). Tombstoning a wrong heal would block the
    /// correct binding forever, silently and with no user gesture behind it,
    /// while deleting costs at most one poll — if the mis-attachment is still
    /// real the next heal removes it again, and if it was not, the branch
    /// matcher re-binds. Durability is also not needed here the way it is for a
    /// detach: a detach must survive re-discovery, but a heal *is* re-discovery
    /// and re-derives its verdict every pass.
    ///
    /// Returns true when a row went.
    @discardableResult
    public func deleteBranchBinding(worktreeID: UUID, identityKey: String) async throws -> Bool {
        guard let identity = Self.identity(from: identityKey) else { return false }
        return try await writer.write { db in
            try Self.matching(worktreeID: worktreeID, identity: identity)
                .filter(Column("source") == PRBindingSource.branch.rawValue)
                .deleteAll(db) > 0
        }
    }

    /// Persist what a refresh observed for one binding: its status, and the
    /// descriptive `headBranch` / `baseRef` the same response carried. A nil ref
    /// means "not observed this pass" and leaves that column alone — a `gh`
    /// outage must not blank a branch name the CLI renders.
    public func updateObservation(bindingID: UUID, status: PRStatus?,
                                  headBranch: String? = nil,
                                  baseRef: String? = nil) async throws {
        let encoded = status.flatMap { value in
            (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        // Built inside the write block: `ColumnAssignment` is not `Sendable`,
        // so it cannot cross into the closure.
        _ = try await writer.write { db in
            var assignments: [ColumnAssignment] = [Column("prStatus").set(to: encoded)]
            if let headBranch { assignments.append(Column("headBranch").set(to: headBranch)) }
            if let baseRef { assignments.append(Column("baseRef").set(to: baseRef)) }
            return try PRBindingRecord
                .filter(key: bindingID.uuidString)
                .updateAll(db, assignments)
        }
    }

    // MARK: - Helpers

    /// Split a `PRBinding.identityKey` back into its four parts. Returns nil for
    /// anything that isn't one, so a malformed key is a no-op rather than a
    /// query matching everything.
    private static func identity(
        from identityKey: String
    ) -> (host: String, owner: String, repo: String, number: Int)? {
        let parts = identityKey.split(separator: "\u{1}", omittingEmptySubsequences: false)
        guard parts.count == 4, let number = Int(parts[3]) else { return nil }
        return (String(parts[0]).lowercased(), String(parts[1]).lowercased(),
                String(parts[2]).lowercased(), number)
    }

    /// The rows one worktree's binding identity names — at most one, by the
    /// table's UNIQUE constraint.
    private static func matching(
        worktreeID: UUID,
        identity: (host: String, owner: String, repo: String, number: Int)
    ) -> QueryInterfaceRequest<PRBindingRecord> {
        PRBindingRecord
            .filter(Column("worktreeID") == worktreeID.uuidString)
            .filter(Column("host") == identity.host)
            .filter(Column("owner") == identity.owner)
            .filter(Column("repo") == identity.repo)
            .filter(Column("number") == identity.number)
    }

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
