import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib

@Suite("Pre-migration snapshot")
struct PreMigrationSnapshotTests {

    @Test func snapshotWritesAFileWithTheSourceContents() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let dbPath = "\(tempDir)/state.db"
        let pool = try DatabasePool(path: dbPath)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE marker (id INTEGER PRIMARY KEY, note TEXT)")
            try db.execute(sql: "INSERT INTO marker (note) VALUES ('hello')")
        }

        let before = snapshotFiles(in: tempDir)
        TBDDatabase.takePreMigrationSnapshot(pool: pool, path: dbPath)
        let after = snapshotFiles(in: tempDir)

        let newSnapshots = after.subtracting(before)
        #expect(newSnapshots.count == 1, "Expected exactly one new snapshot file")

        let snapshotPath = "\(tempDir)/\(newSnapshots.first!)"
        let attrs = try FileManager.default.attributesOfItem(atPath: snapshotPath)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > 0, "Snapshot file should not be empty")

        // Open the snapshot and confirm the row round-trips — this is the proof
        // that VACUUM INTO actually ran (not just `touch`ed a file).
        let snapshotQueue = try DatabaseQueue(path: snapshotPath)
        let note: String? = try snapshotQueue.read { db in
            try String.fetchOne(db, sql: "SELECT note FROM marker WHERE id = 1")
        }
        #expect(note == "hello")
    }

    @Test func snapshotFilenameUsesUtcTimestampFormat() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let dbPath = "\(tempDir)/state.db"
        let pool = try DatabasePool(path: dbPath)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)")
        }

        TBDDatabase.takePreMigrationSnapshot(pool: pool, path: dbPath)
        let snapshots = snapshotFiles(in: tempDir)
        #expect(snapshots.count == 1)

        let name = snapshots.first ?? ""
        // Format: state.db.pre-migration.YYYYMMDD'T'HHMMSS'Z'
        let pattern = #"^state\.db\.pre-migration\.\d{8}T\d{6}Z$"#
        let match = name.range(of: pattern, options: .regularExpression) != nil
        #expect(match, "Snapshot filename '\(name)' did not match expected timestamp format")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory().appending("tbd-snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func snapshotFiles(in dir: String) -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return Set(entries.filter { $0.contains(".pre-migration.") })
    }
}
