import Foundation
import GRDB

/// What a create in the cloud ledger currently knows about itself.
///
/// `pending` — the idempotency key was written and the invocation may or may
/// not have produced a session. `resolved` — a session id was read out of
/// `create`'s output and is on file. `failed` — the create did not produce a
/// readable id within the failure window, so the row stops claiming a session
/// while being RETAINED: the record of a create that may have started a real
/// session must outlive the judgement that it did not.
public enum ClaudeCloudLedgerState: String, Codable, Sendable {
    case pending, resolved, failed
}

/// GRDB row for `claude_cloud_session`: **what this machine started.**
///
/// Distinct from the `remote_session` mirror, which is what the manager last
/// observed. Daemon-internal — it never crosses the RPC wire, so it has no
/// `TBDShared` Codable model, exactly like `watch_desk_judge_lease`.
///
/// This ledger is the whole of the `claude-cloud` provider's inventory: no
/// supported interface enumerates an account's cloud sessions, so `list`
/// answers from these rows alone and is permanently `complete: false`.
public struct ClaudeCloudSessionRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "claude_cloud_session"
    public var id: String
    public var idempotencyKey: String
    public var state: String
    /// Null until a create's output was read. A row with no session id is
    /// never listed — there is no session to name.
    public var sessionID: String?
    /// The vendor's own server-derived summary of the opening instruction,
    /// parsed off `create`'s first line. Null when that parse found nothing,
    /// in which case the lane is named from its id instead. NEVER the
    /// submitted prompt: a cloud session's name comes from the vendor.
    public var title: String?
    public var createdAt: Date
    public var resolvedAt: Date?
    /// The value the row contributes as `meta["repo"]`, so a ledger-only
    /// session still resolves to its registered repository and gets adopted.
    public var repoKey: String
    /// The local checkout `create` runs from.
    public var repoPath: String
    public var branch: String?
    public var environment: String?
    public var paramsJSON: String
    /// The filing axis, orthogonal to liveness. Written by the provider's
    /// `archive`/`unarchive` verbs and reported on every later `list`, because
    /// the contract requires archived sessions to stay enumerated — a session
    /// filtered out of successive snapshots is indistinguishable from a
    /// deleted one.
    public var archived: Bool
}

public struct ClaudeCloudSessionStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) { self.writer = writer }

    public func rows() async throws -> [ClaudeCloudSessionRow] {
        try await writer.read { db in
            try ClaudeCloudSessionRow.order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Writes the idempotency key and its state BEFORE the invocation, so a
    /// create whose output could not be read leaves a `pending` row rather
    /// than nothing — carrying the repository, the branch and the prompt that
    /// were submitted. Idempotent on the key: the daemon's single same-key
    /// retry finds the row it already wrote and keeps its original timestamp.
    @discardableResult
    public func upsertPending(
        idempotencyKey: String, repoKey: String, repoPath: String,
        branch: String?, environment: String?, paramsJSON: String, now: Date
    ) async throws -> ClaudeCloudSessionRow {
        try await writer.write { db in
            if let existing = try ClaudeCloudSessionRow
                .filter(Column("idempotencyKey") == idempotencyKey).fetchOne(db) {
                return existing
            }
            let row = ClaudeCloudSessionRow(
                id: UUID().uuidString, idempotencyKey: idempotencyKey,
                state: ClaudeCloudLedgerState.pending.rawValue, sessionID: nil, title: nil,
                createdAt: now, resolvedAt: nil, repoKey: repoKey, repoPath: repoPath,
                branch: branch, environment: environment, paramsJSON: paramsJSON,
                archived: false)
            try row.insert(db)
            return row
        }
    }
}
