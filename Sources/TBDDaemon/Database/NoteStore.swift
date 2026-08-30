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
///
/// Note CONTENT is file-backed at `~/tbd/notes/<worktreeID>/<noteID>.md`
/// (`TBDConstants.noteContentPath`); the DB row keeps tab identity + title.
/// The DB `content` column is a dormant legacy fallback: reads prefer the
/// file when it exists, writes go to the file only. Empty/whitespace-only
/// content deletes the file (mirrors the app's `NotesFileStore` semantics),
/// so a freshly auto-created empty note produces no file.
///
/// **`list` performs zero filesystem operations, by contract.** Not "fewer" —
/// zero. It returns `NoteSummary`, fetches rows and maps them; it does not
/// stat, enumerate, or open anything. The app polls it every two seconds, and
/// a `list` that touched content made the endpoint's cost scale with the total
/// bytes of every note on the machine (measured at 27% of all daemon
/// filesystem operations). The app reads and writes the content file itself.
///
/// What is left of content in this type is the legacy DB column: `get(id:)`
/// still overlays it for the few rows the startup export never drained, and
/// `update(content:)` remains the one write path the app still delegates —
/// emptying a note, which must delete the file and clear the column together.
public struct NoteStore: Sendable {
    let writer: any DatabaseWriter
    /// Injection seam for tests (like `ThemeStore(themesDirectory:)`): nil
    /// resolves `TBDConstants.noteContentDir` (which honors TBD_HOME) at
    /// call time.
    let notesDirOverride: String?
    /// Injection seam for tests: every content-file read goes through this,
    /// so a test can count them and pin that `list` performs none.
    let readContentFile: @Sendable (String) -> String?

    init(writer: any DatabaseWriter,
         notesDir: String? = nil,
         readContentFile: @Sendable @escaping (String) -> String? = {
             try? String(contentsOfFile: $0, encoding: .utf8)
         }) {
        self.writer = writer
        self.notesDirOverride = notesDir
        self.readContentFile = readContentFile
    }

    // MARK: - Content files

    func contentPath(worktreeID: UUID, noteID: UUID) -> String {
        if let notesDirOverride {
            return ((notesDirOverride as NSString)
                .appendingPathComponent(worktreeID.uuidString) as NSString)
                .appendingPathComponent("\(noteID.uuidString).md")
        }
        return TBDConstants.noteContentPath(worktreeID: worktreeID, noteID: noteID)
    }

    /// File content wins when the file exists; DB column is the fallback for
    /// legacy rows that were never exported.
    private func overlayContent(_ note: Note) -> Note {
        let path = contentPath(worktreeID: note.worktreeID, noteID: note.id)
        guard let fileContent = readContentFile(path) else {
            return note
        }
        var overlaid = note
        overlaid.content = fileContent
        return overlaid
    }

    /// Writes `content` to the note's file (atomically, creating intermediate
    /// directories). Empty/whitespace-only content deletes the file instead.
    private func writeContentFile(_ content: String, worktreeID: UUID, noteID: UUID) throws {
        let path = contentPath(worktreeID: worktreeID, noteID: noteID)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            return
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try content.write(toFile: path, atomically: true, encoding: .utf8)
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

    /// Get a note by ID (content overlaid from its file when one exists).
    public func get(id: UUID) async throws -> Note? {
        let note = try await writer.read { db in
            try NoteRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
        return note.map(overlayContent)
    }

    /// List note METADATA, optionally filtered by worktree and/or by an
    /// explicit set of worktrees (both filters apply when both are given).
    ///
    /// Touches no file — see the type's doc comment. `hasLegacyContent` comes
    /// off the row that was fetched anyway.
    public func list(worktreeID: UUID? = nil,
                     worktreeIDs: [UUID]? = nil) async throws -> [NoteSummary] {
        let notes = try await writer.read { db in
            var request = NoteRecord.all()
            if let worktreeID {
                request = request.filter(Column("worktreeID") == worktreeID.uuidString)
            }
            if let worktreeIDs {
                request = request.filter(worktreeIDs.map(\.uuidString).contains(Column("worktreeID")))
            }
            return try request.fetchAll(db)
        }
        return notes.compactMap { record in
            guard let note = record.toModel() else { return nil }
            return NoteSummary(
                id: note.id,
                worktreeID: note.worktreeID,
                title: note.title,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                hasLegacyContent: !record.content.isEmpty
            )
        }
    }

    /// Update a note's title and/or content. Title goes to the DB row;
    /// content goes to the file only. Exception: an explicit empty-content
    /// update also clears the DB column — the file is deleted, and a stale
    /// legacy column value would otherwise resurrect through the fallback.
    ///
    /// The app writes note content directly and calls this for titles; the one
    /// content case it still routes here is exactly that emptying, because
    /// deleting the file and clearing the column have to happen together.
    public func update(id: UUID, title: String? = nil, content: String? = nil) async throws -> Note {
        let updated = try await writer.write { db -> Note in
            guard var record = try NoteRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Note not found")
            }
            if let title { record.title = title }
            if let content, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.content = ""
            }
            record.updatedAt = Date()
            try record.update(db)
            guard let model = record.toModel() else {
                // The row we just wrote carries a valid UUID by construction;
                // a nil here means the id column was corrupted out-of-band.
                throw DatabaseError(message: "Note row has a malformed id after update")
            }
            return model
        }
        if let content {
            try writeContentFile(content, worktreeID: updated.worktreeID, noteID: updated.id)
        }
        return overlayContent(updated)
    }

    /// Delete a note by ID. Deliberately does NOT delete the note's content
    /// file — closing a note tab removes the row, the `.md` survives on disk.
    /// (Orphan-file GC is out of scope; files are intentionally retained.)
    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try NoteRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// Delete all notes for a worktree. Content files are intentionally
    /// retained (see `delete(id:)`).
    public func deleteForWorktree(worktreeID: UUID) async throws {
        _ = try await writer.write { db in
            try NoteRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
        }
    }

    /// One-time best-effort export of legacy DB note content to files, run at
    /// daemon startup (sibling of `sweepClaudeSettingsOverlayColumnToFiles`).
    /// For every row with non-empty content and no file yet, write the file.
    /// The DB column is NOT cleared — it stays as a dormant fallback/backup;
    /// the file simply wins once it exists. Idempotent by construction (the
    /// file-exists guard also protects newer file edits from being clobbered
    /// on later startups). Failures are logged and never block startup.
    public func exportContentColumnToFiles() async {
        let logger = Logger(subsystem: "com.tbd.daemon", category: "startup")
        let rows: [Note]
        do {
            rows = try await writer.read { db in
                try NoteRecord.fetchAll(db).compactMap { $0.toModel() }
            }
        } catch {
            logger.error("note content export: read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for note in rows
        where !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = contentPath(worktreeID: note.worktreeID, noteID: note.id)
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try writeContentFile(note.content, worktreeID: note.worktreeID, noteID: note.id)
                logger.info("Exported note \(note.id, privacy: .public) content to \(path, privacy: .public)")
            } catch {
                logger.error("note content export failed for \(note.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
