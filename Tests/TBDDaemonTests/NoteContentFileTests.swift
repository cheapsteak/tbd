import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Note CONTENT is file-backed (`<notesDir>/<worktreeID>/<noteID>.md`); the
/// DB row keeps identity + title, its `content` column surviving only as a
/// dormant legacy fallback. These tests use the `TBDDatabase(inMemory:
/// notesDir:)` injection seam with a per-test temp dir — no TBD_HOME setenv,
/// so the suite runs fully parallel.
@Suite("Note content files")
struct NoteContentFileTests {

    /// In-memory DB with an isolated notes dir and one (scratch-style)
    /// worktree row to hang notes off. Caller removes `dir`.
    private func makeFixture() async throws -> (db: TBDDatabase, dir: URL, worktree: Worktree) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-notes-\(UUID().uuidString)")
        let db = try TBDDatabase(inMemory: true, notesDir: dir.path)
        let wt = try await db.worktrees.createScratch(
            name: "fixture", displayName: "fixture",
            path: "/tmp/fixture-\(UUID().uuidString)", tmuxServer: "tbd-test"
        )
        return (db, dir, wt)
    }

    private func filePath(dir: URL, worktreeID: UUID, noteID: UUID) -> String {
        dir.appendingPathComponent(worktreeID.uuidString)
            .appendingPathComponent("\(noteID.uuidString).md").path
    }

    private func rawDBContent(db: TBDDatabase, noteID: UUID) async throws -> String? {
        try await db.writerForTests.read { db in
            try String.fetchOne(
                db, sql: "SELECT content FROM note WHERE id = ?",
                arguments: [noteID.uuidString]
            )
        }
    }

    @Test func updateWritesFileAndNotDBColumn() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try await db.notes.create(worktreeID: wt.id)
        let path = filePath(dir: dir, worktreeID: wt.id, noteID: note.id)
        // A freshly created (empty) note must produce no file.
        #expect(!FileManager.default.fileExists(atPath: path))

        let updated = try await db.notes.update(id: note.id, content: "hello world")
        #expect(updated.content == "hello world")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hello world")
        #expect(try await rawDBContent(db: db, noteID: note.id) == "",
                "content must not be written to the DB column")

        #expect(try await db.notes.get(id: note.id)?.content == "hello world")
    }

    @Test func updateToEmptyDeletesFile() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try await db.notes.create(worktreeID: wt.id)
        _ = try await db.notes.update(id: note.id, content: "something")
        let path = filePath(dir: dir, worktreeID: wt.id, noteID: note.id)
        #expect(FileManager.default.fileExists(atPath: path))

        let cleared = try await db.notes.update(id: note.id, content: "   \n")
        #expect(!FileManager.default.fileExists(atPath: path),
                "empty/whitespace-only content must delete the file")
        #expect(cleared.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(try await db.notes.get(id: note.id)?.content == "")
    }

    @Test func fileWinsOverDBAndDBIsFallback() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Legacy row: content only in the DB column, no file.
        let note = try await db.notes.create(worktreeID: wt.id)
        try await db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE note SET content = 'legacy' WHERE id = ?",
                arguments: [note.id.uuidString]
            )
        }
        #expect(try await db.notes.get(id: note.id)?.content == "legacy",
                "with no file, the DB column is the fallback")
        #expect(try await db.notes.list(worktreeID: wt.id).first?.content == "legacy")

        // File appears (e.g. external edit) → file wins over the stale column.
        let path = filePath(dir: dir, worktreeID: wt.id, noteID: note.id)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "from the file".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try await db.notes.get(id: note.id)?.content == "from the file")
        #expect(try await db.notes.list(worktreeID: wt.id).first?.content == "from the file")
    }

    @Test func clearingLegacyNoteDoesNotResurrectDBContent() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try await db.notes.create(worktreeID: wt.id)
        try await db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE note SET content = 'legacy' WHERE id = ?",
                arguments: [note.id.uuidString]
            )
        }
        // Explicitly clearing must stick: the file is deleted AND the legacy
        // column is cleared, so the old content can't resurrect via fallback.
        _ = try await db.notes.update(id: note.id, content: "")
        #expect(try await db.notes.get(id: note.id)?.content == "")
    }

    @Test func startupExportWritesFilesOnceAndNeverClobbers() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Legacy rows: one with content, one empty.
        let legacy = try await db.notes.create(worktreeID: wt.id)
        let empty = try await db.notes.create(worktreeID: wt.id)
        try await db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE note SET content = 'exported' WHERE id = ?",
                arguments: [legacy.id.uuidString]
            )
        }

        await db.notes.exportContentColumnToFiles()

        let legacyPath = filePath(dir: dir, worktreeID: wt.id, noteID: legacy.id)
        let emptyPath = filePath(dir: dir, worktreeID: wt.id, noteID: empty.id)
        #expect(try String(contentsOfFile: legacyPath, encoding: .utf8) == "exported")
        #expect(!FileManager.default.fileExists(atPath: emptyPath),
                "empty rows must produce no file")
        #expect(try await rawDBContent(db: db, noteID: legacy.id) == "exported",
                "the export must NOT clear the DB column (dormant backup)")

        // A newer file edit survives a second startup export untouched.
        try "newer edit".write(toFile: legacyPath, atomically: true, encoding: .utf8)
        await db.notes.exportContentColumnToFiles()
        #expect(try String(contentsOfFile: legacyPath, encoding: .utf8) == "newer edit",
                "a re-run must never clobber an existing file")
    }

    @Test func deleteKeepsContentFile() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try await db.notes.create(worktreeID: wt.id)
        _ = try await db.notes.update(id: note.id, content: "keep me")
        let path = filePath(dir: dir, worktreeID: wt.id, noteID: note.id)

        try await db.notes.delete(id: note.id)
        #expect(try await db.notes.get(id: note.id) == nil, "the row must be gone")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep me",
                "closing/deleting a note must never destroy its content file")

        // Worktree-level cleanup keeps files too.
        let note2 = try await db.notes.create(worktreeID: wt.id)
        _ = try await db.notes.update(id: note2.id, content: "also kept")
        let path2 = filePath(dir: dir, worktreeID: wt.id, noteID: note2.id)
        try await db.notes.deleteForWorktree(worktreeID: wt.id)
        #expect(try String(contentsOfFile: path2, encoding: .utf8) == "also kept")
    }
}
