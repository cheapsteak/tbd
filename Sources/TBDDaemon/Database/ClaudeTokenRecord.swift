import Foundation
import GRDB
import TBDShared

struct ClaudeTokenRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "claude_tokens"

    var id: String
    var name: String
    var keychain_ref: String
    var kind: String
    var created_at: Date
    var last_used_at: Date?

    init(from token: ClaudeToken) {
        self.id = token.id.uuidString
        self.name = token.name
        self.keychain_ref = token.id.uuidString
        self.kind = token.kind.rawValue
        self.created_at = token.createdAt
        self.last_used_at = token.lastUsedAt
    }

    func toModel() -> ClaudeToken {
        ClaudeToken(
            id: UUID(uuidString: id)!,
            name: name,
            kind: ClaudeTokenKind(rawValue: kind) ?? .oauth,
            createdAt: created_at,
            lastUsedAt: last_used_at
        )
    }
}

public struct ClaudeTokenStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(name: String, kind: ClaudeTokenKind) async throws -> ClaudeToken {
        let token = ClaudeToken(name: name, kind: kind)
        let record = ClaudeTokenRecord(from: token)
        try await writer.write { db in
            try record.insert(db)
        }
        return token
    }

    public func list() async throws -> [ClaudeToken] {
        try await writer.read { db in
            try ClaudeTokenRecord.fetchAll(db).map { $0.toModel() }
        }
    }

    public func get(id: UUID) async throws -> ClaudeToken? {
        try await writer.read { db in
            try ClaudeTokenRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    public func getByName(_ name: String) async throws -> ClaudeToken? {
        try await writer.read { db in
            try ClaudeTokenRecord
                .filter(Column("name") == name)
                .fetchOne(db)?
                .toModel()
        }
    }

    public func rename(id: UUID, name: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE claude_tokens SET name = ? WHERE id = ?",
                arguments: [name, id.uuidString]
            )
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try ClaudeTokenRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func touchLastUsed(id: UUID, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE claude_tokens SET last_used_at = ? WHERE id = ?",
                arguments: [date, id.uuidString]
            )
        }
    }
}
