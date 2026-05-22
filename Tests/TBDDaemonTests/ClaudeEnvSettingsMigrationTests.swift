import Testing
import GRDB
@testable import TBDDaemonLib

@Suite("v26 claude_env_settings migration")
struct ClaudeEnvSettingsMigrationTests {
    @Test("config table has claude_env_settings column")
    func columnExists() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.read { conn in
            let cols = try Row.fetchAll(conn, sql: "PRAGMA table_info(config)")
                .map { $0["name"] as String }
            #expect(cols.contains("claude_env_settings"))
        }
    }

    @Test("config defaults to empty env overrides")
    func defaultsEmpty() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides.isEmpty)
    }
}
