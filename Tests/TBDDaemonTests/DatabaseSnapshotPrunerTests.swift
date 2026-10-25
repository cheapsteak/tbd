import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite("Database snapshot pruner")
struct DatabaseSnapshotPrunerTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory().appending("tbd-pruner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stamps(_ n: Int) -> [String] {
        (1...n).map { String(format: "202601%02dT120000Z", $0) }
    }

    private func touch(_ dir: String, _ name: String) {
        FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data("x".utf8))
    }

    private func names(_ dir: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    }

    @Test func keepsNewestThreeOfEachKind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for s in stamps(5) {
            touch(dir, "state.db.pre-migration.\(s)")
            touch(dir, "state.db.pre-column-drop.\(s)")
        }
        let deleted = DatabaseSnapshotPruner.prune(databasePath: "\(dir)/state.db")
        #expect(deleted == 4)
        let kept = Set(stamps(5).suffix(3))
        for kind in ["pre-migration", "pre-column-drop"] {
            let remaining = names(dir).filter { $0.contains(".\(kind).") }
            #expect(remaining == Set(kept.map { "state.db.\(kind).\($0)" }))
        }
    }

    @Test func ignoresNamesThatAreNotExactCopies() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var untouched: [String] = ["state.db", "state.db-wal", "state.db.bak", "state.db.backup-by-hand"]
        for s in stamps(5) {
            untouched.append("state.db.pre-migration.\(s)-wal")
            untouched.append("state.db.pre-migration.\(s).bak")
            untouched.append("other.db.pre-migration.\(s)")
            untouched.append("xstate.db.pre-migration.\(s)")
            untouched.append("state.db.pre-migration.\(s)Z")
        }
        for n in untouched { touch(dir, n) }
        let deleted = DatabaseSnapshotPruner.prune(databasePath: "\(dir)/state.db")
        #expect(deleted == 0)
        #expect(names(dir) == Set(untouched))
    }

    @Test func ordersByNameNotFileDate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let all = stamps(5)
        for (i, s) in all.enumerated() {
            let name = "state.db.pre-migration.\(s)"
            touch(dir, name)
            // Oldest name gets the newest file date.
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(all.count - i) * 1000)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: "\(dir)/\(name)")
        }
        DatabaseSnapshotPruner.prune(databasePath: "\(dir)/state.db")
        #expect(names(dir) == Set(all.suffix(3).map { "state.db.pre-migration.\($0)" }))
    }

    @Test func derivesPatternFromDatabaseFileName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for s in stamps(5) {
            touch(dir, "custom.db.pre-migration.\(s)")
            touch(dir, "state.db.pre-migration.\(s)")
        }
        DatabaseSnapshotPruner.prune(databasePath: "\(dir)/custom.db")
        #expect(names(dir).filter { $0.hasPrefix("custom.db.") }
            == Set(stamps(5).suffix(3).map { "custom.db.pre-migration.\($0)" }))
        #expect(names(dir).filter { $0.hasPrefix("state.db.") }
            == Set(stamps(5).map { "state.db.pre-migration.\($0)" }))
    }

    /// The database name is matched literally: its `.` is not a wildcard.
    @Test func escapesTheDatabaseFileName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lookalikes = stamps(5).map { "stateXdb.pre-migration.\($0)" }
        for n in lookalikes { touch(dir, n) }
        let deleted = DatabaseSnapshotPruner.prune(databasePath: "\(dir)/state.db")
        #expect(deleted == 0)
        #expect(names(dir) == Set(lookalikes))
    }

    /// The whole name must match: a trailing newline is not the end of the
    /// name, and a stamp in other scripts' digits is not TBD's stamp.
    @Test func rejectsATrailingNewlineAndNonASCIIDigits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var untouched: [String] = []
        for s in stamps(5) {
            untouched.append("state.db.pre-migration.\(s)\n")
            untouched.append("state.db.pre-column-drop.\(Self.arabicIndicDigits(s))")
        }
        for n in untouched { touch(dir, n) }
        #expect(names(dir) == Set(untouched))
        let deleted = DatabaseSnapshotPruner.prune(databasePath: "\(dir)/state.db")
        #expect(deleted == 0)
        #expect(names(dir) == Set(untouched))
    }

    /// The copy the caller just wrote survives even when a clock running
    /// behind gives it the oldest stamp. It takes one of the three kept
    /// places, and the newest of the rest fill the others.
    @Test func neverDeletesTheProtectedCopy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for s in stamps(5) { touch(dir, "state.db.pre-migration.\(s)") }
        let justWritten = "state.db.pre-migration.20250101T120000Z"
        touch(dir, justWritten)
        let deleted = DatabaseSnapshotPruner.prune(
            databasePath: "\(dir)/state.db", protecting: ["\(dir)/\(justWritten)"])
        #expect(deleted == 3)
        #expect(names(dir) == Set([justWritten] + stamps(5).suffix(2).map { "state.db.pre-migration.\($0)" }))
    }

    @Test func continuesPastAFailedDelete() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for s in stamps(6) { touch(dir, "state.db.pre-migration.\(s)") }
        let stuck = "state.db.pre-migration.\(stamps(6)[0])"
        let fm = FailingRemoveFileManager(failing: "\(dir)/\(stuck)")
        let deleted = DatabaseSnapshotPruner.prune(databasePath: "\(dir)/state.db", fileManager: fm)
        // Three are over the limit; one cannot be deleted, the other two are.
        #expect(deleted == 2)
        #expect(names(dir).contains(stuck))
        #expect(names(dir).count == 4)
    }

    /// Startup prunes the pre-migration copies only. The pre-column-drop
    /// copies are `RetiredColumnReconciler`'s to prune, after a run in which
    /// nothing failed.
    @Test func databaseInitPrunesBacklog() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // First open creates and fully migrates the database.
        _ = try openDatabase(dir)
        let before = names(dir).filter { $0.contains(".pre-migration.") }
        #expect(before.isEmpty)
        for s in stamps(5) {
            touch(dir, "state.db.pre-migration.\(s)")
            touch(dir, "state.db.pre-column-drop.\(s)")
        }
        // Reopen: no pending migration, but the file existed.
        _ = try openDatabase(dir)
        let after = names(dir).filter { $0.contains(".pre-migration.") }
        #expect(after == Set(stamps(5).suffix(3).map { "state.db.pre-migration.\($0)" }))
        let columnDrop = names(dir).filter { $0.contains(".pre-column-drop.") }
        #expect(columnDrop == Set(stamps(5).map { "state.db.pre-column-drop.\($0)" }))
    }

    /// A start whose migration fails prunes nothing. The daemon is relaunched
    /// until it comes up, each start writing another copy of the
    /// half-migrated database, and pruning then would push out the clean copy
    /// taken before the upgrade.
    @Test func aFailedMigrationLeavesEveryCopy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            let db = try openDatabase(dir)
            // Forget that `v1` ran. Re-running it creates `repo`, which
            // already exists, so the next open fails its migration.
            try db.writerForTests.write { conn in
                try conn.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v1'")
            }
        }
        let seeded = Set(stamps(5).map { "state.db.pre-migration.\($0)" })
        for n in seeded { touch(dir, n) }

        #expect(throws: (any Error).self) {
            _ = try openDatabase(dir)
        }

        let after = names(dir).filter { $0.contains(".pre-migration.") }
        #expect(after.isSuperset(of: seeded))
        // The failed start still wrote its own copy before migrating.
        #expect(after.count == seeded.count + 1)
    }

    /// Startup never deletes the copy it just wrote, even when every older
    /// copy carries a later stamp, as when the clock runs behind.
    @Test func databaseInitKeepsTheCopyItJustWrote() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            let db = try openDatabase(dir)
            // Forget the newest migration so the next open has one pending.
            // Migrations are idempotent, so re-running it succeeds.
            let newest = try #require(TBDDatabase.buildMigratorForTests().migrations.last)
            try db.writerForTests.write { conn in
                try conn.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [newest])
            }
        }
        let future = (1...5).map { String(format: "209901%02dT120000Z", $0) }
        let seeded = Set(future.map { "state.db.pre-migration.\($0)" })
        for n in seeded { touch(dir, n) }

        _ = try openDatabase(dir)

        let after = names(dir).filter { $0.contains(".pre-migration.") }
        #expect(after.count == DatabaseSnapshotPruner.keepPerKind)
        #expect(after.subtracting(seeded).count == 1)
        #expect(after.intersection(seeded) == Set(future.suffix(2).map { "state.db.pre-migration.\($0)" }))
    }

    // MARK: - Helpers

    private func openDatabase(_ dir: String) throws -> TBDDatabase {
        try TBDDatabase(path: "\(dir)/state.db", notesDir: "\(dir)/notes", terminalHistoryDir: "\(dir)/history")
    }

    /// `stamp` with each ASCII digit replaced by its Arabic-Indic counterpart,
    /// which `\d` would match and `[0-9]` does not.
    private static func arabicIndicDigits(_ stamp: String) -> String {
        String(stamp.map { ch -> Character in
            guard ch.isASCII, let digit = ch.wholeNumberValue,
                  let scalar = Unicode.Scalar(0x0660 + UInt32(digit))
            else { return ch }
            return Character(scalar)
        })
    }
}

/// A `FileManager` that refuses to remove one path, to exercise the skip.
private final class FailingRemoveFileManager: FileManager, @unchecked Sendable {
    let failing: String
    init(failing: String) {
        self.failing = failing
        super.init()
    }
    override func removeItem(atPath path: String) throws {
        if path == failing {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(atPath: path)
    }
}
