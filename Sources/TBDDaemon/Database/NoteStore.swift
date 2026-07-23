import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// GRDB Record type for the `note` table.
struct NoteRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "note"

    var id: String
    var worktreeID: String
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(from note: Note) {
        self.id = note.id.uuidString
        self.worktreeID = note.worktreeID.uuidString
        self.title = note.title
        self.content = note.content
        self.createdAt = note.createdAt
        self.updatedAt = note.updatedAt
    }

    /// Failable decode: skips (returns nil after a logged warning) rather than
    /// crashing when a required UUID fails to parse.
    func toModel() -> Note? {
        guard let uuid = UUID(uuidString: id) else {
            decodeLogger.warning("Skipping note row \(id, privacy: .public): malformed id")
            return nil
        }
        guard let wtID = UUID(uuidString: worktreeID) else {
            decodeLogger.warning("Skipping note row \(id, privacy: .public): malformed worktreeID \(worktreeID, privacy: .public)")
            return nil
        }
        return Note(
            id: uuid,
            worktreeID: wtID,
            title: title,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

/// Provides CRUD operations for notes.
public struct NoteStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new note. With no explicit `title`, uses a monotonically
    /// increasing default ("Note 1", "Note 2", etc.).
    public func create(worktreeID: UUID, title: String? = nil) async throws -> Note {
        try await writer.write { db in
            // Use MAX to avoid duplicate titles after deletions
            let maxNum = try Int.fetchOne(db, sql: """
                SELECT MAX(CAST(SUBSTR(title, 6) AS INTEGER))
                FROM note
                WHERE worktreeID = ? AND title LIKE 'Note %'
                """, arguments: [worktreeID.uuidString]) ?? 0
            let note = Note(
                worktreeID: worktreeID,
                title: title ?? "Note \(maxNum + 1)"
            )
            let record = NoteRecord(from: note)
            try record.insert(db)
            return note
        }
    }

    /// Get a note by ID.
    public func get(id: UUID) async throws -> Note? {
        try await writer.read { db in
            try NoteRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// List notes, optionally filtered by worktree.
    public func list(worktreeID: UUID? = nil) async throws -> [Note] {
        try await writer.read { db in
            var request = NoteRecord.all()
            if let worktreeID {
                request = request.filter(Column("worktreeID") == worktreeID.uuidString)
            }
            return try request.fetchAll(db).compactMap { $0.toModel() }
        }
    }

    /// Update a note's title and/or content.
    public func update(id: UUID, title: String? = nil, content: String? = nil) async throws -> Note {
        try await writer.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Note not found")
            }
            if let title { record.title = title }
            if let content { record.content = content }
            record.updatedAt = Date()
            try record.update(db)
            guard let model = record.toModel() else {
                // The row we just wrote carries a valid UUID by construction;
                // a nil here means the id column was corrupted out-of-band.
                throw DatabaseError(message: "Note row has a malformed id after update")
            }
            return model
        }
    }

    /// Delete a note by ID.
    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try NoteRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// Delete all notes for a worktree.
    public func deleteForWorktree(worktreeID: UUID) async throws {
        _ = try await writer.write { db in
            try NoteRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
        }
    }
}
