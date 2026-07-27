import Foundation
import GRDB
import TBDShared
import os

private let remoteSessionStoreLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

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
    /// Sidebar-dock pin timestamp, or nil when unpinned — see
    /// `RemoteSessionInfo.pinnedAt`. Purely presentational: nothing in the
    /// daemon reads this value beyond echoing it to clients.
    public var pinnedAt: Date?

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

/// Lazily-fetched, per-transaction cache of every registered repo, used to
/// resolve `meta["repo"]` for unresolved sessions. Without this, `upsert`
/// fetching the full repo table inline costs one `RepoRecord.fetchAll` PER
/// unresolvable session on every single poll (N sessions × every poll,
/// forever, since resolution keeps retrying while `resolvedRepoID` is null —
/// see the pinning doc comment below). A `final class` (not a `struct`)
/// because it needs reference semantics: `applySnapshot`'s loop shares one
/// instance across every `upsert` call in the transaction, and each call
/// must see the SAME cached fetch (or lack thereof) as the ones before it.
/// Not `Sendable` on purpose — never crosses an await boundary or escapes
/// the single synchronous `writer.write { db in ... }` closure it's created
/// inside.
private final class RepoCache {
    private let db: Database
    private var cached: [Repo]?

    init(db: Database) {
        self.db = db
    }

    /// Fetches on first call, then returns the same array for the rest of
    /// this cache's lifetime (one `write` transaction). Safe even if this
    /// transaction inserted/removed repos earlier in the SAME transaction
    /// (won't happen in practice — repo mutation and remote-session
    /// resolution never share a transaction — but if it did, GRDB
    /// transaction isolation means this fetch already reflects it).
    func get() throws -> [Repo] {
        if let cached { return cached }
        let fetched = try RepoRecord.fetchAll(db).compactMap { $0.toModel() }
        cached = fetched
        return fetched
    }
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
        now: Date, encoder: JSONEncoder, db: Database, repoCache: RepoCache
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
               let resolved = try self.resolveRepoID(metaRepo: session.meta?["repo"], repoCache: repoCache) {
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
            let resolvedRepoID = try self.resolveRepoID(metaRepo: session.meta?["repo"], repoCache: repoCache)
            try RemoteSessionRow(
                provider: provider, sessionID: session.id,
                payload: payloadString, state: session.state.rawValue,
                agentState: session.agentState.rawValue,
                firstSeen: now, lastSeen: now,
                missingCount: 0, gone: false, dismissed: false,
                resolvedRepoID: resolvedRepoID?.uuidString,
                // A brand-new session is never pinned. An EXISTING row's pin
                // is preserved because the branch above mutates and updates
                // the row it read, never reconstructing it.
                pinnedAt: nil
            ).insert(db)
            return (true, nil)
        }
    }

    /// Resolves `metaRepo` against `repoCache` — lazily fetched at most once
    /// per transaction (see `RepoCache`'s doc comment) rather than once per
    /// unresolved session. Logs at `.debug` when `metaRepo` is present but
    /// matched no local repo — the only way to answer "why isn't my session
    /// in my repo's section" without attaching a debugger, since a miss here
    /// otherwise leaves no trace anywhere.
    private func resolveRepoID(metaRepo: String?, repoCache: RepoCache) throws -> UUID? {
        guard let metaRepo else { return nil }
        let repos = try repoCache.get()
        let resolved = RemoteRepoMatching.resolveRepoID(metaRepo: metaRepo, repos: repos)
        if resolved == nil {
            let normalizedKey = RemoteRepoMatching.normalizedKey(metaRepo)
            remoteSessionStoreLogger.debug(
                "remote session meta[repo]=\(metaRepo, privacy: .public) (normalized: \(normalizedKey ?? "unparseable", privacy: .public)) matched no local repo")
        }
        return resolved
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
            // Shared across every session in this snapshot so an unresolved
            // repo lookup costs at most one `RepoRecord.fetchAll` for the
            // WHOLE poll, not one per unresolved session.
            let repoCache = RepoCache(db: db)

            for session in sessions {
                let existingRow = byID.removeValue(forKey: session.id)
                let outcome = try self.upsert(
                    session, provider: provider, existing: existingRow,
                    now: now, encoder: encoder, db: db, repoCache: repoCache)
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
                now: now, encoder: encoder, db: db, repoCache: RepoCache(db: db))
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
    ///
    /// Dismissing also DROPS any sidebar-dock pin: dismiss means "get this
    /// out of my sight", and a dismissed row is filtered out of every session
    /// list, so leaving `pinnedAt` set would strand an invisible pin that
    /// silently resurrects the row in the dock if the session were ever
    /// un-dismissed. Deliberately part of the same UPDATE (not a second
    /// statement) so the two can't diverge.
    @discardableResult
    public func dismiss(provider: String, sessionID: String) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE remote_session SET dismissed = 1, pinnedAt = NULL
                    WHERE provider = ? AND sessionID = ? AND dismissed = 0
                    """,
                arguments: [provider, sessionID])
            return db.changesCount > 0
        }
    }

    /// Pin or unpin one mirror row for the sidebar dock. `pinnedAt` is
    /// stamped by the caller (the RPC handler, daemon-side) so pin order is
    /// server-assigned and consistent across clients — the same contract
    /// `WorktreeStore.setPinned` follows.
    ///
    /// Returns whether a row actually changed, mirroring `dismiss`/`markGone`
    /// so the handler can skip a pointless UI broadcast. An unknown session
    /// changes nothing; re-pinning an already-pinned row DOES change it (the
    /// timestamp moves), which is why this compares against the requested
    /// null-ness rather than blanket-writing.
    @discardableResult
    public func setPinned(provider: String, sessionID: String, pinnedAt: Date?) async throws -> Bool {
        try await writer.write { db in
            if let pinnedAt {
                try db.execute(
                    sql: "UPDATE remote_session SET pinnedAt = ? WHERE provider = ? AND sessionID = ?",
                    arguments: [pinnedAt, provider, sessionID])
            } else {
                try db.execute(
                    sql: "UPDATE remote_session SET pinnedAt = NULL WHERE provider = ? AND sessionID = ? AND pinnedAt IS NOT NULL",
                    arguments: [provider, sessionID])
            }
            return db.changesCount > 0
        }
    }
}
