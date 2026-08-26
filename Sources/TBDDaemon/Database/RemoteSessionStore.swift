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
        if var row = existing {
            // Nothing serializes the `list` poll against the `events` stream
            // against a one-off verb response, so a sighting can arrive after
            // one that observed the same session LATER. Taking its agent
            // state would reinstate a state the provider has moved on from —
            // putting the attention hand back on a session that has been
            // working for minutes, where only the next genuine transition
            // could clear it again.
            //
            // Only the AGENT axis is withheld, because `agent_state_at` is
            // the only thing the contract timestamps: it says when the agent
            // state was determined and nothing about when the title, terminal
            // state, or `meta` were. Withholding those too would drop a
            // rename that arrived in the same response. Presence is never
            // withheld either — the session was there to be reported,
            // whenever the report was taken.
            let session = Self.withFreshestAgentAxis(
                incoming: session, storedPayload: row.payload, provider: provider, now: now)
            let payloadString = String(data: try encoder.encode(session), encoding: .utf8) ?? "{}"
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
            let payloadString = String(data: try encoder.encode(session), encoding: .utf8) ?? "{}"
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

    /// `incoming`, with its agent axis replaced by the mirrored one whenever
    /// the mirrored one is demonstrably newer.
    ///
    /// Returns `incoming` untouched in every other case, which is every case
    /// for a provider that does not send `agent_state_at` — the ordering
    /// check can only fire where the provider gave TBD something to order by.
    ///
    /// The whole payload is re-encoded from the result, so the mirror never
    /// holds a payload whose `agent_state` and `agent_state_at` disagree:
    /// both fields move together or neither does.
    static func withFreshestAgentAxis(
        incoming: RemoteSessionPayload, storedPayload: String, provider: String, now: Date
    ) -> RemoteSessionPayload {
        guard RemoteSnapshotOrdering.decide(
            incomingAgentStateAt: incoming.agentStateAt,
            storedAgentStateAt: storedAgentStateAt(storedPayload),
            now: now) == .presenceOnly,
            let stored = decodeStoredPayload(storedPayload)
        else { return incoming }

        remoteSessionStoreLogger.debug(
            """
            out-of-order sighting for \(provider, privacy: .public)/\
            \(incoming.id, privacy: .public): agent_state \
            \(incoming.agentState.rawValue, privacy: .public) at \
            \(incoming.agentStateAt ?? "nil", privacy: .public) predates the mirrored \
            \(stored.agentState.rawValue, privacy: .public) at \
            \(stored.agentStateAt ?? "nil", privacy: .public); agent axis kept, rest applied
            """)

        return RemoteSessionPayload(
            id: incoming.id, title: incoming.title, createdAt: incoming.createdAt,
            state: incoming.state, exitCode: incoming.exitCode,
            agentState: stored.agentState,
            agentStateReason: stored.agentStateReason,
            agentStateAt: stored.agentStateAt,
            meta: incoming.meta, archived: incoming.archived)
    }

    /// The `agent_state_at` inside a mirrored payload string.
    ///
    /// Read back out of the stored JSON rather than kept in its own column:
    /// the payload is already the mirror's record of what the provider last
    /// said, and a column would be a second copy of one fact that a future
    /// write path could forget to keep in step. Nil for a payload that
    /// predates the field, is unparseable, or simply omitted it — all of
    /// which mean the same thing here, which is that there is no ordering
    /// information and the sighting applies.
    ///
    /// Decodes one field rather than the whole `RemoteSessionPayload`: this
    /// runs once per session per sighting, and the full decode — with every
    /// leniency rule and diagnostic in it — is paid only on the rare path
    /// where a sighting actually is out of order.
    static func storedAgentStateAt(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredAgentStateStamp.self, from: data).agentStateAt
    }

    private static func decodeStoredPayload(_ payload: String) -> RemoteSessionPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteSessionPayload.self, from: data)
    }

    /// Just enough of the Session object to read one field back.
    private struct StoredAgentStateStamp: Decodable {
        let agentStateAt: String?

        enum CodingKeys: String, CodingKey {
            case agentStateAt = "agent_state_at"
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

    /// Reconcile one provider's session list against the mirror table.
    /// Rows for OTHER providers are never touched — snapshots are
    /// provider-scoped, so an empty snapshot from provider B must not affect
    /// provider A's rows.
    ///
    /// `complete` is the contract's snapshot-completeness claim
    /// (`docs/remote-provider-contract.md` § Snapshot completeness). It splits
    /// the three things a snapshot does. An INCOMPLETE snapshot still
    /// **adopts** and **updates** the sessions it sighted — a session observed
    /// in a partial view has been positively observed, and that observation is
    /// as good as any other — while advancing **neither** the absence
    /// bookkeeping **nor** freshness. Absence from a snapshot that never
    /// claimed to see everything is evidence of nothing.
    ///
    /// Both halves of freshness are suppressed, and the persisted one is why
    /// this is not cosmetic: the in-memory stamp lives in
    /// `RemoteProviderManager.lastSuccessfulSnapshotAt`, but the `tbd_meta`
    /// row below is what a daemon restart recovers from, so writing it on a
    /// partial view would make that view survive a restart looking current.
    /// Defaulted to `true` so every caller that predates the field keeps its
    /// exact behavior.
    public func applySnapshot(
        provider: String, sessions: [RemoteSessionPayload], complete: Bool = true, now: Date
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
            // already gone is left alone. Skipped entirely for an incomplete
            // snapshot — it is authoritative about presence only, and per the
            // contract an unbroken run of incomplete snapshots leaves the
            // mirror exactly where it stands.
            if complete {
                for var row in byID.values where !row.gone {
                    row.missingCount += 1
                    if row.missingCount >= 2 { row.gone = true }
                    changed = true
                    try row.update(db)
                }
            }

            // Persist the authoritative full-inventory observation in this
            // same transaction. Event-stream upserts deliberately do not
            // touch this key: a healthy single-session stream must never make
            // a broken full-list path look fresh after daemon restart. An
            // incomplete snapshot is excluded for the same reason — it is not
            // a full-inventory observation, and one written here would outlive
            // the daemon looking like one.
            if complete {
                try db.execute(
                    sql: "INSERT INTO tbd_meta (key, value) VALUES (?, ?) "
                        + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [
                        Self.snapshotTimestampKey(provider: provider),
                        String(now.timeIntervalSince1970),
                    ]
                )
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

    /// One provider's mirror rows. Adoption reads these straight after a
    /// snapshot to learn the repo association this store just PINNED, rather
    /// than resolving `meta["repo"]` a second time — a second resolution could
    /// disagree with the pin, and the pin is the one the Provider Desk shows.
    public func rows(provider: String) async throws -> [RemoteSessionRow] {
        try await writer.read { db in
            try RemoteSessionRow.filter(Column("provider") == provider).fetchAll(db)
        }
    }

    /// The single mirror row for one session, for the events path where a
    /// whole-provider fetch would be wasted work.
    public func row(provider: String, sessionID: String) async throws -> RemoteSessionRow? {
        try await writer.read { db in
            try RemoteSessionRow
                .filter(Column("provider") == provider)
                .filter(Column("sessionID") == sessionID)
                .fetchOne(db)
        }
    }

    public func list() async throws -> [RemoteSessionRow] {
        try await writer.read { db in
            try RemoteSessionRow.order(Column("firstSeen").desc).fetchAll(db)
        }
    }

    /// Exact persisted time of the provider's last complete inventory. This
    /// is intentionally separate from row `lastSeen`, which can advance from
    /// the independent events stream.
    public func lastSuccessfulSnapshotAt(provider: String) async throws -> Date? {
        try await writer.read { db in
            guard let value = try String.fetchOne(
                db, sql: "SELECT value FROM tbd_meta WHERE key = ?",
                arguments: [Self.snapshotTimestampKey(provider: provider)]),
                let seconds = TimeInterval(value)
            else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    private static func snapshotTimestampKey(provider: String) -> String {
        "remote.last-successful-snapshot.\(provider)"
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
