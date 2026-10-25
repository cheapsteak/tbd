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
        #expect(names(dir).filter { $0.hasPrefix("custom.db.") }.count == 3)
        #expect(names(dir).filter { $0.hasPrefix("state.db.") }.count == 5)
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

    @Test func databaseInitPrunesBacklog() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dbPath = "\(dir)/state.db"
        // First open creates and fully migrates the database.
        _ = try TBDDatabase(path: dbPath, notesDir: "\(dir)/notes", terminalHistoryDir: "\(dir)/history")
        let before = names(dir).filter { $0.contains(".pre-migration.") }
        #expect(before.isEmpty)
        for s in stamps(5) { touch(dir, "state.db.pre-migration.\(s)") }
        // Reopen: no pending migration, but the file existed.
        _ = try TBDDatabase(path: dbPath, notesDir: "\(dir)/notes", terminalHistoryDir: "\(dir)/history")
        let after = names(dir).filter { $0.contains(".pre-migration.") }
        #expect(after == Set(stamps(5).suffix(3).map { "state.db.pre-migration.\($0)" }))
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
