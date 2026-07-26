import Foundation
import GRDB
import TBDShared

/// GRDB row for the `remote_session` mirror table. The provider is the
/// source of truth; this table is a cache with drift bookkeeping
/// (`missingCount`/`gone` per the two-absence rule) so a flaky provider poll
/// doesn't make a session disappear from the UI on one missed snapshot.
public struct RemoteSessionRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "remote_session"
    public var provider: String
    public var sessionID: String
    public var payload: String
    public var state: String
    public var agentState: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var missingCount: Int
    public var gone: Bool
    public var dismissed: Bool
    /// Pinned repo resolution — see `RemoteSessionInfo.resolvedRepoID`'s doc
    /// comment for the full pinning contract. Stored as the UUID string
    /// (matching `RepoRecord.id`'s convention) rather than a GRDB-native UUID
    /// type.
    public var resolvedRepoID: String?

    public var decodedPayload: RemoteSessionPayload? {
        payload.data(using: .utf8).flatMap { try? JSONDecoder().decode(RemoteSessionPayload.self, from: $0) }
    }

    public var resolvedRepoIDUUID: UUID? {
        resolvedRepoID.flatMap(UUID.init(uuidString:))
    }
}

public struct SnapshotOutcome: Sendable {
    public let changed: Bool
    /// Sessions whose stored agentState differed and whose new value is
    /// waiting_input or exited — the notify-worthy edges. First sighting of a
    /// session never notifies (prevents a banner storm on daemon start).
    public let attention: [RemoteSessionPayload]
}

