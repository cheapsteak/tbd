import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib

@Suite struct MigrationV18Tests {

    @Test func createsChannelIndexTable() throws {
        let dbPath = NSTemporaryDirectory() + "tbd-v18-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let db = try TBDDatabase(path: dbPath)
        try db.writerForTests.read { db in
            let exists = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type='table' AND name='channel_index'
                """)
            #expect(exists == true)

            // Verify columns
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info('channel_index')")
            let names = Set(cols.compactMap { $0["name"] as String? })
            #expect(names == ["name", "createdAt", "lastMessageAt", "messageCount"])
        }
    }
}
