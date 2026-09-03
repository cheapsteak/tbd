import Foundation
import GRDB
import TBDShared

/// GRDB row for the `retained_transcript` table
/// (`20260902120000_retained_transcript`).
///
/// Snake-case property names because the columns are snake-case, matching
/// `ShadowPeerArtifactRecord`'s convention rather than `RemoteSessionRow`'s
/// camel-case one — the table is new, so it follows the newer of the two.
struct RetainedTranscriptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "retained_transcript"

    var id: String
    var provider: String
    var key: String
    var expires_at: Date?
    var bytes: Int
    var source_session_id: String?
    var source_title: String?
    var resolved_repo_id: String?
    var origin_worktree_id: String?
    var local_path: String?
    var created_at: Date

    init(from model: RetainedTranscript) {
        self.id = model.id.uuidString
        self.provider = model.provider
        self.key = model.key
        self.expires_at = model.expiresAt
        self.bytes = model.bytes
        self.source_session_id = model.sourceSessionID
        self.source_title = model.sourceTitle
        self.resolved_repo_id = model.resolvedRepoID?.uuidString
        self.origin_worktree_id = model.originWorktreeID?.uuidString
        self.local_path = model.localPath
        self.created_at = model.createdAt
    }

    /// Nil when `id` is not a UUID — a row nothing this daemon wrote could
    /// have produced. Dropped rather than crashed, on the same terms every
    /// other record type in this directory degrades: one unreadable row costs
    /// its own key and never the listing.
    func toModel() -> RetainedTranscript? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return RetainedTranscript(
            id: uuid,
            provider: provider,
            key: key,
            expiresAt: expires_at,
            bytes: bytes,
            sourceSessionID: source_session_id,
            sourceTitle: source_title,
            resolvedRepoID: resolved_repo_id.flatMap(UUID.init(uuidString:)),
            originWorktreeID: origin_worktree_id.flatMap(UUID.init(uuidString:)),
            localPath: local_path,
            createdAt: created_at)
    }
}

/// Reads and writes TBD's record of the transcripts a provider has retained.
///
/// The rows are the only enumeration a caller has: the provider contract gives
/// no way to list the keys a provider issued, so a key that never reaches this
/// table is a retained transcript nobody can ever recall.
public struct RetainedTranscriptStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Record one receipt.
    ///
    /// `(provider, key)` is unique, and re-recording the same pair replaces the
    /// row rather than failing. That is correct rather than lossy: a provider
    /// that hands back a key it has already issued is describing the same
    /// stored blob, and the newer receipt carries the newer `bytes` and
    /// `expires_at`. The existing row's `local_path` is deliberately preserved
    /// — a file already on this disk is still there, and a re-`retain` is not
    /// a reason to forget where it landed.
    public func insert(_ transcript: RetainedTranscript) async throws {
        let row = RetainedTranscriptRecord(from: transcript)
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO retained_transcript
                        (id, provider, key, expires_at, bytes, source_session_id,
                         source_title, resolved_repo_id, origin_worktree_id,
                         local_path, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, key) DO UPDATE SET
                        expires_at = excluded.expires_at,
                        bytes = excluded.bytes,
                        source_session_id = COALESCE(excluded.source_session_id, source_session_id),
                        source_title = COALESCE(excluded.source_title, source_title),
                        resolved_repo_id = COALESCE(excluded.resolved_repo_id, resolved_repo_id),
                        origin_worktree_id = COALESCE(excluded.origin_worktree_id, origin_worktree_id),
                        local_path = COALESCE(excluded.local_path, local_path)
                    """,
                arguments: [
                    row.id, row.provider, row.key, row.expires_at, row.bytes,
                    row.source_session_id, row.source_title, row.resolved_repo_id,
                    row.origin_worktree_id, row.local_path, row.created_at,
                ])
        }
    }

    /// One provider's receipts, newest first — the order a human wants when
    /// hunting for the key they made a moment ago.
    public func all(provider: String) async throws -> [RetainedTranscript] {
        try await writer.read { db in
            try RetainedTranscriptRecord
                .filter(Column("provider") == provider)
                .order(Column("created_at").desc)
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }

    /// Every receipt across every provider, newest first.
    public func all() async throws -> [RetainedTranscript] {
        try await writer.read { db in
            try RetainedTranscriptRecord
                .order(Column("created_at").desc)
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }

    /// The one row filed under `(provider, key)`, which is the identity a key
    /// has. A key is never looked up without its provider: keys are
    /// provider-scoped and two providers may legitimately issue the same
    /// string.
    public func find(provider: String, key: String) async throws -> RetainedTranscript? {
        try await writer.read { db in
            try RetainedTranscriptRecord
                .filter(Column("provider") == provider)
                .filter(Column("key") == key)
                .fetchOne(db)?
                .toModel()
        }
    }

    /// The newest receipt taken from a session that belonged to this lane, or
    /// nil when the lane has none.
    ///
    /// This is what makes Revive-as-reseed possible: an archived lane whose
    /// remote session was destroyed has no session left to unarchive, and the
    /// receipt is the only thing that says its conversation survived somewhere.
    /// Newest first, because a lane retained more than once — say a manual
    /// `tbd remote retain` and then a `delete --retain` — wants the last word
    /// on the conversation rather than the first.
    public func latest(originWorktreeID: UUID) async throws -> RetainedTranscript? {
        try await writer.read { db in
            try RetainedTranscriptRecord
                .filter(Column("origin_worktree_id") == originWorktreeID.uuidString)
                .order(Column("created_at").desc)
                .fetchOne(db)?
                .toModel()
        }
    }

    /// Record where a `recall` wrote this receipt's JSONL on this machine.
    ///
    /// Returns whether a row actually changed, mirroring
    /// `RemoteSessionStore.dismiss`'s contract — an unknown `(provider, key)`
    /// changes nothing, and a caller can tell that from a write it made.
    @discardableResult
    public func setLocalPath(provider: String, key: String, localPath: String?) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE retained_transcript SET local_path = ?
                    WHERE provider = ? AND key = ?
                    """,
                arguments: [localPath, provider, key])
            return db.changesCount > 0
        }
    }

    /// Drop every row whose provider-stated expiry has passed as of `date`.
    ///
    /// **`date` is passed, never read here.** Expiry is a persisted timestamp
    /// compared against now, which is the date seam rather than the clock seam
    /// (`Duration` is behavior; `Date` is data), and a store that read its own
    /// clock could not be tested without one.
    ///
    /// Rows with no stated expiry are never touched: an absent `expires_at`
    /// means the provider made no claim, and deleting on that would discard
    /// records the provider may still be holding. Returns the number of rows
    /// removed so a sweep can report what it reclaimed.
    @discardableResult
    public func deleteExpired(asOf date: Date) async throws -> Int {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM retained_transcript WHERE expires_at IS NOT NULL AND expires_at <= ?",
                arguments: [date])
            return db.changesCount
        }
    }

    /// Forget one receipt outright.
    public func delete(provider: String, key: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM retained_transcript WHERE provider = ? AND key = ?",
                arguments: [provider, key])
        }
    }
}
