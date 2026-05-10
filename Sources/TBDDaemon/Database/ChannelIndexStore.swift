import Foundation
import GRDB
import TBDShared

/// GRDB Record for the `channel_index` table — derivable cache of per-channel
/// metadata that backs `tbd channels list` and the daemon's per-post update.
public struct ChannelIndexRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "channel_index"

    public var name: String
    public var createdAt: Date
    public var lastMessageAt: Date?
    public var messageCount: Int

    public init(name: String, createdAt: Date, lastMessageAt: Date?, messageCount: Int) {
        self.name = name
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
    }
}

/// CRUD for `channel_index`. All methods are safe for concurrent callers.
public struct ChannelIndexStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Upsert: create the row if missing, increment `messageCount` and bump
    /// `lastMessageAt` if present.
    public func recordPost(name: String, at timestamp: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO channel_index (name, createdAt, lastMessageAt, messageCount)
                    VALUES (?, ?, ?, 1)
                    ON CONFLICT(name) DO UPDATE SET
                        lastMessageAt = excluded.lastMessageAt,
                        messageCount = messageCount + 1
                    """,
                arguments: [name, timestamp, timestamp]
            )
        }
    }

    /// List all channels ordered by most-recent activity first.
    public func list(includeArchived: Bool) async throws -> [ChannelIndexRecord] {
        // includeArchived is a no-op in v1 — archived channels live as
        // files under `_archive/` and never have an index row. The
        // parameter exists so the RPC surface doesn't change when
        // archived-listing arrives.
        _ = includeArchived
        return try await writer.read { db in
            try ChannelIndexRecord
                .order(Column("lastMessageAt").desc)
                .fetchAll(db)
        }
    }

    /// Remove the row (used on archive).
    public func delete(name: String) async throws {
        try await writer.write { db in
            _ = try ChannelIndexRecord.deleteOne(db, key: name)
        }
    }
}
