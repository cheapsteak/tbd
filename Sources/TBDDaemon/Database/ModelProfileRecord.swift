import Foundation
import GRDB
import TBDShared

struct ModelProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "model_profiles"

    var id: String
    var name: String
    var keychain_ref: String
    var kind: String
    var base_url: String?
    var model: String?
    var created_at: Date
    var last_used_at: Date?

    init(from profile: ModelProfile) {
        self.id = profile.id.uuidString
        self.name = profile.name
        self.keychain_ref = profile.id.uuidString
        self.kind = profile.kind.rawValue
        self.base_url = profile.baseURL
        self.model = profile.model
        self.created_at = profile.createdAt
        self.last_used_at = profile.lastUsedAt
    }

    func toModel() -> ModelProfile {
        ModelProfile(
            id: UUID(uuidString: id)!,
            name: name,
            kind: CredentialKind(rawValue: kind) ?? .oauth,
            baseURL: base_url,
            model: model,
            createdAt: created_at,
            lastUsedAt: last_used_at
        )
    }
}

public struct ModelProfileStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(name: String, kind: CredentialKind,
                       baseURL: String? = nil, model: String? = nil) async throws -> ModelProfile {
        let profile = ModelProfile(name: name, kind: kind, baseURL: baseURL, model: model)
        let record = ModelProfileRecord(from: profile)
        try await writer.write { db in
            try record.insert(db)
        }
        return profile
    }

    public func list() async throws -> [ModelProfile] {
        try await writer.read { db in
            try ModelProfileRecord.fetchAll(db).map { $0.toModel() }
        }
    }

    public func get(id: UUID) async throws -> ModelProfile? {
        try await writer.read { db in
            try ModelProfileRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    public func getByName(_ name: String) async throws -> ModelProfile? {
        try await writer.read { db in
            try ModelProfileRecord
                .filter(Column("name") == name)
                .fetchOne(db)?
                .toModel()
        }
    }

    public func rename(id: UUID, name: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE model_profiles SET name = ? WHERE id = ?",
                arguments: [name, id.uuidString]
            )
        }
    }

    /// Update the proxy fields. Pass nil to clear them.
    public func updateEndpoint(id: UUID, baseURL: String?, model: String?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE model_profiles SET base_url = ?, model = ? WHERE id = ?",
                arguments: [baseURL, model, id.uuidString]
            )
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try ModelProfileRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func touchLastUsed(id: UUID, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE model_profiles SET last_used_at = ? WHERE id = ?",
                arguments: [date, id.uuidString]
            )
        }
    }
}