/// Provider-scoped mirror of `RemoteSessionPayload` rows (Task 2 wire types).
/// Task 5's daemon manager drives `applySnapshot` on each poll and turns its
/// `SnapshotOutcome` into UI deltas / notifications.
public struct RemoteSessionStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert-or-update one row given its (already-fetched) existing row, if
    /// any. Shared by `applySnapshot` (bulk, rows pre-fetched per provider)
    /// and `upsertOne` (single row, its own fetch) so the change-detection
    /// and attention-edge rules exist in exactly one place. Absence
    /// bookkeeping (missingCount/gone) is NOT this helper's job — only
    /// `applySnapshot` performs that, over whatever it did *not* see in a
    /// full snapshot.
    private func upsert(
        _ session: RemoteSessionPayload, provider: String, existing: RemoteSessionRow?,
        now: Date, encoder: JSONEncoder, db: Database
    ) throws -> (changed: Bool, attention: RemoteSessionPayload?) {
        let payloadString = String(data: try encoder.encode(session), encoding: .utf8) ?? "{}"
        if var row = existing {
            let previousAgentState = row.agentState
            var changed = row.payload != payloadString || row.missingCount != 0 || row.gone
            var attention: RemoteSessionPayload?
            if previousAgentState != session.agentState.rawValue,
               session.agentState == .waitingInput || session.agentState == .exited {
                attention = session
            }
            // Pin the repo association at first sighting: only attempt (or
            // re-attempt) resolution while the stored value is still null —
            // e.g. the repo hasn't been added to TBD yet. Once set, a
            // provider that later changes its reported `meta["repo"]` can
            // never migrate this row to a different repo section underneath
            // the user. See `RemoteSessionInfo.resolvedRepoID`'s doc comment.
            if row.resolvedRepoID == nil,
               let resolved = try self.resolveRepoID(metaRepo: session.meta?["repo"], db: db) {
                row.resolvedRepoID = resolved.uuidString
                changed = true
            }
            row.payload = payloadString
            row.state = session.state.rawValue
            row.agentState = session.agentState.rawValue
            row.lastSeen = now
            row.missingCount = 0
            row.gone = false
            try row.update(db)
            return (changed, attention)
        } else {
            // First sighting never notifies — otherwise the daemon would
            // fire a banner storm for every pre-existing session on startup.
            let resolvedRepoID = try self.resolveRepoID(metaRepo: session.meta?["repo"], db: db)
            try RemoteSessionRow(
                provider: provider, sessionID: session.id,
                payload: payloadString, state: session.state.rawValue,
                agentState: session.agentState.rawValue,
                firstSeen: now, lastSeen: now,
                missingCount: 0, gone: false, dismissed: false,
                resolvedRepoID: resolvedRepoID?.uuidString
            ).insert(db)
            return (true, nil)
        }
    }

    /// Resolves `metaRepo` against the repos currently registered in the
    /// SAME transaction `upsert` runs in — reading `repo` directly here
    /// (rather than threading a `[Repo]` snapshot in from the caller) keeps
    /// the read and the write consistent and avoids a repo query at all for
    /// the common case (an already-resolved row, or no `meta["repo"]`).
    private func resolveRepoID(metaRepo: String?, db: Database) throws -> UUID? {
        guard metaRepo != nil else { return nil }
        let repos = try RepoRecord.fetchAll(db).compactMap { $0.toModel() }
        return RemoteRepoMatching.resolveRepoID(metaRepo: metaRepo, repos: repos)
    }

    /// Reconcile one provider's full session list against the mirror table.
    /// Rows for OTHER providers are never touched — snapshots are
    /// provider-scoped, so an empty snapshot from provider B must not affect
    /// provider A's rows.
    public func applySnapshot(
        provider: String, sessions: [RemoteSessionPayload], now: Date
    ) async throws -> SnapshotOutcome {
        try await writer.write { db in
            var changed = false
            var attention: [RemoteSessionPayload] = []
            let existing = try RemoteSessionRow
                .filter(Column("provider") == provider)
                .fetchAll(db)
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.sessionID, $0) })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]   // stable payload string for change detection

            for session in sessions {
                let existingRow = byID.removeValue(forKey: session.id)
                let outcome = try self.upsert(
                    session, provider: provider, existing: existingRow,
                    now: now, encoder: encoder, db: db)
                if outcome.changed { changed = true }
                if let attentionSession = outcome.attention { attention.append(attentionSession) }
            }

            // Everything left in byID was absent from this snapshot. Two
            // consecutive absences mark a row gone (transports flake); a row
            // already gone is left alone.
            for var row in byID.values where !row.gone {
                row.missingCount += 1
                if row.missingCount >= 2 { row.gone = true }
                changed = true
                try row.update(db)
            }
            return SnapshotOutcome(changed: changed, attention: attention)
        }
    }

    /// Upsert a single session from an `events` `session` line. Same
    /// change-detection and attention-edge rules as `applySnapshot`, applied
    /// to just this one row — it never touches any other row's absence
    /// bookkeeping (only full snapshots drive the two-absence rule).
    public func upsertOne(
        provider: String, session: RemoteSessionPayload, now: Date
    ) async throws -> SnapshotOutcome {
        try await writer.write { db in
            let existing = try RemoteSessionRow
                .filter(Column("provider") == provider)
                .filter(Column("sessionID") == session.id)
                .fetchOne(db)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let outcome = try self.upsert(
                session, provider: provider, existing: existing,
                now: now, encoder: encoder, db: db)
            return SnapshotOutcome(
                changed: outcome.changed,
                attention: outcome.attention.map { [$0] } ?? [])
        }
    }

    /// Explicit removal from an `events` `removed` line. The provider is
    /// authoritative about this, so it marks the row gone immediately —
    /// unlike inferred absence from a snapshot, this skips the two-absence
    /// rule entirely. Returns whether a row actually changed (an unknown
    /// session, or one already gone, changes nothing) so callers can skip a
    /// pointless UI broadcast — the same `changed` contract `applySnapshot`
    /// and `upsertOne` report.
    @discardableResult
    public func markGone(provider: String, sessionID: String) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE remote_session SET gone = 1 WHERE provider = ? AND sessionID = ? AND gone = 0",
                arguments: [provider, sessionID])
            return db.changesCount > 0
        }
    }

    public func list() async throws -> [RemoteSessionRow] {
        try await writer.read { db in
            try RemoteSessionRow.order(Column("firstSeen").desc).fetchAll(db)
        }
    }

    /// Returns whether a row actually changed (an unknown session, or one
    /// already dismissed, changes nothing) — mirrors `markGone`'s contract so
    /// callers can skip a pointless UI broadcast.
    @discardableResult
    public func dismiss(provider: String, sessionID: String) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE remote_session SET dismissed = 1 WHERE provider = ? AND sessionID = ? AND dismissed = 0",
                arguments: [provider, sessionID])
            return db.changesCount > 0
        }
    }
}
