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
    var title: String?
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
        self.title = binding.title
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
                         headBranch: headBranch, baseRef: baseRef, title: title,
                         status: status,
                         source: bindingSource, detached: detached, boundAt: boundAt)
    }
}

/// The whole binding table, partitioned by worktree — what `listAllByWorktree`
/// returns and what `pr.bindingsAll` reports.
public struct AllWorktreeBindings: Sendable {
    /// Live bindings per worktree, in bind order. A worktree with none is
    /// absent rather than mapped to an empty array.
    public let live: [UUID: [PRBinding]]
    /// Tombstoned bindings per worktree, for the worktrees that have any.
    public let detachedCounts: [UUID: Int]

    public init(live: [UUID: [PRBinding]], detachedCounts: [UUID: Int]) {
        self.live = live
        self.detachedCounts = detachedCounts
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

    /// Every worktree's live bindings and tombstone count, from ONE read.
    ///
    /// One query rather than a live pass and a tombstone pass, for the same
    /// reason `handlePRBindings` partitions in Swift: two SELECTs racing a
    /// concurrent detach can disagree, and a live list that has lost a row while
    /// the count has not yet gained it reads to the app as "nothing bound and
    /// nothing detached" — which is exactly when the legacy-status fallback
    /// resurrects a PR the user just removed.
    ///
    /// Live bindings come back in bind order (`boundAt`, then `rowid`), the
    /// order every PR surface renders, so a row does not move under the cursor
    /// as CI states change. A worktree with neither a live binding nor a
    /// tombstone is absent from both maps.
    public func listAllByWorktree() async throws -> AllWorktreeBindings {
        let rows = try await writer.read { db in
            try PRBindingRecord
                .order(Column("boundAt").asc, Column("rowid").asc)
                .fetchAll(db)
        }
        var live: [UUID: [PRBinding]] = [:]
        var detachedCounts: [UUID: Int] = [:]
        for row in rows {
            guard let binding = row.toModel() else { continue }
            if binding.detached {
                detachedCounts[binding.worktreeID, default: 0] += 1
            } else {
                live[binding.worktreeID, default: []].append(binding)
            }
        }
        return AllWorktreeBindings(live: live, detachedCounts: detachedCounts)
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

    /// Tombstone a PR whether or not this worktree has a row for it: mark the
    /// existing row detached, or insert the tombstone when there is none.
    ///
    /// The insert arm is what lets a detach assert "this does not belong here"
    /// about a PR nothing ever bound — a chip synthesized from the cached
    /// `Worktree.prStatus`, or a `tbd pr detach` issued before discovery got
    /// there.
    ///
    /// **One write transaction covers both arms**, and that is the point of
    /// having a single method rather than a `setDetached` call followed by an
    /// insert-on-miss. Split across two transactions, a concurrent bind — the
    /// poll's branch matcher or a hook's `pr attach`, both of which run while
    /// the user is clicking — can insert a live row in the gap; the insert then
    /// finds an identity already on record, declines, and the untrack silently
    /// does nothing, which is the exact failure this gesture exists to remove.
    ///
    /// Returns whether the record **changed**: true when a live row was
    /// tombstoned or a tombstone was inserted, false when the PR was already
    /// tombstoned. An existing row keeps its own `source` and `boundAt` — only
    /// a tombstone with no prior row records nothing but the caller's decision.
    ///
    /// Deliberately NOT routed through `upsert`. The cap counts only
    /// non-detached rows, so a tombstone can never breach it, but `upsert`
    /// checks that count before writing anything and would evict a live
    /// terminal binding — or drop the write entirely — to make room for a row
    /// that occupies none of the budget.
    @discardableResult
    public func tombstone(_ binding: PRBinding) async throws -> Bool {
        try await writer.write { db in
            var record = PRBindingRecord(from: binding)
            record.detached = true
            if let existing = try Self.fetchIdentity(db, record: record) {
                guard !existing.detached else { return false }
                try PRBindingRecord
                    .filter(key: existing.id)
                    .updateAll(db, Column("detached").set(to: true))
                return true
            }
            try record.insert(db)
            return true
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
    /// descriptive `headBranch` / `baseRef` / `title` the same response carried.
    /// A nil one of those means "not observed this pass" and leaves that column
    /// alone — a `gh` outage must not blank a branch name the CLI renders or a
    /// title the status bar has on screen.
    public func updateObservation(bindingID: UUID, status: PRStatus?,
                                  headBranch: String? = nil,
                                  baseRef: String? = nil,
                                  title: String? = nil) async throws {
        let encoded = status.flatMap { value in
            (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        // Built inside the write block: `ColumnAssignment` is not `Sendable`,
        // so it cannot cross into the closure.
        _ = try await writer.write { db in
            var assignments: [ColumnAssignment] = [Column("prStatus").set(to: encoded)]
            if let headBranch { assignments.append(Column("headBranch").set(to: headBranch)) }
            if let baseRef { assignments.append(Column("baseRef").set(to: baseRef)) }
            if let title { assignments.append(Column("title").set(to: title)) }
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
