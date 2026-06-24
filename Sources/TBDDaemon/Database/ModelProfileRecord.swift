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
    var aws_region: String?
    var aws_profile: String?
    /// JSON-encoded `[String]` (the profile's ordered fallback model ids), or
    /// nil when no fallback is configured. Stored as text so the array survives
    /// a single column.
    var fallback_models: String?
    /// JSON-encoded `[String: String]` free-form env overrides (profile scope).
    var env_overrides: String?
    var created_at: Date
    var last_used_at: Date?

    init(from profile: ModelProfile) {
        self.id = profile.id.uuidString
        self.name = profile.name
        self.keychain_ref = profile.id.uuidString
        self.kind = profile.kind.rawValue
        self.base_url = profile.baseURL
        self.model = profile.model
        self.aws_region = profile.awsRegion
        self.aws_profile = profile.awsProfile
        self.fallback_models = Self.encodeFallbackModels(profile.fallbackModels)
        self.env_overrides = EnvOverridesCoding.encode(profile.envOverrides)
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
            awsRegion: aws_region,
            awsProfile: aws_profile,
            fallbackModels: Self.decodeFallbackModels(fallback_models),
            envOverrides: EnvOverridesCoding.decode(env_overrides),
            createdAt: created_at,
            lastUsedAt: last_used_at
        )
    }

    /// Encode the fallback list to JSON text. Returns nil for nil/empty so the
    /// column stays NULL and `toModel()` round-trips back to nil.
    static func encodeFallbackModels(_ models: [String]?) -> String? {
        guard let models, !models.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(models) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode the JSON-text fallback list. nil/empty/invalid → nil.
    static func decodeFallbackModels(_ text: String?) -> [String]? {
        guard let text, let data = text.data(using: .utf8),
              let models = try? JSONDecoder().decode([String].self, from: data),
              !models.isEmpty else { return nil }
        return models
    }
}

public struct ModelProfileStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func create(name: String, kind: CredentialKind,
                       baseURL: String? = nil, model: String? = nil,
                       awsRegion: String? = nil, awsProfile: String? = nil,
                       fallbackModels: [String]? = nil) async throws -> ModelProfile {
        let profile = ModelProfile(name: name, kind: kind, baseURL: baseURL, model: model,
                                   awsRegion: awsRegion, awsProfile: awsProfile,
                                   fallbackModels: fallbackModels)
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

    /// Update the proxy fields. Pass nil to clear them. `fallbackModels`
    /// nil/empty clears the stored list (column set to NULL).
    public func updateEndpoint(id: UUID, baseURL: String?, model: String?,
                               fallbackModels: [String]? = nil) async throws {
        let fallbackJSON = ModelProfileRecord.encodeFallbackModels(fallbackModels)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE model_profiles SET base_url = ?, model = ?, fallback_models = ? WHERE id = ?",
                arguments: [baseURL, model, fallbackJSON, id.uuidString]
            )
        }
    }

    /// Update the bedrock-specific fields on an existing profile. Pass
    /// `awsProfile == nil` to clear (use AWS SDK default chain).
    /// `fallbackModels` nil/empty clears the stored list (column set to NULL).
    public func updateBedrock(id: UUID, awsRegion: String, awsProfile: String?, model: String,
                              fallbackModels: [String]? = nil) async throws {
        let fallbackJSON = ModelProfileRecord.encodeFallbackModels(fallbackModels)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE model_profiles SET aws_region = ?, aws_profile = ?, model = ?, fallback_models = ? WHERE id = ?",
                arguments: [awsRegion, awsProfile, model, fallbackJSON, id.uuidString]
            )
        }
    }

    /// Set or clear the per-profile free-form env overrides.
    public func setEnvOverrides(id: UUID, overrides: [String: String]) async throws {
        let json = EnvOverridesCoding.encode(overrides)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE model_profiles SET env_overrides = ? WHERE id = ?",
                arguments: [json, id.uuidString]
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
