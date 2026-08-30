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
///
/// The `readContentFile` seam on `NoteStore` is what makes the metadata
/// contract testable: a counting reader turns "does `list` open content
/// files?" into an assertion instead of a code-reading exercise.
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
        #expect(try await db.notes.list(worktreeID: wt.id).first?.hasLegacyContent == true,
                "a non-empty legacy column is exactly what hasLegacyContent reports")

        // File appears (e.g. external edit) → file wins over the stale column.
        let path = filePath(dir: dir, worktreeID: wt.id, noteID: note.id)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "from the file".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try await db.notes.get(id: note.id)?.content == "from the file")
        #expect(try await db.notes.list(worktreeID: wt.id).first?.hasLegacyContent == true,
                "the column is still non-empty, so the flag is unchanged by the file")
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

    // MARK: - `list` touches no files

    /// A `NoteStore` over the fixture's DB whose every content-file read goes
    /// through a counter.
    private func countingStore(db: TBDDatabase, dir: URL) -> (NoteStore, NoteReadCounter) {
        let counter = NoteReadCounter()
        let store = NoteStore(
            writer: db.writerForTests,
            notesDir: dir.path,
            readContentFile: { counter.read($0) }
        )
        return (store, counter)
    }

    @Test("list opens zero content files, however many notes exist")
    func listDoesNotReadContentFiles() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<20 {
            let note = try await db.notes.create(worktreeID: wt.id)
            _ = try await db.notes.update(id: note.id, content: "body \(index)")
            #expect(FileManager.default.fileExists(
                atPath: filePath(dir: dir, worktreeID: wt.id, noteID: note.id)))
        }

        let (store, counter) = countingStore(db: db, dir: dir)
        let summaries = try await store.list()

        #expect(summaries.count == 20, "the assertion below is vacuous on an empty list")
        #expect(counter.reads == 0,
                "list must never open a content file — it read \(counter.reads)")
    }

    @Test("get reads exactly one content file")
    func getReadsExactlyOneContentFile() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try await db.notes.create(worktreeID: wt.id)
        _ = try await db.notes.update(id: note.id, content: "the body")
        for _ in 0..<4 {
            let other = try await db.notes.create(worktreeID: wt.id)
            _ = try await db.notes.update(id: other.id, content: "other")
        }

        let (store, counter) = countingStore(db: db, dir: dir)
        let before = counter.reads
        #expect(try await store.get(id: note.id)?.content == "the body")
        #expect(counter.reads - before == 1,
                "get is O(1) reads regardless of how many notes exist")
    }

    /// `hasLegacyContent` reports the DB column and nothing else. The
    /// file-backed row reporting `false` is the surprising case and it is
    /// correct: the app owns the union of column and file, precisely so no
    /// reader can mistake one for the other.
    @Test("hasLegacyContent reports the DB column, not the file")
    func listReportsLegacyColumnOnly() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Column only — written with raw SQL, because `update()` would
        //    write the file and destroy the case under test.
        let columnOnly = try await db.notes.create(worktreeID: wt.id)
        try await db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE note SET content = 'column only' WHERE id = ?",
                arguments: [columnOnly.id.uuidString]
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: filePath(dir: dir, worktreeID: wt.id, noteID: columnOnly.id)))

        // 2. File-backed, empty column — the ordinary modern note.
        let fileBacked = try await db.notes.create(worktreeID: wt.id)
        _ = try await db.notes.update(id: fileBacked.id, content: "on disk")
        #expect(FileManager.default.fileExists(
            atPath: filePath(dir: dir, worktreeID: wt.id, noteID: fileBacked.id)))

        // 3. Freshly created — neither.
        let fresh = try await db.notes.create(worktreeID: wt.id)

        let (store, counter) = countingStore(db: db, dir: dir)
        let byID = Dictionary(uniqueKeysWithValues: try await store.list().map { ($0.id, $0) })

        #expect(byID[columnOnly.id]?.hasLegacyContent == true,
                "the legacy column is the one thing this flag reports")
        #expect(byID[fileBacked.id]?.hasLegacyContent == false,
                "a file-backed note with an empty column reports false — the app takes the union")
        #expect(byID[fresh.id]?.hasLegacyContent == false)
        #expect(counter.reads == 0, "and none of that opened a file")
    }

    @Test("list works, and is correct, with no notes directory at all")
    func listPerformsNoFilesystemWork() async throws {
        // The strongest available statement of "list touches no files": point
        // the store at a path that does not exist. Anything that stats or
        // enumerates would come back wrong or empty; a pure row map does not
        // care.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-notes-absent-\(UUID().uuidString)")
        let db = try TBDDatabase(inMemory: true, notesDir: dir.path)
        let wt = try await db.worktrees.createScratch(
            name: "fixture", displayName: "fixture",
            path: "/tmp/fixture-\(UUID().uuidString)", tmuxServer: "tbd-test"
        )

        var legacy: Set<UUID> = []
        for index in 0..<40 {
            let note = try await db.notes.create(worktreeID: wt.id)
            if index == 3 || index == 36 {
                try await db.writerForTests.write { db in
                    try db.execute(
                        sql: "UPDATE note SET content = 'legacy' WHERE id = ?",
                        arguments: [note.id.uuidString]
                    )
                }
                legacy.insert(note.id)
            }
        }

        let summaries = try await db.notes.list()
        #expect(summaries.count == 40)
        #expect(Set(summaries.filter(\.hasLegacyContent).map(\.id)) == legacy)
        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "list must not have created, or needed, the notes directory")
    }

    /// The assertion that keeps the resurrection bug dead. The app deletes no
    /// content file itself: an emptying save routes back through the daemon so
    /// the file and the legacy column go together. If the column survived, the
    /// next open would see "file missing + hasLegacyContent" and restore the
    /// text the user just deleted.
    @Test("emptying a note clears the legacy column as well as the file")
    func emptyingANoteClearsTheLegacyColumn() async throws {
        let (db, dir, wt) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try await db.notes.create(worktreeID: wt.id)
        _ = try await db.notes.update(id: note.id, content: "worth keeping")
        try await db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE note SET content = 'legacy too' WHERE id = ?",
                arguments: [note.id.uuidString]
            )
        }
        let path = filePath(dir: dir, worktreeID: wt.id, noteID: note.id)
        #expect(FileManager.default.fileExists(atPath: path))

        _ = try await db.notes.update(id: note.id, content: "")

        #expect(!FileManager.default.fileExists(atPath: path), "the file must be gone")
        #expect(try await rawDBContent(db: db, noteID: note.id) == "",
                "and the legacy column with it")
        #expect(try await db.notes.list(worktreeID: wt.id).first?.hasLegacyContent == false,
                "so nothing is left to resurrect on the next open")
    }

    @Test("list filters by an explicit worktree set")
    func listFiltersByWorktreeIDs() async throws {
        let (db, dir, wtA) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wtB = try await db.worktrees.createScratch(
            name: "fixture-b", displayName: "fixture-b",
            path: "/tmp/fixture-\(UUID().uuidString)", tmuxServer: "tbd-test"
        )

        let inA = try await db.notes.create(worktreeID: wtA.id)
        let inB = try await db.notes.create(worktreeID: wtB.id)

        let onlyA = try await db.notes.list(worktreeIDs: [wtA.id])
        #expect(onlyA.map(\.id) == [inA.id])

        let both = try await db.notes.list(worktreeIDs: [wtA.id, wtB.id])
        #expect(Set(both.map(\.id)) == Set([inA.id, inB.id]))

        #expect(try await db.notes.list(worktreeIDs: []).isEmpty,
                "an empty set selects nothing, not everything")
    }
}

/// Counts every content-file read a `NoteStore` makes, via its
/// `readContentFile` injection seam.
private final class NoteReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func read(_ path: String) -> String? {
        lock.lock()
        count += 1
        lock.unlock()
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
