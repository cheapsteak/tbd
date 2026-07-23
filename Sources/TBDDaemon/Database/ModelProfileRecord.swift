import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

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
    var sort_order: Int = 0

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
        self.sort_order = profile.sortOrder
    }

    /// Failable decode: skips (returns nil after a logged warning) rather than
    /// crashing when the primary key UUID fails to parse. `kind` already
    /// decodes safely via `?? .oauth`.
    func toModel() -> ModelProfile? {
        guard let uuid = UUID(uuidString: id) else {
            decodeLogger.warning("Skipping model_profiles row \(id, privacy: .public): malformed id")
            return nil
        }
        return ModelProfile(
            id: uuid,
            name: name,
            kind: CredentialKind(rawValue: kind) ?? .oauth,
            baseURL: base_url,
            model: model,
            awsRegion: aws_region,
            awsProfile: aws_profile,
            fallbackModels: Self.decodeFallbackModels(fallback_models),
            envOverrides: EnvOverridesCoding.decode(env_overrides),
            createdAt: created_at,
            lastUsedAt: last_used_at,
            sortOrder: sort_order
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

    /// Create a new model profile. Automatically assigns
    /// sortOrder = max(sortOrder) + 1 (profiles are global — no repoID scoping).
    public func create(name: String, kind: CredentialKind,
                       baseURL: String? = nil, model: String? = nil,
                       awsRegion: String? = nil, awsProfile: String? = nil,
                       fallbackModels: [String]? = nil) async throws -> ModelProfile {
        try await writer.write { db in
            let maxOrder = try Int.fetchOne(
                db, sql: "SELECT MAX(sort_order) FROM model_profiles"
            ) ?? 0
            let profile = ModelProfile(name: name, kind: kind, baseURL: baseURL, model: model,
                                       awsRegion: awsRegion, awsProfile: awsProfile,
                                       fallbackModels: fallbackModels, sortOrder: maxOrder + 1)
            let record = ModelProfileRecord(from: profile)
            try record.insert(db)
            return profile
        }
    }

    public func list() async throws -> [ModelProfile] {
        try await writer.read { db in
            try ModelProfileRecord
                .order(Column("sort_order"))
                .fetchAll(db).compactMap { $0.toModel() }
        }
    }

    /// Reorder model profiles. Only affects the profiles in the provided list;
    /// any other profile not in the list is pushed to sortOrder values after
    /// the reordered ones. Mirrors `WorktreeStore.reorder` — profiles are
    /// global, so there's no repo scoping.
    public func reorder(profileIDs: [UUID]) async throws {
        try await writer.write { db in
            for (index, profileID) in profileIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE model_profiles SET sort_order = ? WHERE id = ?",
                    arguments: [index, profileID.uuidString]
                )
            }
            // Push any profiles not in the provided list to after the reordered ones.
            let idStrings = profileIDs.map(\.uuidString)
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")
            let args: [any DatabaseValueConvertible] = [profileIDs.count] + idStrings
            try db.execute(
                sql: """
                    UPDATE model_profiles SET sort_order = ? + rowid
                    WHERE id NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(args)
            )
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
