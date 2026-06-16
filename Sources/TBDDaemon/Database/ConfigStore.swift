import Foundation
import GRDB
import os
import TBDShared

private let configLogger = Logger(subsystem: "com.tbd.daemon", category: "config")

struct ConfigRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "config"

    var id: String
    var default_profile_id: String?
    var primary_agent_preference: String?
    /// JSON-encoded `[String: ClaudeEnvValue]` overrides map. Nil/absent
    /// means no overrides — every setting falls back to its registry default.
    var claude_env_settings: String?
    /// JSON-encoded `[String: String]` free-form env overrides (global scope).
    var env_overrides: String?

    func toModel() -> Config {
        Config(
            defaultProfileID: default_profile_id.flatMap(UUID.init(uuidString:)),
            primaryAgentPreference: primary_agent_preference
                .flatMap(PrimaryAgentPreference.init(rawValue:)) ?? .defaultValue,
            envSettingOverrides: ConfigStore.decodeOverrides(claude_env_settings),
            envOverrides: EnvOverridesCoding.decode(env_overrides)
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

    /// Decode the `claude_env_settings` JSON column into an overrides map.
    /// Any malformed/absent value decodes to an empty map so a corrupt row
    /// degrades to registry defaults rather than crashing a spawn. A genuinely
    /// corrupt row (JSON present but undecodable) is logged so it's observable
    /// via `log stream` instead of silently resetting the user's settings.
    static func decodeOverrides(_ json: String?) -> [String: ClaudeEnvValue] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ClaudeEnvValue].self, from: data)
        } catch {
            configLogger.error(
                "Corrupt claude_env_settings row, falling back to defaults: \(String(describing: error), privacy: .public)"
            )
            return [:]
        }
    }

    public func setDefaultProfileID(_ id: UUID?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET default_profile_id = ? WHERE id = ?",
                arguments: [id?.uuidString, Self.singletonID]
            )
        }
    }

    public func setPrimaryAgentPreference(_ preference: PrimaryAgentPreference) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET primary_agent_preference = ? WHERE id = ?",
                arguments: [preference.rawValue, Self.singletonID]
            )
        }
    }

    /// Persist the Claude spawn-env setting overrides map. An empty map
    /// clears all overrides; spawns then use every setting's registry default.
    public func setEnvSettingOverrides(_ overrides: [String: ClaudeEnvValue]) async throws {
        let json = String(data: try JSONEncoder().encode(overrides), encoding: .utf8)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET claude_env_settings = ? WHERE id = ?",
                arguments: [json, Self.singletonID]
            )
        }
    }

    /// Persist the global free-form env overrides. Empty clears the column.
    public func setEnvOverrides(_ overrides: [String: String]) async throws {
        let json = EnvOverridesCoding.encode(overrides)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE config SET env_overrides = ? WHERE id = ?",
                arguments: [json, Self.singletonID]
            )
        }
    }
}
