import Foundation
import GRDB

public struct TBDMetaStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func getString(key: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM tbd_meta WHERE key = ?", arguments: [key])
        }
    }

    public func setString(key: String, value: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO tbd_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    public func getInt(key: String) async throws -> Int? {
        guard let s = try await getString(key: key) else { return nil }
        return Int(s)
    }

    public func setInt(key: String, value: Int) async throws {
        try await setString(key: key, value: String(value))
    }
}
