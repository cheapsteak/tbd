import Foundation
import GRDB
import TBDShared

struct ConfigRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "config"

    var id: String
    var default_claude_token_id: String?

    func toModel() -> Config {
        Config(
            defaultClaudeTokenID: default_claude_token_id.flatMap(UUID.init(uuidString:))
        )
    }
}

public struct ConfigStore: Sendable {
    static let singletonID = "singleton"
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func get() async throws -> Config {
        try await writer.read { db in
            try ConfigRecord.fetchOne(db, key: Self.singletonID)?.toModel() ?? Config()
        }
    }

    public func setDefaultClaudeTokenID(_ id: UUID?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET default_claude_token_id = ? WHERE id = ?",
                arguments: [id?.uuidString, Self.singletonID]
            )
        }
    }
}
