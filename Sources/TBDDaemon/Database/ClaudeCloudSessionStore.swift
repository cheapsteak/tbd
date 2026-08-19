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

    /// Whether a caller may spawn `claude --cloud` under an idempotency key.
    public enum SpawnClaim: Sendable {
        /// This caller owns the spawn; the row is `pending`.
        case claimed(ClaudeCloudSessionRow)
        /// Another attempt under this key holds the claim.
        case inFlight
        /// A session is already on file — answer from it rather than spawning.
        case resolved(ClaudeCloudSessionRow)
    }

    /// Claims an idempotency key for a spawn, deciding and recording in ONE
    /// write.
    ///
    /// A read followed by `upsertPending` could not be made safe however
    /// carefully it was written, because `upsertPending` returns an existing
    /// row UNCHANGED: a `failed` row stayed `failed` across the spawn, so two
    /// replays arriving after the pending window gave up both read `failed`,
    /// both fell through, and both spawned. With no discovery to reconcile
    /// two live cloud sessions against one ledger row, that orphans one of
    /// them permanently — and whichever `resolve` lands second overwrites the
    /// first session id, erasing the only record of it.
    ///
    /// GRDB admits a single writer, so a concurrent caller waits and then
    /// observes whatever state this one left. Reclaiming a row additionally
    /// moves it back to `pending` with a compare-and-set and claims only when
    /// that UPDATE actually changed a row. The transition is both the claim
    /// and the truth: an attempt is in flight again, so the pending window
    /// governs it again — which is why the reclaim UPDATE also rewrites
    /// `createdAt` to this call's `now`, not just `state`. `createdAt` carries
    /// two meanings that stay consistent under that rewrite: it is the clock
    /// `list`'s pending-failure window measures, and it is the session's
    /// creation time in the `list` payload. A reclaimed row that goes on to
    /// resolve did have its session created by THIS attempt, so both readings
    /// stay true. Leaving the old `createdAt` in place — writing only `state`
    /// — would make a row reclaimed the instant before a `list` poll read as
    /// already past the window under the ORIGINAL attempt's age, so the very
    /// next sweep marks it `failed` again while the reclaiming caller's spawn
    /// is still in flight, and a third replay reclaims and spawns a second
    /// time: the double-spawn hazard this method exists to close. The cost is
    /// that a reclaimed row no longer records when the original attempt ran —
    /// acceptable because nothing reads that: `list()` projects only
    /// `resolved` rows, and the row is retained under the new timestamp
    /// either way.
    public func claimForSpawn(
        idempotencyKey: String, repoKey: String, repoPath: String,
        branch: String?, environment: String?, paramsJSON: String, now: Date
    ) async throws -> SpawnClaim {
        try await writer.write { db in
            if let existing = try ClaudeCloudSessionRow
                .filter(Column("idempotencyKey") == idempotencyKey).fetchOne(db) {
                // The state this row must still be in for the claim to be
                // this caller's. Nil means no claim is available at all.
                let reclaimable: String?
                switch ClaudeCloudLedgerState(rawValue: existing.state) {
                case .resolved:
                    // A resolved row with no session id names nothing, so it
                    // is reclaimable rather than an answer. `resolve` always
                    // writes one, so this is a can't-happen guarded anyway.
                    guard existing.sessionID == nil else { return .resolved(existing) }
                    reclaimable = ClaudeCloudLedgerState.resolved.rawValue
                case .failed:
                    // A failed row can still carry a session id: `resolve`
                    // can land in the gap between `list()`'s read of a
                    // pending row and its separate `markFailed` write, and a
                    // row caught in exactly that gap must not be reclaimed
                    // and re-spawned — it already names a real session, and
                    // reclaiming it would overwrite that session's id on the
                    // next `resolve`. Answer from the recorded session
                    // instead, exactly like a resolved row with a session id.
                    guard existing.sessionID == nil else { return .resolved(existing) }
                    reclaimable = ClaudeCloudLedgerState.failed.rawValue
                case .pending:
                    reclaimable = nil
                case nil:
                    // An unrecognized state is not a licence to start a second
                    // cloud session; refuse rather than guess.
                    reclaimable = nil
                }
                guard let expected = reclaimable else { return .inFlight }
                try db.execute(
                    sql: """
                    UPDATE claude_cloud_session SET state = ?, createdAt = ?
                    WHERE id = ? AND state = ?
                    """,
                    arguments: [
                        ClaudeCloudLedgerState.pending.rawValue, now, existing.id, expected,
                    ])
                guard db.changesCount == 1 else { return .inFlight }
                var claimed = existing
                claimed.state = ClaudeCloudLedgerState.pending.rawValue
                claimed.createdAt = now
                return .claimed(claimed)
            }
            let row = ClaudeCloudSessionRow(
                id: UUID().uuidString, idempotencyKey: idempotencyKey,
                state: ClaudeCloudLedgerState.pending.rawValue, sessionID: nil, title: nil,
                createdAt: now, resolvedAt: nil, repoKey: repoKey, repoPath: repoPath,
                branch: branch, environment: environment, paramsJSON: paramsJSON,
                archived: false)
            try row.insert(db)
            return .claimed(row)
        }
    }

    /// A create whose output named a session. The provenance link is written
    /// here and nowhere else. `title` is the vendor's parsed summary, or nil
    /// when the title parse found nothing — a cosmetic loss that must never
    /// fail a create that otherwise succeeded. A retry that resolves the same
    /// `id` twice, or names an `id` this store has never seen, is a harmless
    /// no-op: there is nothing to double-apply and nothing to update.
    ///
    /// Compare-and-set on `sessionID`, deliberately **not** on `state`. The
    /// two invariants that matter here are narrower than "the row is still
    /// pending": a session id must never be lost, and it must never be
    /// overwritten by a *different* one. `WHERE id = ? AND (sessionID IS NULL
    /// OR sessionID = ?)` enforces exactly those two and nothing more:
    ///
    /// - a `pending` row (`sessionID` NULL) resolves normally;
    /// - a row that reached `failed` while its spawn was still in flight —
    ///   `markFailed`'s own doc comment describes the gap that produces this
    ///   — still had no session id recorded, so it still resolves rather than
    ///   orphaning the session that was actually created;
    /// - a same-id retry is the harmless idempotent no-op already promised
    ///   above;
    /// - a row already naming a **different** session refuses. That case
    ///   means two sessions exist under one ledger row, which this store has
    ///   no way to reconcile on its own, so it is logged loudly rather than
    ///   silently dropped or silently overwritten.
    ///
    /// A `state = 'pending'` predicate — the shape `claimForSpawn` and
    /// `markFailed` use — was considered and rejected: it would make this
    /// call silently DROP the write whenever the row is not `pending`,
    /// including the `failed`-with-no-id case above, and losing a real
    /// session's id is the exact harm this ledger exists to prevent. A guard
    /// that causes that harm is worse than no guard at all.
    public func resolve(id: String, sessionID: String, title: String?, now: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                UPDATE claude_cloud_session
                SET state = ?, sessionID = ?, title = ?, resolvedAt = ?
                WHERE id = ? AND (sessionID IS NULL OR sessionID = ?)
                """,
                arguments: [
                    ClaudeCloudLedgerState.resolved.rawValue, sessionID, title, now, id, sessionID,
                ])
            guard db.changesCount == 1 else {
                // Either the id does not exist (the documented no-op above) or
                // it exists but already names a DIFFERENT session — the only
                // other way this UPDATE can affect zero rows. Only the latter
                // is worth a human's attention, so check which one this was.
                if let existing = try ClaudeCloudSessionRow
                    .filter(Column("id") == id).fetchOne(db),
                    let existingSessionID = existing.sessionID, existingSessionID != sessionID {
                    claudeCloudLogger.error(
                        """
                        claude-cloud resolve refused: row \(id, privacy: .public) already names \
                        session \(existingSessionID, privacy: .public); refusing to overwrite with \
                        \(sessionID, privacy: .public) — two sessions now exist under one ledger row
                        """)
                }
                return
            }
        }
    }

    /// A pending create that produced no readable session id inside the
    /// failure window. The row stops asking to be treated as in-flight and is
    /// RETAINED rather than deleted, so a create that may well have started a
    /// real session TBD cannot name stays visible as an unresolved create.
    /// `ids` is a batch: an empty batch is a no-op rather than an `IN ()`
    /// clause GRDB would otherwise turn into a query matching nothing (safe)
    /// or, via a hand-rolled `IN ()`, a query matching everything (not safe) —
    /// so the empty case is refused explicitly rather than trusted to SQL.
    ///
    /// Compare-and-set on `state = pending`: `ids` was computed from a read
    /// taken in a SEPARATE transaction (`list()`'s snapshot), so by the time
    /// this write runs, a row in that batch may already have resolved — a
    /// `create` that finally read its session id in the gap between the read
    /// and this write. Without the predicate this UPDATE would stamp that
    /// row back to `failed`, destroying its `sessionID` even though `list()`
    /// only projects `resolved` rows: the session would vanish from every
    /// future `list` with no discovery to recover it, and `claimForSpawn`
    /// would go on to reclaim the row and spawn a second real cloud session
    /// under the same key. The predicate makes a row that resolved in the
    /// gap skipped rather than clobbered — this is a no-op for it, not an
    /// error, because the batch was already known to be a stale snapshot.
    public func markFailed(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { db in
            try ClaudeCloudSessionRow
                .filter(ids.contains(Column("id")))
                .filter(Column("state") == ClaudeCloudLedgerState.pending.rawValue)
                .updateAll(db, Column("state").set(to: ClaudeCloudLedgerState.failed.rawValue))
        }
    }
}
